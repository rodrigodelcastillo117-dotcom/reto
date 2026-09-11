-- iss086 — CALIBRATION RELEASE V1 · ESQUEMA VERSIONADO
-- Orden del dueño (issue #4, comentario 5640472806). Reglas duras:
--   · calibradores versionados por deporte + mercado + model_version + calibration_version
--   · métricas por PARTIDOS INDEPENDIENTES
--   · nada de contar Over y Under como dos eventos
--   · líneas enteras con WIN/PUSH/LOSS
--   · walk-forward temporal + holdout final
--   · Soccer 1X2 multiclase (Home+Draw+Away = 100%)
--   · NFL Poisson totals sigue MODEL_REJECTED
--   · el Normal sobredisperso es un CHALLENGER NUEVO, no "calibración" del malo
--   · cero EV / Kelly / disagreement en el camino de decisión

-- ===========================================================================
-- 1) REGISTRO DE MODELOS. Sin esto la calibración mezcla versiones, que es
--    justo lo que el auditor marcó como inaceptable.
-- ===========================================================================
create table if not exists public.modelo_registry (
  model_version   text primary key,
  deporte         text not null,
  mercado         text not null,
  familia         text,                    -- 'poisson', 'normal_sobredisperso', ...
  estado          text not null check (estado in ('CHALLENGER','PRODUCCION','MODEL_REJECTED','RETIRADO')),
  motivo_estado   text not null,
  evidencia       text,
  creado_at       timestamptz not null default now(),
  actualizado_at  timestamptz not null default now()
);
comment on table public.modelo_registry is
  'Un modelo = (deporte, mercado, familia, version). MODEL_REJECTED significa que el modelo NO tiene senal y NO se rescata con una curva de calibracion.';

-- ===========================================================================
-- 2) EVENTOS DE BACKTEST. La unidad es (partido, mercado, linea).
--    NUNCA (partido, linea, lado): un Over y su Under son el MISMO evento.
--    El lado canonico es siempre el "positivo" (Over / gana local).
-- ===========================================================================
create table if not exists public.calib_eventos (
  id               bigserial primary key,
  model_version    text not null references public.modelo_registry(model_version),
  deporte          text not null,
  mercado          text not null,
  espn_event_id    text not null,
  fecha_partido    timestamptz not null,
  -- hasta que momento vio datos el modelo. Si feature_cutoff >= fecha_partido
  -- hay fuga temporal y el evento es invalido.
  feature_cutoff   timestamptz not null,
  linea            numeric,
  linea_entera     boolean generated always as (linea is not null and linea = trunc(linea)) stored,
  -- BINARIO: probabilidad del lado canonico
  p_raw            numeric check (p_raw is null or (p_raw > 0 and p_raw < 1)),
  resultado        text check (resultado in ('WIN','PUSH','LOSS')),
  -- MULTICLASE (1X2): {"home":..,"draw":..,"away":..}, deben sumar 1
  p_raw_multi      jsonb,
  clase_real       text check (clase_real in ('home','draw','away')),
  n_muestra_modelo int,
  constraint calib_evento_unico unique (model_version, mercado, espn_event_id, linea),
  constraint calib_evento_tiene_prediccion check (p_raw is not null or p_raw_multi is not null),
  constraint calib_evento_sin_fuga check (feature_cutoff < fecha_partido)
);
create index if not exists idx_calib_ev_modelo_fecha on public.calib_eventos(model_version, fecha_partido);
comment on table public.calib_eventos is
  'Un evento = un (partido, mercado, linea). Over y Under NO son dos eventos. El check calib_evento_sin_fuga impide por construccion que un evento use datos posteriores al saque.';
comment on column public.calib_eventos.resultado is
  'WIN/PUSH/LOSS del lado canonico. Las lineas ENTERAS pueden hacer PUSH: el total cae exacto en la linea y la apuesta es nula. Los PUSH se EXCLUYEN de Brier/LogLoss/ECE y se reportan aparte.';

-- ===========================================================================
-- 3) CALIBRADORES VERSIONADOS + su evaluacion
-- ===========================================================================
create table if not exists public.calibradores (
  calibration_version text not null,
  model_version       text not null references public.modelo_registry(model_version),
  deporte             text not null,
  mercado             text not null,
  metodo              text not null check (metodo in ('identity','platt','isotonic','multiclase_dirichlet')),
  params              jsonb,
  -- ventanas, separadas temporalmente
  train_desde         timestamptz not null,
  train_hasta         timestamptz not null,
  test_desde          timestamptz not null,
  test_hasta          timestamptz not null,
  -- conteos: eventos Y partidos independientes, siempre los dos
  n_train_eventos     int not null,
  n_train_partidos    int not null,
  n_test_eventos      int not null,
  n_test_partidos     int not null,
  n_push              int not null default 0,
  -- metricas fuera de muestra
  brier_raw           numeric, brier_cal   numeric,
  logloss_raw         numeric, logloss_cal numeric,
  ece_raw             numeric, ece_cal     numeric,
  temporal_violations int not null,
  mejora_oos          boolean not null,
  elegido             boolean not null default false,
  motivo              text not null,
  creado_at           timestamptz not null default now(),
  primary key (calibration_version, model_version, mercado, metodo),
  constraint calib_ventanas_separadas check (train_hasta <= test_desde),
  constraint calib_sin_fuga_temporal  check (temporal_violations = 0)
);
comment on table public.calibradores is
  'Un calibrador por (deporte, mercado, model_version, calibration_version, metodo). Se guardan TAMBIEN los metodos rechazados, con su motivo: sin eso no se puede auditar por que se eligio el que se eligio. La restriccion calib_sin_fuga_temporal impide guardar un calibrador con fuga.';
comment on column public.calibradores.mejora_oos is
  'El calibrador le gana al RAW fuera de muestra. Si es false, la regla es P_CAL = P_RAW: no se usa la curva.';

-- ===========================================================================
-- 4) PREDICCIONES CONGELADAS — la garantia de replay
--    "Recalibrar manana NO puede cambiar las predicciones de ayer."
--    Se logra congelando la prediccion CON su model_version y
--    calibration_version en el momento de decidir. El replay LEE, no recalcula.
-- ===========================================================================
create table if not exists public.predicciones_congeladas (
  id                  bigserial primary key,
  espn_event_id       text not null,
  deporte             text not null,
  mercado             text not null,
  linea               numeric,
  decidido_at         timestamptz not null default now(),
  fecha_partido       timestamptz not null,
  model_version       text not null,
  calibration_version text not null,
  p_raw               numeric not null,
  p_cal               numeric not null,
  p_publicada         numeric not null,   -- la que vio el usuario
  resultado           text check (resultado in ('WIN','PUSH','LOSS')),
  liquidado_at        timestamptz,
  constraint pc_unica unique (espn_event_id, mercado, linea, decidido_at),
  constraint pc_antes_del_saque check (decidido_at < fecha_partido)
);
create index if not exists idx_pc_evento on public.predicciones_congeladas(espn_event_id, mercado);
comment on table public.predicciones_congeladas is
  'Cada prediccion publicada queda congelada con la version de modelo y de calibrador que la produjo. Recalibrar crea una calibration_version nueva y NO toca estas filas: por eso el historico de ayer no cambia. pc_antes_del_saque impide registrar una prediccion despues del partido.';

-- ===========================================================================
-- 5) Estado inicial del registro de modelos, con la evidencia ya medida
-- ===========================================================================
insert into public.modelo_registry (model_version, deporte, mercado, familia, estado, motivo_estado, evidencia) values
 ('mlb_totales_poisson_v1', 'baseball', 'Over/Under', 'poisson', 'MODEL_REJECTED',
  'Sobreconfiado: estira las probabilidades lejos del 50% y la realidad se queda cerca.',
  'Backtest con particion temporal, 6,022 partidos independientes 2023-2026: dice 65.0% y entrega 58.5%; dice 83.2% y entrega 64.1%. Brier por tramo entre 0.2466 y 0.2684 contra 0.25 de un volado.'),
 ('mlb_totales_normal_v1', 'baseball', 'Over/Under', 'normal_sobredisperso', 'CHALLENGER',
  'Modelo NUEVO, no es una curva encima del Poisson. Pendiente de auditoria antes de promover.',
  'La desviacion real del total contra la lambda es 4.60; Poisson asume sqrt(lambda)=3.03. Fuera de muestra (sd estimada antes de jun-2025, probada en 2,390 partidos posteriores): Poisson 0.25003 -> Normal 0.24532, contra 0.25 de un volado. Mejora real pero chica.'),
 ('nfl_totales_poisson_v1', 'football', 'Over/Under', 'poisson', 'MODEL_REJECTED',
  'Poisson no modela los puntos de NFL: un touchdown vale 7, no 1. No se rescata con una curva.',
  'Backtest con particion temporal, 1,443 partidos independientes: solo 2 de 10 tramos le ganan al volado, y por 0.0001. Infla hasta 23.7 puntos.'),
 ('nfl_totales_normal_v1', 'football', 'Over/Under', 'normal_sobredisperso', 'CHALLENGER',
  'Modelo NUEVO. El dueno autoriza promoverlo SOLO tras auditar temporalidad, conteo uno-por-partido, feature cutoff y model_version.',
  'La desviacion real es 13.83; Poisson asume 6.79, menos de la mitad. Fuera de muestra (sd estimada solo con partidos previos a 2025, probada en 314 partidos de 2025+): Poisson 0.24523 -> Normal 0.22834, contra 0.25 de un volado. Es el resultado que hay que re-auditar antes de promover.'),
 ('mlb_ml_poisson_v1', 'baseball', 'Moneyline', 'poisson', 'MODEL_REJECTED',
  'Sin habilidad: peor que un volado y peor que apostarle siempre al local.',
  'Backtest con particion temporal, 6,022 partidos independientes: Brier modelo 0.25056, volado 0.25000, tasa base 0.24952. Coincide con los 800 partidos de mlb_shadow_predicciones (0.24707) y con el 1-7 real publicado.'),
 ('nfl_ml_poisson_v1', 'football', 'Moneyline', 'poisson', 'MODEL_REJECTED',
  'Sin habilidad. NO confundir con el modelo dedicado nfl-2026.09.2, que es otra cosa y se audita aparte.',
  'Backtest con particion temporal, 1,443 partidos independientes: Brier modelo 0.25514, volado 0.25000, tasa base 0.24800.')
on conflict (model_version) do update set
  estado=excluded.estado, motivo_estado=excluded.motivo_estado,
  evidencia=excluded.evidencia, actualizado_at=now();

grant select on public.modelo_registry, public.calibradores, public.predicciones_congeladas
  to anon, authenticated, service_role;

-- FIN iss086.

-- ===========================================================================
-- 6) normal_cdf SIN recursion. La version recursiva costaba ~130k llamadas
--    anidadas al generar los eventos y se iba a timeout.
-- ===========================================================================
create or replace function public.normal_cdf(z double precision)
returns double precision language sql immutable parallel safe as $$
  select case when z >= 0 then 1 - k else k end
  from (
    select (exp(-a*a/2)/sqrt(2*pi())) * (
             0.319381530*t - 0.356563782*t*t + 1.781477937*t*t*t
           - 1.821255978*t*t*t*t + 1.330274429*t*t*t*t*t) as k
    from (select abs(z) a, 1.0/(1.0 + 0.2316419*abs(z)) t) q
  ) w;
$$;

-- ===========================================================================
-- 7) SIGMA RODANTE Y CAUSAL.
--    dispersion_totales media la sigma sobre TODA la historia: eso es un
--    parametro in-sample y cuenta como fuga. Aqui la sigma de cada partido se
--    estima SOLO con residuos de partidos ANTERIORES.
-- ===========================================================================
create table if not exists public.calib_lambda (
  deporte text not null, espn_event_id text not null, fecha timestamptz not null,
  total int not null, lam double precision not null, muestra int,
  sd_rodante double precision, n_resid int,
  primary key (deporte, espn_event_id)
);
comment on table public.calib_lambda is
  'Lambda del motor y sigma RODANTE por partido. Usar una sigma global seria un parametro in-sample y el auditor lo contaria como fuga.';
truncate public.calib_lambda;
insert into public.calib_lambda (deporte, espn_event_id, fecha, total, lam, muestra)
select distinct 'baseball', espn_event_id, fecha, total, lam, muestra from public.backtest_mlb_totales
union all
select distinct 'football', espn_event_id, fecha, total, lam, muestra from public.backtest_nfl_totales;

update public.calib_lambda c set sd_rodante = r.sd, n_resid = r.n
from (
  select deporte, espn_event_id,
         stddev_pop(total - lam) over w sd, count(*) over w n
  from public.calib_lambda
  window w as (partition by deporte order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)
) r
where r.deporte = c.deporte and r.espn_event_id = c.espn_event_id;

-- ===========================================================================
-- 8) EVENTOS: uno por (partido, linea), con WIN/PUSH/LOSS y correccion de
--    continuidad. Para linea ENTERA:
--      P(WIN)  = P(total >= linea+1) = 1 - Phi((linea + 0.5 - lam)/sd)
--      P(LOSS) = P(total <= linea-1) =     Phi((linea - 0.5 - lam)/sd)
--      P(PUSH) = 1 - P(WIN) - P(LOSS)
--      p_raw   = P(WIN | no PUSH) = P(WIN)/(P(WIN)+P(LOSS))
--    En lineas .5 el push es imposible y p_raw queda P(Over).
-- ===========================================================================
delete from public.calib_eventos where model_version in ('mlb_totales_normal_v1','nfl_totales_normal_v1');
insert into public.calib_eventos
  (model_version, deporte, mercado, espn_event_id, fecha_partido, feature_cutoff,
   linea, p_raw, resultado, n_muestra_modelo)
select
  case when c.deporte='baseball' then 'mlb_totales_normal_v1' else 'nfl_totales_normal_v1' end,
  c.deporte, 'Over/Under', c.espn_event_id, c.fecha,
  c.fecha - interval '1 day',
  q.linea,
  greatest(0.0001, least(0.9999, q.p_win / nullif(q.p_win + q.p_loss, 0))),
  case when c.total > q.linea then 'WIN' when c.total = q.linea then 'PUSH' else 'LOSS' end,
  c.muestra
from public.calib_lambda c
cross join lateral (
  select ln.linea,
         1 - public.normal_cdf(((ln.linea + 0.5 - c.lam) / c.sd_rodante)::double precision) as p_win,
         public.normal_cdf(((ln.linea - 0.5 - c.lam) / c.sd_rodante)::double precision)     as p_loss
  from unnest(case when c.deporte='baseball'
                   then array[7,7.5,8,8.5,9,9.5,10,10.5]::numeric[]
                   else array[37,37.5,40,40.5,43,43.5,46,46.5,49,49.5]::numeric[] end) ln(linea)
) q
where c.sd_rodante is not null and c.sd_rodante > 0 and c.n_resid >= 200
  and q.p_win + q.p_loss > 0;

-- ===========================================================================
-- 9) Platt por Newton-Raphson. Determinista: mismos datos -> mismos (a,b).
--    Los PUSH se EXCLUYEN: la apuesta es nula, no es acierto ni fallo.
-- ===========================================================================
create or replace function public.fit_platt(p_model text, p_desde timestamptz, p_hasta timestamptz)
returns jsonb language plpgsql stable set search_path to 'public' as $function$
declare
  a double precision := 0; b double precision := 1;
  g1 double precision; g2 double precision;
  h11 double precision; h12 double precision; h22 double precision;
  det double precision; da double precision; db double precision;
  it int := 0; v_n int; conv boolean := false;
begin
  select count(*) into v_n from calib_eventos
   where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
     and resultado in ('WIN','LOSS') and p_raw is not null;
  if v_n < 100 then
    return jsonb_build_object('ok', false, 'motivo', 'muestra insuficiente', 'n', v_n);
  end if;
  for it in 1..25 loop
    select sum(y - pr), sum((y - pr)*x), sum(pr*(1-pr)), sum(pr*(1-pr)*x), sum(pr*(1-pr)*x*x)
      into g1, g2, h11, h12, h22
    from (
      select (case when resultado='WIN' then 1 else 0 end)::double precision y,
             ln(p_raw/(1-p_raw))::double precision x,
             1.0/(1.0+exp(-(a + b*ln(p_raw/(1-p_raw))::double precision))) pr
      from calib_eventos
      where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
        and resultado in ('WIN','LOSS') and p_raw is not null
    ) t;
    det := h11*h22 - h12*h12;
    exit when det is null or abs(det) < 1e-12;
    da := ( h22*g1 - h12*g2) / det;
    db := (-h12*g1 + h11*g2) / det;
    a := a + da; b := b + db;
    if abs(da) < 1e-9 and abs(db) < 1e-9 then conv := true; exit; end if;
  end loop;
  return jsonb_build_object('ok', true, 'a', round(a::numeric, 8), 'b', round(b::numeric, 8),
                            'convergio', conv, 'n_train_eventos', v_n);
end $function$;

-- ===========================================================================
-- 10) Evaluador: Brier, LogLoss y ECE de RAW vs CAL. Reporta SIEMPRE eventos
--     Y partidos independientes, y los PUSH aparte.
-- ===========================================================================
create or replace function public.evaluar_calibrador(
  p_model text, p_metodo text, p_params jsonb, p_desde timestamptz, p_hasta timestamptz)
returns jsonb language sql stable set search_path to 'public' as $function$
with ev as (
  select espn_event_id, resultado, p_raw::double precision pr,
         case p_metodo
           when 'identity' then p_raw::double precision
           when 'platt' then 1.0/(1.0+exp(-(
                  (p_params->>'a')::double precision
                + (p_params->>'b')::double precision * ln(p_raw/(1-p_raw))::double precision)))
           else p_raw::double precision end pc
  from calib_eventos
  where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
    and p_raw is not null
),
lim as (select espn_event_id, resultado, pr, greatest(1e-6, least(1-1e-6, pc)) pc from ev),
usable as (select * from lim where resultado in ('WIN','LOSS')),
y as (select espn_event_id, pr, pc, (resultado='WIN')::int yv from usable),
bins  as (select width_bucket(pr,0,1,10) b, count(*) n, avg(pr) conf, avg(yv::double precision) acc from y group by 1),
binsc as (select width_bucket(pc,0,1,10) b, count(*) n, avg(pc) conf, avg(yv::double precision) acc from y group by 1)
select jsonb_build_object(
  'metodo', p_metodo, 'test_desde', p_desde, 'test_hasta', p_hasta,
  'n_eventos',  (select count(*) from usable),
  'n_partidos', (select count(distinct espn_event_id) from usable),
  'n_push',     (select count(*) from lim where resultado='PUSH'),
  'brier_raw',   (select round(avg(power(pr-yv,2))::numeric,6) from y),
  'brier_cal',   (select round(avg(power(pc-yv,2))::numeric,6) from y),
  'logloss_raw', (select round(avg(-(yv*ln(pr) + (1-yv)*ln(1-pr)))::numeric,6) from y),
  'logloss_cal', (select round(avg(-(yv*ln(pc) + (1-yv)*ln(1-pc)))::numeric,6) from y),
  'ece_raw', (select round((sum(n*abs(acc-conf))/nullif(sum(n),0))::numeric,6) from bins),
  'ece_cal', (select round((sum(n*abs(acc-conf))/nullif(sum(n),0))::numeric,6) from binsc),
  'brier_volado', (select round(avg(power(0.5-yv,2))::numeric,6) from y))
$function$;

-- FIN iss086. Resultados en el reporte: shadow-patches/REPORTE_CALIBRACION_V1.md
