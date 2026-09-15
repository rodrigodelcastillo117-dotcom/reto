-- ============================================================================
-- iss038 v2 TEST — contrato canónico de parlay por-pata + fail-close (§25)
--   AUDIT 5609355379 (per-leg server-side resolution).
-- Requiere iss038 v2 (fn_parlay_leg_canonical + v_parlay_canonical_contract) +
--   v2.soccer_prediction_v2_staged. Branch-only. Siembra y limpia sus fixtures.
-- Cubre: 1X2/OU/BTTS exactos; OU línea mismatch => fail-close (sin sustituir);
--   BTTS No sólo explícito; NO_MODEL; NO_CANONICAL_MATCH; parse de pick_desc no
--   estructurado; O/U line_asof>decision => fail-close temporal; joint NULL;
--   contrato visible SIN ai_prob_combinada; set canónico por-pata completo.
-- ============================================================================
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('1001','1002','1003','1005','9999');
delete from public.parlays where apodo='iss038_test';

insert into v2.soccer_prediction_v2_staged
 (espn_event_id, competition_id, home_team, away_team, kickoff, decision_time, feature_data_asof,
  max_source_event_time, sample_home, sample_away, temporal_safe, feature_version, model_version,
  calibration_status, p_home, p_draw, p_away, btts_yes, btts_no, over_line, p_over, p_under,
  line_source, line_asof, model_status, model_status_reason, provenance, feature_snapshot_id, built_at)
values
 ('1001',197,'H','A',   timestamptz '2026-09-09 18:00+00', timestamptz '2026-09-09 12:00+00',
  timestamptz '2026-09-08 12:00+00', timestamptz '2026-09-07 00:00+00',12,11,true,'dc-2026.09.1','dc-2026.09.1',
  'UNVALIDATED',55,25,20,60,40,3.5,45,55,'provider',timestamptz '2026-09-09 10:00+00','MODEL_ACTIVE',null,
  '{"line":"CONTEXT_ONLY"}'::jsonb, gen_random_uuid(), now()),
 ('1002',999,'H2','A2', timestamptz '2026-09-09 18:00+00', timestamptz '2026-09-09 12:00+00',
  timestamptz '2026-09-08 12:00+00', timestamptz '2026-09-07 00:00+00',3,2,true,'dc-2026.09.1','dc-2026.09.1',
  'UNVALIDATED',null,null,null,null,null,null,null,null,null,null,'NO_MODEL','UNSUPPORTED_LEAGUE','{}'::jsonb, gen_random_uuid(), now()),
 ('1003',197,'H3','A3', timestamptz '2026-09-09 18:00+00', timestamptz '2026-09-09 12:00+00',
  timestamptz '2026-09-08 12:00+00', timestamptz '2026-09-07 00:00+00',10,10,true,'dc-2026.09.1','dc-2026.09.1',
  'UNVALIDATED',50,30,20,55,null,2.5,50,50,'provider',timestamptz '2026-09-09 10:00+00','MODEL_ACTIVE',null,'{}'::jsonb, gen_random_uuid(), now()),
 ('1005',197,'H5','A5', timestamptz '2026-09-09 18:00+00', timestamptz '2026-09-09 12:00+00',
  timestamptz '2026-09-08 12:00+00', timestamptz '2026-09-07 00:00+00',10,10,true,'dc-2026.09.1','dc-2026.09.1',
  'UNVALIDATED',48,27,25,58,42,3.5,44,56,'provider',timestamptz '2026-09-09 13:00+00','MODEL_ACTIVE',null,'{}'::jsonb, gen_random_uuid(), now());

insert into public.parlays (id, apodo, fecha, created_at, ai_prob_combinada, picks_data)
values (gen_random_uuid(),'iss038_test',date '2026-09-09',timestamptz '2026-09-09 12:00+00',0.42,
 jsonb_build_array(
   jsonb_build_object('espn_event_id','1001','mercado','1X2','lado','home','pick_desc','Gana Local'),
   jsonb_build_object('espn_event_id','1001','mercado','OU','lado','over','linea','3.5','pick_desc','Over 3.5'),
   jsonb_build_object('espn_event_id','1001','mercado','OU','lado','over','linea','2.5','pick_desc','Over 2.5'),
   jsonb_build_object('espn_event_id','1001','mercado','BTTS','lado','no','pick_desc','BTTS No'),
   jsonb_build_object('espn_event_id','1003','mercado','BTTS','lado','no','pick_desc','BTTS No'),
   jsonb_build_object('espn_event_id','1002','mercado','1X2','lado','home','pick_desc','Gana Local'),
   jsonb_build_object('espn_event_id','9999','mercado','1X2','lado','home','pick_desc','Gana Local'),
   jsonb_build_object('espn_event_id','1001','pick_desc','Over 3.5 goles'),
   jsonb_build_object('espn_event_id','1005','mercado','OU','lado','over','linea','3.5','pick_desc','Over 3.5')
 ));

do $$
declare v record; legs jsonb; l jsonb;
begin
  select * into v from v2.v_parlay_canonical_contract where apodo='iss038_test';
  if v.joint_probability is not null then raise exception 'FAIL: joint_probability no NULL'; end if;
  legs := v.legs;
  l:=legs->0; if (l->>'p_reto')::numeric is distinct from 55 then raise exception 'FAIL leg0'; end if;
  l:=legs->1; if (l->>'p_reto')::numeric is distinct from 45 then raise exception 'FAIL leg1'; end if;
  l:=legs->2; if l->>'p_reto' is not null or l->>'unavailable_reason'<>'OU_LINE_MISMATCH' then raise exception 'FAIL leg2 %',l; end if;
  l:=legs->3; if (l->>'p_reto')::numeric is distinct from 40 then raise exception 'FAIL leg3'; end if;
  l:=legs->4; if l->>'p_reto' is not null or l->>'unavailable_reason'<>'BTTS_NO_NOT_EXPLICIT' then raise exception 'FAIL leg4 %',l; end if;
  l:=legs->5; if l->>'p_reto' is not null or l->>'unavailable_reason'<>'UNSUPPORTED_LEAGUE' then raise exception 'FAIL leg5 %',l; end if;
  l:=legs->6; if l->>'p_reto' is not null or l->>'unavailable_reason'<>'NO_CANONICAL_MATCH' then raise exception 'FAIL leg6 %',l; end if;
  l:=legs->7; if (l->>'p_reto')::numeric is distinct from 45 then raise exception 'FAIL leg7 desc-parse %',l; end if;
  l:=legs->8; if l->>'p_reto' is not null or l->>'unavailable_reason'<>'OU_LINE_AFTER_DECISION' then raise exception 'FAIL leg8 %',l; end if;
  for l in select * from jsonb_array_elements(legs) loop
    if l->>'p_reto' is not null and coalesce((l->>'temporal_ok')::boolean,false) is not true then
      raise exception 'FAIL temporal: %', l; end if;
    if not (l ? 'canonical_event_id' and l ? 'canonical_market' and l ? 'canonical_side' and l ? 'canonical_line'
            and l ? 'p_reto' and l ? 'model_status' and l ? 'model_version' and l ? 'model_snapshot_id'
            and l ? 'provenance' and l ? 'unavailable_reason') then
      raise exception 'FAIL set canónico incompleto: %', l; end if;
  end loop;
  raise notice 'PASS iss038 v2';
end $$;

-- contrato visible no expone ai_prob_combinada
do $$ begin
  if exists(select 1 from information_schema.columns
    where table_schema='v2' and table_name='v_parlay_canonical_contract' and column_name ilike '%ai_prob%')
  then raise exception 'FAIL: ai_prob_combinada visible en contrato'; end if;
end $$;

delete from v2.soccer_prediction_v2_staged where espn_event_id in ('1001','1002','1003','1005','9999');
delete from public.parlays where apodo='iss038_test';
