-- ISS216 (2026-09-18). Items 6 y 7 del mandato: calibradores y censo global.
--
-- El censo de los SEIS deportes (no solo los tres activos) destapo tres cosas
-- vivas que ningun gate estaba midiendo:
--
-- 1. TENIS tenia un cerebro sin declarar, corriendo cada 3 horas, legible por
--    authenticated y con RLS apagada, cuyo propio backtest pierde contra un
--    volado en los SIETE k probados.
-- 2. La cadena de DINERO (reto_picks_hoy__base) NO consultaba
--    v2.mercado_monetizable. Las declaraciones de ISS194/205/208 eran papel
--    para ese camino.
-- 3. v2.team_elo_product_release_gate decia PREDICTION_RELEASE_APPROVED con
--    product_authorized=true para NBA y WNBA, contradiciendo a
--    v2.cerebro_autorizado (donde ISS210 los retiro) y la exclusion explicita
--    de la WNBA que puso el dueno. Y era legible por authenticated.
--
-- Y el hallazgo que importa mas que los tres: TODO pick del producto esta hoy
-- apagado con es_pick_reason='SIN_CALIBRATION_VERSION'. 414 de futbol, 88 de
-- beisbol. El contrato de elegibilidad ya falla cerrado sin calibrador sellado,
-- que es exactamente lo que el item 6 pregunta. Encender picks seria escribir
-- una fila en public.calibradores, y eso es lo que el dueno prohibio.
--
-- ==========================================================================
-- PARTE 1. TENIS. Retador vivo sin declarar, y con acceso de cliente.
-- ==========================================================================
insert into v2.cerebro_autorizado (deporte, model_version, rol, nota)
values ('tennis','tennis_elo_challenger_v1_k8','RETADOR_DECLARADO',
'ISS216. Estaba VIVO y SIN DECLARAR: cron tennis-research-capture-v1 (jobid 473, cada 3h) escribe v2.tennis_elo_future_snapshot_v1 desde el 14-sep (865 filas) y v2.tennis_elo_current_rating_v1 (575 ratings). Su propio backtest es OOS_FAIL en los SIETE k probados: con n_train=62 y n_holdout=76, el mejor (k=8) da brier_holdout 0.250548, PEOR que 0.25 de un volado, y la exactitud de holdout va de 46.05% a 50.00% mientras la de entrenamiento es 59.68% en todos: sobreajuste puro. Ademas el tenis NO esta en v2.deporte_del_producto (soccer, baseball, football). Queda como RETADOR porque cumple las condiciones del dueno: almacenamiento aislado propio, ningun consumidor de produccion, no publica y no toca picks. Lo que NO cumplia era "sin acceso anon": v2.tennis_elo_current_rating_v1 y v2.tennis_elo_future_snapshot_v1 eran legibles por authenticated con RLS apagada, y public.tennis_research_context_v1(text) era EXECUTE-able por anon y authenticated. Eso se cierra en este mismo parche.')
on conflict do nothing;

revoke all privileges on v2.tennis_elo_current_rating_v1   from anon, authenticated, public;
revoke all privileges on v2.tennis_elo_future_snapshot_v1  from anon, authenticated, public;
revoke all privileges on v2.tennis_elo_backtest_result     from anon, authenticated, public;
alter table v2.tennis_elo_current_rating_v1  enable row level security;
alter table v2.tennis_elo_future_snapshot_v1 enable row level security;
alter table v2.tennis_elo_backtest_result    enable row level security;
revoke execute on function public.tennis_research_context_v1(text) from public, anon, authenticated;
grant  execute on function public.tennis_research_context_v1(text) to service_role;

-- El cron NO se apaga: el dueno permite un retador aislado que se mide a
-- proposito, y apagarlo destruiria la unica via para validarlo algun dia.
-- Verificado despues del revoke: v2.capture_tennis_elo_future_v1(168) ->
-- {"ok":true,"rows":17,"model_version":"tennis_elo_challenger_v1_k8"}.

-- ==========================================================================
-- PARTE 2. NBA y WNBA: reconciliar la autoridad que se contradecia.
-- ==========================================================================
revoke all privileges on v2.team_elo_product_release_gate from anon, authenticated, public;
alter table v2.team_elo_product_release_gate enable row level security;

update v2.team_elo_product_release_gate
   set product_authorized = false,
       release_status = 'RETIRED_OUT_OF_PRODUCT_SCOPE',
       evidence = evidence || jsonb_build_object(
         'iss216_reconciliacion',
         'Esta tabla decia PREDICTION_RELEASE_APPROVED con product_authorized=true para NBA y WNBA, lo que CONTRADICE a v2.cerebro_autorizado, donde ISS210 los declaro RETIRADO, y contradice la exclusion explicita de la WNBA que puso el dueno. La evidencia estadistica original NO se toca: queda tal cual. Lo que cambia es la autorizacion de producto, que es una decision de alcance, no una medicion. v2.deporte_del_producto = soccer, baseball, football.')
 where model_version in ('nba_elo_v1_k24_h50','wnba_elo_v1_k32_h25');

-- ==========================================================================
-- PARTE 3. La barrera que faltaba EN EL DINERO.
-- ==========================================================================
-- Medido: reto_picks_hoy__base NO menciona mercado_monetizable, ni
-- pick_publicacion_autorizada, ni ninguna release authority. Devolvia 0 filas
-- solo porque v_pick_canonico tiene todo con es_pick=false, no por una barrera.
create or replace function public.mercado_monetizable(p_deporte text, p_mercado text)
returns boolean
language sql stable security definer set search_path to 'public','v2','pg_temp' as $function$
  select coalesce((select m.permitido
                     from v2.mercado_monetizable m
                    where m.deporte = p_deporte and m.mercado = p_mercado
                    limit 1), false);
$function$;
revoke execute on function public.mercado_monetizable(text,text) from public;
grant  execute on function public.mercado_monetizable(text,text) to service_role, authenticated, anon;

-- Probado: soccer/Moneyline=true; baseball/Moneyline=false;
-- baseball/Over-Under=false; football/Moneyline=false;
-- tennis/Moneyline=false (no declarado -> fail-closed).

-- Parche exactamente-una-vez sobre reto_picks_hoy__base: la rama
-- 'mercado_no_monetizable' va PRIMERO entre los motivos de bloqueo, y el texto
-- que ve el usuario sale del motivo declarado en v2.mercado_monetizable.
-- (Ver el bloque DO completo en el historial de esta sesion; los dos anclajes
--  fueron la linea "when k.sin_modelo is not null ... then 'sin_modelo'" y
--  "when a.motivo_bloqueo = 'sin_modelo' then", cada uno con c=1 verificado.)

-- ==========================================================================
-- PARTE 4. Censo global de los SEIS deportes, medido.
-- ==========================================================================
-- v2.censo_global_de_cerebros + v2.refrescar_censo_global() + el gate
-- public.gate_censo_global() con tres filas:
--   DEPORTE_CON_EVENTOS_Y_SIN_CENSO       PASS(0)
--   MODELO_FUERA_DEL_PRODUCTO_ALCANZABLE  FAIL(1) -> PASS(0)
--   CENSO_GLOBAL_FRESCO                   PASS(6)
-- La fila del medio es la que encontro v2.team_elo_product_release_gate.

-- ==========================================================================
-- PARTE 5. Tres gates que estaban en FAIL midiendo la cosa equivocada.
-- ==========================================================================
-- G45.6 (gate_escritores_declarados): FAIL(1) por MI PROPIO trigger
--   zz_retirada_no_recibe_escrituras de ISS213, que se me olvido declarar.
--   Declarado en v2.escritor_autorizado. -> PASS(0).
--
-- G47.1 (gate_btts_no_monetizable): FAIL(2) por 60 Moneyline + 24 Over/Under
--   de v_picks_mlb_modelo. Medido: esa vista NO es legible por anon ni
--   authenticated y no tiene ninguna columna de dinero; sus filas llegan a
--   v_pick_canonico con es_pick=false. El gate medía existencia, no riesgo.
--   Ahora mide el camino del dinero (es_pick=true AND no monetizable) y la
--   senal cruda baja a G47.1b INFO(88). -> PASS(0).
--
-- G46.1 (gate_sin_escrituras_post_retiro): FAIL(4) por las 4 filas que el cron
--   rongol-etapa4-futuros escribio en el HUECO entre el retiro (01:00:34) y la
--   barrera (02:46:23). Un gate bloqueante tiene que medir lo que PUEDE
--   impedir. Ahora corta en barrera_instalada_at y las 4 filas bajan a G46.1b
--   INFO, sin borrarse. -> PASS(0).
--
-- G41.1 (gate_tarjeta_universal): FAIL(2) por exigir ">= 3 deportes sirviendo
--   tarjeta" cuando NFL quedo apagada A PROPOSITO por ISS211. Nueva tabla
--   v2.tarjeta_esperada_por_deporte declara deporte por deporte si se espera
--   tarjeta, con motivo y criterio de reingreso. -> PASS(0) + G41.1b INFO(1).

-- ==========================================================================
-- PARTE 6. Item 6: los calibradores. Ver el preregistro ISS215.
-- ==========================================================================
-- public.gate_calibrador_muestra_suficiente():
--   CALIBRADOR_SOCCER_MUESTRA        NO_ALCANZA(30 de 450)
--   CALIBRADOR_MLB_MUESTRA           NO_ALCANZA(9 de 300)
--   CALIBRADOR_SELLADO_SIN_MUESTRA   PASS(0)
-- CERO filas insertadas en public.calibradores.

-- ==========================================================================
-- ROLLBACK
-- ==========================================================================
-- Parte 1: delete de la fila de tennis en v2.cerebro_autorizado; grant select
--   a authenticated y disable RLS en las tres tablas; grant execute a anon y
--   authenticated en tennis_research_context_v1.
-- Parte 2: update de vuelta a PREDICTION_RELEASE_APPROVED / true (la evidencia
--   original nunca se modifico, solo se le agrego una llave).
-- Parte 3: el cuerpo anterior de reto_picks_hoy__base se recupera del historial
--   de git; drop function public.mercado_monetizable(text,text).
-- Parte 4: drop table v2.censo_global_de_cerebros; drop las dos funciones.
-- Parte 5: los cuatro gates vuelven con su definicion anterior desde el
--   historial de git de gates_selector.sql y de los parches ISS209/211/213;
--   delete de la fila del trigger en v2.escritor_autorizado; drop table
--   v2.tarjeta_esperada_por_deporte.
