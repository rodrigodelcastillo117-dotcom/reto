-- ISS138 — Fantasy Hub V3 league binding + module truth
-- Scope: publication/orchestration only. No model math changes.
-- Root cause:
--   fantasy_week_hub_v3 searched public.lab_ff_ownership for the real league,
--   but production verified league data lives in v2.fantasy_external_roster_snapshot_v1
--   and v2.fantasy_available_snapshot_v1 / league-state tables. This left league_id NULL
--   and falsely reported waivers/playoff/trade modules as blocked despite verified data.
-- Safety:
--   - exact apodo + season binding from verified external roster snapshot
--   - V2 waiver board remains source of waiver truth
--   - playoff module opens only when verified team + matchup state exists
--   - no probability/model changes

create or replace function public.fantasy_week_hub_v3(
  p_apodo text,
  p_season integer,
  p_week integer,
  p_mode text default 'BALANCEADO'::text,
  p_asof timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path to 'public','v2','pg_temp'
as $function$
declare
  ss jsonb;
  cierre jsonb;
  last_grade jsonb;
  v_real_league text;
  v_waivers jsonb;
  v_capture jsonb;
  v_playoff_ready boolean := false;
begin
  ss := v2.fantasy_start_sit_auto_v2(
    p_apodo,p_season,p_week,p_mode,p_asof,'fantasy-b1-rq80-2026.09.1'
  );
  cierre := public.fantasy_cierre_semana(p_week,p_season);
  v_capture := v2.capture_fantasy_recommendation_v3(
    p_apodo,p_season,p_week,p_asof,p_mode
  );
  perform v2.grade_fantasy_recommendations_v3(p_apodo,p_season,null);

  select jsonb_build_object(
    'season',season,
    'week',week,
    'decision_time',decision_time,
    'grading',grading,
    'graded_at',graded_at
  )
  into last_grade
  from v2.fantasy_recommendation_snapshot_v3
  where apodo=p_apodo
    and season=p_season
    and grading is not null
    and week<p_week
  order by week desc,decision_time desc
  limit 1;

  -- Exact user->league binding from a verified provider roster snapshot.
  select league_id
  into v_real_league
  from v2.fantasy_external_roster_snapshot_v1
  where apodo=p_apodo
    and season=p_season
    and source_verified=true
  order by (target_nfl_week=p_week) desc, captured_at desc
  limit 1;

  if v_real_league is null then
    v_waivers := jsonb_build_object(
      'status','LEAGUE_OWNERSHIP_NOT_CONNECTED',
      'recommendations','[]'::jsonb,
      'reason','RETO no adivina quién está libre: conecta/sincroniza ownership real de la liga antes de recomendar waivers.'
    );
  else
    begin
      -- ONE BRAIN waiver truth: consume the canonical V3 waiver board.
      v_waivers := v2.fantasy_waiver_board_v3(
        p_apodo,v_real_league,p_season,p_week,p_asof
      );
    exception when others then
      v_waivers := jsonb_build_object(
        'status','DATA_UNAVAILABLE',
        'recommendations','[]'::jsonb,
        'reason','El board de waivers no pudo calcularse con evidencia suficiente.'
      );
    end;

    -- The external playoff simulator is diagnostic, but it is genuinely available
    -- once verified league teams + verified schedule state exist.
    select exists(
      select 1
      from v2.fantasy_league_state_v1 ls
      where ls.league_id=v_real_league
        and ls.season=p_season
        and ls.source_verified=true
        and exists (
          select 1
          from v2.fantasy_league_team_state_v1 ts
          where ts.state_id=ls.state_id
        )
        and exists (
          select 1
          from v2.fantasy_league_matchup_state_v1 ms
          where ms.state_id=ls.state_id
        )
    ) into v_playoff_ready;
  end if;

  return jsonb_build_object(
    'ok',coalesce((ss->>'ok')::boolean,false),
    'contract_version','fantasy_week_hub_v3',
    'brain','fantasy-b1-rq80-2026.09.1',
    'league_id',v_real_league,
    'start_sit',ss,
    'week_close',cierre,
    'waivers',v_waivers,
    'previous_week_self_grade',coalesce(
      last_grade,
      jsonb_build_object('status','NO_GRADED_RECOMMENDATION_YET')
    ),
    'capture',jsonb_build_object(
      'status',v_capture->>'capture_status',
      'recommendation_id',v_capture->'recommendation_id'
    ),
    'modules',jsonb_build_object(
      'start_sit','READY',
      'floor_median_ceiling','READY',
      'locks','READY',
      'autograding','READY_FORWARD_ONLY',
      'waivers',coalesce(v_waivers->>'status','DATA_UNAVAILABLE'),
      'trade_analyzer','READY',
      'playoff_simulator',case
        when v_playoff_ready then 'READY'
        else 'BLOCKED_UNTIL_LEAGUE_STATE_SYNC'
      end
    ),
    'principles',jsonb_build_object(
      'one_brain',true,
      'k_dst_projection_invented',false,
      'ownership_invented',false,
      'past_recomputed',false
    )
  );
end
$function$;
