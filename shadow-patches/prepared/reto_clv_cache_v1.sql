-- ✅ APLICADO A PROD 2026-10-14 — fix de acceso anon al panel CLV del Récord Público.
-- Problema: v_reto_clv_v1 leía v2.soccer_publication_market_evidence_v1, que es
-- security_invoker=true y depende de 2 tablas v2 (soccer_dk_market_snapshot_v1,
-- soccer_publication_gate_decision_v1) que anon NO puede leer → HTTP 401 sin sesión.
-- No quise exponer esas tablas v2 a anon. Solución: cache propia (owner postgres)
-- refrescada por función SECURITY DEFINER; la vista pública lee el cache con
-- derechos del owner, sin tocar v2 desde anon. No expone internals del modelo.

create table if not exists public.reto_clv_cache_v1 (
  deporte text primary key,
  picks_con_cierre int, con_ambos_precios int,
  drift_promedio_pp numeric, pct_clv_positivo numeric,
  desde date, hasta date,
  refreshed_at timestamptz not null default now()
);

create or replace function public.refresh_reto_clv_cache_v1()
returns void language plpgsql security definer set search_path to 'public','v2' as $$
begin
  delete from public.reto_clv_cache_v1;
  insert into public.reto_clv_cache_v1
    (deporte, picks_con_cierre, con_ambos_precios, drift_promedio_pp, pct_clv_positivo, desde, hasta, refreshed_at)
  select 'soccer',
    count(*) filter (where closing_valid),
    count(*) filter (where closing_odds is not null and decision_odds is not null),
    round(avg(market_drift_samebook_pp) filter (where closing_valid), 2),
    round(avg((market_drift_samebook_pp > 0)::int) filter (where closing_valid)*100, 1),
    min(kickoff)::date, max(kickoff)::date, now()
  from v2.soccer_publication_market_evidence_v1;
end; $$;

select public.refresh_reto_clv_cache_v1();

-- vista repunta al cache (casts a bigint para igualar tipos y evitar DROP bajo lock)
create or replace view public.v_reto_clv_v1 as
select deporte, picks_con_cierre::bigint as picks_con_cierre,
       con_ambos_precios::bigint as con_ambos_precios,
       drift_promedio_pp, pct_clv_positivo, desde, hasta
from public.reto_clv_cache_v1;
grant select on public.v_reto_clv_v1 to anon, authenticated;

-- refresco cada 6h
select cron.schedule('reto-clv-cache-refresh','23 */6 * * *',$$select public.refresh_reto_clv_cache_v1();$$);
notify pgrst, 'reload schema';
