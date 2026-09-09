-- ============================================================================
-- iss027 — CHAMPIONS / CROSS-LEAGUE MODEL (STAGED, NO APLICAR SIN APPROVAL)
-- ============================================================================
-- BLOQUE 1 del cierre backend SOCCER. Modelo de fuerza entre ligas para
-- competencias cruzadas (Champions, Europa, Conference, Libertadores, Concacaf,
-- AFC). Validado offline (ver shadow-patches/reports/BLOQUE1_crossleague_*.md y
-- lab/champions_crossleague_v1/EVIDENCE_bloque1_validation.txt).
--
-- NO se aplica bajo PROD_FREEZE. NO va en supabase/migrations (no auto-aplicar).
-- Fail-closed-until-validated: el modelo NO altera P_RETO de ninguna competencia
-- cruzada hasta que un humano ejecute este script Y apruebe en v2.model_registry.
--
-- Reglas duras respetadas:
--   * data_asof <= decision_time (forma doméstica = ventana 540d ESTRICTAMENTE
--     anterior al kickoff; ver v2.fn_crossleague_features).
--   * NO usa odds/mercado para fabricar P.
--   * Sudamericana (liga 11): puede entrenar φ, jamás emite pick (servible=false).
--   * Fail-close si liga sin cobertura (>=20 juegos cruzados) o equipo con muestra
--     doméstica < 5 juegos en ventana.
-- ============================================================================

create schema if not exists v2;

-- ── 1) Coeficientes de fuerza por liga (φ), ajustados por MLE Poisson ─────────
create table if not exists v2.liga_fuerza (
  liga_id       integer primary key,
  liga_nombre   text,
  phi           numeric   not null,          -- fuerza relativa (ref Premier=0)
  n_cruzados    integer   not null,          -- juegos cruzados que identifican φ
  servible      boolean   not null default false,  -- >=20 cruzados y no vetada
  fit_at        timestamptz not null default now(),
  model_version text      not null default 'crossleague_v1'
);

-- Valores del ajuste (ridge=10, ref=Premier 39, n_train=826 juegos cruzados usables).
-- Reemplaza el contenido en cada re-fit; se aplica sólo tras approval.
truncate v2.liga_fuerza;
insert into v2.liga_fuerza (liga_id, liga_nombre, phi, n_cruzados, servible) values
  (39, 'Premier League', 0.0, 218, true),
  (140, 'LaLiga', -0.0768, 191, true),
  (78, 'Bundesliga', -0.1079, 177, true),
  (135, 'Serie A', -0.1184, 168, true),
  (61, 'Ligue 1', -0.1105, 155, true),
  (88, 'Eredivisie', -0.382, 106, true),
  (94, 'Primeira Liga', -0.2522, 104, true),
  (144, 'Jupiler Pro League', -0.3017, 79, true),
  (203, 'Super Lig', -0.3585, 61, true),
  (197, 'Super League Greece', -0.3917, 58, true),
  (253, 'MLS', -0.3151, 54, true),
  (262, 'Liga MX', -0.049, 53, true),
  (103, 'Eliteserien', -0.2915, 45, true),
  (119, 'Danish Superliga', -0.2262, 35, true),
  (179, 'Scottish Premiership', -0.4283, 33, true),
  (307, 'Saudi Pro League', 0.0734, 3, false),   -- muestra cruzada insuficiente -> fail-close
  (11,  'CONMEBOL Sudamericana', 0.0, 0, false); -- veto: nunca pick (aunque entrene)

-- ── 2) Parámetros globales del modelo (una fila) ─────────────────────────────
create table if not exists v2.crossleague_params (
  model_version text primary key,
  a0 numeric, batt numeric, bdef numeric, home_adv numeric, rho numeric,
  ref_league integer, ridge numeric, n_train integer,
  sample_floor_domestic integer default 5,   -- min juegos domésticos por equipo
  coverage_floor_cruzados integer default 20,-- min juegos cruzados por liga
  fit_at timestamptz default now()
);
insert into v2.crossleague_params
  (model_version,a0,batt,bdef,home_adv,rho,ref_league,ridge,n_train)
values ('crossleague_v1', -0.1351, 0.5145, 0.2781, 0.3404, 0.0586, 39, 10.0, 826)
on conflict (model_version) do update set
  a0=excluded.a0, batt=excluded.batt, bdef=excluded.bdef, home_adv=excluded.home_adv,
  rho=excluded.rho, ref_league=excluded.ref_league, ridge=excluded.ridge,
  n_train=excluded.n_train, fit_at=now();

-- ── 3) Features temporalmente seguros: forma doméstica previa por equipo ──────
-- data_asof := última fecha doméstica < decision_time dentro de ventana 540d.
create or replace function v2.fn_crossleague_features(
  p_team_espn_id text, p_decision_time timestamptz, p_window_days int default 540
) returns table(n int, gf numeric, ga numeric, liga_modal int, data_asof timestamptz)
language sql stable as $$
  select count(*)::int,
    avg(case when d.home_espn_id=p_team_espn_id then d.home_score else d.away_score end),
    avg(case when d.home_espn_id=p_team_espn_id then d.away_score else d.home_score end),
    mode() within group (order by d.liga_id),
    max(d.fecha)
  from public.historico_partidos_espn d
  where (d.home_espn_id=p_team_espn_id or d.away_espn_id=p_team_espn_id)
    and d.liga_id not in (2,3,848,13,11,15,16,17,20,45,48,66,81,137,143,180,181,667)
    and d.liga_id is not null and d.home_score is not null
    and d.fecha < p_decision_time
    and d.fecha >= p_decision_time - make_interval(days => p_window_days);
$$;

-- ── 4) Función de servicio: P_RETO cross-league (fail-closed) ─────────────────
-- Devuelve NULLs (fail-close) si: liga no servible, muestra doméstica insuficiente,
-- o data_asof > decision_time. NUNCA inventa números.
create or replace function v2.fn_crossleague_p_reto(
  p_home_espn_id text, p_away_espn_id text,
  p_home_liga int, p_away_liga int, p_decision_time timestamptz
) returns table(
  p_reto_home numeric, p_reto_draw numeric, p_reto_away numeric,
  p_over numeric, p_under numeric, btts_yes numeric,
  lambda_home numeric, lambda_away numeric,
  model_status text, model_status_reason text, data_asof timestamptz
) language plpgsql stable as $$
declare
  pr record; pa record; par record;
  fh_serv boolean; fa_serv boolean; phi_h numeric; phi_a numeric;
  lh numeric; la numeric; tau numeric;
  m numeric[][]; s numeric; i int; j int; ph numeric; pd numeric; pav numeric;
  over numeric; btts numeric; asof timestamptz;
begin
  select * into par from v2.crossleague_params where model_version='crossleague_v1';
  select * into pr from v2.fn_crossleague_features(p_home_espn_id, p_decision_time);
  select * into pa from v2.fn_crossleague_features(p_away_espn_id, p_decision_time);
  select phi, servible into phi_h, fh_serv from v2.liga_fuerza where liga_id = coalesce(pr.liga_modal, p_home_liga);
  select phi, servible into phi_a, fa_serv from v2.liga_fuerza where liga_id = coalesce(pa.liga_modal, p_away_liga);

  -- Fail-close gates
  if pr.n is null or pr.n < par.sample_floor_domestic or pa.n is null or pa.n < par.sample_floor_domestic then
    return query select null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,
      null::numeric,null::numeric,'DATA_INCOMPLETE','Sin muestra doméstica suficiente para ambos equipos',null::timestamptz; return;
  end if;
  if coalesce(fh_serv,false)=false or coalesce(fa_serv,false)=false or phi_h is null or phi_a is null then
    return query select null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,
      null::numeric,null::numeric,'DATA_INCOMPLETE','Liga sin cobertura φ validada (modelo cross-league)',null::timestamptz; return;
  end if;
  asof := greatest(pr.data_asof, pa.data_asof);
  if asof > p_decision_time then
    return query select null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,
      null::numeric,null::numeric,'DATA_INCOMPLETE','Fuga temporal: data_asof > decision_time',null::timestamptz; return;
  end if;

  -- λ (mismos coeficientes que la validación Python)
  lh := exp(least(par.a0 + par.batt*ln(greatest(pr.gf,0.05)) + par.bdef*ln(greatest(pa.ga,0.05)) + par.home_adv + (phi_h-phi_a), 2.5));
  la := exp(least(par.a0 + par.batt*ln(greatest(pa.gf,0.05)) + par.bdef*ln(greatest(pr.ga,0.05)) + (phi_a-phi_h), 2.5));

  -- Score matrix 0..10 con corrección Dixon-Coles
  m := array_fill(0::numeric, array[11,11]);
  s := 0;
  for i in 0..10 loop for j in 0..10 loop
    tau := 1;
    if i=0 and j=0 then tau := 1 - lh*la*par.rho;
    elsif i=0 and j=1 then tau := 1 + lh*par.rho;
    elsif i=1 and j=0 then tau := 1 + la*par.rho;
    elsif i=1 and j=1 then tau := 1 - par.rho; end if;
    m[i+1][j+1] := greatest(tau,0) * (exp(-lh)*power(lh,i)/(select f from (select exp(sum(ln(g))) f from generate_series(1,greatest(i,1)) g) q) )
                                    * (exp(-la)*power(la,j)/(select f from (select exp(sum(ln(g))) f from generate_series(1,greatest(j,1)) g) q) );
    if i=0 then m[i+1][j+1] := greatest(tau,0)*exp(-lh)*(exp(-la)*power(la,j)/(select f from (select exp(sum(ln(g))) f from generate_series(1,greatest(j,1)) g) q)); end if;
    s := s + m[i+1][j+1];
  end loop; end loop;

  ph:=0; pd:=0; pav:=0; over:=0; btts:=0;
  for i in 0..10 loop for j in 0..10 loop
    if i>j then ph:=ph+m[i+1][j+1]; elsif i=j then pd:=pd+m[i+1][j+1]; else pav:=pav+m[i+1][j+1]; end if;
    if i+j>=3 then over:=over+m[i+1][j+1]; end if;
    if i>=1 and j>=1 then btts:=btts+m[i+1][j+1]; end if;
  end loop; end loop;

  return query select round(100*ph/s,2), round(100*pd/s,2), round(100*pav/s,2),
    round(100*over/s,2), round(100*(s-over)/s,2), round(100*btts/s,2),
    round(lh,3), round(la,3),
    'READY_UNVALIDATED'::text, 'cross-league Dixon-Coles + φ liga (validado OOS)'::text, asof;
end $$;

-- ── 5) APPROVAL (NO ejecutar hasta que un humano lo decida tras revisar la evidencia)
-- Al aprobar, registrar en v2.model_registry para las competencias cruzadas.
-- Sudamericana (11) queda FUERA (veto de pick).
-- insert into v2.model_registry (sport,model_name,model_version,liga_id,liga_nombre,approved,notes,approved_at)
-- values
--   ('FUT','crossleague','crossleague_v1', 2,  'UEFA Champions League', true, 'BLOQUE1 OOS Brier +0.017 CI[+0.001,+0.033]', now()),
--   ('FUT','crossleague','crossleague_v1', 3,  'UEFA Europa League',     true, 'idem', now()),
--   ('FUT','crossleague','crossleague_v1', 848,'UEFA Conference League', true, 'idem', now()),
--   ('FUT','crossleague','crossleague_v1', 13, 'CONMEBOL Libertadores',  true, 'idem', now()),
--   ('FUT','crossleague','crossleague_v1', 16, 'Concacaf Champions Cup', true, 'idem', now()),
--   ('FUT','crossleague','crossleague_v1', 17, 'AFC Champions League',   true, 'idem', now());
-- (NO Sudamericana. Concacaf/AFC sólo si su cobertura de participantes cumple el piso.)
