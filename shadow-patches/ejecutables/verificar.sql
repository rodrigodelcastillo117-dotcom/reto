-- verificar.sql — ¿la base viva coincide con el MANIFIESTO?
--
-- Devuelve una fila por objeto con su md5 actual. Compara contra
-- MANIFIESTO.txt. Cualquier diferencia = la reconstruccion NO es identica a
-- produccion.
--
-- Uso:  psql -f verificar.sql  (o execute_sql) y diff contra MANIFIESTO.txt
with objs as (
  select c.relname::text nm, 'vista' tipo, pg_get_viewdef(c.oid,true) t
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')
  union all
  select p.oid::regprocedure::text, 'funcion', pg_get_functiondef(p.oid)
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f'
)
select tipo || '  ' || md5(t) || '  ' || nm as linea
from objs
where split_part(nm,'(',1) in (
 'v_pick_canonico','v_mejor_pick_por_partido','picks_premium','v_picks_con_valor',
 'v_mejores_picks_mlb','v_picks_para_parlay','v_picks_premium','v_oraculo_picks_activos',
 'v_super_pick','v_picks_futbol_calc','v_reto13m_mejores','v_reto13m_lo_mejor',
 'parlay_del_dia_v3','destacados_del_dia','refrescar_destacados','mejor_oportunidad_hoy',
 'mejor_oportunidad_hoy_v2__base','mejor_pick_hoy','veredicto_lote__base','rongol_seleccionar_dia',
 'tg_filtrar_pick_del_dia','seleccionar_picks_seguro_valor','generar_parlay_seguro',
 'enrich_oraculo_prob_with_momio','favoritos_bien_pagados','reto_13m_estado__base',
 'zona_realidad','recalcular_zonas_confiables','prob_total_sobre','normal_cdf','motor_mlb')
order by tipo, nm;
