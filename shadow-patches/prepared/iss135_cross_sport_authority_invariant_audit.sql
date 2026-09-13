-- ISS135 — FINAL CROSS-SPORT PUBLICATION AUTHORITY INVARIANT
-- Close the last direct NFL recommendation RPC and expose one zero-row audit
-- surface for NFL + MLB + SOCCER publication bypasses.

create or replace function public.nfl_mejor_pick(p_event text)
returns table(pick text, mercado text, confianza text, "señal" text, detalle text, magnitud numeric)
language sql stable set search_path='public' as $$
  select null::text,null::text,null::text,null::text,null::text,null::numeric
  where false;
$$;

create or replace view public.v_publication_authority_leaks as
-- NFL legacy table must never publish a best pick.
select 'NFL'::text deporte,'nfl_predicciones.mejor_pick'::text superficie,
       p.espn_event_id,
       coalesce(p.mejor_pick,'')::text detalle
from public.nfl_predicciones p
where p.mejor_pick is not null or p.mejor_prob is not null

union all
-- NFL canonical public probabilities/picks must be absent unless exact release gate allows.
select 'NFL','nfl_tablero',t.espn_event_id,
       coalesce(t.reto_pick,'')||'|'||coalesce(t.reto_pick_prob::text,'')
from public.nfl_tablero t
where t.reto_modelo is not null
  and not v2.fn_nfl_release_allowed(t.reto_modelo)
  and (t.reto_pick is not null or t.reto_pick_prob is not null
       or t.p_reto_local is not null or t.p_reto_visitante is not null
       or t.reto_spread_pick is not null or t.reto_total_pick is not null)

union all
-- MLB UI favorite may exist only if the same event has an authorized canonical ML pick.
select 'MLB','v_favorito_mlb',m.espn_event_id,
       coalesce(m.favorito_corto,'')||'|'||coalesce(m.favorito_pct::text,'')
from public.v_favorito_mlb m
where m.favorito_pct is not null
  and not exists (
    select 1 from public.v_pick_canonico c
    where c.es_pick and c.espn_event_id=m.espn_event_id
      and public.deporte_registry(c.deporte)='baseball' and c.mercado='Moneyline'
  )

union all
-- Soccer discovery cannot call a row apostable unless the exact row is canonical-authorized.
select 'SOCCER','v_picks_futbol_calc',s.espn_event_id,
       coalesce(s.mercado,'')||'|'||coalesce(s.pick,'')
from public.v_picks_futbol_calc s
where s.apostable
  and not public.pick_publicacion_autorizada(s.espn_event_id,'soccer',s.mercado,s.pick);

comment on view public.v_publication_authority_leaks is
'Invariant: MUST return zero rows. Any row is a user-facing recommendation bypassing the canonical/release authority gate.';