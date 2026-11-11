-- ============================================================================
-- ISS-012 — Resolver canónico de escudos (parte del CUTOVER unificado)
-- Estado: PREPARADO / NO APLICADO. Producción congelada; se aplica en el ÚNICO
--          cutover coordinado junto con el frontend de la rama unified-truth-v1.
-- ----------------------------------------------------------------------------
-- PROBLEMA (medido 2026-09-08):
--   257 partidos de futbol en ventana; 257 con fila en escudos_evento; solo 213
--   con AMBOS escudos → 44 eventos sin al menos un escudo (los "sin logo").
--   escudos_espn está VACÍO para soccer (0 filas con logo).
--   El registro real de equipos es ligamx_equipos (8,754 con escudo_url).
--
-- REGLA DURA: NUNCA poner un escudo por coincidencia difusa (fuzzy). Eso fue la
--   causa del bug "metió el logo del Atlético". Solo match EXACTO por nombre o
--   alias. Lo que no resuelve EXACTO se deja en blanco y se DOCUMENTA (no se
--   inventa un crest).
--
-- COBERTURA ESPERADA de este resolver sobre los 44:
--   ~11 home + ~12 away resolubles por nombre/alias exacto en ligamx_equipos.
--   El resto (~32 eventos) son de ligas menores que ni ESPN ni el registro
--   tienen → quedan con el fallback neutro del componente EscudoEquipo (blank),
--   nunca con un escudo equivocado. Ver bloque de AUDITORÍA al final.
-- ============================================================================

-- Función READ-ONLY: dado un conjunto de espn_event_id, devuelve el par de
-- escudos resuelto por: (1) escudos_evento; (2) si falta un lado, ligamx_equipos
-- por nombre/alias EXACTO del agenda_espn. Fail-open a lo que exista; nunca fuzzy.
CREATE OR REPLACE FUNCTION public.resolver_escudos_evento(p_ids text[])
RETURNS TABLE(espn_event_id text, escudo_local text, escudo_visitante text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH base AS (
    SELECT ae.espn_event_id, ae.home_nombre, ae.away_nombre,
           ee.escudo_local AS ev_local, ee.escudo_visitante AS ev_visita
    FROM agenda_espn ae
    LEFT JOIN escudos_evento ee ON ee.espn_event_id = ae.espn_event_id
    WHERE ae.espn_event_id = ANY(p_ids)
  ),
  reg AS (  -- índice mínimo del registro con logo
    SELECT lower(nombre) AS k, escudo_url FROM ligamx_equipos WHERE COALESCE(escudo_url,'')<>''
    UNION
    SELECT lower(a) AS k, escudo_url FROM ligamx_equipos e, unnest(e.aliases) a
     WHERE COALESCE(e.escudo_url,'')<>''
  )
  SELECT b.espn_event_id,
    COALESCE(NULLIF(b.ev_local,''),   (SELECT r.escudo_url FROM reg r WHERE r.k = lower(b.home_nombre) LIMIT 1)) AS escudo_local,
    COALESCE(NULLIF(b.ev_visita,''),  (SELECT r.escudo_url FROM reg r WHERE r.k = lower(b.away_nombre) LIMIT 1)) AS escudo_visitante
  FROM base b;
$$;

-- Backfill idempotente EXACTO de escudos_evento (opcional, se corre en el cutover):
-- rellena SOLO los lados vacíos que el resolver puede probar por match exacto.
-- No toca filas ya completas. No inventa nada.
--   UPDATE escudos_evento ee
--      SET escudo_local = COALESCE(NULLIF(ee.escudo_local,''), r.escudo_local),
--          escudo_visitante = COALESCE(NULLIF(ee.escudo_visitante,''), r.escudo_visitante)
--     FROM public.resolver_escudos_evento(ARRAY(SELECT espn_event_id FROM agenda_espn
--            WHERE deporte='soccer' AND fecha > now()-interval '2 days')) r
--    WHERE ee.espn_event_id = r.espn_event_id
--      AND (COALESCE(ee.escudo_local,'')='' OR COALESCE(ee.escudo_visitante,'')='');

-- ROLLBACK:  DROP FUNCTION IF EXISTS public.resolver_escudos_evento(text[]);

-- AUDITORÍA (correr tras aplicar para confirmar cobertura y documentar el resto):
--   SELECT count(*) FILTER (WHERE escudo_local IS NULL OR escudo_visitante IS NULL) AS aun_sin_logo
--   FROM public.resolver_escudos_evento(ARRAY(SELECT espn_event_id FROM agenda_espn
--          WHERE deporte='soccer' AND fecha BETWEEN now()-interval '2 days' AND now()+interval '10 days'));
-- Los "aun_sin_logo" son GENUINAMENTE inmapeables (ligas menores) → blank neutro
-- en EscudoEquipo, documentado, NUNCA un escudo equivocado.
