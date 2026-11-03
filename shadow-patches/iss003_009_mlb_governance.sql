-- ============================================================================
-- ISS-003 + ISS-009 / ISS-009B — DEPLOY ARTIFACT — GOBERNANZA MLB
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY. Este archivo ES el artefacto exacto que se
-- desplegaría (no un generador, no un "hacer durante deploy"). Aplicar en UNA
-- transacción con lock_timeout bajo (ver runbook), en orden: Parte 1 -> 2 -> 4.
-- Mantiene obligatoriamente: CURRENT_AUTHORIZED_MODELS = NONE,
-- MLB economic_authorized = FALSE, MLB stake = $0. No autoriza MLB.
-- No recalibra, no tunea, no toca EXP_OFF/NB r=5/features. Solo cableado/gobernanza.
--
-- PARTE 1 (literal, abajo) = v_pick_canonico REAL, derivada byte-a-byte de la
--   definición VIVA de producción (pg_get_viewdef) con SOLO 3 cambios quirúrgicos:
--     (a) ISS-003a: en el arm MLB de `unidos`, `true AS bool` -> `false AS bool`
--         (calibracion_confiable MLB = FALSE fail-closed; NO mm.confiable).
--     (b) ISS-009B Parte 4a: es_pick pasa a derivarse de un CROSS JOIN LATERAL que
--         llama a economic_eligibility_v1(<ctx>) UNA sola vez (elig.j); del MISMO
--         objeto se deriva la columna NUEVA `es_pick_reason` (= elig.j->>'reason_code').
--         NO se llama dos veces a economic_eligibility_v1 (verificado: 1 sola llamada).
--     (c) `es_pick_reason` se propaga por las capas m0 -> m -> SELECT top y se AÑADE
--         al FINAL del contrato de la vista (columna #44). Las 43 columnas previas
--         quedan idénticas en nombre/orden/tipo (contrato additivo).
--   VERIFICACIÓN CRIPTOGRÁFICA del literal (para que "lo aprobado == lo desplegado"):
--     sha256(Parte 1) = b8e0457c2d94e5ea0124b2cc1b10b2ad722a924a1ffb7d2c92f9f0c01496f6c0
--   (El literal se generó DB-side transformando la def viva; el sha lo ancla.)
--   EQUIVALENCIA probada read-only en prod (283 filas reales): el eligible recomputado
--   con el ctx idéntico == v.es_pick vivo en TODAS (0 divergencias) => el refactor a
--   LATERAL no cambia es_pick; reason_code hoy = MODEL_VERSION_PROVENANCE_MISSING (NONE).
--
-- ISS-003 — el hardcode `calibracion_confiable=true` MLB mentía; Parte 1 lo pone FALSE.
--   (calibracion_confiable NO sustituye a MODEL_SKILL: gates distintos, ver review.)
-- ISS-009 / ISS-009B — mientras MLB SKILL_FINAL=INSUFFICIENT ninguna superficie
--   presenta MLB como PICK/ELITE/APOSTAR. Parte 2 gatea v_mejores_picks_mlb; Parte 4
--   propaga economically_eligible + eligibility_reason_code al dossier analisis_completo.
-- ============================================================================


-- ============================================================================
-- PARTE 1 (ISS-003a + ISS-009B 4a) — v_pick_canonico REAL (literal, def viva + 3 cambios)
-- ============================================================================
CREATE OR REPLACE VIEW public.v_pick_canonico AS
 SELECT espn_event_id,
    deporte,
    liga,
    home,
    away,
    arranca_en,
    mercado,
    pick_nombre,
    pick_desc,
    momio_declarado,
    probabilidad_pct,
    momio_justo,
    muestra_calibracion,
    calibracion_confiable,
    odds_source,
    odds_apertura,
    odds_cierre,
    clv_pct,
    clasificacion,
    confianza,
    razon,
    resumen,
    fuente,
    momio_mercado,
    casa,
    momio_capturado_at,
    home_ml,
    draw_ml,
    away_ml,
    prob_local_casa_pct,
    prob_visitante_casa_pct,
    ev_pct,
    edge_pct,
    prob_que_implica_el_precio_pct,
    favorito,
    favorito_pct,
    etiqueta_cuando,
    es_pick,
    es_senal,
    rank_en_partido,
    explicacion_precio,
    nivel_ventaja,
    zona_realidad(mercado, probabilidad_pct / 100.0) AS zona,
    es_pick_reason
   FROM ( WITH unidos AS (
                 SELECT p.espn_event_id,
                    COALESCE(ae.deporte, ls.deporte, 'soccer'::text) AS deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_mercado AS momio_declarado,
                        CASE
                            WHEN COALESCE(ae.deporte, ls.deporte, 'soccer'::text) ~~ 'baseball%'::text THEN prob_recalibrada_lado('MLB'::text, p.mercado, round(p.probabilidad_real * 100::numeric, 1), sin_acentos(p.pick_nombre) ~~ (('%'::text || sin_acentos(p.home)) || '%'::text) OR p.pick_nombre ~* '^(over|mas de)'::text)
                            ELSE round(p.probabilidad_real * 100::numeric, 1)
                        END AS probabilidad_pct,
                    NULL::numeric AS momio_justo,
                    NULL::integer AS muestra_calibracion,
                    NULL::boolean AS calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    'motor_picks'::text AS fuente
                   FROM picks_recomendados_hoy p
                     LEFT JOIN agenda_espn ae ON ae.espn_event_id = p.espn_event_id
                     LEFT JOIN live_scores ls ON ls.espn_event_id = p.espn_event_id
                  WHERE COALESCE(ae.deporte, ls.deporte, 'soccer'::text) !~~ 'baseball%'::text
                UNION ALL
                 SELECT c.espn_event_id,
                    'soccer'::text AS text,
                    c.liga_nombre,
                    c.home_nombre,
                    c.away_nombre,
                    c.arranca_en,
                    c.mercado,
                    c.pick,
                    c.pick,
                    c.momio_casa,
                        CASE
                            WHEN c.mercado = 'Over/Under'::text AND c.pick ~* '^(over|mas de) *2\.5'::text THEN ajuste_h2h_over25(c.espn_event_id, c.probabilidad_pct)
                            ELSE c.probabilidad_pct
                        END AS probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    'motor_futbol_calibrado'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    c.como_se_calculo,
                    NULL::text AS text,
                    'motor_futbol_calibrado'::text AS text
                   FROM v_picks_futbol_calibrado c
                  WHERE (c.calibracion_confiable OR c.mercado = 'Moneyline'::text) AND c.mercado !~* '(corner|tarjeta)'::text
                UNION ALL
                 SELECT mm.espn_event_id,
                    'baseball'::text AS text,
                    mm.liga_nombre,
                    mm.home_nombre,
                    mm.away_nombre,
                    mm.arranca_en,
                    mm.mercado,
                    mm.pick,
                    mm.pick,
                    NULL::numeric AS "numeric",
                    mm.prob,
                    round(100.0 / NULLIF(mm.prob, 0::numeric), 2) AS round,
                    NULL::integer AS int4,
                    false AS bool,
                    'motor_mlb_cuantitativo'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    mm.detalle,
                    NULL::text AS text,
                    'motor_mlb_cuantitativo'::text AS text
                   FROM v_picks_mlb_modelo mm
                ), precio AS (
                 SELECT u.espn_event_id,
                    u.deporte,
                    u.liga,
                    u.home,
                    u.away,
                    u.arranca_en,
                    u.mercado,
                    u.pick_nombre,
                    u.pick_desc,
                    u.momio_declarado,
                    u.probabilidad_pct,
                    u.momio_justo,
                    u.muestra_calibracion,
                    u.calibracion_confiable,
                    u.odds_source,
                    u.odds_apertura,
                    u.odds_cierre,
                    u.clv_pct,
                    u.clasificacion,
                    u.confianza,
                    u.razon,
                    u.resumen,
                    u.fuente,
                    r.momio AS momio_mercado,
                    r.casa,
                    r.capturado AS momio_capturado_at
                   FROM unidos u
                     LEFT JOIN LATERAL momio_real_de_mercado(u.espn_event_id, u.mercado, u.pick_nombre, u.home, u.away) r(momio, casa, capturado) ON true
                ), mercado AS (
                 SELECT p.espn_event_id,
                    p.deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_declarado,
                    p.probabilidad_pct,
                    p.momio_justo,
                    p.muestra_calibracion,
                    p.calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    p.fuente,
                    p.momio_mercado,
                    p.casa,
                    p.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.home_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_local_casa_pct,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.away_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_visitante_casa_pct
                   FROM precio p
                     LEFT JOIN LATERAL ( SELECT s.home_ml,
                            s.draw_ml,
                            s.away_ml
                           FROM v_radar_odds_fase s
                          WHERE s.espn_event_id = p.espn_event_id AND s.home_ml IS NOT NULL AND s.fase <> 'en_vivo'::text
                          ORDER BY s.snapshot_at DESC
                         LIMIT 1) m_1 ON true
                ), calc AS (
                 SELECT m_1.espn_event_id,
                    m_1.deporte,
                    m_1.liga,
                    m_1.home,
                    m_1.away,
                    m_1.arranca_en,
                    m_1.mercado,
                    m_1.pick_nombre,
                    m_1.pick_desc,
                    m_1.momio_declarado,
                    m_1.probabilidad_pct,
                    m_1.momio_justo,
                    m_1.muestra_calibracion,
                    m_1.calibracion_confiable,
                    m_1.odds_source,
                    m_1.odds_apertura,
                    m_1.odds_cierre,
                    m_1.clv_pct,
                    m_1.clasificacion,
                    m_1.confianza,
                    m_1.razon,
                    m_1.resumen,
                    m_1.fuente,
                    m_1.momio_mercado,
                    m_1.casa,
                    m_1.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                    m_1.prob_local_casa_pct,
                    m_1.prob_visitante_casa_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN (decision_economica_v1(m_1.probabilidad_pct, m_1.momio_mercado, m_1.mercado) ->> 'ev_pct'::text)::numeric
                            ELSE NULL::numeric
                        END AS ev_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round((m_1.probabilidad_pct / 100.0 - 1.0 / m_1.momio_mercado) * 100::numeric, 1)
                            ELSE NULL::numeric
                        END AS edge_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round(100.0 / m_1.momio_mercado, 1)
                            ELSE NULL::numeric
                        END AS prob_que_implica_el_precio_pct,
                        CASE
                            WHEN m_1.prob_local_casa_pct >= m_1.prob_visitante_casa_pct THEN m_1.home
                            ELSE m_1.away
                        END AS favorito,
                    GREATEST(m_1.prob_local_casa_pct, m_1.prob_visitante_casa_pct) AS favorito_pct,
                        CASE
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = (now() AT TIME ZONE 'America/Mexico_City'::text)::date THEN 'HOY '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = ((now() AT TIME ZONE 'America/Mexico_City'::text)::date + 1) THEN 'MAÑANA '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            ELSE (upper(to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'DD/MM'::text)) || ' · '::text) || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                        END AS etiqueta_cuando
                   FROM mercado m_1
                ), marcado AS (
                 SELECT c.espn_event_id,
                    c.deporte,
                    c.liga,
                    c.home,
                    c.away,
                    c.arranca_en,
                    c.mercado,
                    c.pick_nombre,
                    c.pick_desc,
                    c.momio_declarado,
                    c.probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    c.odds_source,
                    c.odds_apertura,
                    c.odds_cierre,
                    c.clv_pct,
                    c.clasificacion,
                    c.confianza,
                    c.razon,
                    c.resumen,
                    c.fuente,
                    c.momio_mercado,
                    c.casa,
                    c.momio_capturado_at,
                    c.home_ml,
                    c.draw_ml,
                    c.away_ml,
                    c.prob_local_casa_pct,
                    c.prob_visitante_casa_pct,
                    c.ev_pct,
                    c.edge_pct,
                    c.prob_que_implica_el_precio_pct,
                    c.favorito,
                    c.favorito_pct,
                    c.etiqueta_cuando,
                    (elig.j ->> 'eligible'::text)::boolean AS es_pick,
                    elig.j ->> 'reason_code'::text AS es_pick_reason,
                    c.momio_mercado IS NULL AND c.probabilidad_pct >= 70::numeric AND c.calibracion_confiable AS es_senal
                   FROM calc c
                     CROSS JOIN LATERAL (SELECT economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(c.deporte), 'mercado', c.mercado, 'fuente', c.fuente, 'model_version', NULL::text, 'model_skill', NULL::text, 'empirical_sufficiency',
                        CASE
                            WHEN COALESCE(c.muestra_calibracion, 0) >= 20 THEN 'OK'::text
                            ELSE 'PENDING'::text
                        END, 'semantic_validity',
                        CASE
                            WHEN pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) THEN 'PASS'::text
                            ELSE 'FAIL'::text
                        END, 'data_readiness', 'READY', 'exact_decision_price',
                        CASE
                            WHEN exact_decision_price(c.espn_event_id, c.mercado, c.pick_desc, c.home, c.away) THEN 'true'::text
                            ELSE 'false'::text
                        END, 'market_abstention', mercado_en_abstencion(c.mercado, c.pick_desc), 'ev_pct', c.ev_pct, 'ev_threshold', 2.5)) AS j) elig
                )
         SELECT m.espn_event_id,
            m.deporte,
            m.liga,
            m.home,
            m.away,
            m.arranca_en,
            m.mercado,
                CASE
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text THEN 'Gana '::text || m.home
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text THEN 'Gana '::text || m.away
                    ELSE m.pick_nombre
                END AS pick_nombre,
            m.pick_desc,
            m.momio_declarado,
            m.probabilidad_pct,
            m.momio_justo,
            m.muestra_calibracion,
            m.calibracion_confiable,
            m.odds_source,
            m.odds_apertura,
            m.odds_cierre,
            m.clv_pct,
            m.clasificacion,
            m.confianza,
            m.razon,
            m.resumen,
            m.fuente,
            m.momio_mercado,
            m.casa,
            m.momio_capturado_at,
            m.home_ml,
            m.draw_ml,
            m.away_ml,
            m.prob_local_casa_pct,
            m.prob_visitante_casa_pct,
            m.ev_pct,
            m.edge_pct,
            m.prob_que_implica_el_precio_pct,
                CASE
                    WHEN COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) >= COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) AND GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.home
                    WHEN GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.away
                    ELSE NULL::text
                END AS favorito,
            GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) AS favorito_pct,
            m.etiqueta_cuando,
            m.es_pick,
            m.es_pick_reason,
            m.es_senal,
            row_number() OVER (PARTITION BY m.espn_event_id ORDER BY m.es_pick DESC, m.es_senal DESC, m.ev_pct DESC NULLS LAST, m.probabilidad_pct DESC) AS rank_en_partido,
                CASE
                    WHEN m.momio_mercado IS NULL THEN ('Todavia no tenemos precio de casa. Nuestro modelo le da '::text || m.probabilidad_pct) || '%.'::text
                    WHEN m.ev_pct > 0::numeric THEN ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MAS de lo que vale.'::text
                    ELSE ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MENOS de lo que vale. Aqui no hay apuesta.'::text
                END AS explicacion_precio,
                CASE
                    WHEN m.es_pick AND m.edge_pct >= 5::numeric THEN 'ok'::text
                    WHEN m.es_pick THEN 'ventaja_corta'::text
                    WHEN m.es_senal THEN 'alta_probabilidad'::text
                    WHEN m.momio_mercado IS NULL THEN 'sin_precio'::text
                    ELSE 'no_apostar'::text
                END AS nivel_ventaja
           FROM ( SELECT m0.espn_event_id,
                    m0.deporte,
                    m0.liga,
                    m0.home,
                    m0.away,
                    m0.arranca_en,
                    m0.mercado,
                    m0.pick_nombre,
                    m0.pick_desc,
                    m0.momio_declarado,
                    m0.probabilidad_pct,
                    m0.momio_justo,
                    m0.muestra_calibracion,
                    m0.calibracion_confiable,
                    m0.odds_source,
                    m0.odds_apertura,
                    m0.odds_cierre,
                    m0.clv_pct,
                    m0.clasificacion,
                    m0.confianza,
                    m0.razon,
                    m0.resumen,
                    m0.fuente,
                    m0.momio_mercado,
                    m0.casa,
                    m0.momio_capturado_at,
                    m0.home_ml,
                    m0.draw_ml,
                    m0.away_ml,
                    m0.prob_local_casa_pct,
                    m0.prob_visitante_casa_pct,
                    m0.ev_pct,
                    m0.edge_pct,
                    m0.prob_que_implica_el_precio_pct,
                    m0.favorito,
                    m0.favorito_pct,
                    m0.etiqueta_cuando,
                    m0.es_pick,
                    m0.es_pick_reason,
                    m0.es_senal,
                    row_number() OVER (PARTITION BY m0.espn_event_id, (
                        CASE
                            WHEN m0.deporte = 'soccer'::text AND m0.mercado = 'Moneyline'::text THEN
                            CASE
                                WHEN m0.pick_nombre ~* '^gana +local'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.home)) || '%'::text) THEN 'ML|local'::text
                                WHEN m0.pick_nombre ~* '^gana +visitante'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.away)) || '%'::text) THEN 'ML|visita'::text
                                WHEN m0.pick_nombre ~~* '%empate%'::text THEN 'ML|empate'::text
                                ELSE 'ML|'::text || m0.pick_nombre
                            END
                            ELSE (m0.mercado || '|'::text) || m0.pick_nombre
                        END) ORDER BY (m0.fuente = 'motor_futbol_calibrado'::text) DESC, m0.muestra_calibracion DESC NULLS LAST) AS rn_dup
                   FROM marcado m0) m
          WHERE m.rn_dup = 1 AND (m.mercado = 'Moneyline'::text OR m.mercado = 'BTTS'::text OR m.mercado = 'Over/Under'::text AND (m.deporte ~~ 'baseball%'::text OR m.deporte ~~ 'football%'::text OR m.pick_nombre ~* '^(over|mas de) *2\.5'::text OR m.pick_nombre ~* '^(over|under|mas de|menos de) *3\.5'::text))) v
  WHERE espn_event_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM agenda_espn a
          WHERE a.espn_event_id = v.espn_event_id AND NOT (EXISTS ( SELECT 1
                   FROM ligas_bloqueadas b
                  WHERE b.tipo = 'endpoint'::text AND a.espn_endpoint ~~ b.patron))));


-- ============================================================================
-- PARTE 2 (ISS-003b + ISS-009) — v_mejores_picks_mlb: NULL=FAIL + gate de gobernanza
-- ============================================================================
-- Cambios vs def viva:
--   (ISS-003b) `COALESCE(j.confiable, true)` -> `COALESCE(j.confiable, false)`.
--   (ISS-009)  añade `economically_eligible` + `reason_code` desde
--              economic_eligibility_v1 (baseball, mercado, motor_mlb_cuantitativo,
--              model_version=NULL => MISSING => false hoy), y degrada `nivel` a
--              'informativo' cuando NO es económicamente elegible. Así la tarjeta
--              puede seguir mostrando análisis (prob, EV, ventaja) pero NO como
--              recomendación 'fuerte'/'ojo' mientras el skill sea insuficiente.
-- El resto del cuerpo es transcripción de la def viva (no se cambia la matemática).
CREATE OR REPLACE VIEW public.v_mejores_picks_mlb AS
WITH picks AS (
  SELECT m.espn_event_id, m.arranca_en, m.liga_nombre, m.home_nombre, m.away_nombre,
         m.mercado, m.pick, m.prob, m.detalle, m.favorito, m.favorito_pct, m.confiable,
         o.ml_home, o.ml_away, o.total_linea, o.over_odds, o.under_odds
    FROM v_picks_mlb_modelo m
    LEFT JOIN odds_espn o ON o.espn_event_id = m.espn_event_id
), con_momio AS (
  SELECT p.*,
    CASE
      WHEN p.mercado='Moneyline' AND p.pick=('ML '||p.home_nombre) THEN p.ml_home
      WHEN p.mercado='Moneyline' AND p.pick=('ML '||p.away_nombre) THEN p.ml_away
      WHEN p.mercado='Over/Under' AND p.pick ~~ 'Over %'  AND p.total_linea::text=split_part(p.pick,' ',2) THEN p.over_odds
      WHEN p.mercado='Over/Under' AND p.pick ~~ 'Under %' AND p.total_linea::text=split_part(p.pick,' ',2) THEN p.under_odds
      ELSE NULL::numeric END AS cuota,
    CASE
      WHEN p.mercado='Moneyline'  AND p.ml_home>1 AND p.ml_away>1 THEN 1/p.ml_home + 1/p.ml_away
      WHEN p.mercado='Over/Under' AND p.over_odds>1 AND p.under_odds>1 THEN 1/p.over_odds + 1/p.under_odds
      ELSE NULL::numeric END AS suma_implicita
  FROM picks p
), juzgado AS (
  SELECT c.*, filtro_pick_live(c.prob/100.0, c.cuota, c.mercado, 'baseball') AS f,
    CASE WHEN c.suma_implicita>0 THEN round(1/c.cuota/c.suma_implicita*100,1) ELSE NULL::numeric END AS mercado_sin_comision
  FROM con_momio c WHERE c.cuota > 1
), final AS (
  SELECT j.*, ((j.f->>'prob_calibrada')::numeric) - j.mercado_sin_comision AS brecha_pp
  FROM juzgado j
  -- ISS-003b: NULL=FAIL (antes COALESCE(j.confiable, true))
  WHERE ((j.f->>'pasa')::boolean) AND (j.mercado <> 'Moneyline' OR COALESCE(j.confiable, false))
)
SELECT DISTINCT ON (espn_event_id) espn_event_id, arranca_en, home_nombre, away_nombre,
  mercado, pick, cuota, prob AS prob_modelo,
  (f->>'prob_calibrada')::numeric AS prob_calibrada,
  mercado_sin_comision, round(brecha_pp,1) AS ventaja_pp,
  (f->>'wr_necesario')::numeric AS necesitas_pct,
  (f->>'ev_pct')::numeric AS ev_pct,
  COALESCE((f->>'calibrado')::boolean, true) AS calibrado,
  -- ISS-009: gate de gobernanza (hoy false: MLB no autorizado / skill insuficiente)
  (economic_eligibility_v1(jsonb_build_object(
      'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
      'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'eligible')::boolean
    AS economically_eligible,
  economic_eligibility_v1(jsonb_build_object(
      'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
      'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'reason_code'
    AS reason_code,
  -- nivel: solo es recomendación si es económicamente elegible; si no, 'informativo'
  CASE
    WHEN NOT (economic_eligibility_v1(jsonb_build_object(
         'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
         'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'eligible')::boolean
      THEN 'informativo'
    WHEN brecha_pp >= 12 THEN 'ojo'
    WHEN brecha_pp >= 3  THEN 'fuerte'
    ELSE 'flojo' END AS nivel,
  detalle,
  equipo_corto(home_nombre,'baseball') AS home_corto,
  equipo_corto(away_nombre,'baseball') AS away_corto,
  CASE
    WHEN mercado='Moneyline' AND pick=('ML '||home_nombre) THEN equipo_corto(home_nombre,'baseball')||' ML'
    WHEN mercado='Moneyline' AND pick=('ML '||away_nombre) THEN equipo_corto(away_nombre,'baseball')||' ML'
    ELSE upper(pick) END AS etiqueta,
  equipo_corto(favorito,'baseball') AS favorito_corto, favorito_pct,
  CASE WHEN mercado='Moneyline' THEN pick=('ML '||favorito) ELSE NULL::boolean END AS pick_es_favorito
FROM final
ORDER BY espn_event_id, ((f->>'ev_pct')::numeric) DESC;
-- Contrato: se AÑADEN columnas (economically_eligible, reason_code) y `nivel` pasa a
-- 'informativo' bajo NONE. El frontend debe: (1) no rotular como PICK/RECOMENDADO
-- cuando nivel='informativo' o economically_eligible=false; (2) mostrar la razón.


-- ============================================================================
-- PARTE 3 (ISS-009, OPCIONAL / gobernanza profunda) — skill como registro
-- ============================================================================
-- HOY el gate g_skill de economic_eligibility_v1 confía en el model_skill que
-- pasa la superficie (ver caso B de los tests: skill='SKILL_PASS' forzado ->
-- g_skill=true). Es seguro porque las superficies pasan NULL, pero es una
-- SUPERFICIE DE BYPASS: un edit podría pasar 'SKILL_PASS' para MLB.
--
-- PROPUESTA (mismo espíritu que economic_model_authority de ISS-006.2): el skill
-- debe ser un REGISTRO de gobernanza, no una afirmación de la superficie. Añadir
-- `skill_final` al registry y que economic_eligibility_v1 derive g_skill del
-- registro de la versión autorizada, NO del ctx.
--
-- ATENCIÓN: esto MODIFICA economic_eligibility_v1 (gate de dinero ya desplegado
-- en ISS-006.2). Hoy el efecto neto es idéntico (todo sigue en false porque no
-- hay filas autorizadas), pero cierra el bypass. Se deja como OPCIONAL: requiere
-- su propio deploy atómico + POST-VERIFY. NO incluido en el deploy principal de
-- ISS-003/009 salvo GO explícito.
--
--   ALTER TABLE public.economic_model_authority ADD COLUMN IF NOT EXISTS skill_final text;  -- default NULL = INSUFFICIENT
--   -- y en economic_eligibility_v1, reemplazar:
--   --   g_skill := (p_ctx->>'model_skill') = 'SKILL_PASS'
--   -- por:
--   --   g_skill := EXISTS (SELECT 1 FROM economic_model_authority a
--   --                       WHERE a.deporte=... AND a.mercado=... AND a.fuente=...
--   --                         AND a.model_version=mv AND a.economic_authorized
--   --                         AND a.skill_final='SKILL_PASS');
--   -- Efecto: un modelo es skill-PASS SOLO si su fila autorizada lo declara.
--   --         MLB, sin fila autorizada, es skill-INSUFFICIENT por defecto.
-- (Solo documentado; no ejecutado en este bloque.)


-- ============================================================================
-- PARTE 4 (ISS-009B) — analisis_completo: el dossier no dice "PICK SUGERIDO" si no elegible
-- ============================================================================
-- ROOT CAUSE: el banner "🎯 PICK SUGERIDO POR EL MOTOR UNIFICADO" (AnalisisCompletoModal)
-- enciende con `mercados.length > 0` — es decir, "hay info de mercado" se confunde con
-- "hay apuesta recomendada". El payload `jmkt` (= 1_el_resumen.mercados) se arma
-- `from v_pick_canonico c` (join por espn_event_id+pick), que YA trae `c.es_pick` (el
-- resultado del gate económico canónico), pero jmkt NO lo propaga.
-- PROVENANCE: suficiente. c = v_pick_canonico → no se inventan joins por nombre/equipo.
--
-- PRE-REQUISITO (Parte 4a) — YA IMPLEMENTADO en la PARTE 1 (literal, arriba).
-- La def viva de v_pick_canonico calculaba es_pick = economic_eligibility_v1(<ctx>)->>'eligible'
-- y DESCARTABA el reason_code (confirmado read-only: es_pick=true, es_pick_reason=false,
-- reason_code no referenciado, 1 sola llamada). La Parte 1 lo corrige: en el CTE `marcado`
-- el jsonb de elegibilidad se computa UNA vez vía CROSS JOIN LATERAL (elig.j) y del MISMO
-- objeto se derivan es_pick := (elig.j->>'eligible')::boolean y la columna NUEVA additiva
-- es_pick_reason := elig.j->>'reason_code'; se propaga m0 -> m -> SELECT top (columna #44).
-- `c.razon` NO se usa (es rationale del modelo, no razón de elegibilidad).
--
-- FIX MÍNIMO (Parte 4b) — insert en el fragmento jmkt (no se reescribe la función):
-- propagar economically_eligible = c.es_pick y eligibility_reason_code = c.es_pick_reason
-- (c = v_pick_canonico, ya con es_pick_reason por la Parte 1).
-- NO se envía stake_final: el dossier no dimensiona; para economically_eligible=false el
-- frontend simplemente NO muestra sizing. Nunca fabricar $0. (Si en el futuro se quiere
-- sizing en el dossier, debe venir de la autoridad canónica, no un literal.)
--
-- ⚠ ORDEN OBLIGATORIO: aplicar PARTE 1 ANTES de este DO block (Parte 4b usa c.es_pick_reason,
-- que la Parte 1 añade a v_pick_canonico). Si se ejecuta este bloque sin la Parte 1, el
-- CREATE OR REPLACE de analisis_completo fallará (columna inexistente) — fail-closed deseado
-- (no propaga un reason_code fabricado). El DO block además aborta si el needle no es único.
DO $ac$
DECLARE s text; s2 text;
  needle text := '''como_se_calculo'', c.razon)';
  repl   text := '''economically_eligible'', c.es_pick, ''eligibility_reason_code'', c.es_pick_reason, ''como_se_calculo'', c.razon)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF (length(s)-length(replace(s,needle,'')))/length(needle) <> 1 THEN
    RAISE EXCEPTION 'ISS009B_ANCHOR_NO_UNICO'; END IF;
  s2 := replace(s, needle, repl);
  IF s2 = s THEN RAISE EXCEPTION 'ISS009B_ANCHOR_NOT_FOUND'; END IF;
  EXECUTE s2;  -- re-CREATE OR REPLACE FUNCTION analisis_completo con el fragmento parcheado
  RAISE NOTICE 'analisis_completo: jmkt propaga economically_eligible/eligibility_reason_code OK';
END $ac$;
-- FRONTEND (AnalisisCompletoModal / BannerPickCanonico) — partición POR MERCADO:
--   mercados_recomendados = mercados.filter(m => m.economically_eligible === true)
--   mercados_informativos = mercados.filter(m => m.economically_eligible !== true)
--   SOLO mercados_recomendados pueden llevar "PICK SUGERIDO"/APOSTAR/RECOMENDADO.
--   mercados_informativos van bajo "ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"
--   (prob/EV/matchup visibles; sin sizing). 1 eligible + 3 no → 1 recomendado + 3 informativos.

-- ============================================================================
-- POST-VERIFY (para el deploy real; aquí como comprobación)
--   V1  0 filas MLB con calibracion_confiable=true y señal real (mm.confiable) <> true.
--   V2  v_mejores_picks_mlb: 0 filas MLB con nivel IN ('ojo','fuerte') (todas 'informativo' o 'flojo' bajo NONE).
--   V3  MLB economic picks/stake = 0 en TODAS las superficies (v_pick_canonico es_pick,
--       mejor_oportunidad_hoy, favoritos_bien_pagados, v_super_pick apto, reto_picks_hoy).
--   V4  CURRENT_AUTHORIZED_MODELS = NONE.
-- ============================================================================
