-- iss093 — SELECTOR CANÓNICO LIMPIO
-- Responde al AUDIT_NO_PASS, comentario 5642144970.
--
-- La orden del dueño, textual: «El usuario quiere lo que RETO cree que pasará,
-- no "lo que más supera un baseline artificial"».
--
-- ===========================================================================
-- LO QUE ENCONTRÉ, INCLUYENDO ALGO PEOR DE LO REPORTADO
-- ===========================================================================
-- Los 4 bloqueadores estaban donde dijo el dueño. Pero el bloqueador del EV era
-- MÁS PROFUNDO que "la vista todavía expone ev_pct":
--
--   En v_pick_canonico, `rank_en_partido` ordenaba por
--       es_pick DESC, es_senal DESC, (probabilidad_pct - baseline) DESC, ...
--   y `es_pick` sale de
--       economic_eligibility_v1(..., 'ev_pct', c.ev_pct, 'ev_threshold', 2.5)
--   O SEA: EL EV NO SÓLO SE EXPONÍA, ERA LA PRIMERA LLAVE DE ORDEN.
--   Ninguna de las dos vistas de arriba podía quedar limpia mientras la raíz
--   ordenara por EV. Se parcheó la raíz primero: `rank_en_partido` ahora ordena
--   sólo por probabilidad_pct.
--
-- Y había DOS superficies visibles más de las nombradas: v_reto13m_lo_mejor
-- (que ES la pantalla "Lo Mejor de Hoy") traía los cuatro defectos a la vez:
-- `base_azar` y `ventaja_sobre_azar` como COLUMNAS y dentro del ORDER BY,
-- `discriminacion_pp`, `prob_que_implica_el_precio_pct`, PARTITION BY deporte,
-- el gate de zona_realidad en el WHERE exterior, un piso fijo de 55% y
-- `h2h_apoya` como PRIMERA llave de orden con `COALESCE(h2h_apoya, true)` de
-- gate. Se reescribe completa.
--
-- ===========================================================================
-- REGLA NUEVA DE SELECCIÓN
-- ===========================================================================
-- 1. Por partido: el resultado con mayor P_RETO. Eso es "lo que RETO cree que
--    pasará". Sin restar baseline, sin pisos de mercado.
-- 2. Orden global: SOLO por P_RETO. TOP_ONLY_GLOBAL.
-- 3. Sin cuota por deporte. Si los 3 mejores son NFL, salen 3 NFL. Si sólo hay
--    uno bueno, sale uno. Si ninguno merece, 0.
-- 4. P_RETO NO se modifica con nada. zona_realidad se queda como contexto
--    informativo y no ordena, no filtra y no sustituye.
--
-- CONSECUENCIA QUE HAY QUE DECIR EN VOZ ALTA: "merece salir" ya no puede
-- significar "le gana a un baseline inventado". Lo único defendible que queda
-- es "el calibrador de ese mercado pasó el holdout limpio", o sea
-- calibradores.apto_para_lock. Hoy NINGÚN mercado lo tiene: ni MLB, ni NFL, ni
-- Soccer. Por lo tanto v_reto13m_mejores devuelve 0 FILAS HOY.
-- No invento un umbral para que la pantalla no se vea vacía: inventar un umbral
-- es exactamente la "regla inventada" que el dueño acaba de prohibir. El
-- análisis experimental vive en v_reto13m_analisis_experimental, etiquetado.
--
-- ===========================================================================
-- UNA REGLA MÍA QUEDA DEROGADA
-- ===========================================================================
-- La invariante 2 de verificar_invariantes.sql decía
--     'PISO ROTO: % picks por debajo del azar'
-- es decir, EXIGÍA el piso que el dueño acaba de prohibir. Queda derogada y
-- sustituida por las 4 pruebas nuevas. Lo anoto porque si no, mi propio arnés
-- de pruebas reprobaría el comportamiento correcto.

-- ===========================================================================
-- 1) REGISTRO DE SUPERFICIE VISIBLE
--    Sin esto, "EV_FIELDS_USER_VISIBLE = 0" no es comprobable: hay 18 vistas
--    con campos de mercado y la mayoría son diagnóstico de laboratorio.
-- ===========================================================================
create table if not exists public.superficie_usuario (
  vista text primary key,
  proposito text not null,
  declarada_at timestamptz not null default now()
);
comment on table public.superficie_usuario is
  'Vistas que el usuario final ve. Las 4 pruebas del selector se aplican SOLO a estas. Una vista de diagnostico puede tener campos de mercado; una de aqui no.';

insert into public.superficie_usuario (vista, proposito) values
  ('v_reto13m_mejores',                'Reto13M: los mejores picks, orden global, solo mercados validados'),
  ('v_reto13m_lo_mejor',               'Lo Mejor de Hoy'),
  ('v_mejor_pick_por_partido',         'Un pick por partido: lo que RETO cree que pasara'),
  ('v_reto13m_analisis_experimental',  'Analisis experimental: visible pero marcado como no validado')
on conflict (vista) do update set proposito = excluded.proposito;

-- ===========================================================================
-- 2) ¿Qué mercado está autorizado a aparecer como pick de verdad?
--    Única respuesta defendible: su calibrador pasó el holdout limpio.
-- ===========================================================================
create or replace function public.mercado_apto_para_lock(p_deporte text, p_mercado text)
returns boolean language sql stable set search_path to 'public' as $function$
  select exists (
    select 1 from calibradores c
    where c.apto_para_lock and not c.invalidado
      and c.deporte = case
            when p_deporte ~* 'baseball|beisbol' then 'baseball'
            when p_deporte ~* 'football|nfl'     then 'football'
            when p_deporte ~* 'soccer|futbol'    then 'soccer'
            else p_deporte end
      and c.mercado = case
            -- en soccer el Moneyline ES el mercado 1X2
            when p_deporte ~* 'soccer|futbol' and p_mercado = 'Moneyline' then '1X2'
            else p_mercado end
  );
$function$;
comment on function public.mercado_apto_para_lock(text,text) is
  'true solo si el calibrador de ese (deporte, mercado) tiene apto_para_lock. Hoy devuelve false para todo a proposito.';
grant execute on function public.mercado_apto_para_lock(text,text) to anon, authenticated, service_role;

-- ===========================================================================
-- 3) El contexto de precio NO se pierde: se muda a una vista de diagnóstico
--    que NO está en superficie_usuario.
-- ===========================================================================
create or replace view public.v_diagnostico_precio as
select p.espn_event_id, p.deporte, p.liga, p.home, p.away, p.arranca_en,
       p.mercado, p.pick_nombre, p.pick_desc,
       p.probabilidad_pct,
       p.momio_mercado, p.casa, p.momio_capturado_at,
       p.ev_pct, p.edge_pct, p.prob_que_implica_el_precio_pct,
       round(p.probabilidad_pct - p.prob_que_implica_el_precio_pct, 2) as discriminacion_pp,
       p.es_pick, p.es_pick_reason, p.nivel_ventaja, p.explicacion_precio
from public.v_pick_canonico p;
comment on view public.v_diagnostico_precio is
  'DIAGNOSTICO, NO SUPERFICIE DE USUARIO. Aqui viven ev_pct, edge_pct, la probabilidad implicita, discriminacion_pp, es_pick y nivel_ventaja. Existen para auditar el mercado, nunca para elegir, ordenar, autorizar ni sustituir un pick.';

-- ===========================================================================
-- 4) LA CADENA LIMPIA
-- ===========================================================================
-- 4a) Raíz: se parcheó `rank_en_partido` de v_pick_canonico para que ordene
--     SOLO por probabilidad_pct. Antes: es_pick DESC (que es EV), es_senal DESC,
--     (probabilidad_pct - baseline) DESC. Se hizo con cirugía server-side sobre
--     pg_get_viewdef para no reescribir 400 líneas a mano y no divergir de
--     producción; el parche aborta si el patrón no coincide exactamente.
--
--     NOTA: v_pick_canonico sigue llevando `zona` y los campos de precio. Eso
--     está permitido: es la capa de ENSAMBLADO, no superficie de usuario, y ahí
--     la medición es contexto inerte (no ordena, no filtra, no sustituye).
--     Verificado: `zona` es passthrough puro en las 2 vistas que la mencionan.
--
-- 4b) v_mejor_pick_por_partido: por partido, argmax P_RETO. Reescrita.
-- 4c) v_reto13m_mejores: orden global por P_RETO, sin cuota, sólo mercados con
--     apto_para_lock. HOY DEVUELVE 0 FILAS.
-- 4d) v_reto13m_analisis_experimental: lo que el cerebro ve, marcado.
-- 4e) v_reto13m_lo_mejor: reescrita completa.
--
-- Efecto medido tras la cirugía:
--   v_mejor_pick_por_partido: 60 picks, rango 32.6%..72.9%,
--     y 2 PICKS POR DEBAJO DEL 50% QUE ANTES ERAN IMPOSIBLES. Esa es la prueba
--     de que el piso del baseline se fue de verdad.
--   v_reto13m_lo_mejor: 46 filas, 3 deportes, top global 1 NFL + 5 soccer
--     seguidos. Sin cuota forzando uno por deporte.
--   v_reto13m_mejores: 0 filas.
--
-- ===========================================================================
-- 5) LAS 4 PRUEBAS OBLIGATORIAS: public.pruebas_selector_limpio()
-- ===========================================================================
--   EV_FIELDS_USER_VISIBLE     = 0   (columna prohibida expuesta en superficie)
--   UNIFORM_BASELINE_PICK_GATE = 0   (33.3 / 50.0 en la CADENA completa)
--   SPORT_QUOTA                = 0   (partition by deporte / rn_deporte)
--   IN_SAMPLE_PROB_MUTATION    = 0   (la medición muta P_RETO, ordena o filtra)
--
-- Las pruebas 2 y 4 recorren el CIERRE DE DEPENDENCIAS (18 vistas), no sólo la
-- vista final: un baseline en la raíz contamina hacia arriba, y eso era
-- exactamente lo que pasaba.
--
-- CONTROL NEGATIVO EJECUTADO: una prueba que nunca falla no vale nada. Se
-- plantaron las 4 violaciones y las 4 saltaron:
--   - v_diagnostico_precio al registro     -> EV_FIELDS_USER_VISIBLE = 7
--   - _cn_baseline (WHERE con 33.3/50.0)   -> UNIFORM_BASELINE_PICK_GATE = 1
--   - _cn_cuota (partition by deporte)     -> SPORT_QUOTA = 2
--   - _cn_mutacion (ORDER BY zona_realidad)-> IN_SAMPLE_PROB_MUTATION = 1
-- Después se borraron y las 4 volvieron a 0.
--
-- AJUSTE HONESTO DE LA PRUEBA 4: mi primera versión marcaba la simple PRESENCIA
-- de zona_realidad en la cadena y reprobaba por v_pick_canonico. El nombre de la
-- prueba dice MUTACION, no presencia, y llevar la medición como contexto está
-- permitido. La afiné a nivel de LÍNEA para detectar lo prohibido de verdad:
-- (a) columna de probabilidad derivada de la medición en la superficie,
-- (b) la medición dentro de un ORDER BY / PARTITION BY / WHERE / HAVING,
-- (c) P_RETO reasignada desde prob_real_del_tramo.
-- El recorrido por línea además corrigió un FALSO POSITIVO real: mi regex
-- anterior cruzaba saltos de línea y declaraba que v_oraculo_canonico ordenaba
-- por `zona` cuando sólo la muestra.
--
-- ===========================================================================
-- 6) DOS COSAS QUE ENCONTRÉ Y QUE NO SON MÍAS DE ARREGLAR AQUÍ
-- ===========================================================================
-- 6a) EL POISSON NUEVO NO SE COLÓ. Verificado: `soccer_1x2_poisson_v1` aparece
--     en 0 vistas de la cadena. La probabilidad de fútbol visible sale de
--     `motor_futbol_calibrado`. El Poisson está en modelo_registry como
--     CHALLENGER y nada más. La preocupación del dueño está cubierta de hecho.
--
-- 6b) PERO `crossleague_v1` NO EXISTE EN ESTA BASE. Cero apariciones: ni en
--     modelo_registry, ni en nombre de tabla, ni en definición de vista. Sólo
--     vive en shadow-patches/prepared/ (iss027, iss037, iss041, iss044, iss051),
--     que son los parches que nunca se ejecutaron contra producción.
--     CONSECUENCIA: "comparar el Poisson contra la versión exacta que produjo el
--     snapshot canónico" no se puede ejecutar en esta base tal como está pedido,
--     porque esa versión no está aquí.
--     Y LO MÁS GRAVE: el motor que SÍ alimenta fútbol al usuario
--     (`motor_futbol_calibrado` / v_picks_futbol_calibrado) NO ESTÁ REGISTRADO en
--     modelo_registry. No tiene model_version, no tiene estado declarado y no
--     tiene calibrador asociado. El único modelo de soccer registrado es el
--     challenger que acabo de crear. Eso se reporta, no se parchea por mi cuenta.
