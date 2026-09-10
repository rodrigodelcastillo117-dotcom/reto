-- iss055 — NFL PLAYER PROPS AUTOGRADE v1 · STAGED / NO PROD CUTOVER
-- Fixes a real gap: simular_eval_player_prop() is MLB-only despite its generic name.
-- This file creates an NFL-specific, deterministic settlement path using persisted
-- nfl_player_game_logs. No HTTP call and no text-only result authority.

create schema if not exists v2;

create or replace function v2.fn_nfl_prop_market(p_text text)
returns text language sql immutable as $$
  select case
    when lower(coalesce(p_text,'')) ~ '(receiving yards|yardas recibid)' then 'RECEIVING_YARDS'
    when lower(coalesce(p_text,'')) ~ '(receptions|recepciones)' then 'RECEPTIONS'
    when lower(coalesce(p_text,'')) ~ '(rushing yards|yardas (terrestres|por tierra))' then 'RUSHING_YARDS'
    when lower(coalesce(p_text,'')) ~ '(rushing attempts|carries|acarreos)' then 'RUSH_ATTEMPTS'
    when lower(coalesce(p_text,'')) ~ '(passing yards|yardas (de )?pase)' then 'PASSING_YARDS'
    when lower(coalesce(p_text,'')) ~ '(passing touchdowns|pass tds|tds? de pase|pases? de touchdown)' then 'PASS_TDS'
    when lower(coalesce(p_text,'')) ~ '(interceptions|intercepciones)' then 'INTERCEPTIONS'
    when lower(coalesce(p_text,'')) ~ '(anytime td|anytime touchdown|anota.*touchdown|anota.*td|touchdown anotado)' then 'ANYTIME_TD'
    when lower(coalesce(p_text,'')) ~ '(total touchdowns|total tds|touchdowns totales)' then 'TOTAL_TDS'
    else null end;
$$;

create or replace function v2.fn_nfl_prop_side(p_text text)
returns text language sql immutable as $$
  select case
    when lower(coalesce(p_text,'')) ~ '(^|[^a-z])(under|menos de|menos)([^a-z]|$)' then 'UNDER'
    when lower(coalesce(p_text,'')) ~ '(^|[^a-z])(over|más de|mas de|más|mas)([^a-z]|$)' then 'OVER'
    when lower(coalesce(p_text,'')) ~ '[0-9]+([.][0-9]+)?[+]' then 'AT_LEAST'
    when v2.fn_nfl_prop_market(p_text)='ANYTIME_TD' then 'OVER'
    else null end;
$$;

create or replace function v2.fn_nfl_prop_line(p_text text)
returns numeric language plpgsql immutable as $$
declare m text[];
begin
  m := regexp_match(lower(coalesce(p_text,'')), '(?:over|under|más de|mas de|menos de|más|mas|menos)[[:space:]]+([0-9]+(?:[.][0-9]+)?)');
  if m is not null then return m[1]::numeric; end if;
  m := regexp_match(lower(coalesce(p_text,'')), '([0-9]+(?:[.][0-9]+)?)[+]');
  if m is not null then return m[1]::numeric; end if;
  if v2.fn_nfl_prop_market(p_text)='ANYTIME_TD' then return 0.5; end if;
  return null;
end $$;

create or replace function v2.fn_nfl_prop_player_text(p_text text)
returns text language plpgsql immutable as $$
declare s text;
begin
  s := btrim(coalesce(p_text,''));
  s := regexp_replace(s, '[[:space:]]+(over|under|más de|mas de|menos de|más|mas|menos)[[:space:]].*$', '', 'i');
  s := regexp_replace(s, '[[:space:]]+[0-9]+(?:[.][0-9]+)?[+].*$', '', 'i');
  s := regexp_replace(s, '[[:space:]]+(receiving yards|yardas recibidas|receptions|recepciones|rushing yards|yardas terrestres|yardas por tierra|passing yards|yardas de pase|rushing attempts|carries|acarreos|anytime td|anytime touchdown|total touchdowns|total tds).*$', '', 'i');
  return nullif(btrim(s),'');
end $$;

create or replace function v2.eval_nfl_player_prop_v1(
  p_espn_event_id text,
  p_pick_desc text,
  p_contract jsonb default null
) returns jsonb
language plpgsql stable security definer
set search_path to public,v2
as $$
declare
  v_market text;
  v_side text;
  v_line numeric;
  v_player_id text;
  v_player_text text;
  v_match jsonb;
  v_status text;
  v_home_score int;
  v_away_score int;
  v_log record;
  v_value numeric;
  v_result text;
begin
  if p_espn_event_id is null or btrim(p_espn_event_id)='' then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','MISSING_EVENT_ID');
  end if;

  v_market := upper(coalesce(p_contract->>'market',v2.fn_nfl_prop_market(p_pick_desc)));
  v_side := upper(coalesce(p_contract->>'side',v2.fn_nfl_prop_side(p_pick_desc)));
  v_line := coalesce(nullif(p_contract->>'line','')::numeric,v2.fn_nfl_prop_line(p_pick_desc));
  v_player_id := nullif(p_contract->>'espn_player_id','');

  if v_market is null or v_market not in ('RECEIVING_YARDS','RECEPTIONS','RUSHING_YARDS','RUSH_ATTEMPTS','PASSING_YARDS','PASS_TDS','INTERCEPTIONS','ANYTIME_TD','TOTAL_TDS') then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','UNSUPPORTED_MARKET','market',v_market);
  end if;
  if v_side is null or v_side not in ('OVER','UNDER','AT_LEAST') then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','UNRESOLVED_SIDE','side',v_side);
  end if;
  if v_line is null or v_line < 0 then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','UNRESOLVED_LINE','line',v_line);
  end if;

  if v_player_id is null then
    v_player_text := v2.fn_nfl_prop_player_text(p_pick_desc);
    if v_player_text is null then
      return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','UNRESOLVED_PLAYER_TEXT');
    end if;
    v_match := public.match_jugador_nfl(v_player_text,null,null);
    if coalesce((v_match->>'resuelto')::boolean,false) is not true then
      return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','AMBIGUOUS_PLAYER','player_text',v_player_text,'candidates',v_match->'candidatos');
    end if;
    v_player_id := v_match->>'espn_player_id';
  end if;

  select lower(coalesce(p.estado,'')),p.pts_home,p.pts_away
    into v_status,v_home_score,v_away_score
  from public.nfl_partidos p
  where p.espn_event_id=p_espn_event_id
  order by p.actualizado desc nulls last
  limit 1;

  if v_status is distinct from 'final' then
    return jsonb_build_object('ok',true,'evaluation','pending','reason','EVENT_NOT_FINAL','event_status',v_status,
      'espn_event_id',p_espn_event_id,'espn_player_id',v_player_id,'market',v_market,'side',v_side,'line',v_line);
  end if;

  select l.* into v_log
  from public.nfl_player_game_logs l
  where l.espn_event_id=p_espn_event_id and l.espn_player_id=v_player_id
  limit 1;

  if not found then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','PLAYER_LOG_MISSING_ON_FINAL',
      'espn_event_id',p_espn_event_id,'espn_player_id',v_player_id,'market',v_market);
  end if;

  v_value := case v_market
    when 'RECEIVING_YARDS' then v_log.rec_yards
    when 'RECEPTIONS' then v_log.receptions
    when 'RUSHING_YARDS' then v_log.rush_yards
    when 'RUSH_ATTEMPTS' then v_log.rush_attempts
    when 'PASSING_YARDS' then v_log.pass_yards
    when 'PASS_TDS' then v_log.pass_tds
    when 'INTERCEPTIONS' then v_log.interceptions
    when 'ANYTIME_TD' then coalesce(v_log.rush_tds,0)+coalesce(v_log.rec_tds,0)
    when 'TOTAL_TDS' then coalesce(v_log.rush_tds,0)+coalesce(v_log.rec_tds,0)
    else null end;

  if v_value is null then
    return jsonb_build_object('ok',false,'evaluation','no_evaluable','reason','STAT_NOT_AVAILABLE',
      'espn_event_id',p_espn_event_id,'espn_player_id',v_player_id,'market',v_market);
  end if;

  v_result := case v_side
    when 'OVER' then case when v_value>v_line then 'ganado' when v_value=v_line then 'nulo' else 'perdido' end
    when 'UNDER' then case when v_value<v_line then 'ganado' when v_value=v_line then 'nulo' else 'perdido' end
    when 'AT_LEAST' then case when v_value>=v_line then 'ganado' else 'perdido' end
  end;

  return jsonb_build_object(
    'ok',true,'evaluation',v_result,'source','nfl_player_game_logs','source_version','nfl_prop_autograde_v1',
    'espn_event_id',p_espn_event_id,'espn_player_id',v_player_id,'player_name',v_log.player_name,
    'market',v_market,'side',v_side,'line',v_line,'stat_value',v_value,
    'game_score',v_home_score||'-'||v_away_score,
    'settlement_key',md5(concat_ws('|',p_espn_event_id,v_player_id,v_market,v_side,v_line::text,v_value::text)));
end $$;

create or replace function v2.autograde_nfl_props_v1(p_dry_run boolean default true)
returns table(pick_id uuid,apodo text,pick_desc text,evaluation text,stat_value numeric,game_score text)
language plpgsql security definer
set search_path to public,v2
as $$
declare r record; e jsonb; v_gain numeric;
begin
  for r in
    select p.* from public.picks p
    where p.resultado='pendiente'
      and p.espn_event_id is not null
      and (upper(coalesce(p.deporte,''))='NFL' or upper(coalesce(p.liga,''))='NFL')
      and (
        v2.fn_nfl_prop_market(p.pick_desc) is not null
        or coalesce(p.features_input_json->'nfl_prop'->>'version','') like 'nfl_prop_%'
      )
  loop
    e := v2.eval_nfl_player_prop_v1(r.espn_event_id,r.pick_desc,r.features_input_json->'nfl_prop');
    if e->>'evaluation' not in ('ganado','perdido','nulo') then continue; end if;
    v_gain := case e->>'evaluation'
      when 'ganado' then round(r.apuesta*(r.momio-1),2)
      when 'nulo' then 0
      else -r.apuesta end;

    if not p_dry_run then
      update public.picks
         set resultado=e->>'evaluation',ganancia_neta=v_gain,
             score_final=e->>'game_score',confianza_calificacion='NFL_PROP_AUTO_V1',
             updated_at=now()
       where id=r.id and resultado='pendiente';
    end if;

    pick_id:=r.id; apodo:=r.apodo; pick_desc:=r.pick_desc;
    evaluation:=e->>'evaluation'; stat_value:=(e->>'stat_value')::numeric; game_score:=e->>'game_score';
    return next;
  end loop;
end $$;

comment on function v2.eval_nfl_player_prop_v1(text,text,jsonb) is
  'Deterministic NFL prop settlement from canonical event/player/stat; final games only; fail-close on ambiguity/missing stat.';
