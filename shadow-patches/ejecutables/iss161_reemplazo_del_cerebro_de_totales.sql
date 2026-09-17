-- ISS161: se reemplaza el cerebro de altas/bajas de la tarjeta
--
-- AUTORIZADO POR EL DUENO ("remplaza").
--
-- QUE SE REEMPLAZA Y QUE NO
--   SI:  los campos over_pct y under_pct de public.v_tarjeta_soccer_v1,
--        o sea el bloque de altas/bajas que ve el usuario.
--   NO:  goles_esperados_total, goles_esperados_local, goles_esperados_visita,
--        marcador_esperado, ni el 1X2, ni BTTS. Salen de otro calculo y no
--        estan en este veredicto. No se tocan.
--
-- POR QUE
--   Lo que se publicaba venia del cerebro crossleague y quedo medido como
--   PEOR_QUE_ADIVINAR_CONCLUYENTE: delta_brier +0.02199, IC95 +0.00438 a
--   +0.03959, correlacion -0.1337. No es que fuera flojo: apuntaba al reves.
--
--   El cerebro nuevo (ISS156/ISS160) le gana a adivinar con el intervalo
--   entero del lado bueno, en prueba preregistrada (ISS158) y fuera de muestra.
--
-- SOLO LINEAS 2.5 Y 3.5. EN 1.5 Y 4.5 NO SE PUBLICA NADA.
--   Misma prueba, mismo corte, n=1080 por linea:
--     1.5   mejora +0.001474  IC95 +/-0.002456  -> CRUZA CERO -> NO PASA
--     2.5   mejora +0.004506  IC95 +/-0.004129  -> PASA
--     3.5   mejora +0.005341  IC95 +/-0.004185  -> PASA
--     4.5   mejora +0.002390  IC95 +/-0.002587  -> CRUZA CERO -> NO PASA
--   La correlacion es parecida en las cuatro (0.10 a 0.14), asi que la senal
--   esta; pero en 1.5 y 4.5 la tasa base es tan desbalanceada (0.79 y 0.16)
--   que no se distingue de adivinar. Ahi la funcion devuelve null y la tarjeta
--   no ensena nada. Falla cerrado.
--
-- SE PUBLICA EL CRUDO, NO EL CALIBRADO. Y ES A PROPOSITO.
--   Se ajusto calibracion afin solo con entrenamiento y se probo fuera:
--     linea 2.5   Brier crudo 0.238457  calibrado 0.237965   (ayuda un pelo)
--     linea 3.5   Brier crudo 0.225258  calibrado 0.225917   (EMPEORA)
--   La calibracion de 3.5 se ajusto cuando la tasa base era 0.3173 y el tramo
--   de prueba vino en 0.3556: la empuja en la direccion equivocada.
--   Elegir calibrado en 2.5 y crudo en 3.5 seria escoger segun el resultado
--   ya visto. Se usa CRUDO en las dos: una sola regla, preregistrada, que pasa
--   en ambas. El paso de calibracion no se gana el sitio y se deja fuera.
--
-- GUARDIA DE PRODUCCION
--   public.ou_por_tiros_tarjeta llama a fn_soccer_ou_por_tiros con
--   exigir_cargado_at = TRUE. Siempre. El false es solo para medir historico.
--   G36.3 lo vigila.
--
-- EFECTO MEDIDO EN LA CARTELERA (211 tarjetas)
--   reemplazadas           134
--   apagadas                 6   (1 en linea 1.5, 3 en 4.5, 2 sin muestra de tiros)
--   encendidas               0
--   cambio medio            5.53 puntos
--   cambio maximo          17.10 puntos
--   cambian 10 pp o mas       17
--   over medio  antes 44.49  ->  despues 47.79
--   (el over real medido en el periodo fue 59.07%, o sea que el nuevo sigue
--    por debajo pero menos lejos que el viejo)
--
--   Gates despues del cambio: cero FAIL en gate_cobertura_y_competencias,
--   gate_frescura_de_datos y gate_fuga_temporal_tiros.
--
-- ROLLBACK
--   No hace falta tocar la vista. Basta con:
--     create or replace function public.ou_por_tiros_tarjeta(text, numeric)
--     returns jsonb language sql stable as $x$ select null::jsonb $x$;
--   y la tarjeta deja de publicar altas/bajas (falla cerrado, no vuelve al
--   cerebro viejo: ese esta medido como peor que adivinar y no debe volver).
--   El estado anterior queda en public.iss161_antes para comparar.

create or replace function public.ou_por_tiros_tarjeta(p_event_id text, p_linea numeric)
returns jsonb
language plpgsql stable as $$
declare v record; r record;
begin
  if p_linea is null or p_linea not in (2.5, 3.5) then
    return null;
  end if;

  select a.home_espn_id, a.away_espn_id, a.fecha into v
  from public.agenda_espn a where a.espn_event_id = p_event_id;
  if not found then return null; end if;

  select * into r from v2.fn_soccer_ou_por_tiros(
    v.home_espn_id, v.away_espn_id, v.fecha, p_linea, 0.3191, 10, 5, true);

  if r.estado <> 'READY' then return null; end if;

  return jsonb_build_object(
    'over_pct',  round(100*r.p_over, 1),
    'under_pct', round(100*r.p_under, 1),
    'lambda_total', r.lambda_total,
    'linea', p_linea,
    'modelo', 'ou_tiros_v1',
    'origen', 'tiros a puerta de los ultimos 10 partidos de cada equipo, convertidos a goles con la tasa de la liga y combinados con Poisson',
    'muestra', jsonb_build_object('local', r.n_home, 'visita', r.n_away),
    'evidencia', 'Probado fuera de muestra sobre 1080 partidos posteriores al 2026-08-01, con la tasa de conversion ajustada solo con partidos anteriores. Le gana a adivinar con IC95 que no cruza cero en 2.5 y en 3.5.');
end
$$;

-- El cableado a la vista se hizo con sustitucion exactamente-una-vez sobre
-- pg_get_viewdef, cambiando solo estas dos expresiones:
--   ((cal.j ->> 'over_pct')) ::numeric AS over_pct
--     -> ((public.ou_por_tiros_tarjeta(e.espn_event_id, pr.over_line) ->> 'over_pct'))::numeric AS over_pct
--   idem para under_pct
-- Si cualquiera de las dos no aparecia exactamente una vez, el DO revienta y
-- no aplica nada.

-- ------------------------------------------------------------------
-- CIERRE DEL CHECK-IN (06:07)
--
-- El check-in que yo mismo programe decia "apaga el cron soccer-stats-backfill
-- si ya termino". NO LO APAGUE, y a proposito.
--
-- Cuando escribi esa instruccion, los tiros eran datos de laboratorio. Ahora
-- son el insumo de un cerebro EN PRODUCCION. Cada dia se juegan partidos
-- nuevos; si mato el cron, la ventana de 10 partidos de cada equipo envejece y
-- el bloque de altas/bajas se va apagando solo en unos dias. Dejo de ser un
-- backfill y paso a ser mantenimiento.
--
-- Lo que se hizo: renombrarlo y bajarle el ritmo, porque a 50 por minuto con
-- 0 pendientes es desperdicio.
--     cron.unschedule('soccer-stats-backfill')
--     cron.schedule('soccer-stats-mantenimiento', '*/10 * * * *',
--                   'select v2.ciclo_stats_soccer(50);')
--
-- El de MLB si se apago (ISS159): ese si era un backfill de una sola vez y
-- su medicion ya esta cerrada con veredicto NO_PUBLICAR.
--
-- ESTADO FINAL DEL BACKFILL
--   tiros bajados            6569
--   marcados sin datos        666   (Taca de Portugal y KNVB Beker: ESPN no
--                                    publica boxscore de esas rondas)
--   pendientes por bajar        0
--   en vuelo                    0
--
-- EVIDENCIA REGISTRADA en v2.evidencia_mercado_candidato, las cuatro lineas:
--   ou_tiros_v1_linea_1.5   +0.001474  [-0.000982, +0.003930]  NO_PUBLICAR
--   ou_tiros_v1_linea_2.5   +0.004506  [+0.000377, +0.008635]  PASA_Y_SE_PUBLICA
--   ou_tiros_v1_linea_3.5   +0.005341  [+0.001156, +0.009526]  PASA_Y_SE_PUBLICA
--   ou_tiros_v1_linea_4.5   +0.002390  [-0.000197, +0.004977]  NO_PUBLICAR
--
--   Quedan al lado, sin borrar, los dos negativos previos del mismo mercado:
--   CEREBRO_CROSSLEAGUE_PUBLICADO y GF_GA_VENTANA10_ARITMETICA_DEL_DUENO,
--   los dos con veredicto PEOR_QUE_ADIVINAR_CONCLUYENTE. El historial de lo
--   que no funciono no se borra.
