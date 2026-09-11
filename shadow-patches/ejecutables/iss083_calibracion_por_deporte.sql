-- iss083 — LA CALIBRACIÓN NO SABÍA DE QUÉ DEPORTE HABLABA — SQL EJECUTABLE
-- Recaptura del 11-sep-2026. Reemplaza a prepared/iss083_*.sql (sólo prosa).
--
-- HALLAZGO: zonas_confiables NO TENÍA COLUMNA DEPORTE y zona_realidad(mercado,
-- prob) tampoco recibía deporte. A un "Under 8.5" de los San Diego Padres le
-- contestaba "bien calibrado (1026 partidos), nivel elite". Esos partidos son
-- de FÚTBOL: modelo_backtest, la única fuente de zonas_confiables, contenía
-- exclusivamente Liga Argentina, MLS, Conference, Brasileirão, Ecuador, Perú,
-- Uruguay, Chile, Sudamericana, Bolivia, Libertadores y Champions. Cero béisbol.
-- (Verificado contra apifootball_ligas_catalogo.)

alter table public.zonas_confiables add column if not exists deporte text;
update public.zonas_confiables set deporte = 'soccer' where deporte is null;
alter table public.zonas_confiables alter column deporte set not null;
comment on column public.zonas_confiables.deporte is
  'Deporte de la medicion. 11-sep-2026: antes no existia y zona_realidad aplicaba la calibracion de futbol sudamericano a picks de MLB.';

-- La PK era (mercado, tramo): no cabían dos deportes en el mismo tramo.
alter table public.zonas_confiables drop constraint if exists zonas_confiables_pkey;
alter table public.zonas_confiables add constraint zonas_confiables_pkey
  primary key (deporte, mercado, tramo);

-- Sobrecarga de 3 argumentos. NO se cambió la firma de 2 porque la usan 8
-- objetos del núcleo (v_pick_canonico, kelly_stake__base, decision_economica_v1,
-- revisar_apuesta__base, devils_advocate__base, analisis_completo_core,
-- reto_13m_estado__base, autodiagnostico). Migrarlos queda pendiente.
--
-- OJO: la versión vigente de esta función es la de iss085, que además reporta
-- partidos independientes y retira la palabra "calibrado". Este bloque queda
-- para que el orden histórico sea reconstruible; iss085 lo sobrescribe.
create or replace function public.zona_realidad(p_mercado text, p_prob numeric, p_deporte text)
 returns jsonb language plpgsql stable set search_path to 'public'
as $function$
declare v_m text; v_t int; v_z record; v_txt text; v_dep text;
begin
  if p_prob is null or p_prob <= 0 or p_prob >= 1 then
    return jsonb_build_object('hay_medicion', false, 'nota', 'sin probabilidad utilizable');
  end if;
  v_dep := case
    when p_deporte ilike '%b%isbol%' or p_deporte ilike '%baseball%' or p_deporte ilike '%mlb%' then 'baseball'
    when p_deporte ilike '%football%' or p_deporte ilike '%nfl%' or p_deporte ilike '%americano%' then 'football'
    when p_deporte ilike '%soccer%' or p_deporte ilike '%f%tbol%' or p_deporte ilike '%futbol%' then 'soccer'
    else lower(coalesce(p_deporte,'')) end;
  v_m := case
    when p_mercado ilike '%btts%' or p_mercado ilike '%ambos%anotan%' then 'BTTS'
    when p_mercado ilike '%corner%' or p_mercado ilike '%esquina%'    then 'Corners'
    when p_mercado ilike '%tarjeta%' or p_mercado ilike '%card%'      then 'Tarjetas'
    when p_mercado ilike '%doble%oportunidad%' or p_mercado ilike '%double chance%' then 'Doble Oportunidad'
    when p_mercado ilike '%total%equipo%' or p_mercado ilike '%team total%' then 'Total Equipo'
    when p_mercado ilike '%over%' or p_mercado ilike '%under%'
      or p_mercado ilike '%mas de%' or p_mercado ilike '%menos de%'
      or p_mercado ilike '%o/u%' or p_mercado ilike '%total%'         then 'Over/Under'
    when p_mercado ilike '%moneyline%' or p_mercado ilike '%ml%'
      or p_mercado ilike '%gana%' or p_mercado ilike '%1x2%'          then 'Moneyline'
    else null end;
  if v_m is null then
    return jsonb_build_object('hay_medicion', false, 'deporte', v_dep,
                              'nota', format('mercado "%s" no esta en la medicion', p_mercado));
  end if;
  v_t := width_bucket(p_prob, 0, 1, 10);
  select * into v_z from zonas_confiables z
   where z.mercado = v_m and z.tramo = v_t and z.deporte = v_dep;
  if not found then
    return jsonb_build_object('hay_medicion', false, 'mercado_medido', v_m, 'deporte', v_dep, 'tramo', v_t,
      'nota', format('NO hay calibracion medida de %s en %s. La medicion que existe es de otro deporte y no se presta.', v_m, v_dep));
  end if;
  v_txt := case
    when v_z.error_abs <= 2 then format('bien calibrado en %s (%s partidos, se desvia %s pts)', v_dep, v_z.n, v_z.error_abs)
    when v_z.prob_dicha > v_z.prob_real then
      format('INFLA: en %s este tramo dice %s%% y entrega %s%% (%s partidos)',
             v_dep, round(100*v_z.prob_dicha,1), round(100*v_z.prob_real,1), v_z.n)
    else
      format('SUBESTIMA: en %s este tramo dice %s%% y entrega %s%% (%s partidos)',
             v_dep, round(100*v_z.prob_dicha,1), round(100*v_z.prob_real,1), v_z.n)
  end;
  return jsonb_build_object(
    'hay_medicion', true, 'mercado_medido', v_m, 'deporte', v_dep, 'tramo', v_t,
    'partidos_medidos', v_z.n, 'prob_del_modelo', round(p_prob, 4),
    'prob_real_del_tramo', v_z.prob_real, 'desviacion_pts', v_z.error_abs,
    'brier', v_z.brier, 'nivel', v_z.nivel, 'peor_que_volado', (v_z.brier >= 0.25),
    'momio_minimo_real', round(1/nullif(v_z.prob_real,0), 3), 'veredicto', v_txt);
end $function$;
grant execute on function public.zona_realidad(text, numeric, text) to anon, authenticated, service_role;

-- Candado: no se publica como "lo mejor del dia" un pick cuyo PROPIO deporte
-- y mercado no tengan medicion, ni uno cuya medicion sea PEOR QUE UN VOLADO.
-- (El segundo tapa el hoyo de BTTS tramo 7: dice 63.7% y entrega 50.0% en 204
--  partidos, Brier 0.2654, y pasaba el primer candado sin problema.)
do $$
declare v text;
begin
  v := rtrim(btrim(pg_get_viewdef('public.v_reto13m_lo_mejor'::regclass, true)), ';');
  execute 'create or replace view public.v_reto13m_lo_mejor as select * from (' || v || ') cal'
       || ' where (public.zona_realidad(cal.mercado, cal.probabilidad_pct/100.0, cal.deporte)->>''hay_medicion'')::boolean'
       || '   and not coalesce((public.zona_realidad(cal.mercado, cal.probabilidad_pct/100.0, cal.deporte)->>''peor_que_volado'')::boolean, true)';
end $$;

-- FIN iss083.
