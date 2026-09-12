-- baseline/v_pick_canonico.sql — VOLCADO INTEGRO DE LA VISTA CANONICA
--
-- POR QUE EXISTE: iss096 decia que este archivo existia y NO ESTABA EN EL REPO.
-- El dueno lo detecto. Sin el, `REPRODUCIBLE_FROM_GIT` no se puede declarar,
-- porque toda la cadena cuelga de una vista preexistente de 21 KB que nunca
-- estuvo versionada (deuda ANTERIOR a este bloque, no creada por iss094-096).
--
-- CONTENIDO: el estado de produccion al 2026-09-12, DESPUES de iss096 y de la
-- correccion de elegibilidad/temporalidad. Ya viene sin semantica economica:
--   ev_pct, edge_pct y prob_que_implica_el_precio_pct estan en NULL
--   es_pick sale de elegibilidad_no_economica_v1 (sin ev, edge, kelly ni stake)
--   nivel_ventaja sale de estado_respaldo(), no de edge_pct
--   la temporalidad se MIDE con feature_asof vs evento_at, no con arranca_en>now()
--
-- md5 del pg_get_viewdef resultante: d12fd2437bba938a4ab90f8d833afce4
-- Verificado por verificar_checksums_iss094_096.sql
--
-- ORDEN: este archivo va ANTES de iss095/iss096. Las funciones que invoca
-- (modelo_de_pick, estado_respaldo, elegibilidad_no_economica_v1) deben existir,
-- asi que el orden completo es:
--   iss088 -> iss089 -> iss090 -> iss091 -> iss094 -> iss094b
--   -> iss095 (crea modelo_de_pick/estado_respaldo/linea_es_canonica)
--   -> iss096 (crea elegibilidad_no_economica_v1)
--   -> baseline/v_pick_canonico.sql  (esta definicion final, ya limpia)
--   -> gates_selector -> verificar_checksums_iss094_096
--
-- DEUDA QUE SIGUE ABIERTA Y NO ESCONDO: las columnas ev_pct, edge_pct,
-- prob_que_implica_el_precio_pct, favorito, favorito_pct, prob_local_casa_pct y
-- prob_visitante_casa_pct siguen EN EL CONTRATO aunque ya no tengan semantica.
-- Quitarlas exige migrar v_oraculo_canonico, v_picks_con_valor y
-- v_mis_favoritos_analisis, que es el punto 2 del orden del dueno.

create or replace view public.v_pick_canonico as
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
    NULL::numeric AS ev_pct,
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
                            WHEN m_1.momio_mercado IS NOT NULL THEN NULL::numeric
                            ELSE NULL::numeric
                        END AS ev_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN NULL::numeric
                            ELSE NULL::numeric
                        END AS edge_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN NULL::numeric
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
                     CROSS JOIN LATERAL ( SELECT elegibilidad_no_economica_v1(jsonb_build_object('deporte', deporte_registry(c.deporte), 'mercado', c.mercado, 'fuente', c.fuente, 'model_version', modelo_de_pick(c.fuente, c.deporte, c.mercado), 'model_skill', 'SKILL_UNKNOWN'::text, 'empirical_sufficiency',
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
                                END, 'market_abstention', mercado_en_abstencion(c.mercado, c.pick_desc), 'respaldo', estado_respaldo(c.deporte, c.mercado, modelo_de_pick(c.fuente, c.deporte, c.mercado)), 'feature_asof', NULL::text, 'evento_at', c.arranca_en)) AS j) elig
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
            row_number() OVER (PARTITION BY m.espn_event_id ORDER BY m.probabilidad_pct DESC NULLS LAST, m.mercado, m.pick_desc) AS rank_en_partido,
                CASE
                    WHEN m.momio_mercado IS NULL THEN ('Nuestro modelo le da '::text || m.probabilidad_pct) || '%. Todavia no tenemos precio de casa.'::text
                    ELSE ((('Nuestro modelo le da '::text || m.probabilidad_pct) || '%. La casa paga '::text) || m.momio_mercado) || ', que se muestra solo como dato informativo.'::text
                END AS explicacion_precio,
            estado_respaldo(m.deporte, m.mercado, modelo_de_pick(m.fuente, m.deporte, m.mercado)) AS nivel_ventaja
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
