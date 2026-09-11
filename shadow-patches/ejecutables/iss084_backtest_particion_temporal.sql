-- iss084 — BACKTEST CON PARTICIÓN TEMPORAL + MODELO SOBREDISPERSO — EJECUTABLE
-- Recaptura del 11-sep-2026. Reemplaza a prepared/iss084_*.sql (sólo prosa).
--
-- POR QUÉ NO SE PUEDE LLAMAR AL MOTOR SOBRE PARTIDOS VIEJOS
-- motor_mlb(p_home, p_away, p_meses, ...) usa "últimos N meses" contado DESDE
-- HOY. Un partido de 2024 se alimentaría con datos de 2026. El backtest saldría
-- bonito y falso. Aquí se reimplementa la lógica exacta con corte por partido
-- usando ventanas RANGE ... '1 day' PRECEDING: ningún partido ve jamás un
-- resultado posterior ni el suyo propio.
--
-- ATAJO EXACTO: la suma de dos Poisson independientes es Poisson(l1+l2), así
-- que los totales salen de una CDF 1-D en vez de la rejilla 26x26 del motor.
--
-- ADVERTENCIA DEL AUDITOR, VIGENTE (comentario 5639091011):
--   - Sólo se prueban líneas .5. Una línea ENTERA (Over 8) puede hacer PUSH y
--     NO puede calibrarse con evidencia de Over 8.5. Pendiente.
--   - La curva de calibración resultante es IN-SAMPLE. Pendiente la validación
--     temporal independiente (train -> test).
--   - NFL totals debe quedar MODEL_REJECTED por política, no rescatarse.
--   Este archivo reproduce lo que se ejecutó; NO afirma que cierre el NO-PASS.

-- ---------------------------------------------------------------------------
-- 1) deporte en la fuente de calibración
-- ---------------------------------------------------------------------------
alter table public.modelo_backtest add column if not exists deporte text;
update public.modelo_backtest set deporte='soccer' where deporte is null;
alter table public.modelo_backtest alter column deporte set default 'soccer';
alter table public.modelo_backtest alter column deporte set not null;
create index if not exists idx_mb_deporte_mercado on public.modelo_backtest(deporte, mercado);
create index if not exists idx_hpe_bb_fecha on public.historico_partidos_espn(fecha) where home_score is not null;

-- ---------------------------------------------------------------------------
-- 2) Normal estándar (A&S 26.2.17). Hace falta porque los totales están
--    SOBREDISPERSOS: Poisson asume sd=sqrt(lambda) y la real es ~2x eso.
--      NFL: sd real 13.83 contra 6.79 que asume Poisson.
--      MLB: sd real  4.60 contra 3.03 que asume Poisson.
-- ---------------------------------------------------------------------------
create or replace function public.normal_cdf(z double precision)
returns double precision language sql immutable as $$
  select case when z < 0 then 1 - public.normal_cdf(-z) else
    1 - (exp(-z*z/2)/sqrt(2*pi())) * (
        0.319381530*t - 0.356563782*t*t + 1.781477937*t*t*t
      - 1.821255978*t*t*t*t + 1.330274429*t*t*t*t*t)
  end
  from (select 1.0/(1.0 + 0.2316419*abs(z)) t) q;
$$;

create table if not exists public.dispersion_totales (
  deporte text primary key,
  sd_real numeric not null,
  sd_que_asume_poisson numeric,
  sesgo numeric,
  n_juegos int,
  brier_poisson numeric,
  brier_normal numeric,
  medido_at timestamptz default now(),
  nota text
);
comment on table public.dispersion_totales is
  'Desviacion REAL del total de un partido contra la lambda del motor. Poisson asume sd=sqrt(lambda); en la realidad los totales estan SOBREDISPERSOS y por eso el motor salia sobreconfiado. Medido con backtest de particion temporal y validado fuera de muestra.';

insert into public.dispersion_totales (deporte, sd_real, sd_que_asume_poisson, sesgo, n_juegos, brier_poisson, brier_normal, nota)
values
 ('football', 13.83, 6.79, -0.90, 1443, 0.24523, 0.22834,
  'Validado fuera de muestra: sd estimada solo con partidos previos a 2025 (13.80), probada en 314 juegos de 2025+. Poisson 0.24523 -> Normal 0.22834, contra 0.25 de un volado. n = PARTIDOS, no filas.'),
 ('baseball', 4.60, 3.03, -0.10, 6022, 0.25003, 0.24532,
  'Validado fuera de muestra: sd estimada antes de jun-2025 (4.50), probada en 2,390 juegos posteriores. Poisson 0.25003 -> Normal 0.24532, contra 0.25 de un volado. La mejora es real pero chica. n = PARTIDOS, no filas.')
on conflict (deporte) do update set
  sd_real=excluded.sd_real, sd_que_asume_poisson=excluded.sd_que_asume_poisson,
  sesgo=excluded.sesgo, n_juegos=excluded.n_juegos, brier_poisson=excluded.brier_poisson,
  brier_normal=excluded.brier_normal, medido_at=now(), nota=excluded.nota;

create or replace function public.prob_total_sobre(p_lambda numeric, p_linea numeric, p_deporte text)
returns numeric language sql stable as $$
  -- P(total > linea) con la desviacion MEDIDA del deporte, no la que asume Poisson.
  select case when p_lambda is null or p_linea is null then null else
    round((1 - public.normal_cdf(
      ((p_linea - p_lambda) / nullif(d.sd_real,0))::double precision))::numeric, 4)
  end
  from public.dispersion_totales d where d.deporte = p_deporte;
$$;
grant execute on function public.prob_total_sobre(numeric,numeric,text) to anon, authenticated, service_role;
grant select on public.dispersion_totales to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) motor_mlb: los totales dejan de salir de la rejilla Poisson (sd=3.03) y
--    pasan a la Normal sobredispersa (sd=4.60). gana_local/gana_visita NO se
--    tocan: siguen saliendo de la rejilla.
--    Con lambda=7.58, under_85 pasó de ~65% a 57.9%.
-- ---------------------------------------------------------------------------
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.motor_mlb'::regproc);
  a := '    ''over_75'',  round((100*sum(pr) filter (where ch+ca > 7.5))::numeric,1),' || E'\n'
    || '    ''over_85'',  round((100*sum(pr) filter (where ch+ca > 8.5))::numeric,1),' || E'\n'
    || '    ''over_95'',  round((100*sum(pr) filter (where ch+ca > 9.5))::numeric,1),' || E'\n'
    || '    ''over_105'', round((100*sum(pr) filter (where ch+ca > 10.5))::numeric,1),' || E'\n'
    || '    ''under_75'', round((100*sum(pr) filter (where ch+ca < 7.5))::numeric,1),' || E'\n'
    || '    ''under_85'', round((100*sum(pr) filter (where ch+ca < 8.5))::numeric,1),' || E'\n'
    || '    ''under_95'', round((100*sum(pr) filter (where ch+ca < 9.5))::numeric,1),';
  b := '    ''over_75'',  round(100*public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 7.5,  ''baseball''),1),' || E'\n'
    || '    ''over_85'',  round(100*public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 8.5,  ''baseball''),1),' || E'\n'
    || '    ''over_95'',  round(100*public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 9.5,  ''baseball''),1),' || E'\n'
    || '    ''over_105'', round(100*public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 10.5, ''baseball''),1),' || E'\n'
    || '    ''under_75'', round(100*(1-public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 7.5, ''baseball'')),1),' || E'\n'
    || '    ''under_85'', round(100*(1-public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 8.5, ''baseball'')),1),' || E'\n'
    || '    ''under_95'', round(100*(1-public.prob_total_sobre((v_lam_l+v_lam_v)::numeric, 9.5, ''baseball'')),1),';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss084.3 bloque de totales no unico'; end if;
  execute replace(v,a,b);
end $$;

-- ---------------------------------------------------------------------------
-- 4) Tablas de backtest (detalle partido por partido, para poder auditar)
-- ---------------------------------------------------------------------------
create table if not exists public.backtest_mlb_totales (
  espn_event_id text, fecha timestamptz, total int, lam double precision,
  muestra int, linea numeric, lado text, prob double precision, acerto boolean);
create table if not exists public.backtest_nfl_totales (
  espn_event_id text, fecha timestamptz, total int, lam double precision,
  muestra int, linea numeric, lado text, prob double precision, acerto boolean);
create table if not exists public.backtest_ml (
  deporte text, espn_event_id text, fecha timestamptz,
  lam_l double precision, lam_v double precision, muestra int,
  prob_local double precision, gano_local boolean);

comment on table public.backtest_mlb_totales is 'Backtest con particion temporal del motor de totales de MLB. Cada partido solo ve juegos ANTERIORES (24 meses por equipo, base de liga 30 dias). OJO: 8 filas por partido (4 lineas x 2 lados). Contar partidos con count(distinct espn_event_id).';
comment on table public.backtest_nfl_totales is 'Igual para NFL (36 meses, base 120 dias, encogimiento n/(n+8)). Poisson NO modela los puntos de NFL (un touchdown vale 7); por eso se sustituyo por la Normal sobredispersa. OJO: 10 filas por partido.';
comment on table public.backtest_ml is 'Backtest con particion temporal de la LINEA DE GANADOR. P(local) = sum_k P(visita=k)*P(local>k) + 0.5*P(empate), igual que motor_mlb reparte los empates. 1 fila por partido.';

-- ---------------------------------------------------------------------------
-- 5) Poblado. Ver reconstruir_backtests.sql para las consultas completas
--    (van aparte porque cada una tarda ~50s y conviene correrlas sueltas).
-- ---------------------------------------------------------------------------

-- FIN iss084.
