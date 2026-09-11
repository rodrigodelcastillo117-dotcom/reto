-- iss056 — NFL Fantasy canonical identity + roster dedupe + Player Prop Board contract
-- STAGED / NO PROD CUTOVER
-- Identity comes from public.nfl_jugadores; availability is separate from identity.
-- Player-prop board only accepts real pre-kickoff provider lines.

create schema if not exists v2;

create or replace function v2.fn_fantasy_pos_norm(p text)
returns text language sql immutable as $$
 select case upper(trim(coalesce(p,'')))
  when 'PK' then 'K' when 'KICKER' then 'K'
  when 'D/ST' then 'DST' when 'DEF' then 'DST' when 'DEFENSE' then 'DST'
  else upper(trim(coalesce(p,''))) end;
$$;

create or replace function v2.fn_fantasy_name_norm(p text)
returns text language sql immutable as $$
 select regexp_replace(
   regexp_replace(lower(translate(coalesce(p,''), '’‘`.-', '''''  ')), '\m(jr|sr|ii|iii|iv|v)\M', '', 'g'),
   '[^a-z0-9]+','','g');
$$;

create or replace function v2.fantasy_player_catalog_v1(p_season int,p_week int)
returns table(
 canonical_player_id text,espn_player_id text,player_name text,player_name_norm text,
 player_position text,team text,catalog_active_flag boolean,availability_status text,injury text,
 depth_order int,opponent text,is_home boolean,kickoff timestamptz,identity_kind text,data_asof timestamptz)
language sql stable security definer set search_path to public,v2 as $$
with sched as (
 select distinct on (upper(c.equipo)) upper(c.equipo) team,upper(c.rival) opponent,c.es_local,c.fecha kickoff,c.espn_event_id
 from public.nfl_calendario_equipo c where c.temporada=p_season and c.semana=p_week
 order by upper(c.equipo),c.fecha desc
),inj as (
 select distinct on(i.espn_player_id) i.espn_player_id,i.estado,i.lesion,i.cargado_at
 from public.nfl_lesiones_semana i where i.temporada=p_season and i.semana=p_week and i.espn_player_id is not null
 order by i.espn_player_id,i.cargado_at desc
),dep as (
 select distinct on(d.espn_player_id) d.espn_player_id,d.orden,d.cargado_at
 from public.nfl_depth_chart d where d.temporada=p_season and d.espn_player_id is not null
 order by d.espn_player_id,d.cargado_at desc,d.orden
),players as (
 select 'NFL:'||j.espn_player_id,j.espn_player_id,j.nombre,v2.fn_fantasy_name_norm(j.nombre),
  v2.fn_fantasy_pos_norm(j.posicion),upper(j.equipo),j.activo,coalesce(i.estado,'UNKNOWN'),i.lesion,d.orden,
  s.opponent,s.es_local,s.kickoff,'PLAYER'::text,
  greatest(j.actualizado_at,coalesce(i.cargado_at,'epoch'::timestamptz),coalesce(d.cargado_at,'epoch'::timestamptz))
 from public.nfl_jugadores j
 left join inj i on i.espn_player_id=j.espn_player_id
 left join dep d on d.espn_player_id=j.espn_player_id
 left join sched s on s.team=upper(j.equipo)
 where j.espn_player_id is not null
),dst as (
 select 'DST:'||s.team,null::text,s.team||' DST',v2.fn_fantasy_name_norm(s.team||' DST'),'DST'::text,s.team,
  true,'ACTIVE'::text,null::text,1,s.opponent,s.es_local,s.kickoff,'DST'::text,s.kickoff from sched s
)
select * from players union all select * from dst;
$$;

create or replace function v2.fn_fantasy_match_player_v1(
 p_name text,p_position text default null,p_team text default null,p_season int default 2026,p_week int default 1)
returns jsonb language plpgsql stable security definer set search_path to public,v2 as $$
declare n text:=v2.fn_fantasy_name_norm(p_name); pos text:=v2.fn_fantasy_pos_norm(p_position);
 tm text:=upper(regexp_replace(coalesce(p_team,''),'[^A-Za-z]','','g')); r record; cnt int;
begin
 if pos='DST' or lower(coalesce(p_name,'')) ~ '(dst|d/st|defense|defensa)' then
  if tm='' then return jsonb_build_object('resolved',false,'reason','DST_NEEDS_TEAM'); end if;
  select * into r from v2.fantasy_player_catalog_v1(p_season,p_week) c where c.identity_kind='DST' and c.team=tm limit 1;
  if found then return jsonb_build_object('resolved',true,'canonical_player_id',r.canonical_player_id,'espn_player_id',null,
   'name',r.player_name,'position','DST','team',r.team,'availability_status',r.availability_status,'identity_kind','DST',
   'opponent',r.opponent,'kickoff',r.kickoff); end if;
  return jsonb_build_object('resolved',false,'reason','DST_TEAM_NOT_IN_WEEK','team',tm);
 end if;
 select count(*) into cnt from public.nfl_jugadores j
 where v2.fn_fantasy_name_norm(j.nombre)=n and (tm='' or upper(j.equipo)=tm)
   and (pos='' or v2.fn_fantasy_pos_norm(j.posicion)=pos);
 if cnt=0 and tm<>'' then
  select count(*) into cnt from public.nfl_jugadores j
  where v2.fn_fantasy_name_norm(j.nombre)=n and (pos='' or v2.fn_fantasy_pos_norm(j.posicion)=pos);
  if cnt=1 then tm:=''; end if;
 end if;
 if cnt<>1 then return jsonb_build_object('resolved',false,'reason',case when cnt=0 then 'PLAYER_NOT_FOUND' else 'AMBIGUOUS_PLAYER' end,
  'candidate_count',cnt,'normalized_name',n,'normalized_position',pos,'team_hint',nullif(tm,'')); end if;
 select j.espn_player_id,j.nombre,v2.fn_fantasy_pos_norm(j.posicion) player_position,upper(j.equipo) team,j.activo into r
 from public.nfl_jugadores j where v2.fn_fantasy_name_norm(j.nombre)=n and (tm='' or upper(j.equipo)=tm)
  and (pos='' or v2.fn_fantasy_pos_norm(j.posicion)=pos) order by j.actualizado_at desc limit 1;
 return (select jsonb_build_object('resolved',true,'canonical_player_id','NFL:'||r.espn_player_id,'espn_player_id',r.espn_player_id,
  'name',r.nombre,'position',r.player_position,'team',r.team,'catalog_active_flag',r.activo,
  'availability_status',c.availability_status,'injury',c.injury,'depth_order',c.depth_order,'opponent',c.opponent,
  'is_home',c.is_home,'kickoff',c.kickoff,'identity_kind','PLAYER')
  from v2.fantasy_player_catalog_v1(p_season,p_week)c where c.espn_player_id=r.espn_player_id limit 1);
end $$;

create or replace function v2.fn_fantasy_roster_canonicalize_v1(p_roster jsonb,p_season int,p_week int)
returns jsonb language plpgsql stable security definer set search_path to public,v2 as $$
declare item jsonb;m jsonb;arr jsonb:='[]'::jsonb;seen text[]:=array[]::text[];k text;canon jsonb;
begin
 if jsonb_typeof(p_roster)<>'array' then raise exception 'roster must be json array'; end if;
 for item in select value from jsonb_array_elements(p_roster) loop
  m:=v2.fn_fantasy_match_player_v1(coalesce(item->>'nombre',item->>'name'),coalesce(item->>'posicion',item->>'position',item->>'slot'),coalesce(item->>'equipo',item->>'team'),p_season,p_week);
  if coalesce((m->>'resolved')::boolean,false) then
   k:=m->>'canonical_player_id';
   canon:=item||jsonb_build_object('canonical_player_id',k,'espn_player_id',m->>'espn_player_id','nombre',m->>'name',
    'posicion',m->>'position','equipo',m->>'team','estado_identidad','CONFIRMADO','availability_status',m->>'availability_status',
    'opponent',m->>'opponent','kickoff',m->>'kickoff');
  else
   k:='UNRESOLVED:'||v2.fn_fantasy_name_norm(coalesce(item->>'nombre',item->>'name'))||':'||upper(coalesce(item->>'equipo',item->>'team',''));
   canon:=item||jsonb_build_object('estado_identidad','SIN_RESOLVER','identity_reason',m->>'reason');
  end if;
  if not(k=any(seen)) then seen:=array_append(seen,k);arr:=arr||jsonb_build_array(canon);end if;
 end loop; return arr;
end $$;

create or replace function v2.save_fantasy_roster_v1(p_apodo text,p_season int,p_week int,p_roster jsonb,p_rival_nombre text default null)
returns jsonb language plpgsql security definer set search_path to public,v2 as $$
declare c jsonb;rid uuid;
begin
 if nullif(trim(p_apodo),'') is null then raise exception 'apodo required'; end if;
 c:=v2.fn_fantasy_roster_canonicalize_v1(p_roster,p_season,p_week);
 insert into public.fantasy_roster_semanal(apodo,temporada,semana,jugadores,rival_nombre,guardado_at)
 values(p_apodo,p_season,p_week,c,p_rival_nombre,now())
 on conflict(apodo,temporada,semana) do update set jugadores=excluded.jugadores,rival_nombre=excluded.rival_nombre,guardado_at=now()
 returning id into rid;
 return jsonb_build_object('ok',true,'id',rid,'players',jsonb_array_length(c),'roster',c);
end $$;

create table if not exists v2.nfl_player_prop_line_snapshot(
 line_snapshot_id uuid primary key default gen_random_uuid(),season int not null,week int not null,espn_event_id text not null,
 kickoff timestamptz not null,captured_at timestamptz not null,provider text not null,bookmaker text not null,provider_event_id text,
 espn_player_id text not null,player_name text not null,team text,player_position text,market text not null,line numeric,side text not null,
 odds_american int,source_payload jsonb,source_version text not null default 'nfl_prop_lines_v1',
 constraint nfl_prop_line_side_ck check(side in('OVER','UNDER','YES','NO')),
 constraint nfl_prop_line_pregame_ck check(captured_at<kickoff),
 unique(provider,bookmaker,espn_event_id,espn_player_id,market,line,side,captured_at));
create or replace function v2.tg_nfl_prop_line_immutable() returns trigger language plpgsql as $$begin raise exception 'nfl_player_prop_line_snapshot is immutable';end$$;
drop trigger if exists nfl_prop_line_immutable on v2.nfl_player_prop_line_snapshot;
create trigger nfl_prop_line_immutable before update or delete on v2.nfl_player_prop_line_snapshot for each row execute function v2.tg_nfl_prop_line_immutable();

create or replace function v2.fn_nfl_prop_orientative_v1(p_player_id text,p_market text,p_line numeric,p_side text)
returns jsonb language plpgsql stable security definer set search_path to public,v2 as $$
declare n int;hits int;avg_v numeric;sd_v numeric;prob numeric;s text:=upper(p_side);m text:=lower(p_market);
begin
 with vals as(select case m when 'passing_yards' then pass_yards::numeric when 'passing_tds' then pass_tds::numeric
  when 'interceptions' then interceptions::numeric when 'rushing_yards' then rush_yards::numeric when 'rushing_attempts' then rush_attempts::numeric
  when 'receptions' then receptions::numeric when 'receiving_yards' then rec_yards::numeric
  when 'anytime_td' then ((coalesce(rush_tds,0)+coalesce(rec_tds,0))>0)::int::numeric else null::numeric end v
  from public.nfl_player_game_logs where espn_player_id=p_player_id)
 select count(v),avg(v),stddev_samp(v),count(*)filter(where case when m='anytime_td' and s='YES' then v>=1
  when m='anytime_td' and s='NO' then v<1 when s='OVER' then v>p_line when s='UNDER' then v<p_line else false end)
 into n,avg_v,sd_v,hits from vals where v is not null;
 if m not in('passing_yards','passing_tds','interceptions','rushing_yards','rushing_attempts','receptions','receiving_yards','anytime_td') then
  return jsonb_build_object('ok',false,'reason','UNSUPPORTED_MARKET');end if;
 if n<3 then return jsonb_build_object('ok',false,'reason','INSUFFICIENT_SAMPLE','sample_size',n);end if;
 prob:=(hits+1.0)/(n+2.0);
 return jsonb_build_object('ok',true,'probability',round(prob,4),'prob_pct',round(prob*100,1),'probability_semantics','HISTORICAL_ORIENTATIVE',
  'sample_size',n,'hits',hits,'historical_mean',round(avg_v,2),'historical_sd',case when sd_v is null then null else round(sd_v,2)end,
  'market',m,'line',p_line,'side',s,'market_used_as_probability',false);
end$$;

create or replace function v2.nfl_prop_board_v1(p_season int,p_week int,p_asof timestamptz default now())
returns table(espn_event_id text,kickoff timestamptz,espn_player_id text,player_name text,player_position text,team text,opponent text,
 market text,line numeric,side text,odds_american int,bookmaker text,line_snapshot_at timestamptz,probability numeric,
 probability_semantics text,sample_size int,model_version text,status text)
language sql stable security definer set search_path to public,v2 as $$
 with latest as(select distinct on(l.bookmaker,l.espn_event_id,l.espn_player_id,l.market,l.side)l.*
  from v2.nfl_player_prop_line_snapshot l where l.season=p_season and l.week=p_week and l.captured_at<=p_asof and l.captured_at<l.kickoff
  order by l.bookmaker,l.espn_event_id,l.espn_player_id,l.market,l.side,l.captured_at desc),
 scored as(select l.*,p.j,c.rival opponent from latest l
  cross join lateral(select v2.fn_nfl_prop_orientative_v1(l.espn_player_id,l.market,l.line,l.side)j)p
  left join public.nfl_calendario_equipo c on c.temporada=l.season and c.semana=l.week and c.espn_event_id=l.espn_event_id and upper(c.equipo)=upper(l.team))
 select s.espn_event_id,s.kickoff,s.espn_player_id,s.player_name,v2.fn_fantasy_pos_norm(s.player_position),s.team,s.opponent,s.market,s.line,s.side,
  s.odds_american,s.bookmaker,s.captured_at,case when(s.j->>'ok')::boolean then(s.j->>'probability')::numeric else null end,
  case when(s.j->>'ok')::boolean then s.j->>'probability_semantics' else 'NO_MODEL'end,coalesce((s.j->>'sample_size')::int,0),
  'nfl_prop_orientative_v1',case when(s.j->>'ok')::boolean then 'READY_ORIENTATIVE' else coalesce(s.j->>'reason','NO_MODEL')end
 from scored s order by case when(s.j->>'ok')::boolean then(s.j->>'probability')::numeric end desc nulls last,s.kickoff,s.player_name,s.market,s.side;
$$;
