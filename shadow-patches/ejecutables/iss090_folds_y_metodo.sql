-- iss090 — SELECCIÓN DE MÉTODO EN FOLDS INTERNOS + HOLDOUT INTOCADO
--
-- Regla del dueño: «no podemos probar isotónico contra Platt sobre el mismo
-- holdout» y «no necesito isotónico sólo porque exista». Entonces:
--   * identidad, Platt e isotónica compiten SÓLO en los folds internos.
--   * el holdout final se mide UNA vez, con el método ya elegido.
--
-- PARTICIÓN (MLB, temporadas naturales):
--   fold 1: entrena < 2024-01-01   evalúa 2024
--   fold 2: entrena < 2025-01-01   evalúa 2025
--   HOLDOUT: entrena < 2026-01-01  evalúa 2026  (jamás usado para elegir)
-- PARTICIÓN (NFL, temporadas julio-a-julio):
--   fold 1: entrena < 2023-07-01   evalúa temporada 2023
--   fold 2: entrena < 2024-07-01   evalúa temporada 2024
--   HOLDOUT: entrena < 2025-07-01  evalúa temporada 2025
--
-- La isotónica es BINADA (cuantiles de p_raw) a propósito: una isotónica sobre
-- puntos individuales produce un escalón por observación y memoriza el
-- entrenamiento. 50 bins de conteo igual es el compromiso estándar.

-- ===========================================================================
-- 1) Isotónica: ajuste por PAVA (pool adjacent violators) sobre bins
-- ===========================================================================
create or replace function public.fit_isotonica_binned(
  p_model text, p_desde timestamptz, p_hasta timestamptz, p_bins int default 50)
returns jsonb language plpgsql stable set search_path to 'public' as $function$
declare
  xs double precision[]; ys double precision[]; ws double precision[];
  lo double precision[]; hi double precision[];
  sy double precision[] := '{}'; sw double precision[] := '{}';
  slo double precision[] := '{}'; shi double precision[] := '{}';
  k int := 0; i int; n int; prev double precision := 0.0;
  vy double precision; vw double precision; vlo double precision; vhi double precision;
  bloques jsonb := '[]'::jsonb;
begin
  with y as (
    select p_raw::double precision pr, (resultado='WIN')::int yv
    from calib_eventos
    where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
      and resultado in ('WIN','LOSS') and p_raw is not null
  ),
  b as (select ntile(p_bins) over (order by pr) nb, pr, yv from y),
  agg as (select nb, count(*)::double precision w, avg(pr) x,
                 avg(yv::double precision) ybar, min(pr) blo, max(pr) bhi
          from b group by nb)
  select array_agg(x order by nb), array_agg(ybar order by nb), array_agg(w order by nb),
         array_agg(blo order by nb), array_agg(bhi order by nb)
    into xs, ys, ws, lo, hi from agg;

  if xs is null then return null; end if;
  n := array_length(xs,1);

  -- PAVA: recorre en orden creciente de p_raw y agrupa violaciones de monotonía
  for i in 1..n loop
    vy := ys[i]; vw := ws[i]; vlo := lo[i]; vhi := hi[i];
    while k > 0 and sy[k] > vy loop
      vy  := (sy[k]*sw[k] + vy*vw) / (sw[k]+vw);
      vw  := sw[k] + vw;
      vlo := least(slo[k], vlo);
      vhi := greatest(shi[k], vhi);
      k := k - 1;
    end loop;
    k := k + 1;
    sy[k] := vy; sw[k] := vw; slo[k] := vlo; shi[k] := vhi;
  end loop;

  -- fronteras contiguas: sin huecos, cubren [0, 1]
  for i in 1..k loop
    bloques := bloques || jsonb_build_object(
      'x_lo', prev,
      'x_hi', case when i = k then 1.0000001 else shi[i] end,
      'y',    round(sy[i]::numeric, 6),
      'n',    sw[i]::int);
    prev := case when i = k then 1.0000001 else shi[i] end;
  end loop;

  return jsonb_build_object('metodo','isotonic','bins',p_bins,'n_bloques',k,
    'bloques', bloques, 'train_desde', p_desde, 'train_hasta', p_hasta);
end $function$;

create or replace function public.aplicar_isotonica(p_params jsonb, p double precision)
returns double precision language sql immutable set search_path to 'public' as $function$
  select coalesce(
    (select (b->>'y')::double precision
       from jsonb_array_elements(p_params->'bloques') b
      where p >= (b->>'x_lo')::double precision
        and p <  (b->>'x_hi')::double precision
      limit 1),
    (p_params->'bloques'->-1->>'y')::double precision)
$function$;

-- ===========================================================================
-- 2) evaluar_calibrador: ahora soporta isotónica
-- ===========================================================================
create or replace function public.evaluar_calibrador(
  p_model text, p_metodo text, p_params jsonb, p_desde timestamptz, p_hasta timestamptz)
returns jsonb language sql stable set search_path to 'public' as $function$
with ev as (
  select espn_event_id, resultado, p_raw::double precision pr,
         case p_metodo
           when 'identity' then p_raw::double precision
           when 'platt' then 1.0/(1.0+exp(-(
                  (p_params->>'a')::double precision
                + (p_params->>'b')::double precision * ln(p_raw/(1-p_raw))::double precision)))
           when 'isotonic' then public.aplicar_isotonica(p_params, p_raw::double precision)
           else p_raw::double precision
         end pc
  from calib_eventos
  where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
    and p_raw is not null
),
lim as (select espn_event_id, resultado, pr, greatest(1e-6, least(1-1e-6, pc)) pc from ev),
usable as (select * from lim where resultado in ('WIN','LOSS')),
y as (select espn_event_id, pr, pc, (resultado='WIN')::int yv from usable),
bins  as (select width_bucket(pr,0,1,10) b, count(*) n, avg(pr) conf, avg(yv::double precision) acc from y group by 1),
binsc as (select width_bucket(pc,0,1,10) b, count(*) n, avg(pc) conf, avg(yv::double precision) acc from y group by 1)
select jsonb_build_object(
  'metodo', p_metodo, 'test_desde', p_desde, 'test_hasta', p_hasta,
  'n_eventos',  (select count(*) from usable),
  'n_partidos', (select count(distinct espn_event_id) from usable),
  'n_push',     (select count(*) from lim where resultado='PUSH'),
  'brier_raw',   (select round(avg(power(pr-yv,2))::numeric,6) from y),
  'brier_cal',   (select round(avg(power(pc-yv,2))::numeric,6) from y),
  'logloss_raw', (select round(avg(-(yv*ln(pr) + (1-yv)*ln(1-pr)))::numeric,6) from y),
  'logloss_cal', (select round(avg(-(yv*ln(pc) + (1-yv)*ln(1-pc)))::numeric,6) from y),
  'ece_raw', (select round((sum(n*abs(acc-conf))/nullif(sum(n),0))::numeric,6) from bins),
  'ece_cal', (select round((sum(n*abs(acc-conf))/nullif(sum(n),0))::numeric,6) from binsc),
  'brier_volado', (select round(avg(power(0.5-yv,2))::numeric,6) from y))
$function$;

-- ===========================================================================
-- 3) Bootstrap por PARTIDO, ahora para cualquier método
--    Cluster = partido: primero se promedia DENTRO del partido y luego se
--    remuestrean esos promedios. Dos eventos del mismo juego no son
--    observaciones independientes.
-- ===========================================================================
create or replace function public.bootstrap_mejora_metodo(
  p_model text, p_metodo text, p_params jsonb,
  p_desde timestamptz, p_hasta timestamptz, p_reps int default 1000)
returns jsonb language sql stable set search_path to 'public' as $function$
with ev as (
  select espn_event_id, (resultado='WIN')::int yv, p_raw::double precision pr,
    greatest(1e-6, least(1-1e-6, case p_metodo
      when 'platt' then 1.0/(1.0+exp(-((p_params->>'a')::double precision
            + (p_params->>'b')::double precision * ln(p_raw/(1-p_raw))::double precision)))
      when 'isotonic' then public.aplicar_isotonica(p_params, p_raw::double precision)
      else p_raw::double precision end)) pc
  from calib_eventos
  where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
    and resultado in ('WIN','LOSS') and p_raw is not null
),
por_partido as (
  select espn_event_id,
         avg(power(pr-yv,2)) - avg(power(pc-yv,2)) as mejora
  from ev group by 1
),
idx as (select row_number() over (order by espn_event_id) i, mejora from por_partido),
n as (select count(*)::int c from idx),
draws as (select b.b, 1 + floor(random()*(select c from n))::int i
          from generate_series(1,p_reps) b(b), generate_series(1,(select c from n)) g(g)),
boot as (select d.b, avg(x.mejora) prom from draws d join idx x on x.i=d.i group by d.b)
select jsonb_build_object(
  'metodo', p_metodo,
  'n_partidos', (select c from n),
  'mejora_media_brier', round(avg(prom)::numeric,6),
  'ic95_inf', round(percentile_cont(0.025) within group (order by prom)::numeric,6),
  'ic95_sup', round(percentile_cont(0.975) within group (order by prom)::numeric,6),
  'pct_remuestreos_a_favor', round((100.0*count(*) filter (where prom>0)/count(*))::numeric,1),
  'significativa', (percentile_cont(0.025) within group (order by prom)) > 0,
  'reps', p_reps)
from boot;
$function$;

grant execute on function public.fit_isotonica_binned(text,timestamptz,timestamptz,int) to anon, authenticated, service_role;
grant execute on function public.aplicar_isotonica(jsonb,double precision) to anon, authenticated, service_role;
grant execute on function public.bootstrap_mejora_metodo(text,text,jsonb,timestamptz,timestamptz,int) to anon, authenticated, service_role;

-- FIN iss090 parte 1 (herramientas). Los folds se corren y registran en iss091.
