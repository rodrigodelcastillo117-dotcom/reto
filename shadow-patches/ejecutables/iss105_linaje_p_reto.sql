-- ISS105 — P0-4: LINAJE REAL DE P_RETO. Descubierto, no rellenado.
--
-- El dueno exigio: descubrir el lineage real, sin default model version, sin
-- constante, sin COALESCE ficticio, sin row_number, sin id sintetico.
-- Esto es lo que el dato REALMENTE permite descubrir, y donde se acaba.
--
-- ORIGEN TRAZADO POR DEPENDENCIAS (pg_depend sobre las vistas de cada motor):
--   motor_futbol_calibrado -> v_picks_futbol_calibrado -> fut_predicciones
--   motor_mlb_cuantitativo -> v_picks_mlb_modelo       -> badrino_partidos
--   motor_picks            -> picks_recomendados_hoy   -> analisis_partidos
--
-- QUE ESTAMPA CADA ORIGEN, VERIFICADO COLUMNA POR COLUMNA:
--   fut_predicciones   NINGUNA columna de version/modelo/motor. Si tiene
--                      generado_at, asi que hay sello temporal pero no identidad
--                      de modelo. 119 de las 284 filas canonicas.
--   badrino_partidos   NINGUNA columna de version/modelo/motor y NINGUN sello
--                      temporal utilizable. 160 filas. El caso peor.
--   analisis_partidos  SI estampa analysis_version='meta-v3' y
--                      probabilidades._fuente_1x2='dixon_coles_determinista',
--                      con generado_en. 5 filas. Version REAL y descubrible.
--
-- POR QUE NO CIERRO EL HUECO AQUI:
--   modelo_registry contiene soccer_1x2_poisson_v1, pero NADA en el dato une una
--   fila de fut_predicciones con ese registro. Mapearlas seria inventar. Ademas
--   motor_modelo_mapa ya advierte, de una ronda anterior, que el modelo del
--   backtest NO es el que sirve la vista. Y 'meta-v3', aunque es una version real
--   estampada por su productor, no existe en modelo_registry: registrarla como si
--   fuera un model_version con autoridad de calibracion seria otra invencion.
--
-- BLOCKER EXTERNO PRECISO: el hueco no es recuperable desde el dato. Exige que
-- los GENERADORES estampen la version:
--   1. el generador de fut_predicciones debe escribir model_version y
--      calibration_version por fila (hoy no existe la columna);
--   2. el generador de badrino_partidos, lo mismo, y ademas un sello temporal;
--   3. 'meta-v3' debe darse de alta en modelo_registry, o declararse
--      explicitamente como pipeline de analisis y NO como modelo predictivo.
-- Eso es cambio de pipeline de escritura, no una vista. Hasta entonces
-- P_RETO_SIN_LLAVE_TRAZABLE = 284 y es el estado honesto.

begin;

create or replace view public.v_linaje_p_reto as
select k.espn_event_id, k.deporte, k.mercado, k.pick_desc, k.fuente, k.probabilidad_pct, k.arranca_en,
  case k.fuente
    when 'motor_futbol_calibrado'  then 'fut_predicciones'
    when 'motor_mlb_cuantitativo'  then 'badrino_partidos'
    when 'motor_picks'             then 'analisis_partidos'
  end as tabla_origen,
  case k.fuente
    when 'motor_picks' then (
      select ap.analisis_json::jsonb->>'analysis_version'
      from analisis_partidos ap where ap.espn_event_id = k.espn_event_id
        and jsonb_typeof(ap.analisis_json::jsonb)='object' limit 1)
    else null
  end as version_descubierta,
  case k.fuente
    when 'motor_picks' then (
      select ap.analisis_json::jsonb #>> '{probabilidades,_fuente_1x2}'
      from analisis_partidos ap where ap.espn_event_id = k.espn_event_id
        and jsonb_typeof(ap.analisis_json::jsonb)='object' limit 1)
    else null
  end as metodo_declarado,
  case k.fuente
    when 'motor_futbol_calibrado' then (
      select max(f.generado_at) from fut_predicciones f
       where f.fecha::date = k.arranca_en::date
         and sin_acentos(lower(btrim(f.home_nombre))) = sin_acentos(lower(btrim(k.home))))
    when 'motor_picks' then (
      select (ap.analisis_json::jsonb->>'generado_en')::timestamptz
      from analisis_partidos ap where ap.espn_event_id = k.espn_event_id
        and jsonb_typeof(ap.analisis_json::jsonb)='object' limit 1)
    else null
  end as calculado_at,
  modelo_de_pick(k.fuente, k.deporte, k.mercado)      as model_version_en_mapa,
  calibracion_de_pick(k.fuente, k.deporte, k.mercado) as calibration_version_en_mapa,
  case
    when modelo_de_pick(k.fuente, k.deporte, k.mercado) is not null then 'TRAZABLE'
    when k.fuente = 'motor_futbol_calibrado'
      then 'ORIGEN_SIN_COLUMNA_DE_VERSION: fut_predicciones no tiene ninguna columna de version/modelo; el generador nunca la estampa'
    when k.fuente = 'motor_mlb_cuantitativo'
      then 'ORIGEN_SIN_COLUMNA_DE_VERSION: badrino_partidos no tiene ninguna columna de version/modelo'
    when k.fuente = 'motor_picks'
      then 'VERSION_EN_ORIGEN_NO_REGISTRADA: analisis_partidos si estampa analysis_version, pero ese valor no existe en modelo_registry'
    else 'FUENTE_DESCONOCIDA'
  end as motivo_sin_llave
from v_pick_canonico k;

create or replace function public.gate_linaje_p_reto()
returns jsonb language sql stable set search_path to 'public' as $function$
select jsonb_build_object(
  'P_RETO_SIN_LLAVE_TRAZABLE', (select count(*) from v_linaje_p_reto where motivo_sin_llave <> 'TRAZABLE'),
  'P_RETO_TRAZABLE',           (select count(*) from v_linaje_p_reto where motivo_sin_llave = 'TRAZABLE'),
  'filas_canonicas',           (select count(*) from v_linaje_p_reto),
  'sin_llave_por_motivo', (select jsonb_object_agg(motivo_sin_llave, n) from
     (select motivo_sin_llave, count(*) n from v_linaje_p_reto
       where motivo_sin_llave <> 'TRAZABLE' group by 1) q),
  'con_version_descubierta_en_origen',
     (select count(*) from v_linaje_p_reto where version_descubierta is not null),
  'sin_ningun_sello_temporal',
     (select count(*) from v_linaje_p_reto where calculado_at is null),
  'por_origen', (select jsonb_object_agg(tabla_origen, jsonb_build_object(
       'filas', n, 'version_en_origen', ver, 'con_sello_temporal', sello)) from
     (select tabla_origen, count(*) n, max(version_descubierta) ver, count(calculado_at) sello
       from v_linaje_p_reto group by 1) q));
$function$;

commit;

-- MEDIDO 2026-09-12 sobre 284 filas canonicas:
--   P_RETO_TRAZABLE                   = 0
--   P_RETO_SIN_LLAVE_TRAZABLE         = 284
--   con_version_descubierta_en_origen = 5     (meta-v3)
--   sin_ningun_sello_temporal         = 160   (todo MLB)
--   por origen: badrino_partidos 160 sin version y sin sello
--               fut_predicciones 119 sin version, 119 con sello
--               analisis_partidos  5 con meta-v3 y con sello
