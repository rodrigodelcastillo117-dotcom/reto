-- ISS130 — NFL Fantasy safe closeout
-- ChatGPT-owned staged candidate. NO production deploy by this file itself.
-- Goal: establish a canonical projection release authority and fail closed all
-- currently exposed in-season predictive RPCs until temporally reproducible,
-- OOS-validated player projections exist.

create schema if not exists v2;

create table if not exists v2.nfl_fantasy_release_gate (
  model_version text primary key,
  evaluation_version text not null,
  status text not null,
  publish_authorized boolean not null default false,
  reason text not null,
  sealed_at timestamptz not null default now(),
  constraint nfl_fantasy_publish_requires_validated
    check (not publish_authorized or status = 'OOS_VALIDATED')
);

create or replace function v2.fn_nfl_fantasy_gate_immutable()
returns trigger
language plpgsql
set search_path = v2, pg_temp
as $$
begin
  raise exception 'nfl_fantasy_release_gate rows are immutable; create a new model/evaluation version instead';
end
$$;

drop trigger if exists trg_nfl_fantasy_gate_immutable on v2.nfl_fantasy_release_gate;
create trigger trg_nfl_fantasy_gate_immutable
before update or delete on v2.nfl_fantasy_release_gate
for each row execute function v2.fn_nfl_fantasy_gate_immutable();

insert into v2.nfl_fantasy_release_gate(
  model_version, evaluation_version, status, publish_authorized, reason
) values (
  'fantasy-legacy-2026.09',
  'audit-2026.09.13-v1',
  'FAIL_CLOSED_TEMPORAL_OOS_NOT_PROVEN',
  false,
  'Current weekly projections depend on movable aggregates/current state and lack a frozen canonical projection snapshot plus temporally clean OOS validation. External ESPN projections are context, not RETO model truth.'
)
on conflict (model_version) do nothing;

create or replace function v2.fn_nfl_fantasy_release_allowed(p_model_version text)
returns boolean
language sql
stable
security invoker
set search_path = v2, pg_temp
as $$
  select coalesce((
    select g.publish_authorized and g.status = 'OOS_VALIDATED'
    from v2.nfl_fantasy_release_gate g
    where g.model_version = p_model_version
  ), false)
$$;

create table if not exists v2.nfl_fantasy_projection_snapshot (
  snapshot_id uuid primary key default gen_random_uuid(),
  espn_player_id text not null,
  season integer not null,
  week integer not null,
  decision_time timestamptz not null,
  model_version text not null,
  feature_version text not null,
  feature_snapshot_id text not null,
  feature_data_asof timestamptz not null,
  projection_ppr numeric not null,
  lower_ppr numeric,
  upper_ppr numeric,
  source_kind text not null default 'RETO_MODEL',
  temporal_safe boolean not null default false,
  availability_verified boolean not null default false,
  created_at timestamptz not null default now(),
  unique(espn_player_id, season, week, decision_time, model_version),
  constraint nfl_fantasy_projection_source_kind
    check (source_kind in ('RETO_MODEL','EXTERNAL_CONTEXT')),
  constraint nfl_fantasy_projection_asof
    check (feature_data_asof <= decision_time)
);

alter table v2.nfl_fantasy_projection_snapshot enable row level security;

create or replace view v2.v_nfl_fantasy_projection_canonical
with (security_invoker = true)
as
select
  s.snapshot_id,
  s.espn_player_id,
  s.season,
  s.week,
  s.decision_time,
  s.model_version,
  s.feature_version,
  s.feature_snapshot_id,
  s.feature_data_asof,
  s.projection_ppr,
  s.lower_ppr,
  s.upper_ppr,
  s.source_kind,
  s.temporal_safe,
  s.availability_verified,
  g.status as model_status
from v2.nfl_fantasy_projection_snapshot s
join v2.nfl_fantasy_release_gate g
  on g.model_version = s.model_version
where s.source_kind = 'RETO_MODEL'
  and s.temporal_safe
  and s.availability_verified
  and g.publish_authorized
  and g.status = 'OOS_VALIDATED';

-- Public in-season predictive surfaces fail closed until the canonical matrix is
-- release-authorized. Static factual/draft/waiver data functions are intentionally
-- left untouched; they must not be relabeled as RETO projections.
create or replace function public.fantasy_proyectar(
  p_espn_player_id text,
  p_semana integer,
  p_temporada integer default 2026,
  p_proyeccion_espn numeric default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, v2, pg_temp
as $$
  select jsonb_build_object(
    'resuelto', false,
    'model_status', 'VALIDATION_BLOCKED',
    'model_version', 'fantasy-legacy-2026.09',
    'motivo', 'Proyeccion RETO no publicable: falta snapshot canonico temporalmente reproducible y validacion OOS.',
    'espn_player_id', p_espn_player_id,
    'semana', p_semana,
    'temporada', p_temporada,
    'proyeccion', null,
    'proyeccion_reto13m', null,
    'proyeccion_espn_contexto', p_proyeccion_espn,
    'fuente_proyeccion', case when p_proyeccion_espn is null then null else 'espn_context_only' end,
    'publish_authorized', false
  )
$$;

create or replace function public.fantasy_ranking(
  p_posicion text default null,
  p_semana integer default null,
  p_temporada integer default null,
  p_tope integer default 50,
  p_min_partidos integer default 3
)
returns table(
  lugar integer, lugar_pos integer, espn_player_id text, jugador text, posicion text,
  equipo text, proyeccion numeric, base_ppr numeric, ppr_reg numeric,
  ppr_reg_ult5 numeric, partidos_reg integer, targets_promedio numeric,
  ppr_pre numeric, partidos_pre integer, cambio_equipo boolean,
  equipo_anterior text, rival text, es_local boolean, en_bye boolean,
  semana_bye integer, matchup text, lugar_defensa integer,
  pts_concede_rival numeric, factor numeric, frase_matchup text, banderas text[]
)
language sql
stable
security definer
set search_path = public, v2, pg_temp
as $$
  select
    null::integer, null::integer, null::text, null::text, null::text,
    null::text, null::numeric, null::numeric, null::numeric,
    null::numeric, null::integer, null::numeric,
    null::numeric, null::integer, null::boolean,
    null::text, null::text, null::boolean, null::boolean,
    null::integer, null::text, null::integer,
    null::numeric, null::numeric, null::text, null::text[]
  where false
$$;

create or replace function public.fantasy_analizar_alineacion(
  p_jugadores jsonb,
  p_semana integer,
  p_temporada integer default 2026
)
returns jsonb
language sql
stable
security definer
set search_path = public, v2, pg_temp
as $$
  select jsonb_build_object(
    'ok', false,
    'listo_para_aconsejar', false,
    'model_status', 'VALIDATION_BLOCKED',
    'model_version', 'fantasy-legacy-2026.09',
    'semana', p_semana,
    'temporada', p_temporada,
    'mi_proyeccion', null,
    'proyeccion_rival', null,
    'diferencia', null,
    'jugadores', '[]'::jsonb,
    'alertas', jsonb_build_array('NFL Fantasy RETO esta temporalmente bloqueado hasta validar un snapshot canonico OOS. No se publican proyecciones propias ni consejos start/sit.'),
    'publish_authorized', false
  )
$$;

create or replace function public.fantasy_start_sit(
  p_apodo text default null,
  p_semana integer default null,
  p_temporada integer default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, v2, pg_temp
as $$
  select jsonb_build_object(
    'ok', false,
    'model_status', 'VALIDATION_BLOCKED',
    'model_version', 'fantasy-legacy-2026.09',
    'semana', p_semana,
    'temporada', p_temporada,
    'con_roster', false,
    'mi_alineacion', null,
    'mejores_de_la_semana', '{}'::jsonb,
    'alertas', jsonb_build_array('NFL Fantasy RETO esta bloqueado para publicacion hasta tener matriz canonica temporalmente reproducible y validacion OOS.'),
    'publish_authorized', false
  )
$$;

comment on table v2.nfl_fantasy_release_gate is
  'Sole publish authority for RETO-owned NFL Fantasy projections. Missing row means DENY.';
comment on view v2.v_nfl_fantasy_projection_canonical is
  'Canonical NFL Fantasy RETO projection matrix. Emits only temporally safe, availability-verified, release-authorized model snapshots.';
