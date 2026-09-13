-- ISS133 — NFL LEGACY PICK AUTHORITY FAIL-CLOSE
-- Keeps nfl_predicciones diagnostic payloads (market/FPI/context) but permanently
-- removes mejor_pick/mejor_prob as an authoritative/public recommendation surface.
-- Canonical NFL publication authority lives only in v2.nfl_model_validation_gate
-- + v2.fn_nfl_release_allowed(). Legacy FPI/market rows remain context only.

create or replace function v2.fn_nfl_legacy_predicciones_failclosed()
returns trigger
language plpgsql
as $$
begin
  new.mejor_pick := null;
  new.mejor_prob := null;

  if new.contexto is null then
    new.contexto := '{}'::jsonb;
  end if;

  new.contexto := new.contexto || jsonb_build_object(
    'legacy_pick_authority', 'DISABLED',
    'legacy_pick_reason', 'NFL legacy market/FPI layer is diagnostic only; canonical picks require independently validated v2 release authority.'
  );

  return new;
end;
$$;

drop trigger if exists trg_nfl_legacy_predicciones_failclosed on public.nfl_predicciones;
create trigger trg_nfl_legacy_predicciones_failclosed
before insert or update on public.nfl_predicciones
for each row execute function v2.fn_nfl_legacy_predicciones_failclosed();

-- Clear currently persisted legacy recommendations without touching mercados/contexto.
update public.nfl_predicciones
set mejor_pick = null,
    mejor_prob = null,
    contexto = coalesce(contexto, '{}'::jsonb) || jsonb_build_object(
      'legacy_pick_authority', 'DISABLED',
      'legacy_pick_reason', 'NFL legacy market/FPI layer is diagnostic only; canonical picks require independently validated v2 release authority.'
    )
where mejor_pick is not null or mejor_prob is not null;

comment on trigger trg_nfl_legacy_predicciones_failclosed on public.nfl_predicciones is
  'Fail-closed guard: legacy NFL market/FPI diagnostics may not publish mejor_pick/mejor_prob. Canonical authority is v2 validation-gated only.';
