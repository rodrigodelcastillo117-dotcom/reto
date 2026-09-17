-- ISS195 · El historial deja de mentir por omision, y el orden de los picks
--          deja de ponerlo el precio
--
-- ===========================================================================
-- 1. PATAS QUE NUNCA SE PUDIERON CALIFICAR
-- ===========================================================================
-- 23 patas llevaban meses en 'pendiente'. De esas, 22 no se podian calificar:
--   19 porque su evento NO EXISTE en ninguna fuente (ni live_scores ni
--      agenda_espn): 9 de tenis, 8 de beisbol, 2 de futbol
--    3 porque son de tenis, y RETO cubre MLB, NFL y futbol. No hay autoridad de
--      resultado declarada para tenis, asi que no se califica tenis.
-- La 23a es de futbol, su evento SI existe y se califica por su via normal:
-- esa no se toco.
--
-- Dejarlas en 'pendiente' para siempre es mentir por omision: el historial del
-- dueno queda con huecos que parecen apuestas vivas.
--
-- ESTO NO ES UN ARREGLO MANUAL DE CALIFICACION. No se puso ganada ni perdida a
-- ninguna. Se declara que NO HAY FORMA de calificarla y se escribe el motivo en
-- la propia pata, con marca de quien lo hizo y cuando. Y no es un parche de una
-- vez: es una regla que corre sola todos los dias.

create or replace function public.marcar_patas_no_calificables(p_dias_minimos int default 7, p_aplicar boolean default false)
returns table(parlay_id uuid, pick text, dep text, motivo text, aplicado boolean)
language plpgsql security definer set search_path to 'public','v2','pg_catalog'
as $function$
begin
  return query
  with cand as (
    select p.id pid, e.ord, e.value v,
      case
        when not exists (select 1 from public.live_scores ls where ls.espn_event_id = e.value->>'espn_event_id')
         and not exists (select 1 from public.agenda_espn ae where ae.espn_event_id = e.value->>'espn_event_id')
          then 'EVENTO_INEXISTENTE_EN_TODA_LA_BASE: el evento de esta pata no aparece ni en resultados en vivo ni en la agenda. Nunca se pudo calificar y no se va a poder.'
        when coalesce(e.value->>'deporte','') !~ 'Fútbol|Futbol|Baseball|NFL|Americano'
          then 'DEPORTE_FUERA_DEL_PRODUCTO: RETO cubre MLB, NFL y futbol. No declara autoridad de resultado para este deporte, asi que no lo califica.'
      end razon
    from public.parlays p
    cross join lateral jsonb_array_elements(p.picks_data) with ordinality e(value,ord)
    where jsonb_typeof(p.picks_data)='array'
      and lower(coalesce(e.value->>'resultado','pendiente'))='pendiente'
      and p.created_at < now() - make_interval(days => p_dias_minimos)
  ), marcables as (
    select * from cand c where c.razon is not null
  ), tocados as (
    update public.parlays p set picks_data = (
      select jsonb_agg(
        case when exists (select 1 from marcables m where m.pid=p.id and m.ord=e.ord)
             then e.value || jsonb_build_object(
                    'resultado','no_calificable',
                    'no_calificable_motivo',(select m.razon from marcables m where m.pid=p.id and m.ord=e.ord),
                    'no_calificable_at', now(),
                    'resuelto_por','marcar_patas_no_calificables (ISS195)')
             else e.value end order by e.ord)
      from jsonb_array_elements(p.picks_data) with ordinality e(value,ord))
    where p_aplicar and exists (select 1 from marcables m where m.pid=p.id)
    returning p.id tid
  )
  select m.pid, m.v->>'pick_desc', m.v->>'deporte', m.razon,
         p_aplicar and exists(select 1 from tocados t where t.tid=m.pid)
  from marcables m order by m.pid, m.ord;
end $function$;

-- Se corre en seco primero (p_aplicar=false) y solo despues se aplica.
-- Ejecutado: 22 marcadas, 22 aplicadas.
-- Cron diario para que no se vuelva a acumular:
--   select cron.schedule('patas-no-calificables','23 6 * * *',
--     $$select public.marcar_patas_no_calificables(7, true)$$);  -- jobid 542


-- ===========================================================================
-- 2. EL ORDEN DE LOS PICKS LO PONIA EL PRECIO
-- ===========================================================================
-- public.reto_picks_hoy__base ordenaba los picks publicados por monto_cand, que
-- sale de kelly_stake, que recibe momio_mercado. O sea: el precio decidia en que
-- orden veias los picks, y en que orden se les asignaba dinero bajo el limite de
-- exposicion. La regla de la casa es argmax P_RETO.
--
-- El conjunto de picks NUNCA salio del precio: eso ya lo decide es_pick, arriba,
-- con la probabilidad del cerebro. Lo que salia del precio era el ORDEN.
--
-- Cambio: las dos ordenaciones (el row_number congelado que usa el recorrido de
-- banca, y el ORDER BY final que pinta las tarjetas) pasan a
--   probabilidad_pct desc nulls last, arranca_en, espn_event_id, pick_desc
-- El monto sigue calculandose y sigue mostrandose. Como dato, no como juez.
--
-- CONSECUENCIA QUE EL DUENO DEBE SABER: bajo el limite de exposicion, la banca
-- ahora se llena empezando por los picks de mayor probabilidad, no por los de
-- mayor stake. Es un cambio de comportamiento de dinero, derivado de la regla,
-- no un ajuste manual.
--
-- RESULTADO: el subgate ORDEN_CANONICO_SALE_DE_KELLY paso de FAIL a PASS.
-- Lo que sigue en FAIL de esa familia es el FILTRO y la RAMA_SUPRESION por
-- monto_cand, que son la capa de ASIGNACION DE DINERO (quien cabe en el limite),
-- no la de seleccion de pick. Eso se deja como esta y se declara: cambiarlo es
-- una decision de banca del dueno, no mia.

-- ===========================================================================
-- VERIFICACION EJECUTADA (2026-09-17)
--
-- gate_pata_calificable:  PATA_CALIFICABLE_SIN_CALIFICAR       FAIL -> PASS
--                         PATA_PENDIENTE_CON_EVENTO_INEXISTENTE FAIL -> PASS
--                         PICK_DE_DEPORTE_NO_DECLARADO          FAIL -> PASS
-- gate_parlay_coherente:  PARLAY_CERRADO_CON_LEGS_PENDIENTES    FAIL -> PASS
-- gate_precio_por_alias:  ORDEN_CANONICO_SALE_DE_KELLY          FAIL -> PASS
--
-- Sistema completo: 25 FAIL al empezar la sesion -> 17 FAIL.
--   118 PASS · 31 INFO · 17 FAIL
-- ===========================================================================
