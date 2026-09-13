-- ISS134 — CROSS-SPORT PUBLICATION AUTHORITY FAIL-CLOSE
-- MLB + SOCCER + legacy recommendation RPCs.
-- Diagnostics remain visible; ONLY public.v_pick_canonico.es_pick may authorize a recommendation.

create or replace function public.pick_publicacion_autorizada(
  p_event text,p_deporte text,p_mercado text,p_pick text
)
returns boolean language sql stable set search_path='public' as $$
 select exists(
   select 1 from public.v_pick_canonico c
   where c.es_pick
     and c.espn_event_id=p_event
     and public.deporte_registry(c.deporte)=public.deporte_registry(p_deporte)
     and coalesce(c.mercado,'')=coalesce(p_mercado,'')
     and public.sin_acentos(coalesce(c.pick_desc,c.pick_nombre,''))=public.sin_acentos(coalesce(p_pick,''))
 );
$$;

-- MLB UI contract: preserve the game rows, but publish favorite/P_RETO only from
-- an actually authorized canonical Moneyline pick. motor_cache is diagnostic only.
create or replace view public.v_favorito_mlb as
with auth as (
 select distinct on (c.espn_event_id)
   c.espn_event_id,c.pick_desc,c.pick_nombre,c.probabilidad_pct,c.momio_capturado_at
 from public.v_pick_canonico c
 where c.es_pick
   and public.deporte_registry(c.deporte)='baseball'
   and c.mercado='Moneyline'
 order by c.espn_event_id,c.probabilidad_pct desc nulls last,c.pick_desc
)
select a.espn_event_id,a.fecha as arranca_en,a.home_nombre,a.away_nombre,
       public.equipo_corto(a.home_nombre,'baseball') as home_corto,
       public.equipo_corto(a.away_nombre,'baseball') as away_corto,
       case
         when x.espn_event_id is null then null::text
         when public.sin_acentos(coalesce(x.pick_desc,x.pick_nombre,'')) like '%'||public.sin_acentos(a.home_nombre)||'%' then public.equipo_corto(a.home_nombre,'baseball')
         when public.sin_acentos(coalesce(x.pick_desc,x.pick_nombre,'')) like '%'||public.sin_acentos(a.away_nombre)||'%' then public.equipo_corto(a.away_nombre,'baseball')
         else null::text
       end as favorito_corto,
       case when x.espn_event_id is not null then x.probabilidad_pct end as favorito_pct,
       x.momio_capturado_at as calculado_at
from public.agenda_espn a
left join auth x on x.espn_event_id=a.espn_event_id
where a.deporte='baseball';

-- Soccer discovery keeps diagnostics, score, market and model context. `apostable`
-- is no longer inferred from a raw probability threshold; it requires the exact
-- canonical event/market/pick to have passed es_pick=true.
create or replace view public.v_picks_futbol_calc as
select p.espn_event_id,p.liga,p.partido,p.fecha,p.hora_cdmx,p.mercado,p.pick,p.probabilidad,p.momio_justo,
       p.momio_mercado,p.bookmaker,null::numeric as ev,p.precio_verificado,p.score_valor,
       p.nivel,p.muestra_historica,p.acierto_historico,p.error_historico,p.marcador_probable,p.fundamento,
       case when p.lam_h is null or p.lam_a is null then 'SIN_MODELO'
            when round(p.lam_h,2)=1.35 and round(p.lam_a,2)=1.35 then 'FALLBACK'
            when p.muestra_modelo is null then 'SIN_MODELO'
            when p.muestra_modelo>=12 then 'ALTA'
            when p.muestra_modelo>=6 then 'MEDIA'
            else 'BAJA' end as respaldo_modelo,
       round(p.momio_justo*1.06,2) as momio_minimo_aceptable,
       public.pick_publicacion_autorizada(p.espn_event_id,'soccer',p.mercado,p.pick) as apostable,
       round(p.probabilidad - 100.0/nullif(p.momio_mercado,0),2) as desacuerdo_vs_precio_pp
from public.picks_premium p
where p.fecha>=now() and p.fecha<=now()+interval '48 hours'
  and p.probabilidad between 52 and 80
  and not (round(coalesce(p.lam_h,0),2)=1.35 and round(coalesce(p.lam_a,0),2)=1.35)
  and p.liga not ilike '%amistoso%'
  and p.liga not ilike '%friendly%'
  and p.liga not ilike '%pretemporada%'
  and not public.pick_en_cuarentena('soccer','Over/Under',p.pick);

-- Legacy top-pick RPC now ranks only canonical authorized picks. No direct read of
-- picks_recomendados_hoy is allowed on a recommendation surface.
create or replace function public.mejor_pick_hoy(
  p_ev_min numeric default 4.0,p_ev_segundo numeric default 8.0,
  p_momio_min numeric default 1.40,p_momio_max numeric default 4.00,
  p_prob_min numeric default 0.35,p_horas integer default 30
)
returns table(
  deporte text,rank_deporte integer,liga text,partido text,mercado text,pick text,
  momio numeric,probabilidad numeric,ev_pct numeric,kelly_pct numeric,confianza numeric,
  momio_verificado boolean,momios_frescos boolean,razon text,resumen text,espn_event_id text
)
language sql stable set search_path='public' as $$
with fresco as (
  select coalesce(max(snapshot_at)>now()-interval '12 hours',false) ok
  from radar_odds_snapshots
), base as (
 select public.deporte_registry(c.deporte) dep,c.liga,
        coalesce(c.home,'?')||' vs '||coalesce(c.away,'?') partido,
        c.mercado,coalesce(nullif(c.pick_desc,''),c.pick_nombre) pick,
        c.momio_mercado momio,c.probabilidad_pct/100.0 prob,c.confianza,
        c.odds_source is not null momio_verificado,c.razon,c.resumen,
        c.espn_event_id,c.arranca_en,
        c.probabilidad_pct-(case
          when public.deporte_registry(c.deporte) in ('baseball','football') then 50.0
          when c.mercado='Moneyline' then 33.3 else 50.0 end) ventaja_pp
 from public.v_pick_canonico c
 where c.es_pick
   and c.probabilidad_pct is not null
   and c.arranca_en>now()-make_interval(hours=>p_horas)
   and c.probabilidad_pct/100.0>=p_prob_min
), r as (
 select b.*,row_number() over(
   partition by dep order by prob desc,arranca_en,espn_event_id,pick
 ) rn
 from base b where ventaja_pp>0
)
select r.dep,r.rn::int,r.liga,r.partido,r.mercado,r.pick,r.momio,
       round(r.prob,4),null::numeric,null::numeric,r.confianza,
       r.momio_verificado,f.ok,r.razon,r.resumen,r.espn_event_id
from r cross join fresco f
where (r.rn=1 and r.ventaja_pp>=coalesce(p_ev_min,4.0))
   or (r.rn=2 and r.ventaja_pp>=coalesce(p_ev_segundo,8.0))
order by r.dep,r.rn;
$$;

-- This old generic JSON selector had no event-level authority check. Frontend is
-- already fail-closed; backend is now fail-closed too so no caller can resurrect it.
create or replace function public.seleccionar_picks_seguro_valor(analisis jsonb)
returns jsonb language sql stable set search_path='public' as $$
 select jsonb_build_object(
   'pick_seguro',null,'pick_valor',null,'contradiccion_detectada',false,
   'picks_descartados','[]'::jsonb,'score_probable',analisis->>'score_probable',
   'total_goles_probable',null,
   'total_picks_evaluados',coalesce(jsonb_array_length(coalesce(analisis->'picks_recomendados','[]'::jsonb)),0),
   'mensaje','RPC legacy desautorizado: solo v_pick_canonico.es_pick puede publicar recomendaciones',
   'metadata',jsonb_build_object('v_engine','FAIL_CLOSED_CANONICAL_ONLY')
 );
$$;