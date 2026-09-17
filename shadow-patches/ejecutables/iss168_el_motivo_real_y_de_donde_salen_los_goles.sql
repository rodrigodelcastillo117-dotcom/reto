-- ISS168: el motivo real de por que no hay pronostico, y de donde salen los goles
--
-- DOS COSAS QUE LA TARJETA DECIA MAL, ENCONTRADAS EN LA TARJETA DE FAVORITOS
--
-- 1) "Datos del evento insuficientes. RETO no publica probabilidad."
--    en Manchester City vs Norwich City. ES FALSO.
--    Medido: Manchester City tiene 51 partidos de muestra y Norwich 28.
--    El motivo real que devuelve el modelo es
--    DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF: al EFL Championship todavia no se
--    le ha podido medir la fuerza de liga, asi que no se puede comparar a
--    Norwich con el City en la misma escala.
--
--    Decir "datos insuficientes" le echa la culpa a los datos del partido
--    cuando los datos del partido estan completos. El backend conocia el motivo
--    exacto y no lo publicaba, asi que el frontend se inventaba uno generico.
--
--    ARREGLO: public.motivo_sin_p_reto(espn_event_id) traduce el
--    model_status_reason a castellano, con las muestras reales dentro:
--      "Los dos equipos tienen historial (51 y 28 partidos), pero a una de las
--       dos divisiones todavia no se le ha podido medir la fuerza de liga, asi
--       que no se pueden comparar en la misma escala. No es que falten datos
--       del partido."
--    Cubre tambien NO_APPROVED_CROSSLEAGUE_POLICY, DOMESTIC_SAMPLE_BELOW_TARGET
--    y TEMPORAL_UNSAFE. Se expone como columna motivo_sin_p_reto.
--
-- 2) "Goles esperados 1.8 - 1.4" en esa misma tarjeta NO SALE DEL CEREBRO.
--    En la vista, goles_esperados_local y goles_esperados_visita son NULL para
--    ese partido. El 1.8 y el 1.4 vienen de contexto_sin_p_reto, que esta
--    marcado FACTUAL_CONTEXT_NOT_P_RETO y calculado con
--    ULTIMOS_5_TODAS_LAS_COMPETICIONES.
--
--    O sea: la misma etiqueta "Goles esperados" se usa para dos cosas
--    distintas, el lambda del modelo y un promedio de los ultimos 5, y el
--    usuario no tiene como distinguirlas.
--
--    ARREGLO: columna origen_de_los_goles_esperados, con dos valores:
--      MODELO                       146 tarjetas
--      CONTEXTO_FACTUAL_ULTIMOS_5     4 tarjetas
--    El frontend ahora puede etiquetarlo distinto. El backend no puede
--    arreglarlo solo: la etiqueta la pinta la tarjeta.
--
-- NOTA DE IMPLEMENTACION
--   create or replace view solo deja ANADIR columnas al final, no insertarlas
--   en medio. El primer intento fallo con 42P16 "cannot change name of view
--   column". Las dos columnas nuevas van despues de nota_total.
--
-- LO QUE ESTO DESTAPA Y NO ARREGLA EL BACKEND
--   El dueno lo vio antes que yo: hay al menos TRES componentes pintando el
--   mismo dato (MatchCardV2 en FUT PRO, PartidoFutbolCard en cartelera, y el de
--   Favoritos). Por eso el mismo partido dice "Analisis disponible - Aun sin
--   P_RETO" en una pagina y "Datos del evento insuficientes" en otra.
--
--   Es el mismo patron de todo lo de esta sesion: Besiktas con "sin pick
--   publicable" y "GANA 38.8%" a la vez, el bloque que se pinta en una pagina y
--   no en otra. Cada componente extra es otra oportunidad de que dos partes
--   digan cosas distintas del mismo partido. Un solo componente, un solo
--   contrato, bloques por deporte. Eso es de Lovable.

create or replace function public.motivo_sin_p_reto(p_event_id text)
returns text language sql stable security definer set search_path = public, v2, pg_temp as $$
  select case s.model_status_reason
    when 'DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF' then
      'Los dos equipos tienen historial ('||coalesce(s.sample_home::text,'?')||' y '
      ||coalesce(s.sample_away::text,'?')||' partidos), pero a una de las dos divisiones '
      ||'todavia no se le ha podido medir la fuerza de liga, asi que no se pueden comparar '
      ||'en la misma escala. No es que falten datos del partido.'
    when 'NO_APPROVED_CROSSLEAGUE_POLICY' then
      'Esta competicion no esta autorizada todavia para publicar probabilidad.'
    when 'DOMESTIC_SAMPLE_BELOW_TARGET' then
      'Falta historial domestico: '||coalesce(s.sample_home::text,'0')||' y '
      ||coalesce(s.sample_away::text,'0')||' partidos, y hacen falta mas.'
    when 'TEMPORAL_UNSAFE' then
      'Los datos disponibles son posteriores a la hora de corte, asi que usarlos seria hacer trampa.'
    else coalesce(s.model_status_reason, 'Sin pronostico publicable todavia.')
  end
  from v2.soccer_prediction_v2 s
  where s.espn_event_id = p_event_id
  order by s.computed_at desc limit 1;
$$;

-- Columnas nuevas al final de v_tarjeta_soccer_v1:
--   motivo_sin_p_reto              text
--   origen_de_los_goles_esperados  'MODELO' | 'CONTEXTO_FACTUAL_ULTIMOS_5'
