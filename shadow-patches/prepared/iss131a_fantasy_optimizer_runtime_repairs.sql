-- ISS131a — verified runtime repairs for v2.fn_fantasy_optimal_lineup_v2
-- Reversible CREATE OR REPLACE only. Verified on disposable oakxebiyashfsiforukq.
-- Repairs:
--   1) invalid USING(slot_code,slot_seq) joins where current_rows exposes roster_slot
--   2) PL/pgSQL output-column ambiguity via #variable_conflict use_column

create or replace function v2.fn_fantasy_optimal_lineup_v2(
  p_apodo text,
  p_season int,
  p_week int,
  p_decision_time timestamptz
) returns table(
  slot_code text,
  slot_seq int,
  current_player text,
  recommended_player text,
  recommended_player_id text,
  projected_mean numeric,
  floor_points numeric,
  ceiling_points numeric,
  locked boolean,
  action text,
  optimizer_status text,
  total_current_modeled numeric,
  total_recommended_modeled numeric,
  modeled_gain numeric
) language plpgsql stable as $$
#variable_conflict use_column
declare
  v_roster jsonb;
  v_assignment jsonb;
  v_total_current numeric;
  v_total_rec numeric;
begin
  select fr.jugadores into v_roster
  from public.fantasy_roster_semanal fr
  where fr.apodo=p_apodo and fr.temporada=p_season and fr.semana=p_week
  order by fr.guardado_at desc limit 1;
  if v_roster is null then return; end if;

  with recursive roster_raw as (
    select e.ordinality::int ord,e.value j,
      coalesce(nullif(e.value->>'espn_player_id',''),s.espn_player_id,
               lower(e.value->>'nombre')||'|'||upper(e.value->>'equipo')) player_key,
      e.value->>'nombre' player_name,upper(e.value->>'equipo') team,
      upper(e.value->>'posicion') position,upper(e.value->>'slot') roster_slot,
      s.espn_player_id,s.projected_mean,s.floor_points,s.ceiling_points,s.model_status,s.kickoff
    from jsonb_array_elements(v_roster) with ordinality e(value,ordinality)
    left join lateral (
      select x.* from v2.fantasy_projection_snapshot_v2 x
      where x.player_name=e.value->>'nombre' and x.team=upper(e.value->>'equipo')
        and x.season=p_season and x.week=p_week and x.decision_time=p_decision_time
      order by x.built_at desc limit 1
    ) s on true
    where upper(e.value->>'posicion') in ('QB','RB','WR','TE')
  ), current_rows as (
    select r.*,row_number() over(partition by roster_slot order by ord)::int slot_seq
    from roster_raw r where roster_slot in ('QB','RB','WR','TE','FLEX')
  ), slots as (
    select * from (values
      (1,'QB'::text,1),(2,'RB',1),(3,'RB',2),(4,'WR',1),(5,'WR',2),(6,'TE',1),(7,'FLEX',1)
    ) s(idx,slot_code,slot_seq)
  ), slot_meta as (
    select s.*,c.player_key current_key,c.player_name current_name,
      c.model_status current_model_status,c.kickoff current_kickoff,
      ((c.kickoff is not null and c.kickoff<=p_decision_time)
       or (c.player_key is not null and c.model_status<>'READY')) is_locked
    from slots s
    left join current_rows c on c.roster_slot=s.slot_code and c.slot_seq=s.slot_seq
  ), pool as (
    select distinct on(player_key)
      player_key,player_name,espn_player_id,position,projected_mean,floor_points,ceiling_points,model_status
    from roster_raw order by player_key,ord
  ), search(idx,used,assignment,score) as (
    select sm.idx,jsonb_build_array(p.player_key),jsonb_build_object(sm.idx::text,p.player_key),
      coalesce(p.projected_mean,0)::numeric
    from slot_meta sm join pool p on true
    where sm.idx=1 and ((sm.is_locked and p.player_key=sm.current_key)
      or (not coalesce(sm.is_locked,false) and p.model_status='READY' and p.position='QB'))
    union all
    select sm.idx,sr.used||to_jsonb(p.player_key),
      sr.assignment||jsonb_build_object(sm.idx::text,p.player_key),
      sr.score+coalesce(p.projected_mean,0)
    from search sr join slot_meta sm on sm.idx=sr.idx+1
    join pool p on not(sr.used ? p.player_key)
    where (sm.is_locked and p.player_key=sm.current_key)
      or (not coalesce(sm.is_locked,false) and p.model_status='READY' and
        case sm.slot_code when 'QB' then p.position='QB' when 'RB' then p.position='RB'
          when 'WR' then p.position='WR' when 'TE' then p.position='TE'
          when 'FLEX' then p.position in ('RB','WR','TE') else false end)
  ), winner as (
    select sr.assignment,sr.score from search sr where sr.idx=7
    order by sr.score desc,sr.assignment::text asc limit 1
  )
  select w.assignment into v_assignment from winner w;

  if v_assignment is null then
    return query select 'STATUS'::text,0,null::text,null::text,null::text,
      null::numeric,null::numeric,null::numeric,false,'NO_RECOMMENDATION'::text,
      'NO_COMPLETE_MODELED_LINEUP'::text,null::numeric,null::numeric,null::numeric;
    return;
  end if;

  select sum(s.projected_mean) into v_total_current
  from jsonb_array_elements(v_roster) e
  join v2.fantasy_projection_snapshot_v2 s
    on s.player_name=e->>'nombre' and s.team=upper(e->>'equipo')
   and s.season=p_season and s.week=p_week and s.decision_time=p_decision_time
  where upper(e->>'slot') in ('QB','RB','WR','TE','FLEX') and s.model_status='READY';

  with rec as (
    select (kv.key)::int idx,kv.value #>> '{}' player_key from jsonb_each(v_assignment) kv
  ), pool as (
    select distinct on(coalesce(espn_player_id,lower(player_name)||'|'||team))
      coalesce(espn_player_id,lower(player_name)||'|'||team) player_key,projected_mean
    from v2.fantasy_projection_snapshot_v2
    where season=p_season and week=p_week and decision_time=p_decision_time
    order by coalesce(espn_player_id,lower(player_name)||'|'||team),built_at desc
  )
  select sum(p.projected_mean) into v_total_rec from rec r join pool p using(player_key);

  return query
  with roster_raw as (
    select e.ordinality::int ord,e.value j,
      coalesce(nullif(e.value->>'espn_player_id',''),s.espn_player_id,
               lower(e.value->>'nombre')||'|'||upper(e.value->>'equipo')) player_key,
      e.value->>'nombre' player_name,upper(e.value->>'equipo') team,
      upper(e.value->>'posicion') position,upper(e.value->>'slot') roster_slot,
      s.espn_player_id,s.projected_mean,s.floor_points,s.ceiling_points,s.model_status,s.kickoff
    from jsonb_array_elements(v_roster) with ordinality e(value,ordinality)
    left join lateral (
      select x.* from v2.fantasy_projection_snapshot_v2 x
      where x.player_name=e.value->>'nombre' and x.team=upper(e.value->>'equipo')
        and x.season=p_season and x.week=p_week and x.decision_time=p_decision_time
      order by x.built_at desc limit 1
    ) s on true
  ), current_rows as (
    select r.*,row_number() over(partition by roster_slot order by ord)::int slot_seq
    from roster_raw r where roster_slot in ('QB','RB','WR','TE','FLEX')
  ), slots as (
    select * from (values
      (1,'QB'::text,1),(2,'RB',1),(3,'RB',2),(4,'WR',1),(5,'WR',2),(6,'TE',1),(7,'FLEX',1)
    ) s(idx,slot_code,slot_seq)
  ), skill as (
    select sl.idx,sl.slot_code,sl.slot_seq,c.player_name current_name,c.player_key current_key,
      c.model_status current_status,c.kickoff current_kickoff,v_assignment->>sl.idx::text rec_key
    from slots sl
    left join current_rows c on c.roster_slot=sl.slot_code and c.slot_seq=sl.slot_seq
  ), pool as (
    select distinct on(player_key) player_key,player_name,espn_player_id,
      projected_mean,floor_points,ceiling_points
    from roster_raw where player_key is not null order by player_key,ord
  ), skill_out as (
    select sk.slot_code,sk.slot_seq,sk.current_name,p.player_name recommended_name,p.espn_player_id,
      p.projected_mean,p.floor_points,p.ceiling_points,
      ((sk.current_kickoff is not null and sk.current_kickoff<=p_decision_time)
       or (sk.current_key is not null and sk.current_status<>'READY')) locked,
      case when sk.current_key=p.player_key then 'KEEP' else 'MOVE' end action,1 ord
    from skill sk join pool p on p.player_key=sk.rec_key
  ), fixed_unmodeled as (
    select case when roster_slot='DST' then 'DST' else roster_slot end slot_code,
      row_number() over(partition by roster_slot order by ord)::int slot_seq,
      player_name current_name,player_name recommended_name,espn_player_id,
      null::numeric projected_mean,null::numeric floor_points,null::numeric ceiling_points,
      true locked,'KEEP_UNMODELED'::text action,2 ord
    from roster_raw where roster_slot in ('K','DST')
  ), all_out as (
    select * from skill_out union all select * from fixed_unmodeled
  )
  select a.slot_code,a.slot_seq,a.current_name,a.recommended_name,a.espn_player_id,
    a.projected_mean,a.floor_points,a.ceiling_points,a.locked,a.action,
    'OPTIMIZED_GLOBAL_MEDIAN'::text,v_total_current,v_total_rec,
    case when v_total_current is not null and v_total_rec is not null then v_total_rec-v_total_current end
  from all_out a
  order by a.ord,
    case a.slot_code when 'QB' then 1 when 'RB' then 2 when 'WR' then 3 when 'TE' then 4
      when 'FLEX' then 5 when 'K' then 6 when 'DST' then 7 else 8 end,
    a.slot_seq;
end $$;
