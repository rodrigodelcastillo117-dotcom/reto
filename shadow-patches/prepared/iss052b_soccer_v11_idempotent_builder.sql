-- iss052b — replay/idempotence fix for canonical crossleague_v1_1 wrapper
-- On replay the legacy builder emits a temporary crossleague_v1 row. If the canonical
-- crossleague_v1_1 row already exists, discard only the legacy row before refreshing the
-- canonical record. If it does not exist (first run), convert the one legacy row in place.
create or replace function v2.build_soccer_prediction_v2_staged(
  p_decision_time timestamptz,p_enforce_availability boolean default true,p_mapping_version text default null)
returns integer language plpgsql as $$
declare n int;r record;x record;v_sid uuid;v_has_canonical boolean;
begin
  n:=v2.build_soccer_prediction_v2_staged_v1_legacy(p_decision_time,p_enforce_availability,p_mapping_version);

  for r in
    select distinct a.espn_event_id,a.home_espn_id,a.away_espn_id,a.liga_id,
           c.competition_id catalog_competition_id,
           (select s.over_line from v2.soccer_prediction_v2_staged s
             where s.espn_event_id=a.espn_event_id and s.decision_time=p_decision_time
             order by case when s.model_version='crossleague_v1_1' then 0 else 1 end,s.built_at desc limit 1) over_line
    from public.agenda_espn a
    join v2.competition_catalog c
      on c.sport='soccer' and c.provider='espn' and c.provider_competition_id=a.liga_id::text
    join v2.crossleague_competition_policy cp
      on cp.competition_id=c.competition_id and cp.status='PROD_APPROVED' and cp.model_version='crossleague_v1_1'
    where a.deporte='soccer' and a.fecha>p_decision_time
  loop
    select * into x
    from v2.fn_crossleague_v11_staged(r.home_espn_id,r.away_espn_id,p_decision_time,r.catalog_competition_id,r.over_line);

    select exists(select 1 from v2.soccer_prediction_v2_staged s
      where s.espn_event_id=r.espn_event_id and s.decision_time=p_decision_time
        and s.model_version='crossleague_v1_1') into v_has_canonical;

    if v_has_canonical then
      delete from v2.soccer_prediction_v2_staged s
      where s.espn_event_id=r.espn_event_id and s.decision_time=p_decision_time
        and s.model_version<>'crossleague_v1_1';
    else
      update v2.soccer_prediction_v2_staged s
         set model_version='crossleague_v1_1'
       where s.espn_event_id=r.espn_event_id and s.decision_time=p_decision_time
         and s.model_version<>'crossleague_v1_1';
    end if;

    v_sid:=null;
    if x.gf_home is not null and x.gf_away is not null then
      insert into v2.feature_snapshot(espn_event_id,decision_time,home_gf,home_gc,away_gf,away_gc,
        sample_home,sample_away,feature_data_asof,max_source_event_time,feature_version,
        phi_home,phi_away,phi_model_version,phi_training_cutoff,phi_config_hash)
      values(r.espn_event_id,p_decision_time,x.gf_home,x.ga_home,x.gf_away,x.ga_away,
        x.sample_home,x.sample_away,x.data_asof,x.data_asof,'domestic_form_phi_v1_1',
        x.phi_home,x.phi_away,'crossleague_v1_1',x.training_cutoff,x.config_hash)
      on conflict (espn_event_id,decision_time,feature_version) do nothing;
      select feature_snapshot_id into v_sid from v2.feature_snapshot
       where espn_event_id=r.espn_event_id and decision_time=p_decision_time
         and feature_version='domestic_form_phi_v1_1';
    end if;

    update v2.soccer_prediction_v2_staged s set
      model_name='reto_crossleague',model_route='CROSSLEAGUE',model_version='crossleague_v1_1',
      feature_version='domestic_form_phi_v1_1',calibration_status='OOS_VALIDATED',
      feature_data_asof=x.data_asof,max_source_event_time=x.data_asof,
      sample_home=x.sample_home,sample_away=x.sample_away,
      temporal_safe=(x.model_status='READY_UNVALIDATED' and x.data_asof<=p_decision_time and x.loaded_asof<=p_decision_time),
      p_home=case when x.model_status='READY_UNVALIDATED' then x.p_home end,
      p_draw=case when x.model_status='READY_UNVALIDATED' then x.p_draw end,
      p_away=case when x.model_status='READY_UNVALIDATED' then x.p_away end,
      btts_yes=case when x.model_status='READY_UNVALIDATED' then x.btts_yes end,
      btts_no=case when x.model_status='READY_UNVALIDATED' then x.btts_no end,
      p_over=case when x.model_status='READY_UNVALIDATED' then x.p_over end,
      p_under=case when x.model_status='READY_UNVALIDATED' then x.p_under end,
      p_push=case when x.model_status='READY_UNVALIDATED' then x.p_push end,
      ou_line_type=case when x.model_status='READY_UNVALIDATED' then x.ou_line_type end,
      ou_supported=case when x.model_status='READY_UNVALIDATED' then x.ou_supported end,
      score_dist=case when x.model_status='READY_UNVALIDATED' then x.score_dist end,
      top_scores=case when x.model_status='READY_UNVALIDATED' then x.top_scores end,
      model_status=x.model_status,model_status_reason=x.model_status_reason,
      provenance=coalesce(x.provenance,'{}'::jsonb)||jsonb_build_object('model_route','CROSSLEAGUE','canonical_brain',true),
      availability_verified=true,feature_snapshot_id=v_sid,built_at=now()
    where s.espn_event_id=r.espn_event_id and s.decision_time=p_decision_time
      and s.model_version='crossleague_v1_1';
  end loop;

  return n;
end $$;
