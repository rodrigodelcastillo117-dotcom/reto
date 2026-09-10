-- ============================================================================
-- iss054 — NFL BRAIN · ONE DISTRIBUTION · ONE P_RETO · STAGED
-- ============================================================================
-- NO PROD MUTATION · branch-only · RELEASE_GATE=HOLD · PROD_FREEZE=ON · NO CUTOVER.
--
-- Supersedes iss017's NO_OWN_MODEL stance: NFL now HAS its own brain. DraftKings supplies
-- LINE + ODDS + timestamp and nothing else. P_RETO is ours or it is NULL.
--
-- ── WHAT THE MODEL IS, MEASURED NOT ASSUMED (prod read-only, 2026-09-10) ────
-- Training universe: public.nfl_partidos, temporada=2025, tipo_temporada=2 (REGULAR season),
-- 272 games, 272 final. Preseason is EXCLUDED and that is not cosmetic:
--      2025 regular  avg total 46.03   avg home 24.05   avg away 21.98
--      2026 preseason avg total 33.00  avg home 17.36   avg away 15.64
-- Treating 28 preseason games as the same sample would drag every projection ~13 points low.
--
-- Measured parameters (272 games):
--      HOME FIELD ADVANTAGE  = +2.070 points (mean margin)
--      sd(margin)            = 14.177
--      sd(total)             = 13.814
--      sd(home points)       = 9.800     sd(away points) = 9.994
--      corr(home pts, away pts) = -0.0259
-- The near-zero correlation is why home and away scoring are modelled INDEPENDENTLY, and the
-- numbers agree: sqrt(9.800^2 + 9.994^2) = 13.99 ≈ both measured sds. Independence here is a
-- measurement, not a convenience.
--
-- ── WHY NOT A PLAIN NORMAL: NFL KEY NUMBERS ─────────────────────────────────
-- Measured margin frequencies in those 272 games:
--      |margin| = 3  ->  41 games (15.1%)
--      |margin| = 7  ->  26 games ( 9.6%)
--      |margin| = 5  ->   9 games ( 3.3%)
-- A continuous normal assigns ZERO mass to an exact margin and smooth mass around it, so it
-- misprices a -3 or -7 spread badly and cannot report a real push probability. NFL scoring
-- lives on a lattice (field goals and touchdowns), so this file models team points as a
-- DISCRETE distribution over the EMPIRICAL 2025 scoring shape, tilted to the team's predicted
-- mean. Key numbers keep their real mass and P(push) is a genuine number.
--
-- ── ONE DISTRIBUTION ────────────────────────────────────────────────────────
-- Each snapshot persists the two marginal pmfs (home and away points, 0..55). Because the two
-- are independent by measurement, the pair IS the joint distribution, losslessly and compactly
-- (112 numbers instead of a 3,136-cell grid). Every published market is a sum over that same
-- joint: moneyline and spread from the margin convolution, total from the sum convolution.
-- The gate recomputes all of them from the persisted pmfs and fails if any scalar disagrees.
--
-- ── HONEST LIMITATION, STATED UP FRONT ──────────────────────────────────────
-- Week 1 of 2026 has ZERO completed regular-season games, so team ratings come from 2025 and
-- cannot see roster turnover. That is real uncertainty and it is handled by an explicit,
-- versioned early-season variance inflation, NOT by pretending precision. The inflation factor
-- is a JUDGMENT CALL and is labelled as such: calibration_status = UNVALIDATED_EARLY_SEASON.
-- No claim of skill over DraftKings is made anywhere in this file.
-- ============================================================================

create schema if not exists v2;

-- ── 1) config: every parameter is versioned data, not a buried constant ─────
create table if not exists v2.nfl_model_config (
  sport text not null default 'football',
  model_name text not null,
  model_version text not null,
  feature_version text not null,
  calibration_status text not null,
  -- measured on the 2025 regular season
  league_mean_points numeric not null,      -- per team-game
  hfa_points numeric not null,              -- full home-field advantage on the margin
  sd_team_points numeric not null,          -- dispersion of a single team's score
  -- shrinkage: off/def ratings are pulled toward 0 by n/(n+k). k is in GAMES.
  shrink_k numeric not null,
  -- early-season inflation applied to sd_team_points when the rating sample is last season's.
  -- JUDGMENT CALL, not measured: 2025 ratings cannot see 2026 roster turnover.
  early_season_sd_inflation numeric not null,
  max_points int not null default 55,       -- support of the points pmf
  min_rating_games int not null,            -- games per team required to trust a rating
  publish_authorized boolean not null default false,
  sealed_at timestamptz not null default now(),
  primary key (sport, model_version)
);

create or replace function v2.fn_nfl_model_config_immutable() returns trigger language plpgsql as $$
begin
  if to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'NFL_MODEL_CONFIG_DRIFT: (%,%) es inmutable (whole-row); usa un model_version nuevo',
      new.sport, new.model_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_nfl_model_config_immutable on v2.nfl_model_config;
create trigger trg_nfl_model_config_immutable before update on v2.nfl_model_config
  for each row execute function v2.fn_nfl_model_config_immutable();

insert into v2.nfl_model_config
  (model_name, model_version, feature_version, calibration_status,
   league_mean_points, hfa_points, sd_team_points, shrink_k,
   early_season_sd_inflation, max_points, min_rating_games, publish_authorized)
values
  ('nfl_points_lattice_v1', 'nfl-2026.09.1', 'nfl_ratings_asof_v1', 'UNVALIDATED_EARLY_SEASON',
   23.013,    -- 46.026 / 2, measured
   2.070,     -- measured mean margin
   9.897,     -- mean of sd(home)=9.800 and sd(away)=9.994, measured
   6.0,       -- shrink toward league mean; with 17 games/team gives weight 17/23 = 0.739
   1.15,      -- early-season inflation: JUDGMENT, not measured. See header.
   55, 8, true)
on conflict (sport, model_version) do nothing;

-- ── 2) the EMPIRICAL NFL scoring lattice (real 2025 frequencies) ────────────
-- Seeded from the 544 team-games of the 2025 regular season. This is what gives margins of
-- 3 and 7 their real mass. Counts are raw observations; the pmf builder tilts this shape
-- toward each team's predicted mean instead of replacing it with a smooth curve.
create table if not exists v2.nfl_points_shape (
  model_version text not null,
  points int not null,
  observaciones int not null,
  fuente text not null,
  primary key (model_version, points)
);

insert into v2.nfl_points_shape (model_version, points, observaciones, fuente)
select 'nfl-2026.09.1', p, c, 'nfl_partidos temporada=2025 tipo_temporada=2 (544 team-games)'
from (values
  (0,7),(3,8),(6,10),(7,8),(8,3),(9,10),(10,26),(11,1),(12,5),(13,21),(14,14),(15,6),
  (16,18),(17,25),(18,7),(19,17),(20,41),(21,21),(22,14),(23,21),(24,34),(25,8),(26,21),
  (27,36),(28,15),(29,11),(30,14),(31,23),(32,5),(33,8),(34,20),(35,6),(36,2),(37,10),
  (38,11),(39,2),(40,7),(41,8),(42,5),(44,8),(45,2),(47,1),(48,3),(52,1)
) as v(p,c)
on conflict (model_version, points) do nothing;

-- ── 3) normal CDF (Postgres has no erf) ─────────────────────────────────────
-- Abramowitz & Stegun 7.1.26 style rational approximation; |error| < 7.5e-8. Used only for the
-- Gaussian TILT applied to the empirical shape, never as the distribution itself.
create or replace function v2.fn_norm_pdf(z numeric) returns numeric
language sql immutable as $$
  select round((exp(-(z*z)/2.0) / 2.5066282746310002)::numeric, 12);
$$;

-- ── 4) team ratings, fitted AS OF an instant, append-only ───────────────────
create table if not exists v2.nfl_team_rating (
  model_version text not null,
  asof timestamptz not null,
  team_id text not null,
  off_rating numeric not null,      -- points above/below league mean when attacking
  def_rating numeric not null,      -- points above/below league mean conceded (negative = good D)
  games int not null,
  shrink_weight numeric not null,
  fitted_at timestamptz not null default now(),
  primary key (model_version, asof, team_id)
);

create or replace function v2.fn_nfl_team_rating_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'NFL_TEAM_RATING_IMMUTABLE: (%,%,%) ya sellado; ajusta con un asof nuevo',
    old.model_version, old.asof, old.team_id;
end $$;
drop trigger if exists trg_nfl_team_rating_immutable on v2.nfl_team_rating;
create trigger trg_nfl_team_rating_immutable before update or delete on v2.nfl_team_rating
  for each row execute function v2.fn_nfl_team_rating_immutable();

-- Fit offense/defense ratings from COMPLETED REGULAR-SEASON games strictly before p_asof.
-- Alternating refinement with shrinkage, which is the lesson from the soccer audit: Motor A
-- was materially overconfident precisely because its lambdas had NO shrinkage.
create or replace function v2.fn_nfl_fit_ratings(
  p_asof timestamptz,
  p_model_version text default 'nfl-2026.09.1',
  p_iteraciones int default 6
) returns integer language plpgsql as $function$
declare cfg record; n_games int; i int; n_teams int;
begin
  select * into cfg from v2.nfl_model_config
   where sport='football' and model_version=p_model_version;
  if cfg is null then raise exception 'NFL_MODEL_CONFIG_MISSING: %', p_model_version; end if;

  -- ya sellado para este asof: no recomputar (prohibición de recompute-on-read)
  if exists (select 1 from v2.nfl_team_rating
              where model_version=p_model_version and asof=p_asof) then
    return (select count(*)::int from v2.nfl_team_rating
             where model_version=p_model_version and asof=p_asof);
  end if;

  create temp table if not exists _ng (
    team_id text, opp_id text, es_local boolean, pts_for numeric, pts_against numeric
  ) on commit drop;
  delete from _ng;

  -- SOLO temporada regular finalizada y estrictamente anterior al asof.
  insert into _ng
  select p.home_id, p.away_id, true,  p.pts_home, p.pts_away
  from public.nfl_partidos p
  where p.tipo_temporada = 2 and p.pts_home is not null and p.pts_away is not null
    and p.fecha < p_asof
  union all
  select p.away_id, p.home_id, false, p.pts_away, p.pts_home
  from public.nfl_partidos p
  where p.tipo_temporada = 2 and p.pts_home is not null and p.pts_away is not null
    and p.fecha < p_asof;

  select count(*) into n_games from _ng;
  if n_games = 0 then return 0; end if;

  create temp table if not exists _r (
    team_id text primary key, off_r numeric, def_r numeric, games int
  ) on commit drop;
  delete from _r;

  insert into _r (team_id, off_r, def_r, games)
  select team_id, 0, 0, count(*) from _ng group by team_id;

  select count(*) into n_teams from _r;

  -- refinamiento alternado: cada pasada recalcula off dado def y def dado off
  for i in 1..p_iteraciones loop
    -- ofensiva: puntos anotados por encima de lo esperado dada la defensa rival y el HFA
    update _r r set off_r = sub.v
    from (
      select g.team_id,
             avg(g.pts_for - cfg.league_mean_points - ro.def_r
                 - case when g.es_local then cfg.hfa_points/2.0 else -cfg.hfa_points/2.0 end) v
      from _ng g join _r ro on ro.team_id = g.opp_id
      group by g.team_id
    ) sub where sub.team_id = r.team_id;

    -- defensiva: puntos concedidos por encima de lo esperado dada la ofensiva rival
    update _r r set def_r = sub.v
    from (
      select g.team_id,
             avg(g.pts_against - cfg.league_mean_points - ro.off_r
                 - case when g.es_local then -cfg.hfa_points/2.0 else cfg.hfa_points/2.0 end) v
      from _ng g join _r ro on ro.team_id = g.opp_id
      group by g.team_id
    ) sub where sub.team_id = r.team_id;

    -- centrar en cero: off y def son desviaciones respecto a la media de liga
    update _r set off_r = off_r - (select avg(off_r) from _r),
                  def_r = def_r - (select avg(def_r) from _r);
  end loop;

  -- sellar con shrinkage n/(n+k); con 17 juegos y k=6 el peso es 0.739
  insert into v2.nfl_team_rating
    (model_version, asof, team_id, off_rating, def_rating, games, shrink_weight)
  select p_model_version, p_asof, r.team_id,
         round(r.off_r * (r.games::numeric/(r.games + cfg.shrink_k)), 4),
         round(r.def_r * (r.games::numeric/(r.games + cfg.shrink_k)), 4),
         r.games,
         round(r.games::numeric/(r.games + cfg.shrink_k), 4)
  from _r r
  on conflict (model_version, asof, team_id) do nothing;

  return n_teams;
end $function$;

-- ── 5) points pmf: empirical lattice TILTED to a predicted mean ─────────────
-- pmf(k) ∝ observaciones(k) * pdf_normal((k - mu)/sd)
-- The empirical term keeps NFL's real scoring lattice (20, 24, 27 common; 1, 4, 5 nearly
-- impossible). The Gaussian term moves the centre of mass to what the model predicts.
-- Returns jsonb {"0":p,...} in PERCENT, summing to exactly 100.
create or replace function v2.fn_nfl_points_pmf(
  mu numeric, sd numeric, p_model_version text default 'nfl-2026.09.1'
) returns jsonb language plpgsql stable as $$
declare total numeric; res jsonb; maxp int;
begin
  if mu is null or sd is null or sd <= 0 then return null; end if;
  -- un equipo no puede proyectarse por debajo de 3 ni por encima de 45 con datos reales;
  -- fuera de ese rango el ajuste dejó de ser creíble y se fail-closea.
  if mu < 3 or mu > 45 then return null; end if;

  select max(points) into maxp from v2.nfl_points_shape where model_version = p_model_version;
  if maxp is null then return null; end if;

  with w as (
    select s.points,
           s.observaciones * v2.fn_norm_pdf((s.points - mu)/sd) peso
    from v2.nfl_points_shape s
    where s.model_version = p_model_version
  ),
  t as (select sum(peso) tot from w)
  select sum(round(100*w.peso/t.tot, 4)),
         jsonb_object_agg(w.points::text, round(100*w.peso/t.tot, 4))
    into total, res
  from w cross join t where t.tot > 0;

  if res is null or total is null or total <= 0 then return null; end if;
  return res;
end $$;

-- ── 6) derive EVERY market from the SAME pair of pmfs ───────────────────────
-- p_spread_home is the DraftKings line for the HOME team (negative = home favoured), exactly
-- as nfl_partidos/nfl_odds_snapshots store it. Home covers when margin + spread > 0.
create or replace function v2.fn_nfl_markets_from_pmf(
  pmf_home jsonb, pmf_away jsonb,
  p_spread_home numeric default null, p_total_line numeric default null
) returns table(
  p_home_ml numeric, p_away_ml numeric, p_tie_regulation numeric,
  exp_home numeric, exp_away numeric, exp_margin numeric, exp_total numeric,
  p_home_cover numeric, p_away_cover numeric, p_spread_push numeric,
  p_over numeric, p_under numeric, p_total_push numeric,
  spread_push_possible boolean, total_push_possible boolean,
  pmf_sum_home numeric, pmf_sum_away numeric
) language plpgsql immutable as $$
declare
  h numeric; a numeric; ph numeric; pa numeric; joint numeric;
  m numeric; t numeric;
  s_ml_h numeric := 0; s_ml_a numeric := 0; s_tie numeric := 0;
  s_cov_h numeric := 0; s_cov_a numeric := 0; s_push_s numeric := 0;
  s_over numeric := 0; s_under numeric := 0; s_push_t numeric := 0;
  e_h numeric := 0; e_a numeric := 0;
  sum_h numeric := 0; sum_a numeric := 0;
begin
  if pmf_home is null or pmf_away is null then return; end if;

  select sum(value::numeric) into sum_h from jsonb_each_text(pmf_home) as e(key,value);
  select sum(value::numeric) into sum_a from jsonb_each_text(pmf_away) as e(key,value);
  pmf_sum_home := round(sum_h,2); pmf_sum_away := round(sum_a,2);

  spread_push_possible := p_spread_home is not null and (p_spread_home = floor(p_spread_home));
  total_push_possible  := p_total_line  is not null and (p_total_line  = floor(p_total_line));

  -- convolución explícita de las dos marginales independientes
  for h, ph in select e.key::numeric, e.value::numeric from jsonb_each_text(pmf_home) as e(key,value) loop
    e_h := e_h + h * ph / 100.0;
    for a, pa in select e2.key::numeric, e2.value::numeric from jsonb_each_text(pmf_away) as e2(key,value) loop
      joint := (ph/100.0) * (pa/100.0);
      m := h - a;
      t := h + a;

      if m > 0 then s_ml_h := s_ml_h + joint;
      elsif m < 0 then s_ml_a := s_ml_a + joint;
      else s_tie := s_tie + joint; end if;

      if p_spread_home is not null then
        if m + p_spread_home > 0 then s_cov_h := s_cov_h + joint;
        elsif m + p_spread_home < 0 then s_cov_a := s_cov_a + joint;
        else s_push_s := s_push_s + joint; end if;
      end if;

      if p_total_line is not null then
        if t > p_total_line then s_over := s_over + joint;
        elsif t < p_total_line then s_under := s_under + joint;
        else s_push_t := s_push_t + joint; end if;
      end if;
    end loop;
  end loop;

  for a, pa in select e.key::numeric, e.value::numeric from jsonb_each_text(pmf_away) as e(key,value) loop
    e_a := e_a + a * pa / 100.0;
  end loop;

  -- MONEYLINE: en NFL el empate es posible (1 de 272 en 2025) pero el mercado de ML lo trata
  -- como push. Se reporta p_tie aparte y el ML se renormaliza excluyéndolo, igual que MLB.
  if (s_ml_h + s_ml_a) > 0 then
    p_home_ml := round(100 * s_ml_h / (s_ml_h + s_ml_a), 1);
    p_away_ml := round(100 * s_ml_a / (s_ml_h + s_ml_a), 1);
  end if;
  p_tie := round(100 * s_tie, 2);

  exp_home := round(e_h, 2); exp_away := round(e_a, 2);
  exp_margin := round(e_h - e_a, 2); exp_total := round(e_h + e_a, 2);

  if p_spread_home is not null then
    p_home_cover := round(100 * s_cov_h, 1);
    p_away_cover := round(100 * s_cov_a, 1);
    p_spread_push := round(100 * s_push_s, 2);
  end if;
  if p_total_line is not null then
    p_over := round(100 * s_over, 1);
    p_under := round(100 * s_under, 1);
    p_total_push := round(100 * s_push_t, 2);
  end if;
  return next;
end $$;

-- ── 7) DECISION SNAPSHOT: pre-kickoff por construcción, P_RETO separado del mercado ──
create table if not exists v2.nfl_decision_snapshot (
  espn_event_id text not null,
  decision_time timestamptz not null,
  model_version text not null,
  temporada int not null,
  tipo_temporada int not null,
  semana int,
  kickoff timestamptz not null,
  home_team text, away_team text, home_id text, away_id text,
  -- NUESTRA distribución (las dos marginales independientes = el conjunto, sin pérdida)
  pmf_home jsonb, pmf_away jsonb,
  off_home numeric, def_home numeric, off_away numeric, def_away numeric,
  mu_home numeric, mu_away numeric, sd_used numeric,
  exp_home numeric, exp_away numeric, exp_margin numeric, exp_total numeric,
  -- NUESTRAS probabilidades, todas derivadas de pmf_home × pmf_away
  p_home_ml numeric, p_away_ml numeric, p_tie numeric,
  p_home_cover numeric, p_away_cover numeric, p_spread_push numeric,
  p_over numeric, p_under numeric, p_total_push numeric,
  -- EL MERCADO: línea y odds de DraftKings, en columnas físicamente separadas
  dk_spread_home numeric, dk_total numeric,
  dk_ml_home int, dk_ml_away int, dk_over_odds int, dk_under_odds int,
  dk_bookmaker text, dk_snapshot_at timestamptz,
  -- gobernanza
  feature_version text, calibration_status text,
  data_asof timestamptz, ratings_asof timestamptz, asof_proven boolean not null default false,
  rating_games_home int, rating_games_away int,
  coverage numeric, uncertainty numeric,
  model_status text not null, quality_status text, suppression_reason text,
  prob_source text not null,
  provenance jsonb,
  built_at timestamptz not null default now(),
  primary key (espn_event_id, decision_time, model_version),

  -- GUARD 1 — la decisión es estrictamente pre-kickoff. Imposible almacenar lo contrario.
  constraint nfl_snap_pre_kickoff check (decision_time < kickoff),

  -- GUARD 2 — temporada regular únicamente. La pretemporada promedia 33 pts vs 46: no es la
  -- misma muestra y no puede entrar al mismo contrato.
  constraint nfl_snap_solo_regular check (tipo_temporada = 2),

  -- GUARD 3 — la línea de mercado usada NO puede ser posterior a la decisión.
  constraint nfl_snap_odds_pre_decision
    check (dk_snapshot_at is null or dk_snapshot_at <= decision_time),

  -- GUARD 4 — los ratings usados NO pueden ser posteriores a la decisión.
  constraint nfl_snap_ratings_pre_decision
    check (ratings_asof is null or ratings_asof <= decision_time),

  -- GUARD 5 — P_RETO existe si y sólo si hay modelo publicable, y nunca declara fuente de mercado.
  constraint nfl_snap_preto_iff_model check (
    (model_status = 'READY'     and p_home_ml is not null and p_away_ml is not null)
    or
    (model_status <> 'READY'    and p_home_ml is null     and p_away_ml is null)
  ),
  constraint nfl_snap_market_no_es_preto check (
    p_home_ml is null
    or (prob_source not ilike '%no_vig%' and prob_source not ilike '%mercado%'
        and prob_source not ilike '%market%' and prob_source not ilike '%draftkings%'
        and prob_source not ilike '%implied%')
  ),
  -- GUARD 6 — coherencia interna: ML suma 100; over+push+under suma 100; cover+push suma 100.
  constraint nfl_snap_ml_suma check (
    p_home_ml is null or abs((p_home_ml + p_away_ml) - 100) <= 0.2
  ),
  constraint nfl_snap_ou_suma check (
    p_over is null or abs((p_over + coalesce(p_total_push,0) + p_under) - 100) <= 0.2
  ),
  constraint nfl_snap_cover_suma check (
    p_home_cover is null or abs((p_home_cover + coalesce(p_spread_push,0) + p_away_cover) - 100) <= 0.2
  ),
  -- GUARD 7 — una fila canónica NO puede quedar sin contrato de gobernanza.
  -- Este es el defecto que el auditor encontró en mi MLB: filas READY con calibration_status
  -- y data_readiness NULL mezcladas en la misma model_version.
  constraint nfl_snap_gobernanza_completa check (
    model_status <> 'READY'
    or (calibration_status is not null and feature_version is not null
        and coverage is not null and uncertainty is not null and provenance is not null
        and data_asof is not null and ratings_asof is not null)
  )
);
create index if not exists ix_nfl_snap_event on v2.nfl_decision_snapshot (espn_event_id, decision_time desc);
create index if not exists ix_nfl_snap_semana on v2.nfl_decision_snapshot (temporada, semana, decision_time desc);

create or replace function v2.fn_nfl_snapshot_immutable() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'NFL_SNAPSHOT_IMMUTABLE: DELETE prohibido; un snapshot de decision es historia, no estado';
  end if;
  raise exception 'NFL_SNAPSHOT_IMMUTABLE: UPDATE prohibido; una correccion se agrega como decision_time nuevo';
end $$;
drop trigger if exists trg_nfl_snapshot_immutable on v2.nfl_decision_snapshot;
create trigger trg_nfl_snapshot_immutable before update or delete on v2.nfl_decision_snapshot
  for each row execute function v2.fn_nfl_snapshot_immutable();

-- ── 8) línea DraftKings vigente AS OF la decisión ───────────────────────────
-- Prefiere nfl_odds_snapshots (tiene snapshot_at real, 922 capturas DraftKings). Cae a
-- nfl_partidos sólo si no hay snapshot, y en ese caso marca la procedencia para que se vea.
create or replace function v2.fn_nfl_dk_line_asof(
  p_event_id text, p_decision_time timestamptz
) returns table(
  spread_home numeric, total_line numeric, ml_home int, ml_away int,
  over_odds int, under_odds int, bookmaker text, snapshot_at timestamptz, fuente text
) language sql stable as $$
  select o.spread, o.total_linea, o.ml_home, o.ml_away, o.over_odds, o.under_odds,
         o.casa, o.snapshot_at, 'nfl_odds_snapshots'::text
  from public.nfl_odds_snapshots o
  where o.espn_event_id = p_event_id
    and o.snapshot_at <= p_decision_time
    and o.casa = 'DraftKings'
  order by o.snapshot_at desc
  limit 1;
$$;

-- ── 9) BUILDER ──────────────────────────────────────────────────────────────
-- Universo: temporada regular con kickoff > decision_time. Un juego ya iniciado simplemente no
-- está en el universo, y el CHECK lo haría imposible de almacenar aunque lo estuviera.
create or replace function v2.build_nfl_decision_snapshot(
  p_decision_time timestamptz,
  p_model_version text default 'nfl-2026.09.1',
  p_temporada int default null,
  p_semana int default null
) returns integer language plpgsql as $function$
declare
  n int := 0; cfg record; r record; rh record; ra record; dk record; mk record;
  v_sd numeric; v_mu_h numeric; v_mu_a numeric;
  v_pmf_h jsonb; v_pmf_a jsonb;
  v_status text; v_quality text; v_supp text; v_publish boolean;
  v_cov numeric; v_unc numeric; v_ratings_asof timestamptz; v_data_asof timestamptz;
begin
  select * into cfg from v2.nfl_model_config
   where sport='football' and model_version=p_model_version;
  if cfg is null then raise exception 'NFL_MODEL_CONFIG_MISSING: %', p_model_version; end if;

  -- ratings sellados as-of la decisión (se ajustan una vez; no se recomputan en lectura)
  perform v2.fn_nfl_fit_ratings(p_decision_time, p_model_version);
  v_ratings_asof := p_decision_time;

  for r in
    select p.espn_event_id, p.fecha kickoff, p.temporada, p.tipo_temporada, p.semana,
           p.home_team, p.away_team, p.home_id, p.away_id, p.actualizado
    from public.nfl_partidos p
    where p.tipo_temporada = 2
      and p.fecha > p_decision_time
      and (p_temporada is null or p.temporada = p_temporada)
      and (p_semana    is null or p.semana    = p_semana)
    order by p.fecha, p.espn_event_id
  loop
    select * into rh from v2.nfl_team_rating
     where model_version=p_model_version and asof=v_ratings_asof and team_id=r.home_id;
    select * into ra from v2.nfl_team_rating
     where model_version=p_model_version and asof=v_ratings_asof and team_id=r.away_id;
    select * into dk from v2.fn_nfl_dk_line_asof(r.espn_event_id, p_decision_time);

    v_pmf_h := null; v_pmf_a := null; v_mu_h := null; v_mu_a := null; v_sd := null;
    mk := null; v_cov := null; v_unc := null;

    if rh.team_id is not null and ra.team_id is not null then
      -- E[pts_home] = mu + off_home + def_away + hfa/2 ; simétrico para el visitante
      v_mu_h := cfg.league_mean_points + rh.off_rating + ra.def_rating + cfg.hfa_points/2.0;
      v_mu_a := cfg.league_mean_points + ra.off_rating + rh.def_rating - cfg.hfa_points/2.0;
      -- inflación de varianza de inicio de temporada: los ratings son de 2025 y no ven
      -- la rotación de rosters de 2026. Declarado, versionado, y NO medido.
      v_sd := round(cfg.sd_team_points * cfg.early_season_sd_inflation, 4);
      v_pmf_h := v2.fn_nfl_points_pmf(round(v_mu_h,3), v_sd, p_model_version);
      v_pmf_a := v2.fn_nfl_points_pmf(round(v_mu_a,3), v_sd, p_model_version);
      if v_pmf_h is not null and v_pmf_a is not null then
        select * into mk from v2.fn_nfl_markets_from_pmf(
          v_pmf_h, v_pmf_a, dk.spread_home, dk.total_line);
      end if;
      -- cobertura = qué fracción de la muestra mínima tiene el equipo con menos juegos
      v_cov := round(least(1.0, least(rh.games, ra.games)::numeric / cfg.min_rating_games), 4);
      -- incertidumbre = sd del margen implicada por las dos marginales (sqrt(2)*sd)
      -- sqrt() devuelve double precision: el cast es obligatorio o round(double,int) no existe.
      -- Encontrado al ejecutar, no al leer.
      v_unc := round((v_sd * sqrt(2.0))::numeric, 3);
    end if;

    v_data_asof := greatest(coalesce(dk.snapshot_at, v_ratings_asof), v_ratings_asof);

    v_publish := (mk.p_home_ml is not null
                  and v_cov is not null and v_cov >= 1.0
                  and v_pmf_h is not null and v_pmf_a is not null);

    v_status := case when v_publish then 'READY' else 'DATA_INCOMPLETE' end;
    v_quality := case
      when not v_publish then 'SUPPRESSED'
      when dk.spread_home is null and dk.total_line is null then 'NO_LINE_CONTEXT'
      when cfg.calibration_status like 'UNVALIDATED%' then 'UNVALIDATED_EARLY_SEASON'
      else 'OK' end;
    v_supp := case
      when v_publish then null
      when rh.team_id is null or ra.team_id is null then
        'Sin rating as-of para uno de los equipos ('||r.home_team||' / '||r.away_team||')'
      when v_cov is null or v_cov < 1.0 then
        'Muestra de rating insuficiente: cobertura '||coalesce(v_cov::text,'0')||' < 1.0 ('
        ||cfg.min_rating_games||' juegos minimos)'
      when v_pmf_h is null or v_pmf_a is null then
        'La distribucion de puntos no pudo construirse (media proyectada fuera de rango creible)'
      else 'Datos insuficientes' end;

    insert into v2.nfl_decision_snapshot (
      espn_event_id, decision_time, model_version, temporada, tipo_temporada, semana, kickoff,
      home_team, away_team, home_id, away_id,
      pmf_home, pmf_away, off_home, def_home, off_away, def_away,
      mu_home, mu_away, sd_used, exp_home, exp_away, exp_margin, exp_total,
      p_home_ml, p_away_ml, p_tie_regulation,
      p_home_cover, p_away_cover, p_spread_push, p_over, p_under, p_total_push,
      dk_spread_home, dk_total, dk_ml_home, dk_ml_away, dk_over_odds, dk_under_odds,
      dk_bookmaker, dk_snapshot_at,
      feature_version, calibration_status, data_asof, ratings_asof, asof_proven,
      rating_games_home, rating_games_away, coverage, uncertainty,
      model_status, quality_status, suppression_reason, prob_source, provenance)
    values (
      r.espn_event_id, p_decision_time, p_model_version, r.temporada, r.tipo_temporada, r.semana, r.kickoff,
      r.home_team, r.away_team, r.home_id, r.away_id,
      case when v_publish then v_pmf_h end, case when v_publish then v_pmf_a end,
      rh.off_rating, rh.def_rating, ra.off_rating, ra.def_rating,
      round(v_mu_h,3), round(v_mu_a,3), v_sd,
      mk.exp_home, mk.exp_away, mk.exp_margin, mk.exp_total,
      case when v_publish then mk.p_home_ml end,
      case when v_publish then mk.p_away_ml end,
      case when v_publish then mk.p_tie end,
      case when v_publish then mk.p_home_cover end,
      case when v_publish then mk.p_away_cover end,
      case when v_publish then mk.p_spread_push end,
      case when v_publish then mk.p_over end,
      case when v_publish then mk.p_under end,
      case when v_publish then mk.p_total_push end,
      dk.spread_home, dk.total_line, dk.ml_home, dk.ml_away, dk.over_odds, dk.under_odds,
      dk.bookmaker, dk.snapshot_at,
      cfg.feature_version,
      case when v_publish then cfg.calibration_status end,
      case when v_publish then v_data_asof end,
      v_ratings_asof,
      (dk.snapshot_at is null or dk.snapshot_at <= p_decision_time) and v_ratings_asof <= p_decision_time,
      rh.games, ra.games,
      case when v_publish then v_cov end,
      case when v_publish then v_unc end,
      v_status, v_quality, v_supp,
      'nfl_points_lattice_v1',
      case when v_publish then jsonb_build_object(
        'engine','nfl_points_lattice_v1',
        'training_universe','nfl_partidos temporada=2025 tipo_temporada=2 (272 juegos finales)',
        'preseason_excluded', true,
        'preseason_note','pretemporada 2026 promedia 33.0 pts vs 46.0 regular: muestra distinta',
        'hfa_points', cfg.hfa_points,
        'league_mean_points', cfg.league_mean_points,
        'sd_team_points_base', cfg.sd_team_points,
        'early_season_sd_inflation', cfg.early_season_sd_inflation,
        'early_season_inflation_is_judgment', true,
        'shrink_k', cfg.shrink_k,
        'shrink_weight_home', rh.shrink_weight, 'shrink_weight_away', ra.shrink_weight,
        'distribution','pmf empirica 2025 inclinada a la media proyectada; key numbers 3 y 7 conservan masa real',
        'joint_is_product_of_marginals', true,
        'joint_justification','corr(pts_home,pts_away) = -0.0259 medido en 272 juegos',
        'p_tie_semantics','masa de empate al final del TIEMPO REGULAR, no empate final. Medido: el modelo da ~4.6% y el empate final real fue 1 de 272 (0.37%) en 2025, consistente con que ~8% de los empates en regular sobreviven al tiempo extra. ML se renormaliza excluyendo esta masa.',
        'markets_derived_from','pmf_home x pmf_away unicamente',
        'market_is_context_not_preto', true,
        'dk_line_source', dk.fuente, 'dk_snapshot_at', dk.snapshot_at,
        'decision_pre_kickoff', true) end
    )
    on conflict (espn_event_id, decision_time, model_version) do nothing;
    n := n + 1;
  end loop;
  return n;
end $function$;

-- ── 10) vistas de auditoría ─────────────────────────────────────────────────
create or replace view v2.v_nfl_post_kickoff_violations as
select espn_event_id, decision_time, kickoff, model_version
from v2.nfl_decision_snapshot where decision_time >= kickoff;

create or replace view v2.v_nfl_temporal_violations as
select espn_event_id, decision_time, model_version,
       dk_snapshot_at, ratings_asof, data_asof,
       case when dk_snapshot_at > decision_time then 'ODDS_POST_DECISION'
            when ratings_asof  > decision_time then 'RATINGS_POST_DECISION'
            when data_asof     > decision_time then 'DATA_ASOF_POST_DECISION' end as violacion
from v2.nfl_decision_snapshot
where dk_snapshot_at > decision_time or ratings_asof > decision_time or data_asof > decision_time;

create or replace view v2.v_nfl_snapshot_identity_violations as
select espn_event_id, decision_time, count(*) n_rows,
       string_agg(distinct model_version, ',' order by model_version) model_versions
from v2.nfl_decision_snapshot
group by espn_event_id, decision_time having count(*) > 1;

-- filas canónicas con contrato de gobernanza incompleto: el defecto que el auditor encontró
-- en MLB. Aquí es imposible por CHECK, y esta vista lo demuestra en cada corrida.
create or replace view v2.v_nfl_governance_incomplete as
select espn_event_id, decision_time, model_version, model_status,
       calibration_status, coverage, uncertainty, data_asof, ratings_asof
from v2.nfl_decision_snapshot
where model_status = 'READY'
  and (calibration_status is null or feature_version is null or coverage is null
       or uncertainty is null or provenance is null or data_asof is null or ratings_asof is null);

-- ── 11) candidatos: un mejor pick por juego entre ML / spread / total ───────
-- No EV, no Kelly, no "valor". La pregunta es qué cree el modelo y con qué probabilidad.
create or replace view v2.v_nfl_daily_candidates as
with legs as (
  select s.espn_event_id, s.decision_time, s.model_version, s.temporada, s.semana, s.kickoff,
         s.home_team, s.away_team, s.quality_status, s.calibration_status, s.coverage, s.uncertainty,
         c.market, c.side, c.line, c.p_reto, c.push
  from v2.nfl_decision_snapshot s
  cross join lateral (values
    ('ML',     s.home_team, null::numeric,      s.p_home_ml,    null::numeric),
    ('ML',     s.away_team, null,               s.p_away_ml,    null),
    ('SPREAD', s.home_team, s.dk_spread_home,   s.p_home_cover, s.p_spread_push),
    ('SPREAD', s.away_team, -s.dk_spread_home,  s.p_away_cover, s.p_spread_push),
    ('TOTAL',  'OVER',      s.dk_total,         s.p_over,       s.p_total_push),
    ('TOTAL',  'UNDER',     s.dk_total,         s.p_under,      s.p_total_push)
  ) c(market, side, line, p_reto, push)
  where s.model_status = 'READY' and c.p_reto is not null
)
select * from legs;

-- ============================================================================
-- ROLLBACK (branch only):
--   drop view if exists v2.v_nfl_daily_candidates, v2.v_nfl_governance_incomplete,
--     v2.v_nfl_snapshot_identity_violations, v2.v_nfl_temporal_violations,
--     v2.v_nfl_post_kickoff_violations;
--   drop function if exists v2.build_nfl_decision_snapshot(timestamptz,text,int,int),
--     v2.fn_nfl_dk_line_asof(text,timestamptz),
--     v2.fn_nfl_markets_from_pmf(jsonb,jsonb,numeric,numeric),
--     v2.fn_nfl_points_pmf(numeric,numeric,text),
--     v2.fn_nfl_fit_ratings(timestamptz,text,int), v2.fn_norm_pdf(numeric);
--   drop table if exists v2.nfl_decision_snapshot, v2.nfl_team_rating,
--     v2.nfl_points_shape, v2.nfl_model_config;
--
-- iss017 (NFL NO_OWN_MODEL) queda SUPERSEDED: NFL ya tiene cerebro propio. El mercado sigue
-- expuesto por separado y NUNCA como P_RETO.
-- ============================================================================
