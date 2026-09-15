-- iss085 — LA MUESTRA ESTABA INFLADA POR FILAS DUPLICADAS
-- 11-sep-2026. SQL EJECUTABLE (no prosa). Ejecutado con execute_sql desde
-- este archivo; la base viva se reconstruye corriendo este archivo.
--
-- BLOCKER del auditor (comentario 5639091011), y tiene razon:
--   "No son 8,441 partidos independientes. Produccion tiene 6,022 juegos MLB,
--    pero genero 48,176 filas porque cada partido se prueba en multiples
--    lineas y lados."
--
-- Al medirlo resulto PEOR: la inflacion tambien estaba en los datos de futbol
-- que ya existian antes de esta sesion.
--   soccer Over/Under   9,010 filas ->  1,802 partidos  (5x)
--   soccer Corners      3,272 filas ->    409 partidos  (8x)
--   soccer Tarjetas     2,376 filas ->    396 partidos  (6x)
--   soccer Moneyline    5,406 filas ->  1,802 partidos  (3x)
--   baseball O/U       48,176 filas ->  6,022 partidos  (8x)
--   football O/U       14,430 filas ->  1,443 partidos (10x)
--
-- Un "Over 8.5" y un "Under 8.5" del MISMO juego no son dos observaciones:
-- son la misma observacion y su complemento exacto. El nivel 'elite' exigia
-- n >= 400 y se estaba contando sobre filas duplicadas.
--
-- Esto NO resuelve el NO-PASS. Resuelve solo el conteo, que es lo que estaba
-- mintiendo en pantalla. La calibracion sigue siendo IN-SAMPLE y por eso aqui
-- tambien se retira la palabra "calibrado" de los veredictos que ve el usuario.

-- 1) La tabla guarda las dos cosas: filas y partidos independientes.
alter table public.zonas_confiables add column if not exists n_partidos int;

-- 2) El recalculador cuenta partidos independientes y decide el nivel con esos.
create or replace function public.recalcular_zonas_confiables()
 returns table(zonas integer, elite integer, alta integer, media integer)
 language plpgsql
 set search_path to 'public'
as $function$
begin
  delete from zonas_confiables;
  insert into zonas_confiables (deporte, mercado, tramo, n, n_partidos, prob_dicha, prob_real, error_abs, brier, nivel)
  select deporte, mercado, width_bucket(prob_modelo,0,1,10),
         count(*)::int,
         count(distinct fixture_id)::int,
         round(avg(prob_modelo),4),
         round(avg(case when acerto then 1 else 0 end),4),
         round(100*abs(avg(case when acerto then 1 else 0 end)-avg(prob_modelo)),2),
         round(avg(power(prob_modelo-case when acerto then 1 else 0 end,2)),4),
         -- Los umbrales miran PARTIDOS INDEPENDIENTES, no filas.
         case
           when count(distinct fixture_id) >= 400
            and abs(avg(case when acerto then 1 else 0 end)-avg(prob_modelo)) <= 0.015 then 'elite'
           when count(distinct fixture_id) >= 200
            and abs(avg(case when acerto then 1 else 0 end)-avg(prob_modelo)) <= 0.030 then 'alta'
           else 'media' end
  from modelo_backtest
  where muestra_min >= 8
  group by deporte, mercado, width_bucket(prob_modelo,0,1,10)
  having count(distinct fixture_id) >= 100;   -- antes: count(*) >= 100 sobre filas

  select count(*)::int,
         count(*) filter (where nivel='elite')::int,
         count(*) filter (where nivel='alta')::int,
         count(*) filter (where nivel='media')::int
    into zonas, elite, alta, media from zonas_confiables;
  return next;
end $function$;

select * from public.recalcular_zonas_confiables();

-- 3) zona_realidad reporta PARTIDOS INDEPENDIENTES y deja de decir "calibrado".
--    El auditor: "prob_real del tramo se calcula usando los mismos datos sobre
--    los que despues se presume que esta calibrado. Eso es calibracion
--    in-sample." Cierto. Hasta que exista la validacion temporal independiente
--    (train historico -> fit -> periodo futuro nunca visto), el veredicto dice
--    MEDIDO EN MUESTRA y nunca CALIBRADO.
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
    return jsonb_build_object('hay_medicion', false, 'mercado_medido', v_m, 'deporte', v_dep,
      'tramo', v_t,
      'nota', format('NO hay medicion de %s en %s. La que existe es de otro deporte y no se presta.', v_m, v_dep));
  end if;

  -- Nunca decimos "bien calibrado": la curva se ajusto con estos mismos datos.
  v_txt := case
    when v_z.prob_dicha > v_z.prob_real then
      format('MEDIDO EN MUESTRA (sin validacion fuera de muestra): en %s este tramo dice %s%% y entrega %s%% sobre %s partidos',
             v_dep, round(100*v_z.prob_dicha,1), round(100*v_z.prob_real,1), coalesce(v_z.n_partidos, v_z.n))
    when v_z.error_abs <= 2 then
      format('MEDIDO EN MUESTRA (sin validacion fuera de muestra): en %s se desvia %s pts sobre %s partidos',
             v_dep, v_z.error_abs, coalesce(v_z.n_partidos, v_z.n))
    else
      format('MEDIDO EN MUESTRA (sin validacion fuera de muestra): en %s este tramo dice %s%% y entrega %s%% sobre %s partidos',
             v_dep, round(100*v_z.prob_dicha,1), round(100*v_z.prob_real,1), coalesce(v_z.n_partidos, v_z.n))
  end;

  return jsonb_build_object(
    'hay_medicion', true, 'mercado_medido', v_m, 'deporte', v_dep, 'tramo', v_t,
    'partidos_medidos', coalesce(v_z.n_partidos, v_z.n),   -- INDEPENDIENTES
    'filas_medidas', v_z.n,                                -- con lineas/lados duplicados
    'validado_fuera_de_muestra', false,
    'prob_del_modelo', round(p_prob, 4),
    'prob_real_del_tramo', v_z.prob_real, 'desviacion_pts', v_z.error_abs,
    'brier', v_z.brier, 'nivel', v_z.nivel, 'peor_que_volado', (v_z.brier >= 0.25),
    'momio_minimo_real', round(1/nullif(v_z.prob_real,0), 3), 'veredicto', v_txt);
end $function$;

grant execute on function public.zona_realidad(text, numeric, text) to anon, authenticated, service_role;

-- 4) Fuera EV del camino de seleccion (regla permanente del dueno:
--    "NO QUIERO NADAA DE EV, DE VERDAD NADA DE NADA").
--    v_reto13m_mejores heredaba ev_pct, edge_pct y prob_que_implica_el_precio_pct
--    via "v.*". Ya no ordenaban nada, pero seguian dentro de la vista que decide.
--    El precio queda solo en momio_mercado/casa, como contexto declarado.
drop view if exists public.v_reto13m_mejores;
create view public.v_reto13m_mejores as
with cal as (
  select v.espn_event_id, v.deporte, v.liga, v.home, v.away, v.arranca_en,
         v.mercado, v.pick_nombre, v.pick_desc, v.probabilidad_pct,
         v.muestra_calibracion, v.calibracion_confiable,
         v.momio_mercado, v.casa, v.etiqueta_cuando,
         public.zona_realidad(v.mercado, v.probabilidad_pct/100.0, v.deporte) as z
  from public.v_mejor_pick_por_partido v
  where v.probabilidad_pct >= 55::numeric
    and public.sin_modelo_independiente(v.deporte, v.mercado) is null
    and public.sin_modelo_independiente(v.deporte, v.pick_desc) is null
),
f as (
  select c.*,
    round(100*((c.z->>'prob_real_del_tramo')::numeric), 1) as probabilidad_ajustada_pct,
    c.z->>'veredicto'                            as medicion_veredicto,
    (c.z->>'partidos_medidos')::int              as medicion_partidos,
    (c.z->>'nivel')                              as medicion_nivel,
    (c.z->>'validado_fuera_de_muestra')::boolean as validado_fuera_de_muestra,
    round(100*(c.probabilidad_pct/100.0 - ((c.z->>'prob_real_del_tramo')::numeric)), 1) as inflacion_pp
  from cal c
  where (c.z->>'hay_medicion')::boolean
    and not coalesce((c.z->>'peor_que_volado')::boolean, true)
),
r as (
  select f.*,
    -- Nada es LOCK mientras la medicion no pase validacion temporal independiente.
    false as es_lock,
    row_number() over (partition by f.deporte
      order by f.probabilidad_ajustada_pct desc, f.medicion_partidos desc, f.probabilidad_pct desc) as rn_deporte
  from f
)
select r.espn_event_id, r.deporte, r.liga, r.home, r.away, r.arranca_en, r.etiqueta_cuando,
       r.mercado, r.pick_nombre, r.pick_desc,
       r.probabilidad_pct as probabilidad_cruda_pct,
       r.probabilidad_ajustada_pct,
       r.inflacion_pp,
       r.medicion_veredicto, r.medicion_partidos, r.medicion_nivel,
       r.validado_fuera_de_muestra,
       r.muestra_calibracion, r.calibracion_confiable,
       r.momio_mercado, r.casa,   -- contexto declarado; no selecciona ni ordena
       r.es_lock, r.rn_deporte
from r where r.rn_deporte <= 1;

grant select on public.v_reto13m_mejores to anon, authenticated, service_role;
