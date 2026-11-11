-- iss078 · "Picks por probabilidad" recomendaba cosas que nosotros mismos decíamos
--          que NO iban a pasar.
--
-- El owner mandó captura de esa pantalla dentro de Favoritos. El PRIMER pick de la
-- lista era:
--     ML Miami Marlins · NOSOTROS 46.3% · lo que implica el precio 36.9%
-- Un pick al 46.3%. Nosotros mismos decimos que NO va a pasar, y aun así encabezaba
-- la pantalla. Y el owner acababa de decir: "tenemos cerebro nuevo, que se basa en
-- % DE QUE PASEN LAS COSAS".
--
-- POR QUÉ PASABA: el filtro de v_picks_con_valor era
--     WHERE ev_pct is not null AND ev_pct > 0 AND probabilidad_pct >= 45
-- Eso es EV puro. 46.3% a momio 2.71 da EV positivo, así que entraba. El piso de 45%
-- dejaba pasar justamente los que no llegan a la mitad.
-- Medido el 2026-09-11: 6 de los 20 picks estaban POR DEBAJO del 50%, y 4 de esos 6
-- eran línea de ganador de MLB, que es exactamente el mercado que perdió 7 de 8.
-- La pantalla ya decía arriba "Ordenados por qué tanto discrepamos del precio de la
-- casa, no por el porcentaje más alto" -- el texto era correcto, el FILTRO no.
--
-- ===== TRES REGLAS NUEVAS, NINGUNA ES EV =====
-- 1. PISO DE 50%. Si el cerebro se basa en el % de que pase, no puede recomendar algo
--    que él mismo cree que no va a pasar. Menos de 50% no es un pick. Se acabó.
-- 2. SE RESPETA mercados_sin_modelo. Es el registro que YA EXISTÍA en el sistema para
--    declarar "aquí no tenemos modelo propio"; no inventé un mecanismo nuevo.
-- 3. EL ORDEN ES POR DISCRIMINACIÓN (nuestro % menos el % que implica el precio), no
--    por el % más alto: el % más alto suele ser el favorito obvio, donde no hay nada
--    que ganar. Y tampoco por EV.
-- Además se exige probabilidad_pct > prob_que_implica_el_precio_pct: si el mercado nos
-- gana en el propio pick, no hay nada que decir.
-- ev_pct se conserva como columna (para no romper a quien la lea) pero devuelve NULL.
--
-- ===== SE AGREGÓ AL REGISTRO: mlb_moneyline_sin_modelo =====
-- Con la evidencia enfrente, no por corazonada:
--   mlb_shadow_predicciones, 800 partidos liquidados:
--     Brier prod_espejo_0.5 = 0.24707 · shadow_0.2 = 0.24801
--     Un volado = 0.25. "Siempre gana el local" (tasa 0.538) = 0.2486.
--     El modelo de MLB está DENTRO DEL RUIDO de un volado.
--   Historial publicado: 8 picks, TODOS línea de ganador de MLB, 1-7.
--     12.5% real contra 58.0% prometido; probabilidad de eso si el modelo fuera de
--     verdad 58%: 1.17%. Desacuerdo medio contra el precio: 1.26 puntos.
--   Y predecir_mlb LO DICE ÉL MISMO en su aviso_modelo:
--     "En beisbol el mercado casi siempre tiene razon... No apostar la linea de ganador"
-- SOLO se bloqueó la LÍNEA DE GANADOR, no los totales: el aviso del sistema es
-- específico de ese mercado, y los totales de MLB siguen apareciendo. Bloquear lo que
-- el sistema declaró, ni más ni menos.
--
-- ===== SE CORRIGIÓ nfl_sin_modelo, QUE DECÍA ALGO FALSO =====
-- Decía: "NFL no tiene modelo propio: nfl_predecir devuelve la cuota de la casa sin
-- vig como si fuera probabilidad del motor." Eso ERA cierto el 5-sep y HOY ES FALSO.
-- Verificado el 2026-09-11: existe nfl-2026.09.2 y sus probabilidades DISCREPAN del
-- mercado (BUF@HOU: mercado 48.3% / modelo 61.2%; CHI@CAR: 39.6% / 48.0%), y
-- prob_fuente declara MERCADO_NO_VIG con p_reto en NULL en los partidos donde el
-- modelo no alcanza, así que la app no miente sobre el origen.
-- SE MANTIENE ACTIVO, pero por la razón CORRECTA: el modelo existe y le gana a un
-- volado (Brier 0.22702 vs 0.25) pero PIERDE CONTRA EL MERCADO (0.21822), sobre 208
-- partidos de una sola temporada, t pareada -1.135.
-- Una etiqueta con el motivo equivocado es una trampa: alguien la lee, ve que el
-- motivo ya no aplica, la desactiva, y enciende picks que el mercado le gana.
--
-- ===== RESULTADO MEDIDO, leído como anon =====
-- ANTES: 20 picks, 6 por debajo del 50%, 5 de línea de ganador de MLB.
-- AHORA: 27 picks, CERO por debajo del 50%, CERO con EV, cero línea de ganador de MLB.
--   Vancouver @ Austin      Under 3.5      70.1% vs 56.5% = 13.6 pts
--   Sporting KC @ LAFC      Gana visitante 69.7% vs 60.8% =  8.9 pts
--   Internazionale @ Udinese Under 3.5     71.0% vs 63.0% =  8.0 pts
--   LA Galaxy @ Seattle     Under 3.5      71.4% vs 63.6% =  7.8 pts
--   Cubs @ Pirates          Over 8         61.7% vs 54.3% =  7.4 pts
-- Comparar con los 8 que se perdieron, cuyo desacuerdo medio era 1.26 puntos.

insert into public.mercados_sin_modelo
  (etiqueta, patron_deporte, patron_mercado, activo, motivo, evidencia, criterio_reingreso, desde)
values (
  'mlb_moneyline_sin_modelo',
  '(MLB|baseball|beisbol|béisbol)',
  '(Moneyline|Gana |ML )',
  true,
  'El modelo de MLB no tiene habilidad medible en la linea de ganador, y predecir_mlb lo dice el mismo en su aviso_modelo.',
  'Brier 0.24707 sobre 800 partidos liquidados contra 0.25 de un volado. 8 picks publicados, todos de este mercado, 1-7.',
  'Brier del modelo MENOR que el del mercado sin vig, con t pareada > 2 y n >= 250, medido en v_evidencia_modelo_vs_mercado (iss075).',
  now())
on conflict do nothing;

create or replace view public.v_picks_con_valor as
 SELECT espn_event_id, deporte, liga, home, away, arranca_en, mercado, pick_desc,
    probabilidad_pct,
    prob_que_implica_el_precio_pct,
    round(probabilidad_pct - prob_que_implica_el_precio_pct, 2) AS discriminacion_pp,
    null::numeric AS ev_pct,
    momio_mercado, casa, momio_justo, calibracion_confiable, muestra_calibracion
   FROM v_pick_canonico p
  WHERE arranca_en > now()
    AND probabilidad_pct IS NOT NULL
    AND prob_que_implica_el_precio_pct IS NOT NULL
    AND probabilidad_pct >= 50::numeric
    AND probabilidad_pct > prob_que_implica_el_precio_pct
    AND public.sin_modelo_independiente(p.deporte, p.mercado) IS NULL
    AND public.sin_modelo_independiente(p.deporte, p.pick_desc) IS NULL;

-- PENDIENTE: la vista se sigue llamando v_picks_con_valor, que es lenguaje de EV.
-- No la renombré para no romper el front. El nombre honesto sería
-- v_picks_por_probabilidad.
