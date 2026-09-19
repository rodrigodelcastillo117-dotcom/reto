-- ROLLBACK de ISS260: devuelve a v_picks_futbol_calc la publicacion de picks de
-- Over/Under de futbol (vuelven ~40 filas de "Over 2.5" y similares).
--
-- Es el mismo texto de la vista quitando UNA linea del WHERE:
--     AND mercado <> 'Over/Under'::text
--
-- OJO al correrlo: esa superficie esta MUERTA hoy (cron 314 apagado, funcion de
-- refresco rota desde el 2026-09-11, y ni anon ni authenticated tienen SELECT).
-- Revertir esto no la enciende; solo deshace la exclusion del mercado retirado.

create or replace view public.v_picks_futbol_calc as
 SELECT espn_event_id,
    liga,
    partido,
    fecha,
    hora_cdmx,
    mercado,
    pick,
    probabilidad,
    momio_justo,
    momio_mercado,
    bookmaker,
    NULL::numeric AS ev,
    precio_verificado,
    score_valor,
    nivel,
    muestra_historica,
    acierto_historico,
    error_historico,
    marcador_probable,
    fundamento,
        CASE
            WHEN lam_h IS NULL OR lam_a IS NULL THEN 'SIN_MODELO'::text
            WHEN round(lam_h, 2) = 1.35 AND round(lam_a, 2) = 1.35 THEN 'FALLBACK'::text
            WHEN muestra_modelo IS NULL THEN 'SIN_MODELO'::text
            WHEN muestra_modelo >= 12 THEN 'ALTA'::text
            WHEN muestra_modelo >= 6 THEN 'MEDIA'::text
            ELSE 'BAJA'::text
        END AS respaldo_modelo,
    round(momio_justo * 1.06, 2) AS momio_minimo_aceptable,
    pick_publicacion_autorizada(espn_event_id, 'soccer'::text, mercado, pick) AS apostable,
    round(probabilidad - 100.0 / NULLIF(momio_mercado, 0::numeric), 2) AS desacuerdo_vs_precio_pp
   FROM picks_premium p
  WHERE fecha >= now() AND fecha <= (now() + '48:00:00'::interval)
    AND probabilidad >= 52::numeric AND probabilidad <= 80::numeric
    AND NOT (round(COALESCE(lam_h, 0::numeric), 2) = 1.35 AND round(COALESCE(lam_a, 0::numeric), 2) = 1.35)
    AND liga !~~* '%amistoso%'::text AND liga !~~* '%friendly%'::text AND liga !~~* '%pretemporada%'::text
    AND NOT pick_en_cuarentena('soccer'::text, 'Over/Under'::text, pick);

comment on view public.v_picks_futbol_calc is NULL;
