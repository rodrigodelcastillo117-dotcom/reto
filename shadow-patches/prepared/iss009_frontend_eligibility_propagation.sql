-- ============================================================================
-- ISS-009 — FRONTEND ELIGIBILITY PROPAGATION  (PREPARED — **NOT DEPLOYED**)
-- ============================================================================
-- Status:  PREPARED_FOR_DEPLOY. Do NOT apply automatically. No production change.
-- Author:  Claude Code (frontend fail-closed hardening, reto13 branch
--          claude/frontend-unified-picks-v1). Backend branch: this repo.
--
-- WHY -----------------------------------------------------------------------
-- The governance rule is fail-closed:
--     MISSING ECONOMIC ELIGIBILITY IS NOT PERMISSION.
-- A user-facing surface may present an ACTIONABLE recommendation only when the
-- canonical flag is TRUE:  v_pick_canonico.es_pick = true  (ISS-009 authority).
--
-- Three product views/tables that feed live pick surfaces do NOT expose that
-- flag today, so the frontend has been hard-gated to render them as ANÁLISIS
-- INFORMATIVO (never actionable):
--   * public.picks_premium    (VIEW)   -> FUT PRO "premium" section (currently
--                                          not rendered, but kept consistent)
--   * public.v_picks_premium  (VIEW)   -> pages/Premium.tsx  (LIVE)
--   * public.pick_del_dia     (TABLE)  -> pages/PickDelDia.tsx (LIVE, via edge fn)
--
-- This patch propagates the canonical eligibility signal onto those three
-- sources so the SAME frontend gate can re-activate the actionable
-- classification automatically once the value is TRUE — with ZERO further
-- frontend changes. Until then everything stays informativo (fail-closed).
--
-- SAFETY --------------------------------------------------------------------
--   * Additive only. Existing columns keep their name/type/order (required by
--     CREATE OR REPLACE VIEW). New columns are appended at the END.
--   * Eligibility is read via SCALAR SUBQUERIES against v_pick_canonico
--     (LIMIT 1) so a LEFT JOIN can never multiply rows.
--   * economically_eligible defaults to FALSE when no canonical row matches
--     (fail-closed). reason_code carries es_pick_reason for transparency.
--   * The join key normalization (lower(btrim(...)) on espn_event_id + pick
--     name) is intentionally conservative. BEFORE APPLYING: verify the key
--     matches the project's canonical normalizer (see normalize_mercado /
--     claveCanonica) and run the contract tests in shadow-patches/unified/.
--
-- HOW TO APPLY (later, deliberately, in a branch first) ----------------------
--   1. supabase branch (or staging), run this file.
--   2. Run smoke: SELECT count(*) FILTER (WHERE economically_eligible) FROM ...
--   3. Confirm reto13 surfaces re-activate only for es_pick=true rows.
--   4. Promote. NEVER apply straight to prod without the above.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) pick_del_dia (BASE TABLE) — add the eligibility columns (nullable).
--    NULL == unknown == NOT eligible on the frontend (fail-closed). The
--    pick-del-dia writer (edge function / cron) should populate these from
--    v_pick_canonico when it builds each daily pick.
-- ----------------------------------------------------------------------------
ALTER TABLE public.pick_del_dia
  ADD COLUMN IF NOT EXISTS economically_eligible boolean,
  ADD COLUMN IF NOT EXISTS reason_code           text;

COMMENT ON COLUMN public.pick_del_dia.economically_eligible IS
  'ISS-009 canonical economic eligibility. NULL/false => frontend shows ANÁLISIS INFORMATIVO (fail-closed). Populate from v_pick_canonico.es_pick.';
COMMENT ON COLUMN public.pick_del_dia.reason_code IS
  'ISS-009 es_pick_reason mirror for transparency (why eligible / why not).';

-- Optional one-time backfill from the canonical source (safe, fail-closed).
-- Left commented: run intentionally after verifying the join key.
-- UPDATE public.pick_del_dia p SET
--   economically_eligible = COALESCE(vpc.es_pick, false),
--   reason_code           = vpc.es_pick_reason
-- FROM public.v_pick_canonico vpc
-- WHERE vpc.espn_event_id = p.espn_event_id
--   AND lower(btrim(COALESCE(vpc.pick_nombre, vpc.pick_desc))) = lower(btrim(p.pick_desc));

-- ----------------------------------------------------------------------------
-- 2) picks_premium (VIEW) — recreated with two appended columns.
--    Body is the current definition verbatim; only the final SELECT gains
--    economically_eligible + reason_code via scalar subqueries.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.picks_premium AS
 WITH candidatos AS (
         SELECT a.fixture_id, a.espn_event_id, a.fecha, a.hora_cdmx, a.liga_id, a.liga, a.partido,
            a.home_nombre, a.away_nombre, a.lam_h, a.lam_a, a.marcador_probable, a.mercado, a.pick,
            a.probabilidad, a.momio_justo, a.momio_mercado, a.bookmaker, a.ev, a.precio_verificado,
            a.respaldo_confiable, a.muestra_historica, a.sesgo_historico, a.acierto_historico,
            a.error_historico, a.fundamento,
                CASE
                    WHEN a.precio_verificado THEN a.ev
                    ELSE round(a.probabilidad / 100.0 * a.momio_justo * 1.06 - 1::numeric, 4)
                END AS score_valor
           FROM v_analisis_fut_completo a
          WHERE a.fecha > now() AND a.probabilidad >= 33::numeric AND a.probabilidad <= 78::numeric
            AND a.momio_justo >= 1.45 AND a.respaldo_confiable AND a.muestra_historica >= 100::numeric
            AND (a.mercado = 'Moneyline'::text OR a.mercado = 'BTTS'::text
                 OR a.mercado = 'Over/Under'::text AND (a.pick ~~* '%2.5%'::text OR a.pick ~~* '%3.5%'::text))
            AND (a.precio_verificado AND a.ev >= 0.02
                 OR NOT a.precio_verificado AND a.muestra_historica >= 300::numeric
                    AND abs(COALESCE(a.sesgo_historico, 0::numeric)) <= 4::numeric)
            AND NOT (EXISTS ( SELECT 1 FROM ligas_bloqueadas b
                               WHERE b.tipo = 'liga_id'::text AND b.patron = a.liga_id::text))
            AND NOT (EXISTS ( SELECT 1 FROM ligas_bloqueadas b
                               WHERE b.tipo = 'nombre'::text AND COALESCE(a.liga, ''::text) ~~* b.patron))
            AND NOT (EXISTS ( SELECT 1 FROM agenda_espn ag
                               JOIN ligas_bloqueadas b ON b.tipo = 'endpoint'::text AND ag.espn_endpoint ~~ b.patron
                              WHERE ag.espn_event_id = a.espn_event_id))
        ), rankeado AS (
         SELECT c.fixture_id, c.espn_event_id, c.fecha, c.hora_cdmx, c.liga_id, c.liga, c.partido,
            c.home_nombre, c.away_nombre, c.lam_h, c.lam_a, c.marcador_probable, c.mercado, c.pick,
            c.probabilidad, c.momio_justo, c.momio_mercado, c.bookmaker, c.ev, c.precio_verificado,
            c.respaldo_confiable, c.muestra_historica, c.sesgo_historico, c.acierto_historico,
            c.error_historico, c.fundamento, c.score_valor,
            row_number() OVER (PARTITION BY c.fixture_id
                               ORDER BY c.precio_verificado DESC, c.score_valor DESC) AS rn
           FROM candidatos c
        )
 SELECT fecha, hora_cdmx, liga, partido, espn_event_id, mercado, pick, probabilidad, momio_justo,
    momio_mercado, bookmaker, ev, precio_verificado, score_valor, marcador_probable, acierto_historico,
    error_historico, muestra_historica, fundamento,
        CASE
            WHEN precio_verificado AND ev >= 0.06 AND muestra_historica >= 500::numeric THEN 'elite'::text
            WHEN precio_verificado THEN 'alto'::text
            ELSE 'medio'::text
        END AS nivel,
    round(momio_justo * 1.06, 2) AS momio_minimo_aceptable,
    -- ISS-009 eligibility (fail-closed): canonical es_pick from v_pick_canonico.
    COALESCE(( SELECT vpc.es_pick
                 FROM public.v_pick_canonico vpc
                WHERE vpc.espn_event_id = rankeado.espn_event_id
                  AND lower(btrim(COALESCE(vpc.pick_nombre, vpc.pick_desc))) = lower(btrim(rankeado.pick))
                LIMIT 1), false) AS economically_eligible,
    ( SELECT vpc.es_pick_reason
        FROM public.v_pick_canonico vpc
       WHERE vpc.espn_event_id = rankeado.espn_event_id
         AND lower(btrim(COALESCE(vpc.pick_nombre, vpc.pick_desc))) = lower(btrim(rankeado.pick))
       LIMIT 1) AS reason_code
   FROM rankeado
  WHERE rn <= 2
  ORDER BY precio_verificado DESC, score_valor DESC, fecha;

-- ----------------------------------------------------------------------------
-- 3) v_picks_premium (VIEW) — recreated with two appended columns.
--    Body is the current definition verbatim; only the final SELECT gains
--    economically_eligible + reason_code via scalar subqueries.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_picks_premium AS
 WITH combos_aprobados AS (
         SELECT v_nichos_rentables.fuente, v_nichos_rentables.liga, v_nichos_rentables.mercado_norm,
            v_nichos_rentables.rango_momio, v_nichos_rentables.muestra, v_nichos_rentables.wr_pct,
            v_nichos_rentables.roi_pct, v_nichos_rentables.clasificacion_combo
           FROM v_nichos_rentables
          WHERE v_nichos_rentables.wr_pct >= 55::numeric AND v_nichos_rentables.muestra >= 15
            AND v_nichos_rentables.roi_pct >= 0::numeric
        ), picks_candidatos AS (
         SELECT opt.id::text AS pick_id, opt.fuente, opt.espn_event_id, opt.home, opt.away,
            COALESCE((opt.home || ' vs '::text) || opt.away, ''::text) AS partido,
            opt.liga, opt.mercado, opt.pick_desc, opt.pick_nombre,
            opt.momio_mercado AS momio, opt.match_date,
            opt.ev_estimado AS ev_declarado, opt.probabilidad_real AS prob_ai_decimal, opt.clasificacion,
            normalize_mercado(COALESCE(opt.mercado, ''::text), opt.pick_desc) AS mercado_norm,
            rango_momio(opt.momio_mercado) AS rango_momio
           FROM oraculo_picks_tracking opt
          WHERE opt.resultado = 'pendiente'::text AND opt.match_date >= now()
            AND opt.match_date <= (now() + '36:00:00'::interval)
            AND (opt.fuente = ANY (ARRAY['ai_pro'::text, 'oraculo'::text, 'ai_parlay'::text]))
            AND opt.momio_mercado >= 1.40 AND opt.momio_mercado <= 5.00
            AND NOT lower(opt.pick_desc) ~~ '%corner%'::text
            AND NOT lower(opt.pick_desc) ~~ '%tarjeta%'::text
            AND NOT lower(opt.pick_desc) ~~ '%card%'::text
        )
 SELECT pc.pick_id, pc.fuente, pc.espn_event_id, pc.home, pc.away, pc.partido, pc.liga, pc.mercado,
    pc.pick_desc, pc.pick_nombre, pc.momio, pc.match_date, pc.ev_declarado,
    pc.clasificacion AS clasificacion_ai, pc.mercado_norm, pc.rango_momio,
    round(COALESCE(pc.prob_ai_decimal, 0::numeric) * 100::numeric, 1) AS prob_ai_pct,
    ca.wr_pct AS historial_wr,
    round(100.0 / pc.momio, 1) AS prob_mercado_pct,
    round(CASE WHEN pc.prob_ai_decimal IS NOT NULL
               THEN pc.prob_ai_decimal * 100::numeric * 0.40 + ca.wr_pct * 0.60
               ELSE ca.wr_pct END, 1) AS prob_estimada_pct,
    ca.muestra AS historial_muestra,
    ca.roi_pct AS historial_roi,
    ca.clasificacion_combo,
    round(GREATEST(0::numeric, LEAST(0.03,
        (ca.wr_pct / 100.0 * (pc.momio - 1::numeric) - (1::numeric - ca.wr_pct / 100.0))
        / NULLIF(pc.momio - 1::numeric, 0::numeric) * 0.25)), 4) AS kelly_fraction,
    (EXISTS ( SELECT 1 FROM lecciones_aprendidas l
               WHERE l.activa AND l.bloqueo_total = true AND l.fuente = pc.fuente
                 AND l.mercado_norm = pc.mercado_norm AND l.rango_momio = pc.rango_momio
                 AND (l.liga IS NULL OR l.liga = pc.liga))) AS tiene_bloqueo_total,
    ((((((((((((pc.fuente || ' en '::text) || pc.liga) || ' / '::text) || pc.mercado_norm) || ' ('::text)
      || pc.rango_momio) || '): '::text) || ca.muestra::text) || ' picks históricos pegaron '::text)
      || ca.wr_pct::text) || '% ('::text) || ca.roi_pct::text) || '% ROI)'::text AS razon_premium,
    -- ISS-009 eligibility (fail-closed): canonical es_pick from v_pick_canonico.
    COALESCE(( SELECT vpc.es_pick
                 FROM public.v_pick_canonico vpc
                WHERE vpc.espn_event_id = pc.espn_event_id
                  AND lower(btrim(COALESCE(vpc.pick_nombre, vpc.pick_desc))) = lower(btrim(COALESCE(pc.pick_nombre, pc.pick_desc)))
                LIMIT 1), false) AS economically_eligible,
    ( SELECT vpc.es_pick_reason
        FROM public.v_pick_canonico vpc
       WHERE vpc.espn_event_id = pc.espn_event_id
         AND lower(btrim(COALESCE(vpc.pick_nombre, vpc.pick_desc))) = lower(btrim(COALESCE(pc.pick_nombre, pc.pick_desc)))
       LIMIT 1) AS reason_code
   FROM picks_candidatos pc
     JOIN combos_aprobados ca ON ca.fuente = pc.fuente AND ca.liga = pc.liga
        AND ca.mercado_norm = pc.mercado_norm AND ca.rango_momio = pc.rango_momio
  WHERE NOT (EXISTS ( SELECT 1 FROM lecciones_aprendidas l
                       WHERE l.activa AND l.bloqueo_total = true AND l.fuente = pc.fuente
                         AND l.mercado_norm = pc.mercado_norm AND l.rango_momio = pc.rango_momio
                         AND (l.liga IS NULL OR l.liga = pc.liga)))
    AND CASE WHEN pc.prob_ai_decimal IS NOT NULL
             THEN pc.prob_ai_decimal * 100::numeric * 0.40 + ca.wr_pct * 0.60
             ELSE ca.wr_pct END <= (100.0 / pc.momio + 10::numeric)
  ORDER BY (round(CASE WHEN pc.prob_ai_decimal IS NOT NULL
                       THEN pc.prob_ai_decimal * 100::numeric * 0.40 + ca.wr_pct * 0.60
                       ELSE ca.wr_pct END, 1)) DESC, ca.muestra DESC, pc.match_date;

COMMIT;

-- ============================================================================
-- POST-APPLY VALIDATION (run manually; do not rely on this being applied)
-- ============================================================================
-- SELECT count(*) AS total,
--        count(*) FILTER (WHERE economically_eligible) AS elegibles
--   FROM public.picks_premium;
-- SELECT count(*) AS total,
--        count(*) FILTER (WHERE economically_eligible) AS elegibles
--   FROM public.v_picks_premium;
-- SELECT count(*) FILTER (WHERE economically_eligible) FROM public.pick_del_dia;
-- Expectation TODAY (authority = NONE, es_pick=false on all rows): elegibles = 0
-- => every surface stays ANÁLISIS INFORMATIVO. Correct fail-closed behavior.
-- ============================================================================
