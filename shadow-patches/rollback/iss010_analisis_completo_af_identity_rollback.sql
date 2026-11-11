-- ============================================================================
-- ISS-010 — ROLLBACK del resolver canónico de identidad en analisis_completo
-- ============================================================================
-- Restaura EXACTAMENTE la función original: dropea el envoltorio, renombra el
-- core de vuelta a analisis_completo (cuerpo byte-idéntico al de producción) y
-- elimina el resolver. No hay pérdida de datos: el patch no escribió nada.
--
-- CORRER SÓLO si iss010_analisis_completo_af_identity.sql fue aplicado.
-- ============================================================================

BEGIN;

-- 1) Quitar el envoltorio delgado.
DROP FUNCTION IF EXISTS public.analisis_completo(text);

-- 2) Devolver el cuerpo original a su nombre público.
ALTER FUNCTION public.analisis_completo_core(text) RENAME TO analisis_completo;

-- 3) Eliminar el resolver (ya no lo llama nadie tras el paso 1).
DROP FUNCTION IF EXISTS public.resolver_evento_canonico(text);

COMMIT;

-- ============================================================================
-- POST-ROLLBACK VALIDATION
-- ============================================================================
-- -- vuelve el comportamiento previo: el id AF da "partido no encontrado"
-- SELECT (public.analisis_completo('af_1635652'))->>'error';   -- 'partido no encontrado'
-- SELECT (public.analisis_completo('401915449'))->'partido';   -- intacto
-- SELECT count(*) FROM pg_proc WHERE proname='resolver_evento_canonico';  -- 0
-- SELECT count(*) FROM pg_proc WHERE proname='analisis_completo_core';    -- 0
-- ============================================================================
