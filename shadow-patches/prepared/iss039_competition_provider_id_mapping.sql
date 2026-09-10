-- ============================================================================
-- iss039 — §20 COMPETITION IDENTITY POR PROVIDER-ID (no por nombre) · STAGED
-- Profundiza el residual §20 de SECOND_PASS_AUDITS: `v2.liga_alias` está keyeada por
-- NOMBRE (liga_source), el key más débil. Re-key por provider_competition_id (ESPN
-- liga_id NUMÉRICO) + mapping_version, para congelar identidad por id de proveedor y ser
-- inmune a variantes de grafía (Real Madrid/Inter/Club Brugge, etc.). NO APLICAR bajo
-- freeze. NO va en supabase/migrations.
-- ============================================================================
-- PRINCIPIO: la identidad de competencia debe resolverse por (provider, provider id
-- numérico, mapping_version), no por texto. El nombre queda como etiqueta humana, nunca
-- como clave. mapping_version permite replay: un cambio de mapeo crea versión nueva sin
-- reescribir la de época (mismo patrón append-only que iss037).
-- ============================================================================

-- 1) Mapa provider-id -> competition_id, versionado (append-only por mapping_version).
create table if not exists v2.competition_provider_map (
  provider               text    not null,          -- 'espn'
  provider_competition_id integer not null,          -- liga_id numérico del proveedor
  competition_id         integer not null,          -- id canónico interno
  competition_label      text,                       -- etiqueta humana (NO es clave)
  mapping_version        text    not null default 'compmap_v1',
  sealed_at              timestamptz not null default now(),
  primary key (provider, provider_competition_id, mapping_version)
);

-- 2) Resolver por PROVIDER-ID (nunca por nombre). Fail-close (0 filas) si no mapeado.
create or replace function v2.fn_resolve_competition(
  p_provider text, p_provider_competition_id integer, p_mapping_version text default 'compmap_v1'
) returns table(competition_id integer, competition_label text, mapping_version text)
language sql stable as $$
  select m.competition_id, m.competition_label, m.mapping_version
  from v2.competition_provider_map m
  where m.provider = p_provider
    and m.provider_competition_id = p_provider_competition_id
    and m.mapping_version = p_mapping_version
  limit 1;
$$;

-- 3) Guarda de integridad: ningún provider-id mapea a >1 competition_id EN LA MISMA
--    mapping_version (colisión de identidad por id). También expone colisiones de nombre
--    residuales (mismo label a >1 competition_id) como diagnóstico, no como clave.
create or replace function v2.fn_competition_map_integrity(p_mapping_version text default 'compmap_v1')
returns table(id_collisions bigint, label_collisions bigint) language sql stable as $$
  select
    (select count(*) from (
       select provider, provider_competition_id
       from v2.competition_provider_map where mapping_version=p_mapping_version
       group by 1,2 having count(distinct competition_id) > 1) x),
    (select count(*) from (
       select competition_label
       from v2.competition_provider_map where mapping_version=p_mapping_version and competition_label is not null
       group by 1 having count(distinct competition_id) > 1) y);
$$;

-- 4) INMUTABILIDAD append-only (v2, corrige AUDIT 5610547890): la PK sólo impide una
--    SEGUNDA fila con la misma clave, NO una mutación in-place de la fila histórica. Un
--    UPDATE de competition_id dentro del MISMO mapping_version rompería replay. Se prohíbe
--    UPDATE y DELETE por fila: un cambio de mapeo = NUEVA mapping_version (INSERT), nunca
--    edición in-place. (TRUNCATE se revoca en prod; sólo para teardown de branch.)
create or replace function v2.fn_competition_map_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'COMPETITION_MAP_IMMUTABLE: % prohibido en competition_provider_map (append-only); un cambio de mapeo requiere una nueva mapping_version', tg_op;
end $$;
drop trigger if exists trg_competition_map_immutable on v2.competition_provider_map;
create trigger trg_competition_map_immutable
  before update or delete on v2.competition_provider_map
  for each row execute function v2.fn_competition_map_immutable();

-- 5) Puntero de versión activa (autoridad única de qué mapping_version usa el builder HOY).
create table if not exists v2.competition_mapping_config (
  singleton boolean primary key default true check (singleton),
  active_mapping_version text not null
);
create or replace function v2.fn_competition_active_mapping() returns text language sql stable as $$
  select active_mapping_version from v2.competition_mapping_config where singleton limit 1;
$$;

-- 6) WIRING REAL del builder (§20, end-to-end): iss033 `mapped` resuelve competition_id
--    por PROVIDER-ID (ag.liga_id numérico ESPN) vía fn_resolve_competition('espn',
--    ag.liga_id, fn_competition_active_mapping()); el NOMBRE queda sólo como etiqueta.
--    provider-id no mapeado -> competition_id NULL -> NO_MODEL (fail-close). Un cambio de
--    label con el MISMO provider-id NO altera la identidad resuelta.
