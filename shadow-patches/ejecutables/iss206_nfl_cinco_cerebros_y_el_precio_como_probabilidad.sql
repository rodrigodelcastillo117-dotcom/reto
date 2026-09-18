-- ISS206 — NFL: habia CINCO caminos de probabilidad, y uno publicaba el precio
--
-- CORRECCION DE UN REPORTE MIO ANTERIOR.
-- Antes de este parche yo afirme que "nfl-2026.09.2 no tiene motor autorizado"
-- y que por lo tanto NFL debia apagarse entero por falta de modelo validado.
-- ESO ESTABA MAL en los dos extremos:
--
--   (a) NFL SI tiene un cerebro validado fuera de muestra, y no es
--       nfl-2026.09.2. Es nfl_hybrid_ml_v1: v2.nfl_model_validation_gate lo
--       sella OOS_VALIDATED con n=143, Brier 0.22986 contra 0.25000 de un
--       volado, brecha maxima de calibracion 6.54pp, alcance MONEYLINE_ONLY,
--       money_authorized = false. Es el unico que v_nfl_release_authority_v1
--       autoriza, y por eso es el unico que llega a v_nfl_publication_v1.
--
--   (b) nfl-2026.09.2 NO es el cerebro bueno: el mismo gate lo sella
--       FAIL_CLOSED_OOS_NOT_PROVEN con publish_authorized = false y
--       n_oos_events = 0. Lo escribe v2.capture_nfl_next_week_challenger,
--       cuyo nombre ya dice que es un RETADOR. Yo lo registre al reves:
--       lo declare AUTORIZADO en v2.cerebro_autorizado el 2026-09-17 con la
--       nota "El unico motor de NFL. Aqui nunca hubo duplicado", y
--       public.modelo_registry lo tiene en PRODUCCION. Las dos cosas son
--       falsas y las dos las arregla este parche.
--
-- Y la nota de esa fila ("nunca hubo duplicado") era falsa de raiz. Hoy hay
-- CINCO caminos de probabilidad de NFL vivos al mismo tiempo:
--
--   1. nfl_hybrid_ml_v1   — canonico, OOS_VALIDATED, Moneyline, sin dinero.
--   2. nfl_form_ml_v1     — NO es rival: es la rama madura del hibrido
--                            (v2.build_nfl_hybrid_ml_v1 llama a
--                            v2.build_nfl_form_ml_v1). Es COMPONENTE.
--   3. nfl-2026.09.2      — retador fallido, 6,029 filas en la MISMA tabla
--                            canonica v2.nfl_decision_snapshot, escribiendo
--                            todavia hoy (ultima 2026-09-18 01:17).
--   4. public.nfl_predecir() -> public.nfl_predicciones — publica el PRECIO
--                            DE LA CASA SIN VIG bajo la columna
--                            'probabilidad', y lo asciende a mejor_pick /
--                            mejor_prob. 284 filas, legible por anon,
--                            ultima escritura 2026-09-18 00:40.
--   5. public.nfl_opinion_modelo() — FPI de ESPN que SOLO opina cuando el
--                            desacuerdo contra la casa pasa 2.14 puntos, y
--                            cuyo propio referente es coalesce(p_home,
--                            nfl_prob_del_spread(spread_mercado)), o sea el
--                            precio. Es "edge contra el mercado" decidiendo.
--
-- El numero 4 viola la regla del dueno de forma directa y literal:
-- "Nunca sustituyas P_RETO con implied/no-vig". El numero 5 viola
-- "SIN EV, SIN KELLY, SIN EDGE CONTRA EL MERCADO PARA DECIDIR".
--
-- Lo que hace este parche, en orden:
--   0) Foto de auditoria del estado previo, antes de tocar nada.
--   1) Amplia los CHECK para poder decir COMPONENTE sin mentir.
--   2) v2.cerebro_autorizado queda con UN solo AUTORIZADO de football.
--   3) public.modelo_registry deja de llamar PRODUCCION a un retador fallido.
--   4) public.motor_modelo_mapa gana el motor REAL de football.
--   5) Apaga de forma reversible al escritor del retador.
--   6) Reescribe nfl_predecir: el precio deja de llamarse probabilidad.
--   7) mercados_sin_modelo declara Spread y Total con motivo explicito.
--   8) Pruebas.
--
-- Nada de esto inventa un motor para hacer pasar un gate. El motor de
-- football que se registra es v2.build_nfl_hybrid_ml_v1, que existe, corre
-- en el cron nfl-hybrid-ml-v1-snapshot cada 3 horas, y esta sellado.

begin;

-- ─────────────────────────────────────────────────────────────────────
-- 0) FOTO DEL ESTADO PREVIO
-- ─────────────────────────────────────────────────────────────────────
create table if not exists v2.auditoria_nfl_corte (
  id            bigserial primary key,
  corrida_at    timestamptz not null default now(),
  etiqueta      text not null,
  hallazgo      text not null,
  valor         text
);

insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'model_versions escribiendo v2.nfl_decision_snapshot',
       string_agg(model_version || '=' || n::text, ' | ' order by n desc)
from (select model_version, count(*) n from v2.nfl_decision_snapshot group by 1) x;

insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'sello de validacion por model_version',
       string_agg(model_version || '=' || validation_status
                  || ' publish=' || publish_authorized::text
                  || ' n_oos=' || coalesce(n_oos_events::text,'-')
                  || ' brier=' || coalesce(brier_model::text,'-'), ' | ' order by model_version)
from v2.nfl_model_validation_gate;

insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'cerebro_autorizado football (ANTES, equivocado)',
       string_agg(model_version || '=' || rol, ' | ' order by model_version)
from v2.cerebro_autorizado where deporte='football';

insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'modelo_registry football (ANTES)',
       string_agg(model_version || '=' || estado, ' | ' order by model_version)
from public.modelo_registry where deporte='football';

-- La prueba de que nfl_predicciones publicaba precio como probabilidad:
-- cuantas filas tienen mejor_prob que provenga de una entrada fuente=mercado.
insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'nfl_predicciones: mejor_pick que venia de fuente=mercado',
       count(*)::text || ' de ' || (select count(*) from public.nfl_predicciones)::text
from public.nfl_predicciones p
where exists (
  select 1 from jsonb_array_elements(p.mercados) m
   where (m->>'fuente') = 'mercado'
     and (m->>'pick') = p.mejor_pick
     and (m->>'probabilidad') is not null
);

insert into v2.auditoria_nfl_corte (etiqueta, hallazgo, valor)
select 'iss206-pre', 'nfl_predicciones: entradas con probabilidad de origen precio',
       count(*)::text
from public.nfl_predicciones p, jsonb_array_elements(p.mercados) m
where (m->>'fuente') = 'mercado' and (m->>'probabilidad') is not null;

commit;

-- ─────────────────────────────────────────────────────────────────────
-- CORRECCION AL ENCABEZADO, medida despues de escribirlo
-- ─────────────────────────────────────────────────────────────────────
-- Arriba escribi que nfl_predecir "asciende el precio a mejor_pick / mejor_prob".
-- MEDIDO: eso NO estaba pasando. mejor_pick y mejor_prob estaban en NULL en las
-- 284 filas de nfl_predicciones, porque ya existia el disparador
-- v2.fn_nfl_legacy_predicciones_failclosed que los anulaba SIEMPRE.
-- La violacion real, medida, era mas estrecha: 1,135 entradas dentro de
-- nfl_predicciones.mercados publicaban el precio sin vig bajo la llave
-- 'probabilidad', en una tabla que anon puede leer. Ninguna llegaba a ser pick.
-- Lo dejo escrito porque afirmar mas de lo que se midio es el error que el
-- dueno prohibio.

-- ─────────────────────────────────────────────────────────────────────
-- 1) CHECKs ampliados para poder decir COMPONENTE sin mentir
-- ─────────────────────────────────────────────────────────────────────
alter table v2.cerebro_autorizado drop constraint cerebro_autorizado_rol_check;
alter table v2.cerebro_autorizado add constraint cerebro_autorizado_rol_check
  check (rol = any (array['AUTORIZADO','RETADOR_DECLARADO','COMPONENTE','RETIRADO']));

alter table public.modelo_registry drop constraint modelo_registry_estado_check;
alter table public.modelo_registry add constraint modelo_registry_estado_check
  check (estado = any (array['CHALLENGER','PRODUCCION','COMPONENTE','MODEL_REJECTED','RETIRADO']));

-- El registro de sustituciones necesita poder decir "resuelto, y asi", sin
-- perder la evidencia de que alguna vez fue SUSTITUCION_CONFIRMADA.
alter table public.p_reto_sustitucion drop constraint p_reto_sustitucion_veredicto_check;
alter table public.p_reto_sustitucion add constraint p_reto_sustitucion_veredicto_check
  check (veredicto = any (array['SUSTITUCION_CONFIRMADA','REVISION_PENDIENTE','NO_ES_SUSTITUCION',
                               'RESUELTO_OBJETO_RETIRADO','RESUELTO_MIGRADO_A_P_RETO']));

-- ─────────────────────────────────────────────────────────────────────
-- 2) v2.cerebro_autorizado: UN solo AUTORIZADO de football
-- ─────────────────────────────────────────────────────────────────────
-- nfl-2026.09.2 -> RETIRADO  (yo lo habia declarado AUTORIZADO por error)
-- nfl_hybrid_ml_v1 -> AUTORIZADO  (es el que el sello autoriza)
-- nfl_form_ml_v1 -> COMPONENTE    (rama madura del hibrido, no rival)
-- El indice unico parcial exige retirar el viejo ANTES de insertar el nuevo.
-- Los textos completos de las notas quedaron en la base; ver
--   select * from v2.cerebro_autorizado where deporte='football';

-- ─────────────────────────────────────────────────────────────────────
-- 3) public.modelo_registry
-- ─────────────────────────────────────────────────────────────────────
-- nfl-2026.09.2: PRODUCCION -> RETIRADO, motivo SIN_MODELO_CANONICO_VALIDADO.
-- nfl_hybrid_ml_v1: alta como PRODUCCION con la evidencia sellada, incluyendo
--   los cortes por anio que NO lo favorecen (2024 = 0.25069, peor que un volado;
--   2026 semana 1 = 0.24309, casi empatado; el promedio lo salva 2025 = 0.20533).
-- nfl_form_ml_v1: alta como COMPONENTE.

-- ─────────────────────────────────────────────────────────────────────
-- 4) public.motor_modelo_mapa: el motor REAL de football
-- ─────────────────────────────────────────────────────────────────────
-- ('motor_nfl_hibrido','football','Moneyline','nfl_hybrid_ml_v1')
-- Motor: v2.build_nfl_hybrid_ml_v1, cron nfl-hybrid-ml-v1-snapshot (jobid 522).
-- calibration_version queda NULL a proposito: no existe calibrador sellado para
-- football en public.calibradores. Por eso estado_respaldo devuelve
-- SIN_CALIBRATION_VERSION y el pick no es elegible. Ese es el fail-closed
-- funcionando, no un hueco por rellenar.

-- ─────────────────────────────────────────────────────────────────────
-- 5) Apagado REVERSIBLE del escritor del retador retirado
-- ─────────────────────────────────────────────────────────────────────
-- select cron.alter_job(469, active := false);   -- nfl-v2-challenger-capture
-- Registrado en v2.apagado_reversible con como_revertir.
-- NOTA operativa: cron.job NO es escribible con UPDATE directo desde este rol
-- ("permission denied for table job"); hay que usar cron.alter_job().

-- ─────────────────────────────────────────────────────────────────────
-- 6) public.nfl_predecir(): el precio deja de llamarse probabilidad
-- ─────────────────────────────────────────────────────────────────────
-- Cambios, uno por uno:
--   * Las entradas fuente='mercado' pierden la llave 'probabilidad' y ganan
--     'prob_implicita_mercado_pct' mas es_modelo=false y una nota que dice
--     "Es PRECIO, no probabilidad del modelo".
--   * Entra una entrada fuente='modelo_canonico' con P_RETO leido de
--     public.v_nfl_publication_v1, con model_version, decision_time e
--     incertidumbre.
--   * La rama nfl_opinion_modelo (FPI contra mercado) SALE de los mercados
--     publicados y pasa a contexto.diagnostico_fpi_vs_mercado, con el texto
--     que explica por que no puede decidir.
--   * mejor_pick / mejor_prob solo pueden venir de fuente='modelo_canonico'.
--   * BUG DE PASO CORREGIDO: el INSERT ... SELECT ... FROM (subconsulta LIMIT 1)
--     original no insertaba NADA cuando la subconsulta salia vacia, asi que un
--     partido sin pick tampoco actualizaba mercados ni contexto. Ahora hay
--     RIGHT JOIN (select 1) para que la fila siempre se escriba.

-- ─────────────────────────────────────────────────────────────────────
-- 6b) LA BARRERA: v2.fn_nfl_legacy_predicciones_failclosed
-- ─────────────────────────────────────────────────────────────────────
-- Antes anulaba mejor_pick y mejor_prob SIEMPRE. Ahora es la barrera de verdad,
-- y valida contra el CATALOGO, no contra la etiqueta del escritor:
--   1. Una entrada puede llevar 'probabilidad' SOLO si declara
--      fuente='modelo_canonico' Y su model_version es exactamente el AUTORIZADO
--      de football en v2.cerebro_autorizado. Todo lo demas pierde la
--      probabilidad, que se conserva renombrada (prob_sin_autoridad_pct) para
--      que nada se borre en silencio.
--   2. mejor_pick / mejor_prob solo sobreviven si coinciden con una entrada que
--      pase la regla 1.
--
-- La PRIMERA version de esta barrera, escrita en esta misma sesion, FALLO la
-- prueba adversarial: anulaba el mejor_pick falsificado pero dejaba la
-- 'probabilidad' dentro de las entradas con etiqueta canonica falsa. Se
-- corrigio y se volvio a probar.

-- ─────────────────────────────────────────────────────────────────────
-- 7) mercados_sin_modelo y v2.mercado_monetizable
-- ─────────────────────────────────────────────────────────────────────
-- nfl_spread_sin_modelo  (nuevo)  motivo SIN_MODELO_CANONICO_VALIDADO
-- nfl_total_sin_modelo   (nuevo)  motivo SIN_MODELO_CANONICO_VALIDADO
-- nfl_sin_modelo         (reescrito) ahora limitado a Moneyline, y el motivo
--   dice la verdad: NFL SI tiene cerebro validado, lo que no tiene es permiso
--   de dinero, porque el modelo le gana al volado pero PIERDE contra el mercado.
-- v2.mercado_monetizable: football/Moneyline, /Spread y /Over-Under = false.
--
-- revoke insert, update, delete, truncate on public.nfl_predicciones from anon, authenticated;
-- revoke insert, update, delete, truncate on public.nfl_partidos      from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- 8) Consumidores donde el MERCADO decidia (hallazgos nuevos de ISS206)
-- ─────────────────────────────────────────────────────────────────────
-- public.nfl_lock_semana
--   ANTES: para dar LOCK exigia reto_va_local = mercado_va_local, y publicaba
--          confianza_pct = LEAST(prob_del_modelo, prob_del_mercado). O sea el
--          precio podia vetar el pick y podia RECORTAR la probabilidad que ve
--          el usuario. Eso es el mercado decidiendo.
--   AHORA: confianza_pct = prob_reto (la del modelo). La concordancia con el
--          mercado se sigue mostrando, pero como contexto: no filtra ni recorta.
--   MEDIDO: 15 filas antes con confianza_pct NULL -> 15 filas con 53.71 a 72.17.
--
-- public.v_prediccion_reto_canonico
--   ANTES: la rama NFL declaraba prob_source = 'nfl_points_lattice_v2'. FALSO.
--          Y pasaba nm.dk_spread_home (la LINEA DE LA CASA) como spread_linea
--          dentro de una vista llamada "prediccion reto canonico".
--   AHORA: prob_source = n.reto_modelo (hoy nfl_hybrid_ml_v1) y las tres
--          columnas de spread quedan en NULL, porque release_scope es
--          MONEYLINE_ONLY y spread_total_authorized = false.

-- ─────────────────────────────────────────────────────────────────────
-- 9) public.v_super_pick: RETIRADA
-- ─────────────────────────────────────────────────────────────────────
-- Veredicto SUSTITUCION_CONFIRMADA: prob_pct = COALESCE(prob_observada, ...) y
-- prob_observada = (ganados + 40*avg(1/momio))/(n+40), una mezcla bayesiana cuyo
-- PRIOR es la probabilidad implicita del precio, puesta PRIMERO en el COALESCE.
-- Cero consumidores: sin SELECT para anon ni authenticated, sin vistas
-- dependientes, y la unica funcion que la nombraba era el gate que vigila que
-- no sea legible. Definicion completa (14,849 caracteres) guardada en
-- v2.apagado_reversible antes del drop.
--   drop view public.v_super_pick;

-- ─────────────────────────────────────────────────────────────────────
-- 10) public.v_picks_para_parlay: migrada a P_RETO
-- ─────────────────────────────────────────────────────────────────────
-- ANTES publicaba probabilidad_pct desde dos fuentes y ninguna era P_RETO:
--   tier PREMIUM = v_picks_premium.prob_estimada_pct
--                = 0.40 * probabilidad de la IA + 0.60 * win-rate historico de
--                  un nicho segmentado POR RANGO DE MOMIO,
--                  con un WHERE que exigia ese numero <= 100/momio + 10;
--   tier AI_VERIFIED = oraculo_picks_tracking.probabilidad_real (la IA).
-- Alimenta construir_parlay_del_dia__base, construir_parlay_v2__base,
-- get_oportunidades_hoy y get_partidos_hoy_top, las cuatro invocables por
-- authenticated.
-- AHORA sale EXCLUSIVAMENTE de public.v_pick_canonico. historial_wr /
-- historial_muestra / historial_roi quedan en NULL: eran precio presentado como
-- track record. Filtros: es_pick, v2.mercado_monetizable,
-- public.mercados_sin_modelo, pick_en_cuarentena, partido no empezado.
-- MEDIDO: 0 filas antes y 0 filas despues. La sustitucion estaba LATENTE, no
-- publicada. Hoy el 0 viene del fail-closed (es_pick=false, SIN_MODEL_VERSION).
-- OJO: CREATE OR REPLACE VIEW no deja cambiar el tipo de una columna, asi que
-- historial_muestra tuvo que quedar null::bigint, no null::integer.

-- ─────────────────────────────────────────────────────────────────────
-- 11) p_reto_sustitucion: los cuatro veredictos resueltos
-- ─────────────────────────────────────────────────────────────────────
-- v_super_pick.prob_pct                      -> RESUELTO_OBJETO_RETIRADO
-- v_picks_para_parlay.probabilidad_pct       -> RESUELTO_MIGRADO_A_P_RETO
-- nfl_tablero.prob_fuente                    -> NO_ES_SUSTITUCION (verificado)
-- refrescar_destacados(integer).suma_implicita -> NO_ES_SUSTITUCION (verificado)
-- Ninguna razon se borro: la nueva se antepone y la original queda detras de
-- "|| HALLAZGO ORIGINAL:".

-- ─────────────────────────────────────────────────────────────────────
-- PRUEBAS (todas corridas, resultados reales)
-- ─────────────────────────────────────────────────────────────────────
-- T1  cerebro_autorizado football: 1 AUTORIZADO (nfl_hybrid_ml_v1),
--     1 COMPONENTE (nfl_form_ml_v1), 1 RETIRADO (nfl-2026.09.2).   OK
-- T2  modelo_registry football: PRODUCCION = nfl_hybrid_ml_v1,
--     RETIRADO = nfl-2026.09.2.                                     OK
-- T3  cron nfl-v2-challenger-capture active = false.                OK
-- T4  nfl_predecir() proceso 256 partidos.                          OK
-- T5  entradas que publican el precio como 'probabilidad':
--       1,135 antes  ->  0 despues.                                 OK
--     (113 de ellas estaban en 28 filas viejas que nfl_predecir ya no
--      recorre; se les paso la barrera con un UPDATE no-op, que renombra
--      la llave y conserva el numero.)
-- T6  mejor_pick no nulo: 0 antes -> 32 despues, todos con
--     model_version = nfl_hybrid_ml_v1. mejor_pick no canonico: 0.    OK
-- T7  PRUEBA ADVERSARIAL, cuatro contrabandos en una sola fila:
--       a) precio con la llave 'probabilidad'            -> RECHAZADO
--       b) etiqueta canonica con model_version RETIRADO  -> RECHAZADO
--       c) etiqueta canonica con model_version inventado -> RECHAZADO
--       d) etiqueta canonica con el COMPONENTE           -> RECHAZADO
--     Resultado: 0 entradas con probabilidad, 4 retiradas por la barrera,
--     mejor_pick NULL, legacy_pick_authority = DISABLED.              OK
--     Residuo de la prueba limpiado y verificado en 0.
-- T8  nfl_tablero: 32 filas MODELO_RETO (todas con p_reto y pick, modelo
--     nfl_hybrid_ml_v1) y 540 P_RETO_NO_DISPONIBLE (todas sin p_reto
--     ni pick).                                                       OK
-- T9  nfl_lock_semana: 15 filas, confianza_pct entre 53.71 y 72.17
--     (antes 15 filas con confianza_pct NULL).                        OK
-- T10 v_prediccion_reto_canonico: nfl -> prob_source nfl_hybrid_ml_v1
--     (15 filas), soccer -> crossleague_canonico (21). spread: 0.      OK
-- T11 v_super_pick ya no existe; su definicion si, guardada.           OK
-- T12 v_picks_para_parlay: 0 filas, por fail-closed.                   OK
-- T13 gate_p_reto_sin_precio:
--       P_RETO_SUSTITUIDO_POR_PRECIO    FAIL -> PASS
--       P_RETO_SUSTITUCION_SIN_REVISAR  FAIL -> PASS
-- T14 gate_linaje_de_writers / MODELO_EN_PRODUCCION_SIN_MOTOR FAIL -> PASS
-- T15 gate_gobierno_no_legible_por_cliente: PASS, PASS (sigue igual).

-- ─────────────────────────────────────────────────────────────────────
-- LO QUE ESTE PARCHE NO CIERRA (y no finge cerrar)
-- ─────────────────────────────────────────────────────────────────────
-- * MOTOR_SIN_MODELO_REGISTRADO sigue FAIL con 7 filas (futbol y MLB): es la
--   seccion D, no esta.
-- * CALIBRADOR_SIN_AUTORIDAD sigue FAIL: 0 calibradores vivos de 18, con 14
--   invalidados. Tambien seccion D.
-- * HALLAZGO ESTRUCTURAL para la seccion D: public.v_pick_canonico pasa
--   'feature_asof' => NULL a elegibilidad_no_economica_v1, y ese predicado exige
--   feature_asof < evento_at. O sea: NINGUN pick del selector canonico puede ser
--   elegible, pase lo que pase con el resto de los criterios. Registrar el
--   model_version solo mueve el motivo de SIN_MODEL_VERSION a SIN_LINAJE_MEDIDO.
--   Hoy v_pick_canonico devuelve 498 filas y las 498 tienen es_pick = false.
-- * HALLAZGO SEPARADO: refrescar_destacados publica en destacados_cache mercados
--   ya retirados por la gobernanza (Over/Under 2.5 de futbol, retirado en ISS194;
--   totales de NFL, declarados SIN_MODELO_CANONICO_VALIDADO aqui) y publica
--   vs_mercado_pts = prob_calibrada - mercado_sin_vig, que es ventaja contra el
--   mercado. Queda anotado, no resuelto.
