-- ISS145 — Verified external Fantasy roster snapshots
-- ADDITIVE. Historical roster rows remain untouched; publishing creates a new weekly row.
create table if not exists v2.fantasy_external_roster_snapshot_v1 (
  snapshot_id uuid primary key default gen_random_uuid(),
  apodo text not null,
  platform text not null,
  league_id text not null,
  team_id text not null,
  season integer not null,
  provider_week integer,
  target_nfl_week integer not null,
  captured_at timestamptz not null,
  source_verified boolean not null default false,
  provider_roster jsonb not null,
  canonical_roster jsonb not null,
  created_at timestamptz not null default now(),
  unique(platform,league_id,team_id,season,target_nfl_week,captured_at)
);

create or replace function v2.guard_fantasy_external_roster_snapshot_v1()
returns trigger language plpgsql set search_path='v2','public','pg_temp' as $$
begin raise exception 'External Fantasy roster snapshots are immutable'; end $$;

drop trigger if exists trg_fantasy_external_roster_snapshot_v1 on v2.fantasy_external_roster_snapshot_v1;
create trigger trg_fantasy_external_roster_snapshot_v1 before update or delete on v2.fantasy_external_roster_snapshot_v1
for each row execute function v2.guard_fantasy_external_roster_snapshot_v1();

create or replace function v2.publish_verified_external_roster_v1(p_snapshot_id uuid)
returns jsonb language plpgsql security definer set search_path='v2','public','pg_temp' as $$
declare s record; rid uuid;
begin
  select * into s from v2.fantasy_external_roster_snapshot_v1 where snapshot_id=p_snapshot_id;
  if s.snapshot_id is null then return jsonb_build_object('ok',false,'status','SNAPSHOT_NOT_FOUND'); end if;
  if not s.source_verified then return jsonb_build_object('ok',false,'status','SOURCE_NOT_VERIFIED'); end if;
  if jsonb_array_length(s.canonical_roster)<1 then return jsonb_build_object('ok',false,'status','EMPTY_ROSTER'); end if;
  insert into public.fantasy_roster_semanal(apodo,temporada,semana,jugadores,analisis,guardado_at)
  values(s.apodo,s.season,s.target_nfl_week,s.canonical_roster,
    jsonb_build_object('source','VERIFIED_EXTERNAL_FANTASY','platform',s.platform,'league_id',s.league_id,'team_id',s.team_id,'snapshot_id',s.snapshot_id),s.captured_at)
  returning id into rid;
  return jsonb_build_object('ok',true,'status','PUBLISHED_AS_NEW_WEEKLY_ROSTER','roster_id',rid,'snapshot_id',s.snapshot_id,
    'season',s.season,'week',s.target_nfl_week,'historical_rows_overwritten',false);
end $$;

grant execute on function v2.publish_verified_external_roster_v1(uuid) to authenticated;

grant select on v2.fantasy_external_roster_snapshot_v1 to authenticated;
