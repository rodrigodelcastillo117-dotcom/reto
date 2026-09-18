-- ISS214 (2026-09-18). #10 del mandato: "clasificar las 269 lineas por
-- comportamiento real, no etiquetarlas para silenciar el gate".
--
-- Al clasificar por comportamiento aparecio lo que la etiqueta escondia.
-- Tres hallazgos vivos, no historicos:
--
-- 1. badrino_predecir() elegia el pick CON EL PRECIO. El codigo decia
--    textualmente "El mejor pick solo sale de fuentes validadas (el mercado)"
--    y hacia WHERE fuente='mercado' ORDER BY probabilidad DESC. 373 de 377
--    filas de badrino_predicciones traian ese pick. La funcion era
--    EXECUTE-able por anon y authenticated, con 43 llamadas por PostgREST.
--    badrino no es el cerebro autorizado de beisbol: lo es mlb_one_brain_v2.
--    Su unica otra fuente se llama, textualmente, 'modelo (sin validar)'.
--
-- 2. v_picks_premium era una maquina de precio puro, legible por anon.
--
-- 3. Tres funciones mas que escriben predicciones eran ejecutables por el
--    cliente: mlb_shadow_generar, nfl_capturar_prediccion, nfl_predecir.
--
-- ==========================================================================
-- PARTE 1. badrino_predecir() deja de elegir el pick con el precio.
-- ==========================================================================
do $$
declare
  v_def text; v_o text; v_n text; c int;
begin
  v_def := pg_get_functiondef('public.badrino_predecir()'::regprocedure);

  v_o := E'    -- El mejor pick solo sale de fuentes validadas (el mercado)\n'
      || E'    SELECT (x->>''pick'') pick, (x->>''probabilidad'')::numeric prob INTO mejor\n'
      || E'    FROM jsonb_array_elements(mk) x\n'
      || E'    WHERE x->>''fuente'' = ''mercado'' AND (x->>''probabilidad'')::numeric <= 88\n'
      || E'    ORDER BY (x->>''probabilidad'')::numeric DESC LIMIT 1;';

  v_n := E'    -- ISS214. EL PRECIO YA NO ELIGE EL PICK.\n'
      || E'    -- Antes esta funcion escogia mejor_pick con WHERE fuente=''mercado''\n'
      || E'    -- ORDER BY probabilidad DESC, y la nota decia "fuentes validadas".\n'
      || E'    -- Medido el 2026-09-18: 373 de 377 filas de badrino_predicciones\n'
      || E'    -- traian un mejor_pick elegido por el precio, y la funcion era\n'
      || E'    -- EXECUTE-able por anon y authenticated (43 llamadas por PostgREST).\n'
      || E'    -- badrino NO es el cerebro autorizado de beisbol: lo es\n'
      || E'    -- mlb_one_brain_v2. Su unica otra fuente se llama, textualmente,\n'
      || E'    -- ''modelo (sin validar)''. Sin cerebro autorizado no hay pick.\n'
      || E'    -- Los mercados siguen guardandose como DATO informativo, con su\n'
      || E'    -- etiqueta de fuente intacta. mejor_pick queda en NULL: fail-closed.\n'
      || E'    SELECT null::text pick, null::numeric prob INTO mejor;';

  -- Disciplina de parche exactamente-una-vez.
  c := (length(v_def) - length(replace(v_def, v_o, ''))) / length(v_o);
  if c <> 1 then
    raise exception 'ISS214 badrino_predecir: se esperaba 1 ocurrencia del bloque, hay %', c;
  end if;

  execute replace(v_def, v_o, v_n);
end $$;

-- El revoke a anon/authenticated NO basta: EXECUTE se hereda por PUBLIC.
-- Ese fue exactamente el error que cometi en ISS209 con score_notifications.
revoke execute on function public.badrino_predecir() from public;
grant  execute on function public.badrino_predecir() to service_role;

comment on function public.badrino_predecir() is
'ISS214. No elige pick. Antes elegia mejor_pick por fuente=''mercado'' ORDER BY probabilidad DESC: el precio creaba el pick. badrino no es el cerebro autorizado de beisbol (mlb_one_brain_v2 lo es), asi que mejor_pick sale NULL. Los mercados quedan como dato informativo. EXECUTE revocado a anon y authenticated (via PUBLIC): un cliente no dispara una escritura de modelo.';

-- Evidencia historica. NO se borra nada.
create table if not exists v2.iss214_pick_elegido_por_precio (
  id bigserial primary key,
  tabla text not null,
  espn_event_id text not null,
  fecha timestamptz,
  mejor_pick_historico text,
  mejor_prob_historica numeric,
  fuente_de_la_eleccion text not null,
  era_futuro boolean not null,
  retirado_del_futuro boolean not null default false,
  registrado_at timestamptz not null default now()
);

comment on table v2.iss214_pick_elegido_por_precio is
'ISS214. Evidencia historica, NO se borra. Cada fila es un pick que badrino_predecir() eligio con WHERE fuente=''mercado'' ORDER BY probabilidad DESC, o sea con el precio. Las filas ya jugadas se conservan tal cual. Solo se retiro el mejor_pick de los eventos AUN NO jugados, porque esos si podian publicarse.';

insert into v2.iss214_pick_elegido_por_precio
  (tabla, espn_event_id, fecha, mejor_pick_historico, mejor_prob_historica, fuente_de_la_eleccion, era_futuro)
select 'public.badrino_predicciones', espn_event_id, fecha, mejor_pick, mejor_prob,
       'WHERE fuente=''mercado'' AND probabilidad<=88 ORDER BY probabilidad DESC LIMIT 1',
       fecha > now()
from public.badrino_predicciones
where mejor_pick is not null;
-- Medido: 373 filas de evidencia, 11 de eventos aun no jugados.

-- Solo el FUTURO se retira. Los 362 picks de eventos ya jugados quedan intactos
-- porque son historia y porque son la prueba del hallazgo.
with retirados as (
  update public.badrino_predicciones
     set mejor_pick = null, mejor_prob = null
   where fecha > now() and mejor_pick is not null
  returning espn_event_id
)
update v2.iss214_pick_elegido_por_precio a
   set retirado_del_futuro = true
 where a.era_futuro and a.espn_event_id in (select espn_event_id from retirados);

-- PRUEBA EN VIVO: correr la funcion y medir que ya no escribe pick.
--   select public.badrino_predecir();            -> 15 eventos procesados
--   ...where generado_at > now() - '3 minutes'   -> con_pick=0,
--                                                   con_mercados_informativos=15,
--                                                   con_lambda_modelo=15

-- ==========================================================================
-- PARTE 2. v_picks_premium se retira. Era precio puro.
-- ==========================================================================
-- Sus lineas marcadas:
--   JOIN combos_aprobados ca ON ca.rango_momio = pc.rango_momio  (el nicho lo
--     definia el MOMIO)
--   END <= (100.0 / pc.momio + 10)                               (exigia
--     ventaja contra el precio)
--   ORDER BY (prob_ai*100*0.40 + ca.wr_pct*0.60) DESC            (mezclaba el
--     modelo con el win-rate del nicho de momio)
-- No se migra porque no hay nada del modelo que rescatar: su criterio entero
-- es el precio. El trigger tg_superficie_solo_sale_con_lapida exige la lapida
-- ANTES del drop.
insert into public.superficie_retirada (vista, motivo, evidencia_cero_consumidores, definicion_historica, fuente_de_la_definicion)
select 'v_picks_premium',
 'ISS214. Maquina de precio puro. Unia picks contra combos_aprobados por ca.rango_momio = pc.rango_momio (el nicho lo definia el MOMIO), filtraba por prob <= 100/momio + 10 (o sea exigia ventaja contra el precio) y ordenaba por la mezcla 0.40*prob_ai + 0.60*wr_pct del nicho de momio. Eso es el precio eligiendo y ordenando picks, prohibido. No se migra porque no tiene ningun consumidor y porque su criterio entero es el precio: no queda nada del modelo que rescatar.',
 'Medido 2026-09-18: vistas dependientes=0; funciones que la nombran=0; consultas de cliente en pg_stat_statements=0; filas que devolvia=0. Estaba en superficie_usuario solo por la clasificacion automatica de ISS096 con la nota "revisar si cambia de pantalla", que nunca se reviso, y no aparecia en la lista de 80 superficies de ISS209.',
 pg_get_viewdef('public.v_picks_premium'::regclass, true),
 'pg_get_viewdef(''public.v_picks_premium''::regclass, true) al momento del retiro';

delete from public.superficie_usuario where vista = 'v_picks_premium';
revoke all privileges on public.v_picks_premium from anon, authenticated, public;
drop view public.v_picks_premium;

-- ==========================================================================
-- PARTE 3. Candado nuevo. Nacio del hallazgo, no al reves.
-- ==========================================================================
create or replace function public.gate_el_precio_no_elige_el_pick()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $function$
  with fuentes as (
    select p.oid::regprocedure::text as obj,
           regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') as src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','v2') and p.prokind = 'f'
    union all
    select c.oid::regclass::text,
           regexp_replace(pg_get_viewdef(c.oid, true), '--[^\n]*', '', 'g')
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public','v2') and c.relkind in ('v','m')
  )
  select 'PICK_ELEGIDO_POR_FUENTE_MERCADO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(obj, ', ' order by obj), 'ninguno')
         || '. Un objeto que elige un pick filtrando por una fuente de PRECIO es el precio creando el pick.'
  from fuentes
  where (src ~* 'fuente''?\s*=\s*''mercado''' or src ~* 'source''?\s*=\s*''market''' or src ~* '''fuente''\s*=\s*''mercado''')
    and src ~* 'mejor_pick|best_pick|pick_elegido|into\s+mejor'
  union all
  select 'ESCRITURA_DE_MODELO_EJECUTABLE_POR_CLIENTE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(obj, ', ' order by obj), 'ninguna')
         || '. Una funcion que escribe predicciones y que anon o authenticated puede EJECUTAR deja al cliente disparar el motor.'
  from (
    select p.oid::regprocedure::text as obj
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','v2') and p.prokind = 'f'
      and regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g')
          ~* '(insert\s+into|update)\s+(public\.|v2\.)?[a-z_]*predicciones'
      and (has_function_privilege('anon', p.oid, 'execute')
        or has_function_privilege('authenticated', p.oid, 'execute'))
  ) w
  union all
  select 'PICK_DE_PRECIO_EN_EVENTO_NO_JUGADO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'filas de badrino_predicciones de eventos AUN NO jugados que todavia cargan un mejor_pick elegido por el precio. '
         || 'La historia ya jugada se conserva a proposito: '
         || (select count(*) from v2.iss214_pick_elegido_por_precio)::text
         || ' filas de evidencia en v2.iss214_pick_elegido_por_precio, '
         || (select count(*) from v2.iss214_pick_elegido_por_precio where retirado_del_futuro)::text
         || ' de ellas retiradas del futuro.'
  from public.badrino_predicciones
  where fecha > now() and mejor_pick is not null;
$function$;

comment on function public.gate_el_precio_no_elige_el_pick() is
'ISS214. Candado contra el precio eligiendo el pick. Nacio del hallazgo vivo en badrino_predecir().';

-- El subgate 2 salio FAIL(3) en su primera corrida y encontro tres escritores
-- de modelo mas que el cliente podia disparar. Verificado antes de revocar:
-- sus llamadas en pg_stat_statements son la forma del cron (select public.X()),
-- sin envoltura pgrst_source, y los crons corren como postgres.
revoke execute on function public.mlb_shadow_generar(integer)   from public, anon, authenticated;
revoke execute on function public.nfl_capturar_prediccion()      from public, anon, authenticated;
revoke execute on function public.nfl_predecir()                 from public, anon, authenticated;
grant  execute on function public.mlb_shadow_generar(integer)   to service_role;
grant  execute on function public.nfl_capturar_prediccion()      to service_role;
grant  execute on function public.nfl_predecir()                 to service_role;

-- ==========================================================================
-- PARTE 4. Los 55 veredictos que faltaban, uno por linea.
-- ==========================================================================
-- No es una etiqueta para apagar el gate: cada linea se leyo y cada razon dice
-- QUE hace la linea. La tabla completa quedo en public.ruta_precio_hallazgo.
-- Reparto medido de las 55:
--   FALSO_POSITIVO_DETECTOR      25  la linea marcada no tiene ningun termino de
--                                    precio; la senal salio de un nombre de
--                                    parametro muerto, de una columna de dato,
--                                    de un literal de texto (incluidas MIS
--                                    propias notas de ISS207/ISS214, que el
--                                    borrado de comentarios no alcanza porque
--                                    viven dentro de una cadena) o de un x*100
--                                    de conversion a porcentaje que el detector
--                                    lee como devig.
--   MEDICION_RETROSPECTIVA        7  solo miran picks YA resueltos.
--   DIMENSIONAMIENTO_ECONOMICO    8  el precio entra DESPUES de P_RETO y solo
--                                    mueve dinero (regla 3). Vigilado en vivo
--                                    por el subgate PRECIO_NO_BORRA_PICKS.
--   DIAGNOSTICO_NO_DECIDE        15  el precio se muestra como dato al lado del
--                                    pick que ya eligio el cerebro.
--
-- Verificaciones que hice para poder firmar estas razones, no deducirlas:
--   favoritos_bien_pagados: p_momio_min y p_momio_max estan en la FIRMA pero no
--     en ningun predicado; ev_pct, ventaja_pp, fraccion y aporte_compuesto_pct
--     salen null::numeric fijos. El nombre miente, el comportamiento no.
--   mejor_pick_hoy: rn viene de order by probabilidad_pct desc. Sus cinco
--     parametros de EV/Kelly/momio tampoco se usan.
--   v_picks_futbol_calc: rastreado hasta su ancestro. picks_premium rankea por
--     score_valor DESC, y score_valor = probabilidad - 33.3 (Moneyline) o
--     - 50.0 (resto): discriminacion contra el prior uniforme, sin precio.
--   v_motor_valor_proximos: el select exterior DEJA FUERA ev_pct, no tiene
--     ORDER BY y no filtra por EV, aunque motor_valor_partido si devuelve ev_pct.
--   evidencia_capturar: rastreados sus tres consumidores (evidencia_liquidar(),
--     v_evidencia_modelo_vs_mercado, v2.refresh_model_learning()); ninguno
--     publica picks ni altera P_RETO.

-- (El INSERT completo de los 55 veredictos, con su razon literal, se ejecuto
--  contra public.ruta_precio_hallazgo; la tabla ES el registro auditable.)

-- ==========================================================================
-- ROLLBACK
-- ==========================================================================
-- Parte 1: el cuerpo anterior de badrino_predecir() se recupera del historial
--   de git de este archivo (el bloque v_o de arriba es su texto exacto). Los
--   11 mejor_pick retirados del futuro estan en
--   v2.iss214_pick_elegido_por_precio con retirado_del_futuro = true y se
--   restauran por espn_event_id. grant execute ... to anon, authenticated.
-- Parte 2: v_picks_premium se recrea con superficie_retirada.definicion_historica,
--   que guarda su pg_get_viewdef completo (4099 caracteres).
-- Parte 3: drop function public.gate_el_precio_no_elige_el_pick(); y
--   grant execute on ... to anon, authenticated para las tres funciones.
-- Parte 4: delete from public.ruta_precio_hallazgo where reverificado_at >= '...'
--   (los veredictos son anotaciones; borrarlos devuelve el gate a FAIL, no
--   cambia ningun comportamiento).
