-- ISS-011 — FIX API-FOOTBALL LIVE INGESTION (FOR REAL)
-- Project: wpiztubmmmzclhlprgpd (prod)
-- Status: PREPARED, NOT APPLIED. Requires READY_FOR_DEPLOY_GO (prod cron/data change,
--         NOT covered by any prior GO).
--
-- ROOT CAUSE (traced end-to-end, 2026-09-08):
--   The ONLY cron that fetches GLOBAL/UCL live scores from API-Football
--   (sync-scores-global?mode=live -> AF /fixtures?live=all) is cron jobid 205
--   'sync-live-5min', which is INACTIVE (active=false).
--   The active live cron (jobid 211 'ligamx-live-2min' -> sync-ligamx?action=live)
--   only queries /fixtures?live=262-848-16-253  (Liga MX, Leagues Cup, Concachampions,
--   MLS). It NEVER covers UEFA Champions League (AF league 2) or the other ~500 leagues.
--   The espejo cron (jobid 224) only MIRRORS ligamx_partidos -> live_scores; it fetches
--   nothing from AF, so it cannot make data fresher than its source.
--   Net effect: UCL/global live state is refreshed ONLY by the 30-min day-sweep
--   (jobid 206 'sync-dia-30min' -> mode=day&dias=0 at :12 and :42). That is why live
--   matches appear frozen for up to ~30 min. It is a DISABLED SCHEDULER, not a broken
--   upsert. The upsert (sync-scores-global) and the mirror
--   (espejar_apifootball_a_live_scores) are both correct.
--
-- PROVIDER FRESHNESS — PROVEN (mandatory >=2 observations, 2026-09-08 ~20:07-20:10 UTC):
--   Manually fired the exact call cron 205 makes (net.http_post sync-scores-global?mode=live).
--   4 real UCL matches, frozen 25 min at 39-40', advanced provider->DB->live_scores:
--     obs#1: af_1635652 46' 0-0 | af_1635654 47' 0-0 | af_1635683 48' 2-1 | af_1635714 47' 2-0
--     obs#2 (+95s): af_1635652 49' 0-0 | af_1635654 50' 0-1(GOL) | af_1635683 51' 2-2(GOL) | af_1635714 50' 2-0
--   Edge response: ok:true, /fixtures?live=all -> 71, guardados 71, espejados 4,
--   quota daily remaining 5934/7500, per-minute 299/300, 857ms. AF is fresh & correct.
--
-- SECONDARY DEFECT (status transitions) — CONFIRMED:
--   259 ligamx_partidos rows are status='live'; 156 are stale >4h (oldest updated
--   2026-08-30, ~9 days). 0 are in the 4 covered leagues. Outside those 4 leagues nothing
--   ever transitions live->finished, because mode=day only re-fetches TODAY's date and
--   the global closer effectively never runs. These zombies re-mirror into live_scores as
--   fake-live af_ rows. The 'no fake clock' primitive marcar_partidos_congelados() DOES
--   flag live_scores as 'SIN SEÑAL' after 160 min, but the mirror (cron 224, every 4 min)
--   re-asserts the stale clock from ligamx_partidos within 4 min — so the flag loses.
--   Correct fix is single-source: close stale live rows in ligamx_partidos; the mirror
--   then propagates 'final'/FT and nothing fights.
--
-- QUOTA IMPACT of re-enabling 205:
--   Daily AF budget 7500. Today used ~1566; recent daily peak 3549 (~47%).
--   205 = *5-min* cron, each fire = 1 AF call (/fixtures?live=all) [+1 backup only when
--   0 live rows]. Gated by apifootball_puede_llamar(2,'critico') AND by existence of a
--   live/near-term row. Worst case (live matches ~all day) ~288 calls/day ≈ +4%.
--   Well within budget. NO quota risk. (Enabling STEP 1 first also stops zombie live_scores
--   rows from keeping 205's guard permanently 'true'.)
--
-- ORDER: apply STEP 1 (closer + one-time cleanup), then STEP 2 (re-enable poller).

-- =====================================================================================
-- STEP 1 — Close stale live rows at the SOURCE (fixes status transitions / zombies)
-- =====================================================================================
-- A live match that kicked off > p_max_min ago and is still 'live' is over. We close it
-- to 'finished' with its last-observed score, EXCEPT matches with a pending/tracked bet:
-- those are left for the existing per-fixture re-fetch rescue in sync-ligamx runLive
-- (which pulls the REAL final score before grading) so we never mis-grade on a stale score.
-- p_max_min = 200 (>3h20m: longer than any football match incl. extra time + penalties).

CREATE OR REPLACE FUNCTION public.cerrar_partidos_live_vencidos(p_max_min integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE v_n int;
BEGIN
  WITH apostados AS (
    SELECT DISTINCT nullif(regexp_replace(espn_event_id,'^af[_:]?',''),'')::bigint AS fx
      FROM picks
     WHERE espn_event_id ~ '^af[_:]?[0-9]+$'
    UNION
    SELECT DISTINCT nullif(regexp_replace(espn_event_id,'^af[_:]?',''),'')::bigint
      FROM oraculo_picks_tracking
     WHERE espn_event_id ~ '^af[_:]?[0-9]+$'
    UNION
    SELECT DISTINCT nullif(regexp_replace(l->>'espn_event_id','^af[_:]?',''),'')::bigint
      FROM parlays p, jsonb_array_elements(p.picks_data) l
     WHERE l->>'espn_event_id' ~ '^af[_:]?[0-9]+$'
  ),
  upd AS (
    UPDATE ligamx_partidos mp
       SET status = 'finished', minuto = NULL, updated_at = now()
     WHERE mp.status = 'live'
       AND mp.fecha_utc < now() - make_interval(mins => p_max_min)
       AND mp.id NOT IN (SELECT fx FROM apostados WHERE fx IS NOT NULL)
    RETURNING 1
  )
  SELECT count(*)::int INTO v_n FROM upd;
  RETURN v_n;
END
$function$;

-- One-time cleanup of the accumulated backlog (safe: excludes bet-linked fixtures).
SELECT public.cerrar_partidos_live_vencidos(200) AS zombies_cerrados_una_vez;

-- Propagate the closures into live_scores so the app stops showing fake-live rows,
-- and flag anything still stale (bet-linked, awaiting rescue) as 'SIN SEÑAL' (no fake clock).
SELECT public.espejar_apifootball_a_live_scores(9) AS espejo_tras_cierre;   -- 9 days to cover backlog window
SELECT * FROM public.marcar_partidos_congelados();

-- Wire the closer to run every cycle of the espejo cron (jobid 224), BEFORE espejar,
-- so future zombies close automatically and are never re-mirrored as fake-live.
-- No AF calls added; pure SQL. (Folded into 224 to avoid new pg_cron jobs — pg_cron
-- saturation history, task #88.)
SELECT cron.alter_job(
  job_id  => 224,
  command => $cmd$
DO $inner$
DECLARE hay boolean;
BEGIN
  -- Cierre en el ORIGEN de partidos 'live' vencidos (>200 min desde el saque), excepto
  -- los que tienen apuesta viva (esos los recupera el rescate por-partido de sync-ligamx).
  PERFORM public.cerrar_partidos_live_vencidos(200);

  -- Solo espejar si hay algo que espejar: partidos en vivo, por arrancar,
  -- o que se movieron hace poco (para que el marcador final sí se propague).
  SELECT EXISTS (
    SELECT 1 FROM ligamx_partidos
     WHERE status = 'live'
        OR (status = 'scheduled' AND fecha_utc BETWEEN now() - interval '15 min' AND now() + interval '15 min')
        OR updated_at > now() - interval '10 min'
  ) INTO hay;

  IF hay AND pg_try_advisory_lock(778001) THEN
    BEGIN
      PERFORM public.espejar_apifootball_a_live_scores(3);
      PERFORM public.marcar_partidos_congelados();  -- deja 'SIN SEÑAL' lo que siga atorado
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_advisory_unlock(778001); RAISE;
    END;
    PERFORM pg_advisory_unlock(778001);
  END IF;
END
$inner$;
  $cmd$
);

-- =====================================================================================
-- STEP 2 — Re-enable the GLOBAL/UCL live poller (the actual freeze fix)
-- =====================================================================================
-- jobid 205 'sync-live-5min' (*/5 * * * *) -> sync-scores-global?mode=live -> /fixtures?live=all
-- Self-gated: fires only when a live/near-term row exists AND apifootball_puede_llamar(2,'critico').
UPDATE cron.job SET active = true WHERE jobid = 205;
