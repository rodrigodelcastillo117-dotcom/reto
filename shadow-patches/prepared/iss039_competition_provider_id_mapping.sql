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

-- 4) CONTRATO de cutover (§20): el builder debe mapear competencia por ag.liga_id
--    (numérico ESPN) vía fn_resolve_competition('espn', ag.liga_id, active_mapping_version),
--    dejando liga_alias(nombre) sólo como fallback/etiqueta. Nombres no mapeados por id
--    fail-close a NO_MODEL. Recomendación: sembrar competition_provider_map desde el
--    catálogo real ESPN en cutover; mientras, liga_alias(nombre) sigue como puente.
