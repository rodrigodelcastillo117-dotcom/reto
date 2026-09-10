-- ============================================================================
-- iss000 — SOCCER BRANCH BASELINE (clean-bootstrap prerequisite) · STAGED
-- ============================================================================
-- WHY THIS EXISTS: a fresh Supabase branch bootstraps to an EMPTY database
-- (0 tables, 0 migrations) because the repo has NO baseline schema migration.
-- The staged SOCCER DAG (iss032..iss039) assumes ~15 prod base objects already
-- exist. This file materializes that dependency closure with the REAL column
-- structures extracted read-only from prod (wpiztubmmmzclhlprgpd), so the DAG
-- and its self-contained gate tests can run reproducibly on a disposable branch.
--
-- NOTE: the two "provider" surfaces (v_momios_confiables, v_liga_promedios_futbol)
-- are VIEWS in prod but are created here as TABLES because the gate tests INSERT
-- their synthetic universe into them (tx + ROLLBACK). Real column structure is
-- preserved 1:1 with prod.  NO PROD MUTATION. Branch-only.
-- ============================================================================

create schema if not exists v2;

-- ── public base tables (real columns from prod) ─────────────────────────────
create table if not exists public.agenda_espn (
  espn_event_id text, espn_endpoint text, liga_id integer, liga_nombre text,
  fecha timestamptz, home_espn_id text, away_espn_id text, home_nombre text,
  away_nombre text, estado text, actualizado_at timestamptz, deporte text
);

create table if not exists public.historico_partidos_espn (
  espn_event_id text, espn_endpoint text, liga_id integer, fecha timestamptz,
  home_espn_id text, away_espn_id text, home_nombre text, away_nombre text,
  home_score integer, away_score integer, cargado_at timestamptz, tipo_temporada text
);

create table if not exists public.live_scores (
  id uuid default gen_random_uuid(), espn_event_id text, home_team text, away_team text,
  home_score integer, away_score integer, status text, minute text, liga text,
  updated_at timestamptz, period text, display_clock text, status_detail text,
  game_date timestamptz, home_sets integer, away_sets integer, home_games integer,
  away_games integer, current_set integer, deporte text, score_detail_json jsonb,
  slug_home text, slug_away text, fecha_dia date, deporte_norm text, liga_id integer,
  deporte_clave text
);

-- provider surfaces materialized as TABLES for gate-test seeding (prod = views)
create table if not exists public.v_momios_confiables (
  id uuid default gen_random_uuid(), odds_event_id text, home_team text, away_team text,
  sport_key text, home_ml numeric, away_ml numeric, draw_ml numeric, over_odds numeric,
  under_odds numeric, over_line numeric, snapshot_at timestamptz, espn_event_id text,
  bookmaker text, overround numeric, confiable boolean
);

create table if not exists public.v_liga_promedios_futbol (
  liga_id integer, partidos bigint, media_goles_local numeric, media_goles_visita numeric
);

create table if not exists public.parlays (
  id uuid default gen_random_uuid() primary key, apodo text, fecha date, picks_ids text,
  picks_data jsonb, apuesta numeric, momio_total numeric, resultado text,
  ganancia_neta numeric, picks_calificacion jsonb, created_at timestamptz default now(),
  updated_at timestamptz default now(), manual_lock boolean, confianza_calificacion text,
  bankroll_post numeric, es_reto_13m boolean
);

create table if not exists public.picks (
  id uuid default gen_random_uuid() primary key, apodo text, fecha date,
  intended_game_date date, deporte text, liga text, partido text, pick_desc text,
  momio numeric, apuesta numeric, resultado text, ganancia_neta numeric,
  bankroll_post numeric, espn_event_id text, espn_home_team text, espn_away_team text,
  confianza_calificacion text, created_at timestamptz default now(),
  updated_at timestamptz default now(), es_pata_parlay boolean, pa_activado boolean,
  pa_score_snapshot jsonb, score_final text
);

create table if not exists public.usuarios (
  id uuid default gen_random_uuid() primary key, apodo text, email text,
  created_at timestamptz default now(), user_id uuid, bankroll_inicial numeric,
  activo boolean
);

-- ligas_master: only the columns is_truly_final's fallback lookup reads
create table if not exists public.ligas_master (
  nombre text, deporte text, aliases text[]
);

-- ── v2 base tables (real columns from prod) ─────────────────────────────────
create table if not exists v2.competition_catalog (
  competition_id text primary key, sport text, provider text, provider_competition_id text,
  canonical_name text, country text, region text, group_name text, enabled boolean,
  model_supported boolean, show_in_futpro boolean, show_in_favorites boolean,
  show_in_reto13m boolean, display_order integer, season_mode text, metadata jsonb,
  created_at timestamptz default now(), updated_at timestamptz default now()
);

create table if not exists v2.liga_alias (
  liga_source text, competition_id text, created_at timestamptz default now()
);

create table if not exists v2.model_registry (
  sport text, model_name text, model_version text, liga_id integer, liga_nombre text,
  approved boolean, notes text, approved_at timestamptz default now()
);

-- ── model core function: Dixon-Coles score distribution (REAL, self-contained) ──
CREATE OR REPLACE FUNCTION v2.fn_score_dist(atk_h numeric, def_h numeric, atk_a numeric, def_a numeric, mgl numeric, mgv numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  lh numeric; la numeric;
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; p_home numeric := 0; p_draw numeric := 0; p_away numeric := 0;
  btts numeric := 0; p_over numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  dist jsonb := '[]'::jsonb; dist_sum numeric := 0;
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
    dist := dist || jsonb_build_object('s', i||'-'||j, 'p', round(pij*100,2));
    dist_sum := dist_sum + round(pij*100,2);
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
    'dist', dist, 'dist_sum_pct', round(dist_sum,1), 'max_goals', maxg, 'dist_complete', true);
end $function$;

-- ── grading guard helpers (REAL from prod; ligas_master fallback present above) ──
CREATE OR REPLACE FUNCTION public.es_accion_de_persona()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ select auth.uid() is not null $function$;

CREATE OR REPLACE FUNCTION public.is_truly_final(p_status text, p_status_detail text, p_minute text, p_period text, p_home_score integer, p_away_score integer, p_liga text, p_deporte text DEFAULT NULL::text)
 RETURNS boolean LANGUAGE plpgsql STABLE SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT := lower(COALESCE(p_status, ''));
  v_detail TEXT := lower(COALESCE(p_status_detail, ''));
  v_minute TEXT := lower(COALESCE(p_minute, ''));
  v_period_num INTEGER; v_minute_num INTEGER;
  v_liga TEXT := lower(COALESCE(p_liga, ''));
  v_dep TEXT := lower(COALESCE(p_deporte, ''));
  v_deporte_resolvido TEXT;
  v_is_soccer BOOLEAN := false; v_is_mlb BOOLEAN := false; v_is_nba BOOLEAN := false;
  v_is_nhl BOOLEAN := false; v_is_nfl BOOLEAN := false; v_is_tennis BOOLEAN := false;
  v_is_final_status BOOLEAN; v_sets_max INTEGER; v_sets_min INTEGER;
BEGIN
  v_is_final_status := v_status IN ('final', 'post', 'ft', 'complete', 'completed')
    OR v_status ~ '^status_(final|full_time|play_complete|complete)'
    OR v_status ~ '_final(_pen|_ot|_aet|_so|_overtime)?$';
  IF NOT v_is_final_status THEN RETURN false; END IF;
  IF v_detail ~ '(suspend|suspendid)' OR v_minute ~ 'suspend' OR v_status ~ 'suspend' THEN
    IF COALESCE(p_home_score,0) = 0 AND COALESCE(p_away_score,0) = 0
       AND v_detail ~ '(postpon|cancel|aplazad|cancelad)' THEN RETURN true; END IF;
    RETURN false;
  END IF;
  v_is_tennis := v_dep LIKE '%tenis%' OR v_dep LIKE '%tennis%' OR v_dep LIKE '%🎾%'
                 OR (v_liga ~* '(atp|wta|tennis|tenis)' AND v_liga !~* '(soccer|futbol)');
  IF v_is_tennis AND p_home_score IS NOT NULL AND p_away_score IS NOT NULL
     AND NOT (v_detail ~ '(retir|walkover|w/o|w\.o|default|abandon|withdraw)') THEN
    v_sets_max := greatest(p_home_score, p_away_score);
    v_sets_min := least(p_home_score, p_away_score);
    IF NOT ( (v_sets_max = 2 AND v_sets_min <= 1) OR (v_sets_max = 3 AND v_sets_min <= 2) ) THEN
      IF v_sets_max = 0 AND v_detail ~ '(postpon|cancel)' THEN RETURN true; END IF;
      RETURN false;
    END IF;
  END IF;
  IF v_detail ~ '(postpon|cancel|forfeit|rained|aplazad|cancelad)'
     OR v_minute ~ '(postpon|cancel|suspend)' OR v_status ~ '(postpon|cancel|suspend)' THEN RETURN true; END IF;
  IF v_detail IN ('final', 'ft', 'completed', 'complete', 'game over', 'fin', 'finalizado') THEN RETURN true; END IF;
  IF v_minute IN ('final', 'ft', 'completed', 'fin', 'finalizado') THEN RETURN true; END IF;
  v_is_soccer := v_dep LIKE '%fut%' OR v_dep LIKE '%soccer%' OR v_dep LIKE '%⚽%';
  v_is_mlb := v_dep LIKE '%baseball%' OR v_dep LIKE '%beis%' OR v_dep LIKE '%⚾%';
  v_is_nba := v_dep LIKE '%basket%' OR v_dep LIKE '%🏀%';
  v_is_nhl := v_dep LIKE '%hockey%' OR v_dep LIKE '%🏒%';
  v_is_nfl := (v_dep LIKE '%american%' OR v_dep LIKE '%🏈%') AND NOT v_dep LIKE '%soccer%';
  IF NOT (v_is_soccer OR v_is_mlb OR v_is_nba OR v_is_nhl OR v_is_nfl OR v_is_tennis) THEN
    SELECT lower(deporte) INTO v_deporte_resolvido FROM ligas_master
    WHERE lower(nombre) = v_liga OR EXISTS (SELECT 1 FROM unnest(aliases) a WHERE lower(a) = v_liga) LIMIT 1;
    IF v_deporte_resolvido IS NOT NULL THEN
      v_is_soccer := v_deporte_resolvido = 'soccer' OR v_deporte_resolvido LIKE '%futbol%';
      v_is_mlb := v_deporte_resolvido = 'baseball'; v_is_nba := v_deporte_resolvido = 'basketball';
      v_is_nhl := v_deporte_resolvido = 'hockey'; v_is_nfl := v_deporte_resolvido = 'football';
      v_is_tennis := v_deporte_resolvido = 'tennis';
    END IF;
  END IF;
  IF NOT (v_is_soccer OR v_is_mlb OR v_is_nba OR v_is_nhl OR v_is_nfl OR v_is_tennis) THEN
    v_is_soccer := v_liga ~* '(liga|premier|champions|europa|conference|bundes|serie a|ligue|eredivisie|mls|copa|mundial|euro|saudi pro|primera|segunda|championship)';
  END IF;
  v_minute_num := CASE WHEN v_minute ~ '^\d+' THEN substring(v_minute FROM '^(\d+)')::INTEGER ELSE NULL END;
  v_period_num := CASE WHEN p_period ~ '^\d+$' THEN p_period::INTEGER ELSE NULL END;
  IF v_status IN ('status_final_pen','status_final_ot','status_final_aet','status_final_so','status_final_overtime','status_full_time','status_play_complete') THEN RETURN true; END IF;
  IF v_is_soccer THEN
    IF v_minute_num >= 90 THEN RETURN true; END IF;
    IF v_status = 'status_final' AND (v_period_num >= 2 OR v_minute_num >= 90) THEN RETURN true; END IF;
    IF v_status = 'final' AND v_period_num >= 2 THEN RETURN true; END IF;
    RETURN false;
  END IF;
  RETURN false;
END; $function$;

-- ============================================================================
-- BASELINE ADDITIONS (SOCCER FINAL GATE) — prod base objects missing from the
-- original scaffold, required by iss031/iss035/iss038 gate tests. Extracted
-- READ-ONLY from prod (wpiztubmmmzclhlprgpd). Empty tables => genuine fail-closed
-- behavior. All idempotent. NO PROD MUTATION.
-- ============================================================================
create extension if not exists unaccent;

-- ── missing columns / constraints on baseline tables ────────────────────────
alter table public.usuarios  add column if not exists reto_inicio_at timestamptz;
create unique index if not exists usuarios_apodo_key on public.usuarios(apodo);
create unique index if not exists live_scores_espn_event_id_key on public.live_scores(espn_event_id);
alter table public.picks     add column if not exists pa_activado_at timestamptz;
alter table public.parlays   add column if not exists ai_prob_combinada numeric;
alter table public.parlays   add column if not exists cashout_monto numeric;
alter table public.parlays   add column if not exists momio_efectivo numeric;
alter table public.parlays   add column if not exists bono numeric;
alter table public.parlays   add column if not exists ganancia_total numeric;

-- ── ajustes_cuenta (bankroll adjustments; read by calcular_bankroll_actual__base) ──
create table if not exists public.ajustes_cuenta (
  id uuid default gen_random_uuid(), user_id uuid, apodo text, fecha date,
  tipo text, monto numeric, descripcion text, created_at timestamptz default now()
);

-- ── resolver_evento_canonico dependency closure (empty => fail-closed resolve) ──
create table if not exists public.evento_id_map (
  id_externo text, espn_event_id text
);
create table if not exists public.ligamx_partidos (
  id bigint, espn_event_id text, fecha_utc timestamptz, home_id bigint, away_id bigint
);
create table if not exists public.ligamx_equipos (
  api_football_id bigint, nombre text
);
create table if not exists public.marcadores_archivo (
  espn_event_id text, home_team text, away_team text, game_date timestamptz
);

-- ── bankroll truth functions (REAL from prod) ───────────────────────────────
CREATE OR REPLACE FUNCTION public.apodo_scope(p_in text)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select case when auth.uid() is not null
              then (select u.apodo from public.usuarios u where u.user_id = auth.uid())
              else p_in end
$function$;

CREATE OR REPLACE FUNCTION public.reto_desde__base(p_apodo text)
 RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select coalesce((select reto_inicio_at from usuarios where apodo = p_apodo),
                  '-infinity'::timestamptz);
$function$;

CREATE OR REPLACE FUNCTION public.reto_desde(p_apodo text)
 RETURNS timestamptz LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public.reto_desde__base(public.apodo_scope(p_apodo)) $function$;

CREATE OR REPLACE FUNCTION public.calcular_bankroll_actual__base(p_apodo text)
 RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select round(
    coalesce((select bankroll_inicial from usuarios where apodo=p_apodo),0)
  + coalesce((select sum(monto) from ajustes_cuenta
      where apodo=p_apodo and created_at >= public.reto_desde(p_apodo)),0)
  + coalesce((select sum(ganancia_neta) from picks
      where apodo=p_apodo and resultado in ('ganado','perdido','push','nulo','retirado')
        and created_at >= public.reto_desde(p_apodo)),0)
  + coalesce((select sum(ganancia_total) from parlays
      where apodo=p_apodo and resultado in ('ganado','perdido','push','nulo','retirado')
        and created_at >= public.reto_desde(p_apodo)),0), 2)
$function$;

CREATE OR REPLACE FUNCTION public.calcular_bankroll_actual(p_apodo text)
 RETURNS numeric LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public.calcular_bankroll_actual__base(public.apodo_scope(p_apodo)) $function$;

-- ── slug_equipo + resolver_evento_canonico (REAL from prod) ─────────────────
CREATE OR REPLACE FUNCTION public.slug_equipo(p text)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  WITH limpio AS (SELECT lower(unaccent(COALESCE(p,''))) t),
  sin_ruido AS (
    SELECT regexp_replace(
      regexp_replace(t,
        '(^|\s)(fc|cf|sc|ac|as|rsc|rc|hnk|nk|ifk|if|bk|fk|sk|cd|ca|club|deportivo|real|atletico|athletic|sporting|united|utd|city|calcio|ssc|us|usl|afc|cfr|mfk|zn|jk|ks|lks|gks|szk|pfc|cska|se|ec|sd|ud|sv|tsv|vfb|vfl|fsv|msv|bsc|kv|kaa|kvc|rkc|psv|nec|az)(\s|$)',
        ' ', 'g'),
      '\s+(ii|b|res\.?|reserve|u\d+|sub\d+|femenino|women|w)(\s|$)', ' ', 'g') t
    FROM limpio),
  translit AS (
    SELECT regexp_replace(
      regexp_replace(
        regexp_replace(t, 'kiev', 'kyiv', 'g'),
        'goteborg|gothenburg', 'goteborg', 'g'),
      'munchen|munich', 'munchen', 'g') t
    FROM sin_ruido)
  SELECT regexp_replace(t, '[^a-z0-9]', '', 'g') FROM translit;
$function$;

CREATE OR REPLACE FUNCTION public.resolver_evento_canonico(p_id text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_id    text := btrim(coalesce(p_id, ''));
  v_espn  text; v_num text; v_af bigint; v_home text; v_away text;
  v_fecha date; v_n int; v_partes text[];
BEGIN
  IF v_id = '' THEN
    RETURN jsonb_build_object('espn_event_id', NULL, 'reason_code', 'ANALYSIS_UNAVAILABLE', 'metodo', 'empty');
  END IF;
  IF EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_id) THEN
    RETURN jsonb_build_object('espn_event_id', v_id, 'reason_code', 'DIRECT', 'metodo', 'agenda_espn');
  END IF;
  SELECT m.espn_event_id INTO v_espn FROM evento_id_map m WHERE m.id_externo = v_id;
  IF v_espn IS NOT NULL AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_espn) THEN
    RETURN jsonb_build_object('espn_event_id', v_espn, 'reason_code', 'MAP_CACHE', 'metodo', 'evento_id_map');
  END IF;
  v_num := regexp_replace(v_id, '^af[_:]?', '', 'i');
  IF v_num ~ '^[0-9]+$' THEN
    v_af := v_num::bigint;
    SELECT p.espn_event_id INTO v_espn FROM ligamx_partidos p WHERE p.id = v_af AND p.espn_event_id IS NOT NULL;
    IF v_espn IS NOT NULL AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_espn) THEN
      RETURN jsonb_build_object('espn_event_id', v_espn, 'reason_code', 'MAP_LIGAMX', 'metodo', 'ligamx_partidos.espn_event_id');
    END IF;
    SELECT h.nombre, a.nombre, p.fecha_utc::date INTO v_home, v_away, v_fecha
      FROM ligamx_partidos p
      LEFT JOIN ligamx_equipos h ON h.api_football_id = p.home_id
      LEFT JOIN ligamx_equipos a ON a.api_football_id = p.away_id
     WHERE p.id = v_af;
  ELSIF v_id LIKE 'futmap:%' THEN
    v_partes := string_to_array(v_id, ':');
    IF array_length(v_partes, 1) >= 4 THEN
      BEGIN v_fecha := v_partes[3]::date; EXCEPTION WHEN OTHERS THEN v_fecha := NULL; END;
      v_home := split_part(v_partes[4], '_vs_', 1);
      v_away := split_part(v_partes[4], '_vs_', 2);
    END IF;
  END IF;
  IF v_home IS NOT NULL AND v_away IS NOT NULL AND v_fecha IS NOT NULL
     AND slug_equipo(v_home) <> '' AND slug_equipo(v_away) <> '' THEN
    WITH cand AS (
      SELECT DISTINCT l.espn_event_id
      FROM (SELECT espn_event_id, home_team, away_team, game_date FROM live_scores
            UNION ALL
            SELECT espn_event_id, home_team, away_team, game_date FROM marcadores_archivo) l
      WHERE l.espn_event_id ~ '^[0-9]+$'
        AND l.game_date::date BETWEEN v_fecha - 1 AND v_fecha + 1
        AND slug_equipo(l.home_team) LIKE '%' || left(slug_equipo(v_home), 6) || '%'
        AND slug_equipo(l.away_team) LIKE '%' || left(slug_equipo(v_away), 6) || '%'
        AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = l.espn_event_id)
    )
    SELECT count(*), min(espn_event_id) INTO v_n, v_espn FROM cand;
    IF v_n = 1 THEN
      RETURN jsonb_build_object('espn_event_id', v_espn, 'reason_code', 'FUZZY_UNIQUE', 'metodo', 'equipos+fecha');
    ELSIF v_n > 1 THEN
      RETURN jsonb_build_object('espn_event_id', NULL, 'reason_code', 'IDENTITY_AMBIGUOUS', 'metodo', 'equipos+fecha', 'candidatos', v_n);
    END IF;
  END IF;
  RETURN jsonb_build_object('espn_event_id', NULL, 'reason_code', 'ANALYSIS_UNAVAILABLE', 'metodo', 'no_match');
END;
$function$;

-- ── dossier CONTEXT/MARKET source tables (real prod columns; empty => not-available) ──
-- Required by v2.fn_soccer_dossier_manifest (iss030) when it evaluates a real event.
create table if not exists public.lab_soccer_xg_forward (
  captura_id bigint, match_id text, equipo_id text, lado text, xg_value numeric, source text,
  model_version text, computed_at timestamptz, available_at timestamptz, ingested_at timestamptz,
  kickoff_at timestamptz, temporal_flag text, usable_pre_kickoff boolean, notes text
);
create table if not exists public.alineaciones_espn (
  espn_event_id text, espn_endpoint text, deporte text, fecha_partido timestamptz,
  capturado_at timestamptz, minutos_antes integer, hay_alineacion boolean, rosters jsonb
);
create table if not exists public.futbol_arbitro_partido (
  espn_event_id text, liga text, fecha timestamptz, arbitro_id text, arbitro text,
  amarillas_local numeric, amarillas_visita numeric, rojas_local numeric, rojas_visita numeric,
  faltas_local numeric, faltas_visita numeric, cargado_at timestamptz
);
create table if not exists public.soccer_standings (
  id bigint, liga_id integer, liga_nombre text, temporada integer, conferencia text, grupo text,
  team_id integer, team_nombre text, team_escudo text, posicion integer, puntos integer,
  pj integer, pg integer, pe integer, pp integer, gf integer, gc integer, diff integer,
  forma text, descripcion text, updated_at timestamptz
);
create table if not exists public.bt_h2h (
  espn_event_id text, liga text, fecha timestamptz, h text, a text, over25 integer, btts integer,
  gano_local integer, h2h_over_prev numeric, h2h_local_prev numeric, h2h_n bigint
);
create table if not exists public.bt_descanso (
  espn_event_id text, equipo text, lado text, fecha timestamptz, dias_descanso numeric
);
create table if not exists public.bt_forma (
  espn_event_id text, equipo text, f_over numeric, n bigint
);
create table if not exists public.odds_pro_snapshots (
  id bigint, espn_event_id varchar, fixture_id integer, sport_key varchar, market varchar,
  pinnacle_home_odds numeric, pinnacle_draw_odds numeric, pinnacle_away_odds numeric,
  bookie_best_home_odds numeric, bookie_best_draw_odds numeric, bookie_best_away_odds numeric,
  bookie_best_name varchar, implied_pinnacle_prob_home numeric, implied_pinnacle_prob_draw numeric,
  implied_pinnacle_prob_away numeric, ev_home numeric, ev_draw numeric, ev_away numeric,
  is_opening boolean, is_closing boolean, clv_percentage numeric, created_at timestamptz
);
