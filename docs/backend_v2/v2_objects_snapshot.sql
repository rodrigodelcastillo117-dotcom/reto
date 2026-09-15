-- =====================================================================
-- RETO 13M V2 — Backend soccer objects, reproducible snapshot
-- Project: wpiztubmmmzclhlprgpd (prod). Captured 2026-09-09 (slice 29A closure).
-- Source of truth for the objects that already live in Supabase, versioned
-- in Git for reproducibility/auditability (fixes: "backend en prod sin cerrar
-- de forma reproducible en Git"). Re-dump with the query in README.md.
--
-- ONE BRAIN per sport: reto_dc_v2 (Dixon-Coles from real goal rates of the
-- SAME approved competition). P_RETO manda; odds are context only; fail-closed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- FUNCTION v2.fn_dist_from_lambda — DC joint goal distribution from lambdas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION v2.fn_dist_from_lambda(lh numeric, la numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; p_home numeric := 0; p_draw numeric := 0; p_away numeric := 0;
  btts numeric := 0; p_over numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  dist jsonb := '[]'::jsonb;
  hm2 numeric:=0; hm1 numeric:=0; am2 numeric:=0; am1 numeric:=0;
  o05 numeric:=0; o15 numeric:=0; o25 numeric:=0; o35 numeric:=0;
  cs_h numeric:=0; cs_a numeric:=0;
begin
  if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    tot := tot + greatest(tau,0)*ph*pa;
  end loop; end loop;
  if tot<=0 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    pij := greatest(tau,0)*ph*pa/tot;
    if i>j then p_home:=p_home+pij; elsif i=j then p_draw:=p_draw+pij; else p_away:=p_away+pij; end if;
    if i>=1 and j>=1 then btts:=btts+pij; end if;
    if over_line is not null and (i+j) > over_line then p_over:=p_over+pij; end if;
    if (i-j)>=2 then hm2:=hm2+pij; end if;
    if (i-j)>=1 then hm1:=hm1+pij; end if;
    if (j-i)>=2 then am2:=am2+pij; end if;
    if (j-i)>=1 then am1:=am1+pij; end if;
    if (i+j)>=1 then o05:=o05+pij; end if;
    if (i+j)>=2 then o15:=o15+pij; end if;
    if (i+j)>=3 then o25:=o25+pij; end if;
    if (i+j)>=4 then o35:=o35+pij; end if;
    if j=0 then cs_h:=cs_h+pij; end if;
    if i=0 then cs_a:=cs_a+pij; end if;
    if pij>best then best:=pij; best_i:=i; best_j:=j; end if;
    if pij>=0.01 then dist := dist || jsonb_build_object('s', i||'-'||j, 'p', round(pij*100,1)); end if;
  end loop; end loop;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho, 'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home*100,1), 'p_draw', round(p_draw*100,1), 'p_away', round(p_away*100,1),
    'btts_yes', round(btts*100,1), 'btts_no', round((1-btts)*100,1),
    'over_line', over_line,
    'p_over', case when over_line is null then null else round(p_over*100,1) end,
    'p_under', case when over_line is null then null else round((1-p_over)*100,1) end,
    'predicted_score', best_i||'-'||best_j, 'predicted_score_prob', round(best*100,1),
    'dist', dist, 'max_goals', maxg,
    'markets', jsonb_build_object(
      'dc_1x', round((p_home+p_draw)*100,1), 'dc_12', round((p_home+p_away)*100,1), 'dc_x2', round((p_draw+p_away)*100,1),
      'home_minus15', round(hm2*100,1), 'away_plus15', round((1-hm2)*100,1),
      'home_minus1', round(hm1*100,1), 'away_plus1', round(am1*100,1),
      'away_minus15', round(am2*100,1), 'home_plus15', round((1-am2)*100,1),
      'over05', round(o05*100,1), 'over15', round(o15*100,1), 'over25', round(o25*100,1), 'over35', round(o35*100,1),
      'under15', round((1-o15)*100,1), 'under25', round((1-o25)*100,1), 'under35', round((1-o35)*100,1),
      'clean_sheet_home', round(cs_h*100,1), 'clean_sheet_away', round(cs_a*100,1)
    ));
end $function$;

-- ---------------------------------------------------------------------
-- FUNCTION v2.fn_score_dist — resolves lambdas from goal rates, then dist
--   lh = atk_h * def_a / mgv ;  la = atk_a * def_h / mgl
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION v2.fn_score_dist(atk_h numeric, def_h numeric, atk_a numeric, def_a numeric, mgl numeric, mgv numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  lh numeric; la numeric;
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; p_home numeric := 0; p_draw numeric := 0; p_away numeric := 0;
  btts numeric := 0; p_over numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  dist jsonb := '[]'::jsonb;
begin
  if atk_h is null or def_h is null or atk_a is null or def_a is null
     or mgl is null or mgv is null or mgl<=0 or mgv<=0 then return null; end if;
  lh := atk_h * def_a / mgv;
  la := atk_a * def_h / mgl;
  if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1];
    pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    tot := tot + greatest(tau,0)*ph*pa;
  end loop; end loop;
  if tot<=0 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1];
    pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    pij := greatest(tau,0)*ph*pa/tot;
    if i>j then p_home:=p_home+pij; elsif i=j then p_draw:=p_draw+pij; else p_away:=p_away+pij; end if;
    if i>=1 and j>=1 then btts:=btts+pij; end if;
    if over_line is not null and (i+j) > over_line then p_over:=p_over+pij; end if;
    if pij>best then best:=pij; best_i:=i; best_j:=j; end if;
    if pij>=0.01 then dist := dist || jsonb_build_object('s', i||'-'||j, 'p', round(pij*100,1)); end if;
  end loop; end loop;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho,
    'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home*100,1), 'p_draw', round(p_draw*100,1), 'p_away', round(p_away*100,1),
    'btts_yes', round(btts*100,1), 'btts_no', round((1-btts)*100,1),
    'over_line', over_line,
    'p_over', case when over_line is null then null else round(p_over*100,1) end,
    'p_under', case when over_line is null then null else round((1-p_over)*100,1) end,
    'predicted_score', best_i||'-'||best_j, 'predicted_score_prob', round(best*100,1),
    'dist', dist, 'max_goals', maxg);
end $function$;

-- ---------------------------------------------------------------------
-- FUNCTION v2.build_soccer_prediction_v2 — additive builder (immutable snapshots)
--   registry-gated (reg_ok), same-competition goal rates, sample>=8, temporal_safe,
--   odds are context only. Publishes P_RETO only when publish=true else DATA_INCOMPLETE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION v2.build_soccer_prediction_v2()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare n int;
begin
  with upcoming as (
    select distinct on (a.espn_event_id) a.espn_event_id, a.liga_id, a.liga_nombre, a.home_nombre, a.away_nombre, a.fecha
    from public.agenda_espn a
    where a.deporte='soccer' and a.fecha > now()
      and a.home_nombre is not null and a.away_nombre is not null and a.liga_id is not null
    order by a.espn_event_id, a.fecha
  ),
  odds as (
    select distinct on (espn_event_id) espn_event_id, over_line, over_odds, under_odds,
           home_ml, draw_ml, away_ml, bookmaker, snapshot_at
    from public.v_momios_confiables
    where espn_event_id is not null and snapshot_at <= now()
    order by espn_event_id, snapshot_at desc
  ),
  calc as (
    select u.espn_event_id, la.competition_id, u.liga_id, u.home_nombre, u.away_nombre, u.fecha as kickoff,
           gh.partidos hpj, ga.partidos apj,
           greatest(gh.ultimo_partido, ga.ultimo_partido) data_asof,
           (r.approved is true) as reg_ok,
           o.over_line, o.over_odds, o.under_odds, o.home_ml, o.draw_ml, o.away_ml, o.bookmaker, o.snapshot_at,
           v2.fn_score_dist(gh.anotados_local_prom, gh.recibidos_local_prom,
                            ga.anotados_visita_prom, ga.recibidos_visita_prom,
                            lg.media_goles_local, lg.media_goles_visita, o.over_line) as d
    from upcoming u
    join v2.liga_alias la on la.liga_source = u.liga_nombre
    join v2.competition_catalog c on c.competition_id = la.competition_id and c.enabled = true
    left join v2.model_registry r on r.sport='soccer' and r.model_name='reto_dc_v2'
         and r.model_version='dc-2026.09.1' and r.liga_id=u.liga_id
    left join public.v_goles_equipo_futbol gh on gh.equipo = u.home_nombre and gh.liga_id = u.liga_id
    left join public.v_goles_equipo_futbol ga on ga.equipo = u.away_nombre and ga.liga_id = u.liga_id
    left join public.v_liga_promedios_futbol lg on lg.liga_id = u.liga_id
    left join odds o on o.espn_event_id = u.espn_event_id
  )
  insert into v2.soccer_prediction_v2
    (espn_event_id, competition_id, home_team, away_team, kickoff, data_asof,
     sample_home, sample_away, temporal_safe, feature_version, model_version, calibration_status,
     lambda_home, lambda_away, exp_goals_total, p_home, p_draw, p_away,
     btts_yes, btts_no, over_line, p_over, p_under, line_source,
     predicted_score, predicted_score_prob, score_dist,
     odds_home, odds_draw, odds_away, odds_over, odds_under, odds_bookmaker, odds_captured_at,
     model_status, model_status_reason, provenance)
  select
    espn_event_id, competition_id, home_nombre, away_nombre, kickoff, data_asof,
    hpj, apj, true, 'goal_rates_same_comp_v1', 'dc-2026.09.1', 'UNVALIDATED',
    (d->>'lambda_home')::numeric, (d->>'lambda_away')::numeric, (d->>'exp_goals_total')::numeric,
    case when publish then (d->>'p_home')::numeric end,
    case when publish then (d->>'p_draw')::numeric end,
    case when publish then (d->>'p_away')::numeric end,
    case when publish then (d->>'btts_yes')::numeric end,
    case when publish then (d->>'btts_no')::numeric end,
    over_line,
    case when publish then (d->>'p_over')::numeric end,
    case when publish then (d->>'p_under')::numeric end,
    case when over_line is not null then 'v_momios_confiables:'||coalesce(bookmaker,'?') end,
    case when publish then (d->>'predicted_score') end,
    case when publish then (d->>'predicted_score_prob')::numeric end,
    case when publish then d->'dist' end,
    home_ml, draw_ml, away_ml, over_odds, under_odds, bookmaker, snapshot_at,
    case when publish then 'READY_UNVALIDATED' else 'DATA_INCOMPLETE' end,
    case when publish then 'Modelo Dixon-Coles V2 desde tasas de goles reales de la MISMA competencia (aprobada). Sin validar (calibración pendiente).'
         when not reg_ok then 'Competencia no aprobada para el modelo (Champions/torneos cruzados sin modelo validado). RETO no publica probabilidad.'
         when hpj is null or apj is null then 'Sin tasas de goles de ambos equipos EN ESTA competencia. RETO no publica probabilidad.'
         when hpj < 8 or apj < 8 then 'Muestra insuficiente en esta competencia (<8 partidos). RETO no publica probabilidad.'
         when d is null then 'El modelo no pudo estimar goles. RETO no publica probabilidad.'
         else 'Datos insuficientes.' end,
    jsonb_build_object('engine','dc_goal_rates_same_comp','event_liga_id',liga_id,
                       'competition_approved',reg_ok,'odds_context','v_momios_confiables',
                       'odds_is_context_not_preto',true)
  from calc,
       lateral (select (reg_ok and hpj is not null and apj is not null and hpj>=8 and apj>=8 and d is not null) as publish) pub;
  get diagnostics n = row_count;
  return n;
end $function$;

-- ---------------------------------------------------------------------
-- model_registry seed (SINGLE SOURCE OF TRUTH for model approval)
-- Only these 11 domestic leagues are approved for reto_dc_v2 / dc-2026.09.1.
-- competition_catalog.model_supported MUST mirror this (governance).
-- ---------------------------------------------------------------------
-- liga_id | liga_nombre        (approved=true)
--   78    Bundesliga
--   88    Eredivisie
--   140   La Liga
--   262   Liga MX
--   94    Liga Portugal
--   61    Ligue 1
--   253   MLS
--   39    Premier League
--   307   Saudi Pro League
--   135   Serie A
--   203   Super Lig
-- Champions(2)/Europa(3)/Conference/CONCACAF/Libertadores/Sudamericana/
-- Leagues Cup/Danish/Eliteserien/Jupiler/Greek/Scottish = NOT approved -> P_RETO NULL.

-- The public read-contracts (v_futpro_v2, v_analisis_v2, v_reto13m_daily) are
-- versioned alongside in v2_read_contracts.sql (see README.md).
