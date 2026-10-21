-- ============================================================================
-- iss034b — PARLAY GRADING TRIGGER SET (prod-faithful) · STAGED · BRANCH-ONLY
-- ============================================================================
-- WHY THIS EXISTS: iss034_parlay_gapA_test_extra (C3/C4/C5) requires the COMPLETE
-- prod grading trigger set on public.parlays — not just auto_cerrar (iss034), but
-- also protect_parlays_premature_grading + bloquear_calificacion_parlay_con_legs_futuros
-- (defense in depth). iss034_extra installs NO triggers itself, so this staged file
-- is what makes it runnable on a disposable branch.
--
-- PROVENANCE: every function body below was captured READ-ONLY from prod
-- (wpiztubmmmzclhlprgpd) via pg_get_functiondef(), VERBATIM. NO PROD MUTATION.
-- Nothing here deploys/publishes/cuts-over. NOT for supabase/migrations. Branch-only.
--
-- DEPENDENCIES (already created by iss000 baseline, read-only from prod):
--   public.live_scores, public.marcadores_archivo, public.evento_id_map,
--   public.ligamx_partidos, public.ligamx_equipos, public.slug_equipo,
--   public.is_truly_final. iss034 must be applied first (auto_cerrar_parlay_si_leg_perdido
--   + v2.fn_leg_is_final). mundial_partidos is stubbed below (prod lacks it).
-- ============================================================================

-- ── mundial_partidos: STUB only (prod has no such table). Columns cover every
--    reference in protect_parlays_premature_grading (id/estado/home_score/away_score);
--    home_id/away_id added per DAG note for schema completeness. Empty => fail-closed.
create table if not exists public.mundial_partidos (
  id int primary key, estado text, home_score int, away_score int, home_id int, away_id int
);

-- ── is_postponed_or_cancelled(text,text,text) — VERBATIM prod ────────────────
CREATE OR REPLACE FUNCTION public.is_postponed_or_cancelled(p_status text, p_status_detail text, p_minute text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE v_text TEXT;
BEGIN
  v_text := lower(COALESCE(p_status,'')||' '||COALESCE(p_status_detail,'')||' '||COALESCE(p_minute,''));
  RETURN v_text ~ '(postpon|cancel|suspend|forfeit|rained|aplazad|cancelad|suspendid|walkover|w/o|retired|retir|abandon|abandonad|no contest|awarded)';
END $function$;

-- ── buscar_marcador(text) — VERBATIM prod ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.buscar_marcador(p_espn_event_id text)
 RETURNS TABLE(home_team text, away_team text, home_score integer, away_score integer, home_sets integer, away_sets integer, status text, status_detail text, game_date timestamp with time zone, fuente text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  SELECT x.home_team, x.away_team, x.home_score, x.away_score,
         x.home_sets, x.away_sets,
         CASE WHEN coalesce(lower(x.status_detail),'') ~ '(postpon|aplaz|suspend|posterg|interrump|abandon|cancel|walkover|forfeit|awarded|pospues)'
              THEN 'postponed' ELSE x.status END AS status,
         x.status_detail, x.game_date, x.fuente
  FROM (
    SELECT l.home_team, l.away_team, l.home_score, l.away_score,
           l.home_sets, l.away_sets, l.status, l.status_detail, l.game_date,
           'live_scores'::text AS fuente, 1 AS prioridad
    FROM live_scores l WHERE l.espn_event_id = p_espn_event_id
    UNION ALL
    SELECT h.home_team, h.away_team, h.home_score, h.away_score,
           h.home_sets, h.away_sets, h.status, h.status_detail, h.game_date,
           'archivo'::text, 2
    FROM marcadores_archivo h WHERE h.espn_event_id = p_espn_event_id
    UNION ALL
    SELECT eh.nombre, ea.nombre, lp.home_score, lp.away_score,
           NULL::int, NULL::int,
           CASE WHEN lp.status = 'finished' THEN 'final'
                WHEN lp.status = 'live' THEN 'live' ELSE 'scheduled' END,
           CASE WHEN lp.status = 'finished' THEN 'FT' ELSE lp.status END,
           lp.fecha_utc, 'api_football'::text, 3
    FROM ligamx_partidos lp
    LEFT JOIN ligamx_equipos eh ON eh.id = lp.home_id
    LEFT JOIN ligamx_equipos ea ON ea.id = lp.away_id
    WHERE p_espn_event_id ~ '^af[_:][0-9]+$'
      AND lp.id = substring(p_espn_event_id from '^af[_:]([0-9]+)$')::bigint
  ) x
  ORDER BY (x.status = 'final'
            AND coalesce(lower(x.status_detail),'') !~ '(postpon|aplaz|suspend|posterg|interrump|abandon|cancel|walkover|forfeit|awarded|pospues)') DESC,
           x.prioridad
  LIMIT 1;
$function$;

-- ── buscar_marcador_v2(text,text,text,date) — VERBATIM prod ──────────────────
CREATE OR REPLACE FUNCTION public.buscar_marcador_v2(p_event_id text, p_home text DEFAULT NULL::text, p_away text DEFAULT NULL::text, p_fecha date DEFAULT NULL::date)
 RETURNS TABLE(home_team text, away_team text, home_score integer, away_score integer, home_sets integer, away_sets integer, status text, status_detail text, game_date timestamp with time zone, fuente text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE v_id text := p_event_id; v_fix bigint;
  c_no_jugado constant text := '(postpon|aplaz|suspend|posterg|interrump|abandon|cancel|walkover|forfeit|awarded|pospues)';
BEGIN
  RETURN QUERY
  SELECT x.home_team, x.away_team, x.home_score, x.away_score, x.home_sets,
         x.away_sets,
         CASE WHEN coalesce(lower(x.status_detail),'') ~ c_no_jugado THEN 'postponed' ELSE x.status END,
         x.status_detail, x.game_date, x.fuente
  FROM (
    SELECT l.home_team, l.away_team, l.home_score, l.away_score, l.home_sets,
           l.away_sets, l.status, l.status_detail, l.game_date, 'live_scores'::text fuente, 1 prio
    FROM live_scores l WHERE l.espn_event_id = v_id
    UNION ALL
    SELECT h.home_team, h.away_team, h.home_score, h.away_score, h.home_sets,
           h.away_sets, h.status, h.status_detail, h.game_date, 'archivo'::text, 2
    FROM marcadores_archivo h WHERE h.espn_event_id = v_id
  ) x ORDER BY x.prio LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  SELECT em.espn_event_id INTO v_id FROM evento_id_map em WHERE em.id_externo = p_event_id;
  IF v_id IS NOT NULL AND v_id <> p_event_id THEN
    RETURN QUERY
    SELECT x.home_team, x.away_team, x.home_score, x.away_score, x.home_sets,
           x.away_sets,
           CASE WHEN coalesce(lower(x.status_detail),'') ~ c_no_jugado THEN 'postponed' ELSE x.status END,
           x.status_detail, x.game_date, x.fuente
    FROM (
      SELECT l.home_team, l.away_team, l.home_score, l.away_score, l.home_sets,
             l.away_sets, l.status, l.status_detail, l.game_date, 'live_scores:map'::text fuente, 1 prio
      FROM live_scores l WHERE l.espn_event_id = v_id
      UNION ALL
      SELECT h.home_team, h.away_team, h.home_score, h.away_score, h.home_sets,
             h.away_sets, h.status, h.status_detail, h.game_date, 'archivo:map'::text, 2
      FROM marcadores_archivo h WHERE h.espn_event_id = v_id
    ) x ORDER BY x.prio LIMIT 1;
    IF FOUND THEN RETURN; END IF;
  END IF;

  IF p_event_id ~ '^af[_:]?[0-9]+$' THEN
    v_fix := regexp_replace(p_event_id, '^af[_:]?', '')::bigint;
    RETURN QUERY
    SELECT eh.nombre, ea.nombre,
           COALESCE((mp.raw->'score'->'fulltime'->>'home')::int, mp.home_score),
           COALESCE((mp.raw->'score'->'fulltime'->>'away')::int, mp.away_score),
           NULL::int, NULL::int,
           CASE WHEN mp.status IN ('finished','FT','AET','PEN') THEN 'final'
                WHEN mp.status IN ('scheduled','NS','TBD','PST','postponed') THEN 'pre'
                ELSE 'in' END,
           COALESCE(mp.raw->'fixture'->'status'->>'short', mp.status),
           mp.fecha_utc, 'api_football_fixture'::text
    FROM ligamx_partidos mp
    LEFT JOIN ligamx_equipos eh ON eh.api_football_id = mp.home_id
    LEFT JOIN ligamx_equipos ea ON ea.api_football_id = mp.away_id
    WHERE mp.id = v_fix AND mp.home_score IS NOT NULL
    LIMIT 1;
    IF FOUND THEN RETURN; END IF;
  END IF;

  IF p_home IS NOT NULL AND p_away IS NOT NULL THEN
    RETURN QUERY
    SELECT x.home_team, x.away_team, x.home_score, x.away_score, x.home_sets,
           x.away_sets,
           CASE WHEN coalesce(lower(x.status_detail),'') ~ c_no_jugado THEN 'postponed' ELSE x.status END,
           x.status_detail, x.game_date, x.fuente
    FROM (
      SELECT l.home_team, l.away_team, l.home_score, l.away_score, l.home_sets,
             l.away_sets, l.status, l.status_detail, l.game_date, 'live_scores:nombres'::text fuente, 1 prio
      FROM live_scores l
      WHERE slug_equipo(l.home_team)=slug_equipo(p_home) AND slug_equipo(l.away_team)=slug_equipo(p_away)
        AND (p_fecha IS NULL OR l.game_date::date BETWEEN p_fecha-1 AND p_fecha+1)
      UNION ALL
      SELECT h.home_team, h.away_team, h.home_score, h.away_score, h.home_sets,
             h.away_sets, h.status, h.status_detail, h.game_date, 'archivo:nombres'::text, 2
      FROM marcadores_archivo h
      WHERE slug_equipo(h.home_team)=slug_equipo(p_home) AND slug_equipo(h.away_team)=slug_equipo(p_away)
        AND (p_fecha IS NULL OR h.game_date::date BETWEEN p_fecha-1 AND p_fecha+1)
    ) x ORDER BY x.prio LIMIT 1;
    IF FOUND THEN RETURN; END IF;
  END IF;

  IF p_home IS NOT NULL AND p_away IS NOT NULL AND p_fecha IS NOT NULL THEN
    RETURN QUERY
    SELECT eh.nombre, ea.nombre,
           COALESCE((mp.raw->'score'->'fulltime'->>'home')::int, mp.home_score),
           COALESCE((mp.raw->'score'->'fulltime'->>'away')::int, mp.away_score),
           NULL::int, NULL::int,
           CASE WHEN mp.status IN ('finished','FT','AET','PEN') THEN 'final'
                WHEN mp.status IN ('scheduled','NS','TBD','PST','postponed') THEN 'pre'
                ELSE 'in' END,
           COALESCE(mp.raw->'fixture'->'status'->>'short', mp.status),
           mp.fecha_utc, 'api_football:nombres'::text
    FROM ligamx_partidos mp
    LEFT JOIN ligamx_equipos eh ON eh.api_football_id = mp.home_id
    LEFT JOIN ligamx_equipos ea ON ea.api_football_id = mp.away_id
    WHERE mp.home_score IS NOT NULL
      AND mp.fecha_utc::date BETWEEN p_fecha-1 AND p_fecha+1
      AND slug_equipo(eh.nombre)=slug_equipo(p_home)
      AND slug_equipo(ea.nombre)=slug_equipo(p_away)
    LIMIT 1;
  END IF;
END $function$;

-- ── bloquear_calificacion_parlay_con_legs_futuros() — VERBATIM prod ──────────
CREATE OR REPLACE FUNCTION public.bloquear_calificacion_parlay_con_legs_futuros()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today date;
  v_leg jsonb;
  v_leg_date date;
  v_legs jsonb;
  v_has_future_leg boolean := false;
  v_any_leg_lost boolean := false;
BEGIN
  -- Solo cuando cambia resultado a algo definitivo
  IF NEW.resultado IS NOT DISTINCT FROM OLD.resultado THEN
    RETURN NEW;
  END IF;

  IF NEW.resultado NOT IN ('ganado', 'perdido', 'nulo') THEN
    RETURN NEW;
  END IF;

  -- ⚡ CLAVE: un parlay con UN leg perdido YA es perdido, sin importar que
  -- los demás legs sean futuros. Permitir cerrar como 'perdido' de inmediato.
  v_legs := COALESCE(NEW.picks_data::jsonb, '[]'::jsonb);
  FOR v_leg IN SELECT jsonb_array_elements(v_legs) LOOP
    IF (v_leg ->> 'resultado') = 'perdido' THEN
      v_any_leg_lost := true;
      EXIT;
    END IF;
  END LOOP;

  -- Si hay un leg perdido y el parlay se está marcando 'perdido' → PERMITIR.
  IF v_any_leg_lost AND NEW.resultado = 'perdido' THEN
    RETURN NEW;
  END IF;

  -- Para 'ganado' o 'nulo': mantener la protección de legs futuros.
  v_today := (NOW() AT TIME ZONE 'America/Mexico_City')::date;

  FOR v_leg IN SELECT jsonb_array_elements(v_legs) LOOP
    BEGIN
      v_leg_date := (v_leg ->> 'intended_game_date')::date;
      IF v_leg_date IS NOT NULL AND v_leg_date > v_today THEN
        IF (v_leg ->> 'resultado') IS NULL OR (v_leg ->> 'resultado') = 'pendiente' THEN
          v_has_future_leg := true;
          EXIT;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;
  END LOOP;

  IF v_has_future_leg THEN
    RAISE WARNING 'BLOQUEADO parlay %: intento de calificar como % pero tiene legs pendientes con fecha futura',
      NEW.id, NEW.resultado;
    NEW.resultado := 'pendiente';
    NEW.ganancia_neta := NULL;
    NEW.bankroll_post := NULL;
  END IF;

  RETURN NEW;
END;
$function$;

-- ── protect_parlays_premature_grading() — VERBATIM prod ──────────────────────
CREATE OR REPLACE FUNCTION public.protect_parlays_premature_grading()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_leg JSONB; v_live RECORD; v_alt RECORD;
  v_is_final BOOLEAN; v_is_postponed BOOLEAN;
  v_any_premature BOOLEAN := false;
  v_any_score_mismatch BOOLEAN := false;
  v_legs JSONB;
  v_score_h_leg INTEGER; v_score_a_leg INTEGER;
  v_mundial_id INTEGER; v_mp RECORD;
BEGIN
  IF NEW.resultado IS NOT DISTINCT FROM OLD.resultado AND OLD.resultado IS NOT NULL THEN RETURN NEW; END IF;
  IF NEW.resultado NOT IN ('ganado','perdido') THEN RETURN NEW; END IF;
  IF OLD.resultado IN ('ganado','perdido','nulo') THEN RETURN NEW; END IF;
  -- AUTO_LOST_LEG NO esta exento: ese es justo el camino que hay que revisar.
  IF NEW.confianza_calificacion IN ('MANUAL','ADMIN_OVERRIDE') THEN RETURN NEW; END IF;

  v_legs := COALESCE(NEW.picks_data, OLD.picks_data);

  IF NEW.resultado = 'perdido' THEN
    FOR v_leg IN SELECT * FROM jsonb_array_elements(v_legs) LOOP
      IF (v_leg->>'resultado') = 'perdido' AND (v_leg->>'espn_event_id') IS NOT NULL THEN
        IF (v_leg->>'espn_event_id') LIKE 'mundial_%' THEN
          v_mundial_id := NULLIF(regexp_replace(v_leg->>'espn_event_id','\D','','g'),'')::int;
          SELECT estado, home_score INTO v_mp FROM mundial_partidos WHERE id = v_mundial_id;
          IF FOUND AND v_mp.estado='final' AND v_mp.home_score IS NOT NULL THEN RETURN NEW; END IF;
        ELSE
          SELECT * INTO v_live FROM live_scores WHERE espn_event_id=(v_leg->>'espn_event_id') LIMIT 1;
          IF FOUND THEN
            IF is_truly_final(v_live.status, v_live.status_detail, v_live.minute, v_live.period,
                              v_live.home_score, v_live.away_score, v_leg->>'liga', v_leg->>'deporte')
            THEN RETURN NEW; END IF;
          ELSE
            SELECT * INTO v_alt FROM buscar_marcador_v2(
              v_leg->>'espn_event_id', v_leg->>'home_team', v_leg->>'away_team',
              NULLIF(v_leg->>'intended_game_date','')::date) LIMIT 1;
            IF FOUND AND v_alt.status='final' THEN RETURN NEW; END IF;
          END IF;
        END IF;
      END IF;
    END LOOP;
  END IF;

  FOR v_leg IN SELECT * FROM jsonb_array_elements(v_legs) LOOP
    IF (v_leg->>'resultado') IN ('ganado','perdido') AND (v_leg->>'espn_event_id') IS NOT NULL THEN

      -- PAGO ANTICIPADO: la casa ya pago esta pata; el marcador final ya no la cambia.
      IF (v_leg->>'pa_activado') = 'true' THEN CONTINUE; END IF;

      IF (v_leg->>'espn_event_id') LIKE 'mundial_%' THEN
        v_mundial_id := NULLIF(regexp_replace(v_leg->>'espn_event_id','\D','','g'),'')::int;
        SELECT estado, home_score, away_score INTO v_mp FROM mundial_partidos WHERE id=v_mundial_id;
        IF NOT FOUND OR v_mp.estado<>'final' OR v_mp.home_score IS NULL THEN
          v_any_premature := true;
        END IF;
        CONTINUE;
      END IF;

      SELECT * INTO v_live FROM live_scores WHERE espn_event_id=(v_leg->>'espn_event_id') LIMIT 1;
      IF FOUND THEN
        v_is_postponed := is_postponed_or_cancelled(v_live.status, v_live.status_detail, v_live.minute);
        v_is_final := is_truly_final(v_live.status, v_live.status_detail, v_live.minute,
                        v_live.period, v_live.home_score, v_live.away_score,
                        v_leg->>'liga', v_leg->>'deporte');

        -- Suspendido/pospuesto SOLO se salta si ademas ya no puede reanudarse.
        -- is_truly_final distingue un cancelado de verdad de uno suspendido a media.
        IF v_is_postponed AND v_is_final THEN CONTINUE; END IF;

        IF NOT v_is_final THEN v_any_premature := true; END IF;
        v_score_h_leg := NULLIF(v_leg->>'homeScore','')::INTEGER;
        v_score_a_leg := NULLIF(v_leg->>'awayScore','')::INTEGER;
        IF v_score_h_leg IS NOT NULL AND v_score_a_leg IS NOT NULL THEN
          IF v_score_h_leg <> v_live.home_score OR v_score_a_leg <> v_live.away_score THEN
            v_any_score_mismatch := true;
          END IF;
        END IF;
      ELSE
        SELECT * INTO v_alt FROM buscar_marcador_v2(
          v_leg->>'espn_event_id', v_leg->>'home_team', v_leg->>'away_team',
          NULLIF(v_leg->>'intended_game_date','')::date) LIMIT 1;
        IF FOUND THEN
          IF v_alt.status <> 'final' THEN v_any_premature := true; END IF;
        ELSIF NEW.confianza_calificacion NOT IN ('MANUAL','HIGH') THEN
          v_any_premature := true;
        END IF;
      END IF;
    END IF;
  END LOOP;

  IF v_any_premature OR v_any_score_mismatch THEN
    NEW.resultado := 'pendiente';
    NEW.ganancia_neta := 0;
    NEW.confianza_calificacion := CASE
      WHEN v_any_score_mismatch THEN 'BLOQUEADO_SCORE_MISMATCH'
      ELSE 'BLOQUEADO_PREMATURO' END;
  END IF;

  RETURN NEW;
END $function$;

-- ── triggers on public.parlays (drop-if-exists then create; idempotent) ──────
-- Firing order is alphabetical by trigger name for the same timing:
--   protect_parlays_premature < trg_auto_cerrar_parlay < trg_bloquear_calificacion...
-- auto_cerrar (iss034) closes on a truly-final lost leg; protect blocks premature
-- grading; bloquear (UPDATE OF resultado) guards future legs. Defense in depth.
drop trigger if exists trg_auto_cerrar_parlay on public.parlays;
create trigger trg_auto_cerrar_parlay before update on public.parlays
  for each row execute function public.auto_cerrar_parlay_si_leg_perdido();

drop trigger if exists protect_parlays_premature on public.parlays;
create trigger protect_parlays_premature before update on public.parlays
  for each row execute function public.protect_parlays_premature_grading();

drop trigger if exists trg_bloquear_calificacion_parlay_legs_futuros on public.parlays;
create trigger trg_bloquear_calificacion_parlay_legs_futuros before update of resultado on public.parlays
  for each row execute function public.bloquear_calificacion_parlay_con_legs_futuros();
