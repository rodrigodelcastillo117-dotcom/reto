-- =====================================================================
-- ISS137 -- LA COBERTURA SE PARO OTRA VEZ, Y NO ERA LA CUOTA
--
-- Tras revivir la ingesta en ISS130 corrio bien un rato (24 equipos por
-- media hora) y luego bajo a 6 por media hora, sin escribir observaciones
-- nuevas. Los jobs volvian con:
--     status RETRY | reason BACKFILL_RETRY | last_error API_FOOTBALL_QUOTA_BLOCKED
-- y uno acumulaba 79 intentos.
--
-- LO QUE PARECIA: se acabo la cuota diaria de API-Football.
-- LO QUE ERA: la cuota diaria estaba en 3409 de 7500 y bloqueado=false.
--             La propia API reportaba 4239 llamadas restantes.
--
-- LA CAUSA REAL, en public.apifootball_puede_llamar:
--     v_tope := case p_prioridad
--                 when 'critico' then limite * 0.95   -- 7125
--                 when 'normal'  then limite * 0.45   -- 3375
--                 when 'bajo'    then limite * 0.35   -- 2625
--                 else                limite * 0.45   -- 3375
--
-- soccer-global-backfill llama con p_prioridad = 'medio', que NO ES NINGUNO
-- DE LOS CASOS. Cae silenciosamente al else y queda topado en 3375, cuando
-- ya iban 3409 llamadas. El backfill quedo encerrado con 4239 llamadas
-- reales disponibles que no podia tocar.
--
-- Es la tercera vez en esta sesion que un fallo se esconde en silencio:
--   ISS130  el catch vacio del kick se tragaba el 500 del worker
--   ISS130  refresh de 57s reventaba el statement_timeout sin avisar
--   ISS137  una prioridad que nadie definio cae al default sin avisar
--
-- ============ EL ARREGLO ============
--
-- 'medio' pasa a ser un caso EXPLICITO con tope 0.75 (5625 llamadas).
-- Eso es deliberado y no es "subirle a todo":
--   - critico conserva 0.95 (7125), o sea 1500 llamadas que SOLO el puede
--     usar aunque el backfill se coma su cuota entera. Calificar partidos y
--     traer resultados nunca se queda sin aire.
--   - normal y bajo no se tocan.
--   - el backfill deja de estar encerrado y puede terminar la cola.
--
-- Tambien deja de ser un caso fantasma: si manana alguien escribe otra
-- prioridad inventada, seguira cayendo al 0.45, pero al menos 'medio' ya
-- significa lo que dice.
--
-- REVERSION: volver el case a como estaba, quitando la linea de 'medio'.
-- =====================================================================

create or replace function public.apifootball_puede_llamar(p_costo integer default 1, p_prioridad text default 'normal'::text)
returns boolean language plpgsql set search_path to 'public' as $function$
declare v record; v_tope int;
begin
  insert into apifootball_uso (dia_utc) values ((now() at time zone 'utc')::date)
  on conflict (dia_utc) do nothing;
  select * into v from apifootball_uso where dia_utc = (now() at time zone 'utc')::date;

  if v.bloqueado_hasta is not null and v.bloqueado_hasta > now() then
    return false;
  elsif v.bloqueado_hasta is not null then
    update apifootball_uso set bloqueado_hasta = null, bloqueado = false where dia_utc = v.dia_utc;
  end if;

  v_tope := case p_prioridad
              when 'critico' then (v.limite * 0.95)::int  -- calificacion, resultados: casi todo
              when 'normal'  then (v.limite * 0.45)::int  -- enriquecimiento
              when 'medio'   then (v.limite * 0.75)::int  -- backfill de cobertura historica
              when 'bajo'    then (v.limite * 0.35)::int  -- relleno
              else                (v.limite * 0.45)::int end;
  if v.llamadas + p_costo > v_tope then return false; end if;

  update apifootball_uso set llamadas = llamadas + p_costo, updated_at = now() where dia_utc = v.dia_utc;
  return true;
end $function$;

-- =====================================================================
-- VERIFICADO CON LA RESPUESTA REAL, NO EN TEORIA:
--
--   Antes del arreglo, cada job volvia con API_FOOTBALL_QUOTA_BLOCKED.
--
--   Despues:
--     200 {"ok":true,"processed":4,"results":[
--       {"team":"Willem II",      "league":"Eredivisie",         "writes":12},
--       {"team":"Stenhousemuir",  "league":"Scottish League Cup","writes":5},
--       {"team":"Ross County",    "league":"Scottish Premiership","writes":0},
--       {"team":"Lyngby Boldklub","league":"Danish Superliga",   "writes":16}]}
--     33 observaciones nuevas escritas en una sola corrida.
--
--   Topes tras el cambio, con 3414 llamadas usadas:
--     medio   5625  -> puede llamar: true
--     critico 7125  -> puede llamar: true  (1500 exclusivas de reserva)
--
-- ANOTADO Y NO ARREGLADO, para no inventar:
--   A Stenhousemuir se le asigno "Scottish League Cup" como liga DOMESTICA.
--   Eso es una COPA, no una liga. El filtro de chooseLeague exige
--   tipo='league' en apifootball_ligas_catalogo, asi que el catalogo tiene
--   esa copa mal tipada. Contamina el historial domestico de ese equipo con
--   partidos de copa. Es un dato mal clasificado de origen, no logica mia;
--   lo dejo reportado en vez de parchearlo a ciegas.
-- =====================================================================
