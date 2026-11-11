-- /calibracion es ruta PÚBLICA pero su RPC calibracion_publica_kpis (STABLE, solo lectura, agrega
-- la calibración de picks ya resueltos) era SECURITY INVOKER sin grant a anon => tronaba para
-- visitantes sin login ("No se pudo cargar la calibración" + ceros).
-- Fix: DEFINER (corre como dueño, igual que la vista pública de /validacion) + grant a anon.
-- Es data de transparencia agregada (sin PII). Verificado: anon recibe n=2690, 7 bandas, 6 grupos.
ALTER FUNCTION public.calibracion_publica_kpis(boolean) SECURITY DEFINER;
GRANT EXECUTE ON FUNCTION public.calibracion_publica_kpis(boolean) TO anon, authenticated;
