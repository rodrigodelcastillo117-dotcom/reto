-- DEPLOY_ROLLBACK_SNAPSHOT — restauración de GRANTS (parte determinista del rollback).
-- Baseline pre-deploy (2026-09-07 ~06:35Z): rongo.user_id=NULL, ajustes=5, favoritos=59,
-- amigos=0, live_scores=2260. Cuerpos pre-deploy capturados en la sesión (snapshot íntegro).
-- Ejecutar SOLO si el smoke post-deploy falla y hay que revertir grants.
BEGIN;
GRANT EXECUTE ON FUNCTION public.aceptar_batalla(uuid,text,uuid)   TO anon;
GRANT EXECUTE ON FUNCTION public.cancelar_batalla(uuid,text)       TO anon;
GRANT EXECUTE ON FUNCTION public.agregar_favorito(text,text,text)  TO anon;
GRANT EXECUTE ON FUNCTION public.quitar_favorito(text,text,text)   TO anon;
GRANT EXECUTE ON FUNCTION public.generar_codigo_amigo(text)        TO anon;
GRANT EXECUTE ON FUNCTION public.reto_registrar_favoritos(text)    TO anon;
GRANT EXECUTE ON FUNCTION public.upsert_live_scores_guarded(jsonb) TO anon, authenticated;
COMMIT;
-- (El rollback de CUERPOS = re-aplicar las definiciones pre-deploy capturadas en el snapshot
--  de esta sesión; los cambios del patch son aditivos —guardia de identidad al inicio— por lo
--  que el riesgo funcional es mínimo. El deploy va en UNA transacción: si un statement falla,
--  ROLLBACK total y no queda deploy parcial.)
