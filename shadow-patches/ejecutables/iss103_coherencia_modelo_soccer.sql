-- ISS103 — P0-2.F: COHERENCIA MATEMATICA DEL MODELO DE FUTBOL
-- issue #4, comentario 5646384073 (caso Cruz Azul vs America).
--
-- QUE ENCONTRE AL REPRODUCIR, Y POR QUE ES PEOR QUE LO REPORTADO
-- ==============================================================
-- El dueno reporto que 1X/12/X2 no se derivan del 1X2 mostrado. Al reproducir
-- sobre el evento 401876981 (Cruz Azul vs America, 2026-09-13) encontre que el
-- problema no es la algebra de la doble oportunidad: es que hay VARIOS MOTORES
-- publicando numeros distintos para el mismo evento.
--
-- Para ESE evento hay CUATRO probabilidades de local distintas:
--   38.4  analisis_partidos.analisis_json -> probabilidades.home_win
--         (_fuente_1x2 = 'dixon_coles_determinista')
--   39.1  analisis_json -> picks_recomendados[].prob   (el pick PUBLICADO)
--   39.9  fut_predicciones -> mercados[] 'Gana local'
--   49.1  lo que el dueno vio en la UI
-- y TRES pares de xG:
--   1.33 / 1.17      analisis_json.goles_esperados
--   1.512 / 1.205    analisis_json.pronostico_meta.xg   (mismo JSON!)
--   1.4546 / 1.3752  fut_predicciones.lam_h / lam_a
--
-- `mercados_desde_matriz(lam_h, lam_a)` es COHERENTE POR CONSTRUCCION: la doble
-- oportunidad sale del mismo CTE normalizado (h+d, a+d, h+a). Verificado en
-- fut_predicciones para el evento: 39.9+34.7 = 74.6 = el '12' guardado, exacto.
-- O sea el defecto NO esta en el derivador de mercados secundarios.
--
-- OTRO HALLAZGO DEL MISMO JSON: el pick de ese evento se eligio por EDGE.
--   "pick": "[PICK DE VALOR] Cruz Azul ML", "edge_calculado": 11.3,
--   "ev_estimado": "+11.4%", "best_edge_pick": "ML Cruz Azul"
-- Eso viola directamente el candado del dueno (nada de EV/edge/mercado para
-- seleccionar). Queda registrado aqui; la limpieza economica es otro frente.
--
-- DEFECTO ADICIONAL: la vista `v_analisis_partido` REVIENTA al leer este evento
--   ERROR: invalid input syntax for type integer: "38.4"
-- Hay un cast a integer sobre una probabilidad decimal. No lo arreglo en este
-- parche para no tocar una vista de superficie sin su propio ciclo de prueba,
-- pero queda medido y reportado.

begin;

-- Expone, por evento, los numeros de cada motor y los cuatro invariantes.
create or replace view public.v_incoherencia_modelo_soccer as
with motor_a as (
  select ap.espn_event_id::text ev,
         (ap.analisis_json::jsonb #>> '{probabilidades,home_win}')::numeric  a_h,
         (ap.analisis_json::jsonb #>> '{probabilidades,draw}')::numeric      a_d,
         (ap.analisis_json::jsonb #>> '{probabilidades,away_win}')::numeric  a_a,
         (ap.analisis_json::jsonb #>> '{goles_esperados,local}')::numeric    a_xgh,
         (ap.analisis_json::jsonb #>> '{goles_esperados,visitante}')::numeric a_xga,
         ap.analisis_json::jsonb #>> '{probabilidades,_fuente_1x2}'          a_fuente,
         (select (p->>'prob')::numeric from jsonb_array_elements(ap.analisis_json::jsonb->'picks_recomendados') p
           where p->>'mercado'='Moneyline' limit 1)                          a_pick_prob,
         ap.analisis_json::jsonb #>> '{pronostico_meta,xg}'                  a_meta_xg
  from analisis_partidos ap
  where jsonb_typeof(ap.analisis_json::jsonb)='object'
    and ap.analisis_json::jsonb ? 'probabilidades'
),
motor_b as (
  select a.espn_event_id::text ev, f.lam_h b_lamh, f.lam_a b_lama,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Gana local' limit 1)        b_h,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Empate' limit 1)            b_d,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Gana visitante' limit 1)    b_a,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Local o empate' limit 1)    b_1x,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Local o visitante' limit 1) b_12,
         (select (m->>'probabilidad')::numeric from jsonb_array_elements(f.mercados) m
           where m->>'pick'='Visitante o empate' limit 1) b_x2
  from fut_predicciones f
  join agenda_espn a on sin_acentos(lower(btrim(a.home_nombre))) = sin_acentos(lower(btrim(f.home_nombre)))
                    and a.deporte='soccer' and a.fecha::date = f.fecha::date
)
select coalesce(ma.ev, mb.ev) as espn_event_id,
       ma.a_h, ma.a_d, ma.a_a, ma.a_fuente, ma.a_pick_prob, ma.a_xgh, ma.a_xga, ma.a_meta_xg,
       mb.b_h, mb.b_d, mb.b_a, mb.b_1x, mb.b_12, mb.b_x2, mb.b_lamh, mb.b_lama,
       round(abs(coalesce(ma.a_h+ma.a_d+ma.a_a,100) - 100), 2) as motorA_error_suma,
       round(abs(coalesce(mb.b_h+mb.b_d+mb.b_a,100) - 100), 2) as motorB_error_suma,
       round(abs(coalesce(mb.b_1x,0) - coalesce(mb.b_h+mb.b_d,0)), 2) as err_1x,
       round(abs(coalesce(mb.b_12,0) - coalesce(mb.b_h+mb.b_a,0)), 2) as err_12,
       round(abs(coalesce(mb.b_x2,0) - coalesce(mb.b_d+mb.b_a,0)), 2) as err_x2,
       round(abs(coalesce(ma.a_h,0) - coalesce(mb.b_h,0)), 2) as desacuerdo_entre_motores_pp,
       round(abs(coalesce(ma.a_pick_prob, ma.a_h) - coalesce(ma.a_h,0)), 2) as err_pick_vs_distribucion
from motor_a ma full join motor_b mb on mb.ev = ma.ev
where coalesce(ma.ev, mb.ev) is not null;

create or replace function public.gate_coherencia_modelo_soccer()
returns jsonb language sql stable set search_path to 'public' as $function$
select jsonb_build_object(
  'SUMA_1X2_INVALIDA',
     (select count(*) from v_incoherencia_modelo_soccer
       where motorA_error_suma > 0.5 or motorB_error_suma > 0.5),
  'DOBLE_OPORTUNIDAD_INCOHERENTE',
     (select count(*) from v_incoherencia_modelo_soccer
       where err_1x > 0.5 or err_12 > 0.5 or err_x2 > 0.5),
  'MODEL_MATRIX_INCOHERENT',
     (select count(*) from v_incoherencia_modelo_soccer
       where a_h is not null and b_h is not null and desacuerdo_entre_motores_pp > 1.0),
  'PICK_FUERA_DE_SU_DISTRIBUCION',
     (select count(*) from v_incoherencia_modelo_soccer where err_pick_vs_distribucion > 0.5),
  'eventos_evaluados', (select count(*) from v_incoherencia_modelo_soccer),
  'desacuerdo_max_pp', (select max(desacuerdo_entre_motores_pp) from v_incoherencia_modelo_soccer
                         where a_h is not null and b_h is not null),
  'ejemplo_incoherente', coalesce((select jsonb_build_object(
      'evento', espn_event_id,
      'motorA_1x2', jsonb_build_array(a_h, a_d, a_a), 'motorA_fuente', a_fuente,
      'motorB_1x2', jsonb_build_array(b_h, b_d, b_a),
      'desacuerdo_pp', desacuerdo_entre_motores_pp,
      'pick_publicado', a_pick_prob, 'distribucion_del_pick', a_h)
      from v_incoherencia_modelo_soccer
      where a_h is not null and b_h is not null
      order by desacuerdo_entre_motores_pp desc limit 1), '{}'));
$function$;

commit;

-- MEDIDO EN PRODUCCION 2026-09-12, 637 eventos:
--   SUMA_1X2_INVALIDA              = 0    cada motor suma 100 por separado
--   DOBLE_OPORTUNIDAD_INCOHERENTE  = 0    la algebra de fut_predicciones es correcta
--   MODEL_MATRIX_INCOHERENT        = 19   dos motores, distinta P(local)
--   PICK_FUERA_DE_SU_DISTRIBUCION  = 340  el pick publicado no sale de su propia 1X2
--   desacuerdo maximo              = 28.6 pp
--
-- PEOR CASO: evento 401876458
--   Motor A (analisis_json, dixon_coles_determinista):  48.6 / 25.6 / 25.7
--   Motor B (fut_predicciones):                         20.0 / 16.2 / 63.8
--   No solo difieren: se contradicen en QUIEN ES EL FAVORITO.
--
-- CONCLUSION PARA EL CONTRATO: la etiqueta "mercados del mismo modelo" no se
-- puede sostener mientras dos motores publiquen el mismo evento. El arreglo NO es
-- corregir numeros: es elegir un motor canonico (el bakeoff A/B que el propio
-- issue #4 exige) y suprimir en falla cerrada los secundarios de todo evento con
-- MODEL_MATRIX_INCOHERENT. Ese bakeoff necesita muestra historica emparejada y es
-- un frente propio, no un parche.
