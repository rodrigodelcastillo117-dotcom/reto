-- ISS177: dos lambdas en la misma tarjeta, y una atribucion falsa
--
-- ===========================================================================
-- COMO SALIO
-- ===========================================================================
-- Iba a empezar la correccion Dixon-Coles del sesgo de empate. Antes de tocar
-- nada mire que evidencia forward tiene cada cerebro, y aparecio otra cosa.
--
-- ===========================================================================
-- HALLAZGO 1: LA TARJETA SE CONTRADICE A SI MISMA. MEDIDO.
-- ===========================================================================
-- En public.v_tarjeta_soccer_v1_calculo:
--   linea 123-124   over_pct / under_pct  <-  ou_por_tiros_tarjeta()
--                                            (cerebro de tiros a puerta, ISS161)
--   linea 140-142   goles_esperados_*     <-  pr.lambda_home / lambda_away
--                                            (cerebro crossleague / canonical)
--
-- Son DOS lambdas distintas en la misma tarjeta. Medido sobre 135 tarjetas que
-- publican Over:
--   lambda que se MUESTRA         2.795  de media
--   lambda que CALCULA el Over    2.971  de media
--   diferencia absoluta media     0.277 goles, peor 0.997
--   20 tarjetas separadas por mas de medio gol
--
-- Traducido a lo que el usuario puede comprobar con una calculadora:
--   Over que se muestra                          47.37 %
--   Over que implican los goles que se muestran   43.22 %
--   diferencia absoluta media                      6.47 pp
--   peor caso                                     23.16 pp
--   70 de 135 tarjetas se apartan mas de 5 pp
--   30 de 135 se apartan mas de 10 pp
--
-- Esto es EXACTAMENTE la queja que el dueno levanto a ojo dos veces
-- ("POR QUE NO COINCIDE", "Y ASI EN TODAS LAS TARJETAS"). No era estilo: es
-- aritmetica. Y viola la regla de un solo cerebro por deporte.
--
-- NO SE ARREGLA HOY, Y SE DICE POR QUE
--   Las dos salidas obvias son malas:
--     - pasar toda la tarjeta a la lambda de tiros: esa lambda solo esta
--       probada para Over/Under en lineas 2.5 y 3.5. Nadie la ha medido para
--       1X2, BTTS ni margen. Cambiar el cerebro validado sin prueba es lo que
--       llevo meses negandome a hacer.
--     - quitar el Over de tiros y volver al crossleague: el crossleague en
--       Over/Under mide +0.04443 contra adivinar (n=150), o sea PEOR que una
--       moneda. Tirar lo unico que paso una prueba para conservar lo que
--       fallo es al reves.
--   La salida correcta es medir: prueba preregistrada de lambda-tiros contra
--   lambda-crossleague en 1X2 / BTTS / margen, y que mande la que gane. Queda
--   registrada como tarea, no se hace a ojo.
--
-- Mientras tanto queda G40.1 en FAIL a proposito. Un gate rojo que nombra el
-- defecto es mejor que un tablero verde que lo esconde.
--
-- ===========================================================================
-- HALLAZGO 2: ATRIBUCION FALSA EN PANTALLA. ARREGLADO.
-- ===========================================================================
-- public.v_evidencia_mercado_soccer construia, para el mercado 'total':
--   evidencia_publicado = { modelo: 'soccer_canonical_v2',
--                           papel: 'el que publica hoy',
--                           n: 19, brier_modelo: 0.6034 }
--
-- Falso por partida doble:
--   a) quien publica las altas y bajas es el cerebro de tiros, no
--      soccer_canonical_v2;
--   b) ese n=19 y ese Brier 0.6034 son el historial del camino DESCARTADO.
--      Se le estaba colgando al cerebro nuevo el expediente del viejo, y
--      ademas un expediente malo.
--   Y en el mismo JSON, dos lineas mas abajo, el texto decia correctamente que
--   el cerebro se habia reemplazado. La tarjeta se contradecia dentro de un
--   solo campo.
--
-- Tambien: para 'total', evidencia_prior llamaba a crossleague_v1 "prior que
-- alimenta soccer_canonical_v2". En totales no alimenta nada: es el cerebro
-- RETIRADO. Ahora lo dice asi.
--
-- ARREGLADO: para 'total', evidencia_publicado nombra a ou_tiros_v1, declara
-- n=0 historial en vivo, y remite a la prueba preregistrada fuera de muestra
-- (1080 partidos, mejora 0.005774, IC95 0.001589 a 0.009960, solo lineas 2.5
-- y 3.5). Sin numeros prestados.
--
-- ===========================================================================
-- OTROS DATOS MEDIDOS DE PASO (no se tocan, quedan registrados)
-- ===========================================================================
--   soccer_canonical_v2, el que sirve la tarjeta, lleva n=19 eventos medidos.
--   Es de anteayer. No es escandalo, pero su expediente esta practicamente
--   vacio y conviene decirlo.
--
--   Existe dc-2026.09.1 con n=112 en 1X2: Brier 0.67318 contra 0.66667 de
--   adivinar, o sea PEOR. NO publica. Si ese 'dc' es un intento de
--   Dixon-Coles, ya hay uno y va perdiendo: razon de mas para que la
--   correccion del sesgo de empate pase por prueba y no por intuicion.
--
--   crossleague_v1 en 1X2 (n=155) si pasa la regla dura: -0.05371 con IC95
--   superior -0.00724, intervalo entero del lado bueno.
--
--   ou_sot_v1 tiene 133 observaciones con promotion_eligible=false. Eso esta
--   BIEN y no se toca: son el gemelo retrospectivo de la medicion, no un
--   registro en vivo. Marcarlas elegibles seria inflar el expediente.
--
-- ===========================================================================
-- ESTADO VERIFICADO (2026-09-17)
-- ===========================================================================
--   G40.1  FAIL (70 de 135)   <- a proposito, defecto abierto y nombrado
--   G40.2  PASS (0)
--   G37.1 PASS 150 | G37.2 PASS | G37.3 PASS
--   tarjeta refrescada y comprobada servida, no solo calculada


-- ---------------------------------------------------------------------------
-- 1. atribucion correcta por mercado
-- ---------------------------------------------------------------------------
create or replace view public.v_evidencia_mercado_soccer as
 WITH g AS (
         SELECT model_learning_gate.market,
            model_learning_gate.model_version,
            model_learning_gate.n_events,
            model_learning_gate.brier_model,
            model_learning_gate.brier_naive,
            model_learning_gate.brier_vs_naive_diff AS diff,
            2::numeric * model_learning_gate.brier_vs_naive_diff - model_learning_gate.brier_vs_naive_upper95 AS lower95,
            model_learning_gate.brier_vs_naive_upper95 AS upper95,
            model_learning_gate.leader_accuracy_pct,
            model_learning_gate.max_calibration_gap_pp
           FROM v2.model_learning_gate
          WHERE model_learning_gate.scope = 'GLOBAL'::text AND model_learning_gate.brier_vs_naive_upper95 IS NOT NULL
        ), m(mercado_tarjeta, market) AS (
         VALUES ('ganador'::text,'1X2'::text), ('btts'::text,'BTTS'::text), ('total'::text,'Over/Under'::text)
        )
 SELECT m.mercado_tarjeta,
    -- ISS177. En 'total' el crossleague NO es prior de nada: es el cerebro que se
    -- RETIRO el 17 de septiembre. Llamarlo prior era falso.
    CASE WHEN m.mercado_tarjeta = 'total'::text
      THEN jsonb_build_object('modelo','crossleague_v1','papel','el cerebro de totales RETIRADO el 17 de septiembre por salir peor que adivinar','n',p.n_events,'brier_modelo',round(p.brier_model,4),'brier_adivinando',round(p.brier_naive,4),'ic95_inferior',round(p.lower95,4),'ic95_superior',round(p.upper95,4),'accuracy_pct',round(p.leader_accuracy_pct,1),'gap_calibracion_pp',round(p.max_calibration_gap_pp,1))
      ELSE jsonb_build_object('modelo','crossleague_v1','papel','prior que alimenta soccer_canonical_v2 en las 16 ligas domesticas','n',p.n_events,'brier_modelo',round(p.brier_model,4),'brier_adivinando',round(p.brier_naive,4),'ic95_inferior',round(p.lower95,4),'ic95_superior',round(p.upper95,4),'accuracy_pct',round(p.leader_accuracy_pct,1),'gap_calibracion_pp',round(p.max_calibration_gap_pp,1))
    END AS evidencia_prior,
    -- ISS177. En 'total' lo que se publica NO es soccer_canonical_v2. Pegar aqui
    -- su n=19 y su Brier era atribuirle al cerebro nuevo el historial del viejo.
    CASE WHEN m.mercado_tarjeta = 'total'::text
      THEN jsonb_build_object('modelo','ou_tiros_v1','papel','el que publica hoy las altas y bajas','n',0,
             'brier_modelo',null,'brier_adivinando',null,'ic95_inferior',null,'ic95_superior',null,'accuracy_pct',null,
             'nota','Sin historial en vivo todavia. Su evidencia es la prueba preregistrada fuera de muestra sobre 1080 partidos (mejora 0.005774, IC95 de 0.001589 a 0.009960). Solo se publica en lineas 2.5 y 3.5, las unicas que pasaron.')
      ELSE jsonb_build_object('modelo','soccer_canonical_v2','papel','el que publica hoy','n',c.n_events,'brier_modelo',round(c.brier_model,4),'brier_adivinando',round(c.brier_naive,4),'ic95_inferior',round(c.lower95,4),'ic95_superior',round(c.upper95,4),'accuracy_pct',round(c.leader_accuracy_pct,1))
    END AS evidencia_publicado,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'SIN_VEREDICTO_CEREBRO_NUEVO'::text
            WHEN p.lower95 > 0::numeric THEN 'PEOR_QUE_ADIVINAR_CONCLUYENTE'::text
            WHEN p.upper95 < 0::numeric THEN 'MEJOR_QUE_ADIVINAR_CONCLUYENTE'::text
            ELSE 'SIN_VEREDICTO_MUESTRA_INSUFICIENTE'::text
        END AS veredicto,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'El cerebro de altas y bajas se reemplazo el 17 de septiembre. El anterior salia peor que adivinar. El nuevo estima los goles a partir de los tiros a puerta y le gano a adivinar en una prueba fuera de muestra sobre 1080 partidos, con el intervalo del 95% sin cruzar cero. Todavia no acumula resultados en vivo suficientes para calificarlo aqui.'::text
            WHEN p.lower95 > 0::numeric THEN format('Sobre %s partidos reales este mercado sale PEOR que adivinar, y el intervalo de confianza del 95%% esta entero por encima de cero. No es ruido.'::text, p.n_events)
            WHEN p.upper95 < 0::numeric THEN format('Sobre %s partidos reales este mercado supera al baseline con el intervalo de 95%% entero por debajo de cero.'::text, p.n_events)
            ELSE format('Sobre %s partidos el intervalo cruza el cero: todavia no se puede afirmar ni que gana ni que pierde contra adivinar.'::text, p.n_events)
        END AS explicacion,
    'El baseline es adivinar con las frecuencias base (1/3 cada resultado en 1X2, 50/50 en BTTS y Over/Under). Brier mas bajo es mejor.'::text AS como_leerlo,
    now() AS evaluado_at
   FROM m
     LEFT JOIN g p ON p.market = m.market AND p.model_version = 'crossleague_v1'::text
     LEFT JOIN g c ON c.market = m.market AND c.model_version = 'soccer_canonical_v2'::text;


-- ---------------------------------------------------------------------------
-- 2. G40. El gate que deja el defecto 1 a la vista.
-- ---------------------------------------------------------------------------
create or replace function public.gate_tarjeta_no_se_contradice()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql
stable
security definer
set search_path = public, v2, pg_catalog
as $g$
  -- G40 (ISS177). La tarjeta muestra unos goles esperados y un porcentaje de
  -- Over. Si el Over NO sale de esos goles, el usuario puede hacer la cuenta y
  -- ver que no cuadra. Ya paso: el dueno lo cacho a ojo dos veces.
  with t as (
    select espn_event_id, goles_esperados_total lam, over_pct, linea_total
    from public.tarjeta_soccer_cache
    where over_pct is not null and goles_esperados_total is not null and linea_total is not null
  ), imp as (
    select t.*,
      (1 - (select sum(exp(-t.lam)*power(t.lam,k)
                       /exp(coalesce((select sum(ln(g)) from generate_series(1,k) g),0)))
              from generate_series(0, floor(t.linea_total)::int) k))*100 over_implicito
    from t
  )
  select 'G40.1_el_over_sale_de_los_goles_que_muestra'::text,
    case when count(*) = 0 then 'INFO'
         when count(*) filter (where abs(over_pct-over_implicito) > 5) = 0 then 'PASS'
         else 'FAIL' end,
    count(*) filter (where abs(over_pct-over_implicito) > 5),
    ('De '||count(*)||' tarjetas con Over publicado, '
     ||count(*) filter (where abs(over_pct-over_implicito) > 5)
     ||' se apartan mas de 5 puntos del Over que implican los goles esperados que la propia tarjeta muestra, y '
     ||count(*) filter (where abs(over_pct-over_implicito) > 10)||' se apartan mas de 10. '
     ||'Diferencia media '||coalesce(round(avg(abs(over_pct-over_implicito))::numeric,2)::text,'-')
     ||' pp, peor '||coalesce(round(max(abs(over_pct-over_implicito))::numeric,2)::text,'-')||' pp. '
     ||'CAUSA CONOCIDA: el Over lo calcula el cerebro de tiros a puerta y los goles esperados vienen del '
     ||'cerebro crossleague. Son dos lambdas distintas en la misma tarjeta. Esto NO se arregla escondiendolo: '
     ||'se arregla cuando una sola lambda mande en toda la tarjeta, y cual sea esa lambda tiene que salir de '
     ||'una prueba preregistrada, no de una preferencia.')::text
  from imp
  union all
  select 'G40.2_cada_mercado_nombra_al_modelo_que_lo_calcula'::text,
    case when count(*) = 0 then 'PASS' else 'FAIL' end,
    count(*),
    ('Tarjetas que publican Over pero atribuyen el historial de totales a soccer_canonical_v2, '
     ||'que no es quien lo calcula: '||count(*)||'. Debe ser 0.')::text
  from public.tarjeta_soccer_cache
  where over_pct is not null
    and evidencia_por_mercado->'total'->'evidencia_publicado'->>'modelo' = 'soccer_canonical_v2';
$g$;

grant execute on function public.gate_tarjeta_no_se_contradice() to anon, authenticated, service_role;

select public.refrescar_tarjeta_soccer_cache();


-- ---------------------------------------------------------------------------
-- VERIFICACION
-- ---------------------------------------------------------------------------
-- select * from public.gate_tarjeta_no_se_contradice();
-- select distinct evidencia_por_mercado->'total'->'evidencia_publicado'
--   from public.v_tarjeta_soccer_v1 where over_pct is not null;
