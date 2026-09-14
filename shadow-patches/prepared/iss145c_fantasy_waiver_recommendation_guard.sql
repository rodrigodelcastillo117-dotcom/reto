-- ISS145c: do not recommend cross-position depth swaps as if they were lineup gains.
create or replace function v2.fantasy_waiver_board_v3(p_apodo text,p_league_id text,p_season integer,p_week integer,p_asof timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path=public,v2,pg_temp as $$
declare v_roster jsonb; v_players jsonb; v_current jsonb; v_current_total numeric; v_capture timestamptz; v_rows jsonb:='[]'::jsonb; c record; d record; v_after jsonb; v_after_total numeric; v_best_total numeric; v_best_drop text; v_best_drop_name text; v_best_drop_proj numeric; v_cand_proj numeric; v_cand_floor numeric; v_cand_ceiling numeric; v_n integer; v_quality text; v_status text; v_new_players jsonb;
begin
 select v2.fn_fantasy_roster_canonicalize_v1(r.jugadores,p_season,p_week) into v_roster from public.fantasy_roster_semanal r where r.apodo=p_apodo and r.temporada=p_season and r.semana<=p_week order by r.semana desc,r.guardado_at desc limit 1;
 if v_roster is null then return jsonb_build_object('ok',false,'status','ROSTER_NOT_FOUND'); end if;
 select jsonb_agg(jsonb_build_object('espn_player_id',x->>'espn_player_id','name',coalesce(x->>'nombre',x->>'name'),'position',v2.fn_fantasy_pos_norm(coalesce(x->>'posicion',x->>'position','')))) into v_players from jsonb_array_elements(v_roster) x where nullif(x->>'espn_player_id','') is not null and v2.fn_fantasy_pos_norm(coalesce(x->>'posicion',x->>'position','')) in ('QB','RB','WR','TE');
 v_current:=v2.fantasy_lineup_eval_v3(v_players,p_season,p_week,p_asof); v_current_total:=nullif(v_current->>'lineup_total','')::numeric;
 if coalesce((v_current->>'complete')::boolean,false)=false then return jsonb_build_object('ok',true,'status','CURRENT_LINEUP_INCOMPLETE','current',v_current); end if;
 select max(captured_at) into v_capture from v2.fantasy_available_snapshot_v1 where league_id=p_league_id and season=p_season and week=p_week and source_verified;
 if v_capture is null then return jsonb_build_object('ok',true,'status','AVAILABILITY_NOT_CONNECTED','league_id',p_league_id); end if;
 for c in select distinct on (coalesce(espn_player_id,provider_player_id)) * from v2.fantasy_available_snapshot_v1 where league_id=p_league_id and season=p_season and week=p_week and captured_at=v_capture and source_verified order by coalesce(espn_player_id,provider_player_id),id desc loop
  if c.espn_player_id is null or v2.fn_fantasy_pos_norm(coalesce(c.position,'')) not in ('QB','RB','WR','TE') then v_rows:=v_rows||jsonb_build_array(jsonb_build_object('player',c.player_name,'position',c.position,'team',c.team,'provider_player_id',c.provider_player_id,'status','IDENTITY_OR_POSITION_UNSUPPORTED','recommended',false)); continue; end if;
  select p.projected_mean,p.floor_points,p.ceiling_points,p.n_history,p.quality_flag,p.model_status into v_cand_proj,v_cand_floor,v_cand_ceiling,v_n,v_quality,v_status from v2.fn_fantasy_project_b1_rq80_v2(c.espn_player_id,v2.fn_fantasy_pos_norm(c.position),p_season,p_week,p_asof) p;
  if v_status is distinct from 'READY' then v_rows:=v_rows||jsonb_build_array(jsonb_build_object('player',c.player_name,'position',c.position,'team',c.team,'espn_player_id',c.espn_player_id,'status',coalesce(v_status,'MODEL_UNAVAILABLE'),'recommended',false,'model_version','fantasy-b1-rq80-2026.09.1')); continue; end if;
  v_best_total:=null; v_best_drop:=null; v_best_drop_name:=null; v_best_drop_proj:=null;
  for d in select x->>'espn_player_id' espn_player_id,x->>'name' player_name,x->>'position' pos from jsonb_array_elements(v_players) x loop
   select coalesce(jsonb_agg(e),'[]'::jsonb)||jsonb_build_array(jsonb_build_object('espn_player_id',c.espn_player_id,'name',c.player_name,'position',v2.fn_fantasy_pos_norm(c.position))) into v_new_players from jsonb_array_elements(v_players) e where e->>'espn_player_id'<>d.espn_player_id;
   v_after:=v2.fantasy_lineup_eval_v3(v_new_players,p_season,p_week,p_asof);
   if coalesce((v_after->>'complete')::boolean,false) then v_after_total:=nullif(v_after->>'lineup_total','')::numeric; if v_best_total is null or v_after_total>v_best_total then v_best_total:=v_after_total; v_best_drop:=d.espn_player_id; v_best_drop_name:=d.player_name; select p.projected_mean into v_best_drop_proj from v2.fn_fantasy_project_b1_rq80_v2(d.espn_player_id,d.pos,p_season,p_week,p_asof) p; end if; end if;
  end loop;
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
    'player',c.player_name,'position',v2.fn_fantasy_pos_norm(c.position),'team',c.team,'espn_player_id',c.espn_player_id,'provider_player_id',c.provider_player_id,
    'acquisition_state',c.acquisition_state,'projection',v_cand_proj,'floor',v_cand_floor,'ceiling',v_cand_ceiling,'n_history',v_n,'quality_flag',v_quality,
    'drop_player',v_best_drop_name,'drop_player_id',v_best_drop,'drop_projection',v_best_drop_proj,'lineup_before',v_current_total,'lineup_after',v_best_total,
    'lineup_delta',round(coalesce(v_best_total,v_current_total)-v_current_total,2),
    'status',case when v_quality='LOW_SAMPLE' then 'CAUTION_LOW_SAMPLE' when coalesce(v_best_total,v_current_total)-v_current_total>=0.50 then 'STARTER_UPGRADE' else 'WATCHLIST_ONLY' end,
    'recommended',(v_quality<>'LOW_SAMPLE' and coalesce(v_best_total,v_current_total)-v_current_total>=0.50),
    'model_version','fantasy-b1-rq80-2026.09.1'));
 end loop;
 return jsonb_build_object('ok',true,'status','READY','contract_version','fantasy_waiver_board_v3','league_id',p_league_id,'season',p_season,'week',p_week,'availability_snapshot_at',v_capture,'current_lineup',v_current,'candidates',(select coalesce(jsonb_agg(x order by coalesce((x->>'recommended')::boolean,false) desc,coalesce((x->>'lineup_delta')::numeric,-999) desc,x->>'player'),'[]'::jsonb) from jsonb_array_elements(v_rows) x),'principles',jsonb_build_object('one_brain','fantasy-b1-rq80-2026.09.1','verified_availability_only',true,'cold_start_invented',false,'cross_position_depth_recommendation',false,'acquisition_subtype_invented',false));
end $$;