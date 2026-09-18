--- G36: fuga temporal en ventanas de tiros (ISS157) ---
select * from public.gate_fuga_temporal_tiros();
--- G37: la tarjeta servida no esta vacia ni rancia (ISS170) ---
select * from public.gate_tarjeta_no_vacia();
--- G38: la via de fuerza estimada, vigilada aparte (ISS174) ---
select * from public.gate_phi_estimado();
--- G39: mlb_one_brain_v2 no publica sin evidencia, y la evidencia sigue entrando (ISS176) ---
select * from public.gate_mlb_one_brain_medible();
--- G40: la tarjeta no se contradice a si misma (ISS177). G40.1 en FAIL a proposito ---
select * from public.gate_tarjeta_no_se_contradice();
--- G41: contrato de tarjeta unica, ninguna tarjeta muda (ISS178) ---
select * from public.gate_tarjeta_universal();
--- G40.3 / G40.4: marcador y margen condicionados al pick (ISS179), dentro del mismo gate ---
--- G42: Fantasy alcanzable desde el front y honesto sobre el peso de la temporada (ISS180) ---
select * from public.gate_fantasy_alcanzable();
--- Fantasy: participacion de la temporada actual (ISS181) ---
select public.fantasy_participacion('Courtland Sutton',2026);
--- G43: un solo modelo manda en fantasy, el resumen es la suma de las tarjetas (ISS192) ---
select * from public.gate_fantasy_un_solo_modelo();
--- G44: el modelo de fantasy ve la temporada en curso, no solo la pasada (ISS193) ---
select * from public.gate_fantasy_ve_la_temporada_en_curso();
--- G30.11 / G32.6 / G33.9: totales de futbol retirado por evidencia (ISS194) ---
select * from v2.mercado_retirado;
--- Patas que nunca se pudieron calificar, declaradas en vez de eternas (ISS195) ---
select * from public.marcar_patas_no_calificables(7, false);
--- Un solo cerebro de futbol: el 1X2 del analisis sale del canonico (ISS196) ---
select coalesce(analisis_json#>>'{probabilidades,_fuente_1x2}','(sin 1X2)') fuente, count(*)
from public.analisis_partidos where analisis_json ? 'probabilidades' group by 1;
--- G30.12: el backend no emite totales de futbol, asi el front no puede pintarlos (ISS198) ---
select * from public.gate_tarjetas_soccer() where gate like 'G30.1%';
--- G45: UN cerebro por deporte, declarado y contado todos los dias (ISS199) ---
select * from public.gate_un_solo_cerebro();
select * from v2.cerebro_autorizado order by deporte, rol, model_version;
--- G45.5-G45.8: quien PUEDE escribir, no solo lo ya escrito (ISS200) ---
select * from public.gate_escritores_declarados();
select * from v2.escritor_autorizado order by tipo, objeto;

-- ISS206 (2026-09-18). NFL: gates afectados y su estado medido.
--   gate_p_reto_sin_precio / P_RETO_SUSTITUIDO_POR_PRECIO      FAIL -> PASS (0)
--   gate_p_reto_sin_precio / P_RETO_SUSTITUCION_SIN_REVISAR    FAIL -> PASS (0)
--   gate_linaje_de_writers / MODELO_EN_PRODUCCION_SIN_MOTOR    FAIL -> PASS (0)
--   gate_linaje_de_writers / MOTOR_SIN_MODELO_REGISTRADO       FAIL (7)  sigue igual, es seccion D
--   gate_linaje_de_writers / CALIBRADOR_SIN_AUTORIDAD          FAIL (0)  sigue igual, es seccion D
-- Prueba adversarial de la barrera de NFL (v2.fn_nfl_legacy_predicciones_failclosed):
-- cuatro contrabandos en una fila, los cuatro rechazados. Ver T7 en
-- shadow-patches/ejecutables/iss206_nfl_cinco_cerebros_y_el_precio_como_probabilidad.sql

-- ISS207 (2026-09-18). El precio deja de elegir y de ordenar.
--   gate_precio_de_segunda_mano / PRECIO_SEGUNDA_MANO_VIOLACION_ABIERTA  FAIL(2)  -> PASS(0)
--   gate_precio_no_decide      / PRECIO_DECIDE_VIOLACION_ABIERTA         FAIL(27) -> PASS(0)
--   gate_precio_por_alias      / PRECIO_POR_ALIAS_VIOLACION_ABIERTA      FAIL(8)  -> PASS(0)
--   gate_precio_no_decide      / PRECIO_DECIDE_P0_SIN_CLASIFICAR         FAIL(269) sigue abierto
--   NUEVOS subgates de medicion viva en gate_precio_no_decide:
--     PRECIO_NO_BORRA_PICKS      PASS(0)  -- ningun pick descartado por motivo economico
--     RUTA_PRECIO_REVERIFICADA   PASS     -- los inventarios se comparan contra el codigo vivo

-- ISS208 (2026-09-18). Registro de motores y el candado que nunca podia abrir.
--   gate_linaje_de_writers / MOTOR_SIN_MODELO_REGISTRADO   FAIL(7) -> PASS(0)
--   gate_linaje_de_writers / CALIBRADOR_SIN_AUTORIDAD      FAIL    -> INFO (por instruccion del dueno)
--   gate_linaje_de_writers / FAIL_CLOSED_SIN_CALIBRADOR    NUEVO, PASS(0)  [reemplaza el candado]
-- Hallazgo: v_pick_canonico pasaba feature_asof=NULL a elegibilidad_no_economica_v1,
-- que exige feature_asof < evento_at. Ningun pick podia ser elegible NI EN TEORIA.
-- Corregido con public.feature_asof_de_pick(). 496 de 496 filas con corte de datos
-- real anterior al evento. El motivo paso a SIN_CALIBRATION_VERSION: no hay
-- calibrador sellado para soccer_canonical_v2 ni para mlb_one_brain_v2.

-- ISS209 (2026-09-18). Superficies crudas cerradas (seccion E).
--   gate_superficie_cruda / SUPERFICIE_CRUDA_SIN_DECLARAR      FAIL(92)  -> PASS(0)
--   gate_superficie_cruda / RLS_PERMISIVA_QUE_NO_RESTRINGE     FAIL(53)  -> PASS(0)
--   gate_superficie_cruda / SUPERFICIE_CRUDA_SIN_RLS           FAIL(16)  -> PASS(0)
--   gate_superficie_cruda / SUPERFICIE_CRUDA_SIN_TEMPORALIDAD  FAIL(142) -> PASS(0)
-- NUEVO public.gate_superficies_cerradas_siguen_cerradas():
--   SUPERFICIE_CERRADA_REABIERTA   PASS(0 de 80)
--   LECTURA_GLOBAL_CON_EVIDENCIA   PASS(0)
-- 80 relaciones cerradas, 58 politicas de cliente borradas, RLS deny-by-default en
-- 63 tablas. Fuga corregida: parlays, picks y score_notifications dejaban a
-- cualquier autenticado leer los datos de todos.

-- ISS211 (2026-09-18). feature_asof y autoridad de NFL por rama.
--   NUEVO public.gate_feature_asof_es_real():
--     FEATURE_ASOF_NO_ALMACENADO        PASS(0 de 496)
--     FEATURE_ASOF_SIN_RELOJ            PASS
--     FEATURE_ASOF_ESPEJEA_PUBLICACION  PASS(0 de 200)
-- NFL pasa a fail-closed total: la rama que publicaba (ELO_HISTORICAL_PRIOR) tiene
-- IC95 [-0.03873,+0.00088] contra 0.25, que CRUZA CERO, medido en una
-- reproduccion preregistrada de n=144. 0 filas publicadas, 572 de tablero con
-- P_RETO_NO_DISPONIBLE.

-- ISS212 (2026-09-18). Matriz adversarial de RLS y regresion de las 80.
--   v2.iss212_matriz_rls: 35 pruebas, 34 PASS + 1 HALLAZGO (revision de logs).
--   Regresion: 758 corridas de cron, 134 jobs, 0 fallos por permisos, 0 por RLS,
--   13 por statement timeout en 3 jobs que ya fallaban dias antes de ISS209.
--   Corregida una regresion mia: score_notifications habia perdido el UPDATE de
--   authenticated, asi que marcar una notificacion como vista estaba roto.

-- ISS213 (2026-09-18). Hallazgo historico separado del health productivo.
--   MODEL_MATRIX_INCOHERENT        FAIL(12)   -> PASS(0)   + ARCHIVED_FINDING INFO(12)
--   MODELO_SIN_EVENTO_EN_AGENDA    FAIL(729)  -> PASS(0)   + ARCHIVED_FINDING INFO(729)
--   SEGUNDA_FUENTE_ACTIVA_DE_1X2   NUEVO bloqueante, PASS(0)
--   G45.4                          FAIL(115)  -> PASS(0)
--   ID_AJENO_EN_COLUMNA_espn_...   FAIL(1318) -> PASS(0)   + ARCHIVED_FINDING INFO(1319)
-- HALLAZGO EN VIVO: el G45.4 reescrito detecto 4 escrituras en fut_predicciones
-- DESPUES de su retiro, del cron rongol-etapa4-futuros. Se puso barrera en la
-- tabla (28 intentos bloqueados y auditados) y se apago el cron de forma reversible.

-- ISS214 (2026-09-18). #10 cerrado clasificando por comportamiento, y el
-- comportamiento destapo tres violaciones vivas.
--   gate_precio_no_decide / PRECIO_DECIDE_P0_SIN_CLASIFICAR  FAIL(269) -> PASS(0)
--   (las otras cinco filas del gate ya estaban en PASS y siguen en PASS)
-- NUEVO public.gate_el_precio_no_elige_el_pick():
--   PICK_ELEGIDO_POR_FUENTE_MERCADO             PASS(0)
--   ESCRITURA_DE_MODELO_EJECUTABLE_POR_CLIENTE  FAIL(3) -> PASS(0)
--   PICK_DE_PRECIO_EN_EVENTO_NO_JUGADO          PASS(0)
-- HALLAZGO EN VIVO: badrino_predecir() elegia mejor_pick con
-- WHERE fuente='mercado' ORDER BY probabilidad DESC y lo llamaba "fuentes
-- validadas". 373 de 377 filas de badrino_predicciones traian ese pick, y la
-- funcion era ejecutable por anon y authenticated (43 llamadas por PostgREST).
-- Corregido a fail-closed (mejor_pick NULL), EXECUTE revocado via PUBLIC,
-- 373 filas guardadas como evidencia y solo los 11 picks de eventos no jugados
-- retirados. Retirada ademas v_picks_premium (precio puro, 0 consumidores) y
-- revocado el EXECUTE de cliente a mlb_shadow_generar, nfl_capturar_prediccion
-- y nfl_predecir.
-- Reparto de los 55 veredictos que faltaban: 25 FALSO_POSITIVO_DETECTOR,
-- 15 DIAGNOSTICO_NO_DECIDE, 8 DIMENSIONAMIENTO_ECONOMICO, 7 MEDICION_RETROSPECTIVA.

-- ISS215 (2026-09-18). Item 6: calibradores. NO se corrio la prueba.
-- NUEVO public.gate_calibrador_muestra_suficiente():
--   CALIBRADOR_SOCCER_MUESTRA       NO_ALCANZA(30 de 450 preregistradas)
--   CALIBRADOR_MLB_MUESTRA          NO_ALCANZA(9 de 300 preregistradas)
--   CALIBRADOR_SELLADO_SIN_MUESTRA  PASS(0)
-- Cero filas en public.calibradores. Los dos cerebros siguen
-- SIN_CALIBRATION_VERSION y MLB sigue sin picks monetizables.

-- ISS216 (2026-09-18). Item 7: censo global de los SEIS deportes.
-- NUEVO public.gate_censo_global():
--   DEPORTE_CON_EVENTOS_Y_SIN_CENSO       PASS(0)
--   MODELO_FUERA_DEL_PRODUCTO_ALCANZABLE  FAIL(1) -> PASS(0)
--   CENSO_GLOBAL_FRESCO                   PASS(6)
-- Cuatro gates que estaban en FAIL midiendo la cosa equivocada:
--   G45.6  gate_escritores_declarados        FAIL(1) -> PASS(0)
--   G47.1  gate_btts_no_monetizable          FAIL(2) -> PASS(0) + G47.1b INFO(88)
--   G46.1  gate_sin_escrituras_post_retiro   FAIL(4) -> PASS(0) + G46.1b INFO(4)
--   G41.1  gate_tarjeta_universal            FAIL(2) -> PASS(0) + G41.1b INFO(1)
-- HALLAZGOS EN VIVO:
--   TENIS tenia tennis_elo_challenger_v1_k8 sin declarar, corriendo cada 3h,
--   legible por authenticated con RLS apagada, y con brier_holdout PEOR que
--   0.25 en los siete k probados. Declarado RETADOR y cerrado al cliente.
--   La cadena de DINERO (reto_picks_hoy__base) NO consultaba
--   v2.mercado_monetizable: las declaraciones de ISS194/205/208 eran papel
--   para ese camino. Barrera fail-closed instalada.
--   v2.team_elo_product_release_gate decia product_authorized=true para NBA y
--   WNBA, contra v2.cerebro_autorizado y contra la exclusion del dueno.
-- ESTADO REAL DEL PRODUCTO: los 502 picks de v_pick_canonico estan en
-- es_pick=false con es_pick_reason='SIN_CALIBRATION_VERSION'. El contrato ya
-- falla cerrado sin calibrador sellado (FAIL_CLOSED_SIN_CALIBRADOR PASS(0),
-- 502 filas evaluadas). Encenderlos exigiria inventar una fila en
-- public.calibradores, que es justo lo prohibido.
-- BATERIA COMPLETA: 40 funciones gate_*, CERO FAIL productivos.

-- ISS218 (2026-09-18). Item 4: RLS adversarial. FUGA REAL ENCONTRADA.
-- NUEVO public.gate_rls_no_se_esquiva():
--   VISTA_DE_CLIENTE_SALTA_RLS_DE_TABLA_DE_USUARIO  FAIL(3) -> PASS(0)
--   SECURITY_DEFINER_SIN_SEARCH_PATH                FAIL(8) -> PASS(0)
--   PRIVILEGIO_POR_DEFECTO_ABRE_FUNCIONES_NUEVAS    FAIL(2) -> PASS(0)
--   FUNCIONES_EJECUTABLES_POR_CLIENTE               INFO(1291)  <- sigue abierto
-- public.bankroll_curva, legible por authenticated y con security_invoker
-- apagado, devolvia al usuario A 117 filas de las cuales 37 eran de OTRO USUARIO.
-- Una vista sin security_invoker corre como su dueno y salta RLS. Mi matriz de
-- ISS212 no lo vio porque probo tablas, no vistas. Despues del arreglo: A 79/0,
-- B 17/0. Acceso cruzado observado en logs: ninguno (cota inferior).
-- Causa raiz del EXECUTE abierto: el privilegio por defecto de Supabase concede
-- EXECUTE a anon y authenticated en cada funcion nueva. Cerrado para las nuevas.

-- ISS219 (2026-09-18). Item 7: los tres crons no eran bloqueo externo.
-- NUEVO public.gate_cron_sano():
--   CRON_ACTIVO_FALLANDO_SIEMPRE         FAIL(2)  <- se limpia tras 3 corridas buenas
--   CRON_SATURACION_DE_WORKERS           FAIL(30) <- max_worker_processes=6 con 272 crons
--   CRON_CORRIDAS_QUE_PEGAN_EN_EL_TECHO  FAIL(243 en 12 jobs) <- ABIERTO, 9 sin arreglar
-- 524 phi-extension: bug de SQL (league_id ambiguo) + loop imposible (16.7 s x 44
--   ligas contra 120 s) + reintento infinito de lo rechazado. Los tres corregidos.
-- 310 motor-cache: partido en lotes de 12 por lo mas rancio, 17.7 s medidos.
-- 515 candidate-snapshot: DESACTIVADO. Su vista fuente no cabe en 120 s a ninguna
--   frecuencia porque llama a los motores por evento; el arreglo es refactorizar
--   la fuente, no subir el limite.
-- ISS220 (2026-09-18). Item 5: contador diario v2.calibrador_contador, cron 546.
--   soccer 30/450, ritmo 15/semana, estimada 2027-04-02.
--   baseball 9/300, ritmo 4.5/semana, estimada 2027-12-15.
--   Muestra historica: POSIBLE en futbol (existe fn_crossleague_features_training_asof)
--   con la limitacion de que historico_partidos_espn es backfill; IMPOSIBLE en MLB
--   (mlb_stats_cache se sobrescribe y no hay funcion as-of de beisbol).

-- ISS221 (2026-09-18). FASE 0: no perder una observacion mas.
-- NUEVO public.gate_captura_prospectiva():
--   CAPTURA_PREEVENTO_INCOMPLETA   PASS(0)
--   COBERTURA_CALIFICABLE_BAJO_99  FAIL(4)   <- abierto y honesto
--   CAPTURA_PROSPECTIVA_FRESCA     PASS(16)
--   CAUSAS_DE_PERDIDA_ABIERTAS     INFO(26)
-- RESPUESTA A "138 tarjetas pero 30 observaciones": de 253 eventos con
-- prediccion solo 56 se han jugado (el cerebro arranco el 15-sep). De esos 56,
-- 30 validos y 26 perdidos, y CERO por captura tardia: los 26 son model_status
-- DATA_INCOMPLETE. 16 por politica de competencia (12 historicos ya cerrados,
-- 4 de Sudamericana que es exclusion correcta del dueno), 8 por phi no servible
-- (el mismo cron que arregle en ISS219) y 2 por muestra de arranque.
-- Cobertura de futbol: 38.89% -> 56.52% -> 76.92%. MLB: 100% los dos dias.
-- ISS219 VERIFICADO EN PRODUCCION: phi 04:37 succeeded 40s, motor-cache 04:34
-- succeeded 15s y 04:19 succeeded 23s. Antes fallaban a los 120s.

-- ISS222 (2026-09-18). Gates de captura SEPARADOS, y la prueba del backlog phi.
--   A_CAPTURA_PREEVENTO        PASS(0)
--   B_COBERTURA_MODELO         FAIL(2)  soccer 09-16 66.67%, 09-17 76.92%
--   C_INFO_EXCLUDED            INFO(4)   Sudamericana
--   D_INFO_HISTORICAL          INFO(20)  pre-barrera
--   E_PENDIENTE_NO_FINALIZADO  PENDING(227)
--   F_FRESCURA                 PASS(16)
-- BACKLOG PHI: 44 -> 5 pendientes, 39 procesadas, 6 corridas todas succeeded
-- (7-28 s), CERO ligas instaladas. n_usable promedio 2.4 contra un minimo de 20;
-- 0 de 39 alcanzarian el umbral. MI PREDICCION DE ISS221 ERA FALSA: drenar el
-- backlog no instala phi. El cuello es la muestra cruzada, no el cron.

-- ISS223 (2026-09-18). FASE 3 Paso 1: reproducibilidad de NFL LOGRADA.
-- Causa de las 10/42 diferencias: el tratamiento de los EMPATES. Mi
-- reimplementacion de ISS217 daba 0 a los dos lados (los marcadores no sumaban
-- 1 y cada empate fugaba un punto de masa); ISS211 usaba sh_home=0, sh_away=1.
-- 13 empates en la fuente, 11 de ellos en pretemporada. Todo equipo divergente
-- es participante de un empate o rival de uno; New England 3 de 3.
-- Matriz 2x2 decisiva: solo empate=0 + agosto incluido colapsa el error.
-- delta maximo 0.055713 -> 0.000127; 9 de 10 por debajo de 0.0001.
-- Descartadas con medicion: duplicados (0), Washington (0 de 10), Pro Bowl
-- (0 de 10), deriva temporal (mismo dia con deltas de 0.00001 y 0.055).
-- El veredicto NO cambia: el IC95 sigue cruzando cero. Reproducible no es valido.
