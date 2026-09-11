-- ============================================================================
-- run_mlb_contract_gate.sql — ADVERSARIAL gate for iss052 (MLB decision contract)
-- ============================================================================
-- Evidence goes into v2.gate_run_log and is then SELECTed, because RAISE NOTICE output is
-- dropped by the MCP channel this branch is driven through. A stage that cannot prove its
-- claim is logged FAIL; the caller asserts that zero FAIL rows exist.
--
-- Decision epoch D0 (variable name D0 because DEC is a SQL keyword) = 2026-09-10 22:50:00+00. Chosen because it is strictly AFTER every
-- seeded odds snapshot (22:30..22:49Z, so the market path is live) and strictly BEFORE every
-- seeded first pitch (23:05Z onward, so every snapshot is legal). Stage 0 asserts both facts
-- rather than assuming them.
--
-- Replay epoch EARLY = 2026-07-20 12:00:00+00 exists to prove the as-of feature read is real:
-- a model that secretly reads current state would return the SAME lambdas at both epochs.
-- ============================================================================
create table if not exists v2.gate_run_log (
  run_id uuid not null, stage text not null, seq int not null,
  status text not null, metric text, detail text,
  logged_at timestamptz not null default now(),
  primary key (run_id, stage, seq)
);

do $gate$
declare
  RUN   constant uuid        := gen_random_uuid();
  D0    constant timestamptz := timestamptz '2026-09-10 22:50:00+00';
  LATER constant timestamptz := timestamptz '2026-09-11 00:00:00+00';
  EARLY constant timestamptz := timestamptz '2026-07-20 12:00:00+00';
  s int := 0;
  n int; n2 int; n3 int;
  t1 timestamptz; t2 timestamptz;
  txt1 text; txt2 text;
  num1 numeric; num2 numeric; num3 numeric;
  caught text;
begin
  insert into v2.gate_run_log values (RUN,'S_RUN_HEADER',0,'INFO',
    'run_id='||RUN::text, 'decision='||D0::text||' later='||LATER::text||' early='||EARLY::text);

  -- ══ STAGE 0: epoch sanity — the two facts the whole run depends on ══════════
  s := s + 1;
  select count(*) into n  from public.v_momios_confiables where snapshot_at > D0;
  select count(*) into n2 from public.agenda_espn where deporte='baseball' and fecha <= D0;
  insert into v2.gate_run_log values (RUN,'S0_EPOCH_SANITY',s,
    case when n=0 and n2=0 then 'PASS' else 'FAIL' end,
    format('odds_after_decision=%s fixtures_already_started=%s', n, n2),
    'la epoca de decision debe dejar TODOS los momios disponibles y NINGUN juego iniciado');

  -- ══ STAGE 1: the universe was built and every row is pre-first-pitch ════════
  s := s + 1;
  select count(*) into n  from v2.mlb_prediction_snapshot where decision_time = D0;
  select count(*) into n2 from v2.mlb_prediction_snapshot where decision_time >= scheduled_at;
  select count(*) into n3 from v2.mlb_prediction_snapshot
    where decision_time = D0 and model_status = 'READY_UNVALIDATED' and asof_proven;
  insert into v2.gate_run_log values (RUN,'S1_UNIVERSE',s,
    case when n=30 and n2=0 and n3=30 then 'PASS' else 'FAIL' end,
    format('snapshots=%s post_first_pitch=%s ready_and_asof_proven=%s', n, n2, n3),
    'se esperaban 30 snapshots, CERO con decision_time >= scheduled_at, y 30 READY con as-of probado');

  -- ══ STAGE 2: THE STOP-SHIP FIX — post-first-pitch snapshot is UNSTORABLE ════
  -- iss016's writer window reached 3h PAST first pitch and its canonical view then served
  -- that row as P_RETO. Here the database itself must refuse the write.
  s := s + 1;
  caught := null;
  begin
    insert into v2.mlb_prediction_snapshot
      (espn_event_id, decision_time, model_version, scheduled_at, model_status)
    values ('401816883', timestamptz '2026-09-10 23:30:00+00', 'mlb-2026.09.1',
            timestamptz '2026-09-10 23:05:00+00', 'READY_UNVALIDATED');
    caught := 'NO_ERROR_RAISED';
  exception when check_violation then caught := 'check_violation';
            when others then caught := 'other:'||SQLSTATE;
  end;
  insert into v2.gate_run_log values (RUN,'S2_POST_FIRST_PITCH_REJECTED',s,
    case when caught='check_violation' then 'PASS' else 'FAIL' end, 'outcome='||caught,
    'insert 25 min DESPUES del primer pitcheo debe violar mlb_pred_snapshot_pre_first_pitch');

  s := s + 1;
  caught := null;
  begin
    insert into v2.mlb_prediction_snapshot
      (espn_event_id, decision_time, model_version, scheduled_at, model_status)
    values ('401816883', timestamptz '2026-09-10 23:05:00+00', 'mlb-2026.09.1',
            timestamptz '2026-09-10 23:05:00+00', 'READY_UNVALIDATED');
    caught := 'NO_ERROR_RAISED';
  exception when check_violation then caught := 'check_violation';
            when others then caught := 'other:'||SQLSTATE;
  end;
  insert into v2.gate_run_log values (RUN,'S2B_AT_FIRST_PITCH_REJECTED',s,
    case when caught='check_violation' then 'PASS' else 'FAIL' end, 'outcome='||caught,
    'decision_time = scheduled_at tambien se rechaza (la desigualdad es estricta)');

  -- ══ STAGE 3: the BUILDER excludes already-started games from the universe ═══
  s := s + 1;
  perform v2.build_mlb_prediction_snapshot(LATER, true);
  select count(*) into n  from v2.mlb_prediction_snapshot where decision_time = LATER;
  select count(*) into n2 from v2.mlb_prediction_snapshot
    where decision_time = LATER and espn_event_id in ('401816883','401816886');
  insert into v2.gate_run_log values (RUN,'S3_STARTED_GAMES_EXCLUDED',s,
    case when n=28 and n2=0 then 'PASS' else 'FAIL' end,
    format('snapshots_at_later_epoch=%s started_games_present=%s', n, n2),
    '401816883 (23:05Z) y 401816886 (23:40Z) ya iniciaron a las 00:00Z: fuera del universo');

  -- ══ STAGE 4: APPEND-ONLY enforced, not merely documented ════════════════════
  s := s + 1;
  caught := null;
  begin
    update v2.mlb_prediction_snapshot set p_home_ml = 99.9
     where espn_event_id='401816883' and decision_time = D0;
    caught := 'NO_ERROR_RAISED';
  exception when others then caught := 'blocked';
  end;
  insert into v2.gate_run_log values (RUN,'S4_UPDATE_BLOCKED',s,
    case when caught='blocked' then 'PASS' else 'FAIL' end, 'outcome='||caught,
    'UPDATE sobre un snapshot de decision debe ser imposible');

  s := s + 1;
  caught := null;
  begin
    delete from v2.mlb_prediction_snapshot where espn_event_id='401816883' and decision_time = D0;
    caught := 'NO_ERROR_RAISED';
  exception when others then caught := 'blocked';
  end;
  insert into v2.gate_run_log values (RUN,'S4B_DELETE_BLOCKED',s,
    case when caught='blocked' then 'PASS' else 'FAIL' end, 'outcome='||caught,
    'DELETE sobre un snapshot de decision debe ser imposible (es historia, no estado)');

  s := s + 1;
  caught := null;
  begin
    update v2.mlb_model_config set readiness_floor = 0.01
     where sport='baseball' and model_version='mlb-2026.09.1';
    caught := 'NO_ERROR_RAISED';
  exception when others then caught := 'blocked';
  end;
  select readiness_floor into num1 from v2.mlb_model_config
   where sport='baseball' and model_version='mlb-2026.09.1';
  insert into v2.gate_run_log values (RUN,'S4C_CONFIG_DRIFT_BLOCKED',s,
    case when caught='blocked' and num1=0.60 then 'PASS' else 'FAIL' end,
    format('outcome=%s readiness_floor_still=%s', caught, num1),
    'bajar readiness_floor en caliente para forzar READY debe ser imposible sin nuevo model_version');

  -- ══ STAGE 5: every published market derives from the ONE persisted run_dist ══
  s := s + 1;
  select count(*) into n  from v2.v_mlb_event_gate where decision_time = D0;
  select count(*) into n2 from v2.v_mlb_event_gate where decision_time = D0 and coherence_ok is not true;
  insert into v2.gate_run_log values (RUN,'S5_COHERENCE',s,
    case when n=30 and n2=0 then 'PASS' else 'FAIL' end,
    format('gated=%s incoherent=%s', n, n2),
    'el gate recomputa ML / O-U / top-5 desde run_dist con fn_matrix_market: 0 incoherentes');

  -- independent recomputation OUTSIDE the gate function
  s := s + 1;
  select count(*) into n from (
    select sn.espn_event_id, sn.total_line, sn.p_home_ml, sn.p_away_ml, sn.p_over, sn.p_under, sn.p_push,
           v2.fn_matrix_market(sn.run_dist,'1X2','HOME') mh,
           v2.fn_matrix_market(sn.run_dist,'1X2','AWAY') ma,
           case when sn.total_line is not null then v2.fn_matrix_market(sn.run_dist,'OU','OVER',  sn.total_line) end mo,
           case when sn.total_line is not null then v2.fn_matrix_market(sn.run_dist,'OU','UNDER', sn.total_line) end mu,
           case when sn.total_line is not null then v2.fn_matrix_market(sn.run_dist,'OU','PUSH',  sn.total_line) end mp
    from v2.mlb_prediction_snapshot sn where sn.decision_time = D0
  ) z
  where abs(p_home_ml - round(100*mh/(mh+ma),1)) > 0.2
     or abs(p_away_ml - round(100*ma/(mh+ma),1)) > 0.2
     or (total_line is not null and (abs(p_over - mo) > 0.2 or abs(p_under - mu) > 0.2 or abs(p_push - mp) > 0.2));
  insert into v2.gate_run_log values (RUN,'S5B_INDEPENDENT_RECOMPUTE',s,
    case when n=0 then 'PASS' else 'FAIL' end, format('mismatches=%s', n),
    'recalculo independiente: ML, OVER, UNDER y PUSH deben reproducirse desde run_dist');

  -- WHOLE lines carry real push mass; HALF lines carry exactly zero
  s := s + 1;
  select count(*) into n from v2.mlb_prediction_snapshot
   where decision_time = D0 and total_line is not null
     and ((ou_line_type='WHOLE' and coalesce(p_push,0) <= 0)
       or (ou_line_type='HALF'  and coalesce(p_push,-1) <> 0));
  select count(*) into n2 from v2.mlb_prediction_snapshot
   where decision_time = D0 and ou_line_type='WHOLE';
  insert into v2.gate_run_log values (RUN,'S5C_PUSH_SEMANTICS',s,
    case when n=0 and n2>0 then 'PASS' else 'FAIL' end,
    format('violations=%s whole_line_events=%s', n, n2),
    'WHOLE => push>0; HALF => push=0 (primitivo fn_total_weights compartido con soccer)');

  -- the matrix itself must sum to exactly 100 on every published row
  s := s + 1;
  select count(*) into n from v2.mlb_prediction_snapshot sn
   where sn.decision_time = D0 and sn.run_dist is not null
     and (select round(sum((c->>'p')::numeric),2) from jsonb_array_elements(sn.run_dist) c) <> 100.00;
  insert into v2.gate_run_log values (RUN,'S5D_MATRIX_SUMS_100',s,
    case when n=0 then 'PASS' else 'FAIL' end, format('rows_not_summing_100=%s', n),
    'la distribucion persistida debe sumar EXACTAMENTE 100.00 (residual doblado en la celda modal)');

  -- ══ STAGE 6: market ABSENCE is a diagnostic, never a fabricated edge ════════
  s := s + 1;
  select count(*) into n  from v2.v_mlb_event_gate
   where decision_time = D0 and disc_flag = 'NO_MARKET_DIAGNOSTIC';
  select count(*) into n2 from v2.v_mlb_event_gate
   where decision_time = D0 and disc_flag = 'NO_MARKET_DIAGNOSTIC' and suppress;
  insert into v2.gate_run_log values (RUN,'S6_NO_MARKET_DIAGNOSTIC',s,
    case when n=20 and n2=0 then 'PASS' else 'FAIL' end,
    format('no_market=%s of_which_suppressed=%s', n, n2),
    '20 de 30 fixtures reales no tienen momios: NO_MARKET_DIAGNOSTIC y NO suprimidos');

  -- ══ STAGE 7: REPLAY IDEMPOTENCE — same epoch, byte-identical output ═════════
  s := s + 1;
  select md5(string_agg(espn_event_id||'|'||coalesce(p_home_ml::text,'-')||'|'||coalesce(p_over::text,'-')
             ||'|'||coalesce(run_dist::text,'-'), ';' order by espn_event_id))
    into txt1 from v2.mlb_prediction_snapshot where decision_time = D0;
  perform v2.build_mlb_prediction_snapshot(D0, true);
  select md5(string_agg(espn_event_id||'|'||coalesce(p_home_ml::text,'-')||'|'||coalesce(p_over::text,'-')
             ||'|'||coalesce(run_dist::text,'-'), ';' order by espn_event_id))
    into txt2 from v2.mlb_prediction_snapshot where decision_time = D0;
  select count(*) into n from v2.mlb_prediction_snapshot where decision_time = D0;
  insert into v2.gate_run_log values (RUN,'S7_REPLAY_IDEMPOTENT',s,
    case when txt1 = txt2 and n = 30 then 'PASS' else 'FAIL' end,
    format('md5=%s rows_after_replay=%s', txt1, n),
    're-ejecutar el builder en la MISMA epoca no cambia un byte ni duplica filas');

  -- ══ STAGE 8: AS-OF is real — an earlier decision gets EARLIER data ══════════
  s := s + 1;
  perform v2.build_mlb_prediction_snapshot(EARLY, true);
  select count(*) into n from v2.mlb_prediction_snapshot where decision_time = EARLY;
  select count(*) into n2
    from v2.mlb_prediction_snapshot a
    join v2.mlb_prediction_snapshot b
      on b.espn_event_id = a.espn_event_id and b.decision_time = D0
   where a.decision_time = EARLY
     and a.lambda_home = b.lambda_home and a.lambda_away = b.lambda_away;
  select max(data_asof) into t1 from v2.mlb_prediction_snapshot where decision_time = EARLY;
  select max(data_asof) into t2 from v2.mlb_prediction_snapshot where decision_time = D0;
  insert into v2.gate_run_log values (RUN,'S8_ASOF_IS_REAL',s,
    case when n=30 and n2=0 and t1 < t2 and t1 < EARLY then 'PASS' else 'FAIL' end,
    format('early_snapshots=%s identical_lambdas=%s early_asof=%s dec_asof=%s', n, n2, t1, t2),
    'replay anterior usa observaciones anteriores: 0 lambdas identicas y data_asof estrictamente menor');

  s := s + 1;
  select count(*) into n  from v2.mlb_prediction_snapshot where data_asof > decision_time;
  select count(*) into n2 from v2.mlb_feature_snapshot    where data_asof > decision_time;
  insert into v2.gate_run_log values (RUN,'S8B_NO_FUTURE_LEAK',s,
    case when n=0 and n2=0 then 'PASS' else 'FAIL' end,
    format('pred_leaks=%s feature_leaks=%s', n, n2),
    'data_asof > decision_time es fuga temporal: CERO en ambas tablas');

  -- ══ STAGE 9: CANONICAL READ is clock-independent ════════════════════════════
  s := s + 1;
  select md5(string_agg(canonical_event_id||'|'||decision_time::text||'|'||coalesce(p_home_ml::text,'-'), ';'
             order by canonical_event_id)) into txt1 from v2.fn_mlb_canonical_board(D0);
  select md5(string_agg(canonical_event_id||'|'||decision_time::text||'|'||coalesce(p_home_ml::text,'-'), ';'
             order by canonical_event_id)) into txt2 from v2.fn_mlb_canonical_board(D0);
  select decision_time into t1 from v2.fn_mlb_prediction_asof('401816883', EARLY + interval '1 day');
  select decision_time into t2 from v2.fn_mlb_prediction_asof('401816883', D0);
  insert into v2.gate_run_log values (RUN,'S9_CLOCK_INDEPENDENT_READ',s,
    case when txt1 = txt2 and t1 = EARLY and t2 = D0 then 'PASS' else 'FAIL' end,
    format('board_md5=%s pick_at_early=%s pick_at_dec=%s', txt1, t1, t2),
    'misma p_asof => misma respuesta; p_asof anterior => decision anterior, no la posterior');

  s := s + 1;
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='v2' and p.proname in ('fn_mlb_canonical_board','fn_mlb_prediction_asof')
     and pg_get_functiondef(p.oid) ~* 'now[[:space:]]*\(';
  insert into v2.gate_run_log values (RUN,'S9B_NO_NOW_IN_CANONICAL',s,
    case when n=0 then 'PASS' else 'FAIL' end, format('functions_using_now=%s', n),
    'la lectura canonica no puede depender del reloj de pared (defecto 6 de iss016)');

  -- ══ STAGE 10: ONE P_RETO ════════════════════════════════════════════════════
  s := s + 1;
  select count(*) into n  from v2.v_mlb_snapshot_identity_violations;
  select count(*) into n2 from v2.v_mlb_post_first_pitch_violations;
  insert into v2.gate_run_log values (RUN,'S10_ONE_PRETO',s,
    case when n=0 and n2=0 then 'PASS' else 'FAIL' end,
    format('identity_violations=%s post_first_pitch_violations=%s', n, n2),
    'un solo snapshot por (evento, decision_time) y cero filas post-primer-pitcheo');

  -- ══ STAGE 11: candidates only from eligible, coherent events ════════════════
  s := s + 1;
  select count(*) into n  from v2.v_mlb_daily_candidates where decision_time = D0;
  select count(distinct canonical_event_id) into n2 from v2.v_mlb_daily_candidates where decision_time = D0;
  select count(*) into n3 from v2.v_mlb_daily_candidates c
   where c.decision_time = D0
     and not exists (select 1 from v2.v_mlb_event_gate g
                     where g.canonical_event_id = c.canonical_event_id
                       and g.decision_time = c.decision_time and g.top_only_eligible);
  insert into v2.gate_run_log values (RUN,'S11_CANDIDATES',s,
    case when n3=0 and n>0 then 'PASS' else 'FAIL' end,
    format('legs=%s events=%s ineligible_leaked=%s', n, n2, n3),
    'ninguna pata puede existir para un evento no elegible en el gate');

  -- every leg probability must match the snapshot it claims to come from
  s := s + 1;
  select count(*) into n from v2.v_mlb_daily_candidates c
    join v2.mlb_prediction_snapshot sn
      on sn.espn_event_id = c.canonical_event_id and sn.decision_time = c.decision_time
     and sn.model_version = c.model_version
   where c.decision_time = D0
     and c.canonical_probability is distinct from case
           when c.canonical_market='ML' and c.canonical_side='HOME'  then sn.p_home_ml
           when c.canonical_market='ML' and c.canonical_side='AWAY'  then sn.p_away_ml
           when c.canonical_market='OU' and c.canonical_side='OVER'  then sn.p_over
           when c.canonical_market='OU' and c.canonical_side='UNDER' then sn.p_under end;
  insert into v2.gate_run_log values (RUN,'S11B_LEG_PROB_TRACEABLE',s,
    case when n=0 then 'PASS' else 'FAIL' end, format('untraceable_legs=%s', n),
    'cada pata debe ser exactamente el escalar del snapshot, no una recopia divergente');

  -- ══ STAGE 12: WALK-FORWARD refuses to report without outcomes ═══════════════
  s := s + 1;
  select verdict, n_scored into txt1, n
    from v2.fn_mlb_walk_forward(D0 - interval '1 day', D0 + interval '1 day');
  insert into v2.gate_run_log values (RUN,'S12_WF_NO_OUTCOMES',s,
    case when txt1='INSUFFICIENT_HISTORY' and n=0 then 'PASS' else 'FAIL' end,
    format('verdict=%s n=%s', txt1, n),
    'sin finales cargados el harness dice INSUFFICIENT_HISTORY; no inventa un Brier');

  -- ══ STAGE 12B: WALK-FORWARD arithmetic vs a HAND-COMPUTED fixture ═══════════
  -- 4 events, p_hat = 0.60 for all, THREE home wins and one home loss:
  --   Brier    = ((.6-1)^2*3 + (.6-0)^2)/4 = (0.48+0.36)/4 = 0.21
  --   coinflip = 0.25 exactly      skill_vs_coinflip = 1 - 0.21/0.25 = +0.16
  -- Each game is stored as TWO innings, so a harness that read one row instead of summing
  -- periods would get the outcomes wrong and miss 0.26.
  s := s + 1;
  insert into public.agenda_espn (espn_event_id, fecha, home_espn_id, away_espn_id,
                                  home_nombre, away_nombre, estado, deporte, liga_nombre)
  values ('WF0001', timestamptz '2026-08-20 00:00:00+00','1','2','WF Home A','WF Away A','post','baseball','MLB'),
         ('WF0002', timestamptz '2026-08-20 00:00:00+00','3','4','WF Home B','WF Away B','post','baseball','MLB'),
         ('WF0003', timestamptz '2026-08-20 00:00:00+00','5','6','WF Home C','WF Away C','post','baseball','MLB'),
         ('WF0004', timestamptz '2026-08-20 00:00:00+00','7','8','WF Home D','WF Away D','post','baseball','MLB')
  on conflict (espn_event_id) do nothing;

  insert into v2.mlb_prediction_snapshot
    (espn_event_id, decision_time, model_version, scheduled_at, model_status, p_home_ml, p_away_ml)
  values ('WF0001', timestamptz '2026-08-19 12:00:00+00','mlb-fixture-v1', timestamptz '2026-08-20 00:00:00+00','READY_UNVALIDATED',60.0,40.0),
         ('WF0002', timestamptz '2026-08-19 12:00:00+00','mlb-fixture-v1', timestamptz '2026-08-20 00:00:00+00','READY_UNVALIDATED',60.0,40.0),
         ('WF0003', timestamptz '2026-08-19 12:00:00+00','mlb-fixture-v1', timestamptz '2026-08-20 00:00:00+00','READY_UNVALIDATED',60.0,40.0),
         ('WF0004', timestamptz '2026-08-19 12:00:00+00','mlb-fixture-v1', timestamptz '2026-08-20 00:00:00+00','READY_UNVALIDATED',60.0,40.0)
  on conflict do nothing;

  insert into public.mlb_linescore (espn_event_id, competitor_id, lado, period, carreras) values
    ('WF0001','1','home',1,3),('WF0001','1','home',2,2),('WF0001','2','away',1,1),('WF0001','2','away',2,0),
    ('WF0002','3','home',1,4),('WF0002','3','home',2,0),('WF0002','4','away',1,1),('WF0002','4','away',2,1),
    ('WF0003','5','home',1,3),('WF0003','5','home',2,2),('WF0003','6','away',1,1),('WF0003','6','away',2,0),
    ('WF0004','7','home',1,1),('WF0004','7','home',2,0),('WF0004','8','away',1,2),('WF0004','8','away',2,3);

  select brier_ml, brier_coinflip, skill_vs_coinflip, n_scored, verdict
    into num1, num2, txt2, n, txt1
    from v2.fn_mlb_walk_forward(timestamptz '2026-08-01', timestamptz '2026-09-01','mlb-fixture-v1',4);
  insert into v2.gate_run_log values (RUN,'S12B_WF_ARITHMETIC',s,
    case when num1=0.21 and num2=0.25 and txt2='0.16000' and n=4 then 'PASS' else 'FAIL' end,
    format('brier=%s coinflip=%s skill=%s n=%s verdict=%s', num1, num2, txt2, n, txt1),
    'Brier calculado a mano = 0.21, coinflip 0.25, skill 0.16000, n=4 (suma innings)');

  -- ══ STAGE 13: a positive Brier delta WITHOUT significance must NOT promote ══
  -- Market implies 0.40, model says 0.60, home wins 3 of 4, so the model genuinely beats the
  -- market on raw Brier: model 0.21 vs market 0.31, mean_gain = +0.10. But the per-game gains
  -- are (+0.20,+0.20,+0.20,-0.20) => sd 0.20, se 0.10, t = 1.0, BELOW the 2.0 bar. An earlier
  -- draft of this harness used `gain > 0` and would have returned BEATS_MARKET_PENDING_REVIEW
  -- on exactly this noise. That is the defect this stage pins down.
  s := s + 1;
  insert into public.v_momios_confiables (espn_event_id, home_ml, away_ml, snapshot_at, confiable, bookmaker, sport_key)
  values ('WF0001',2.5,1.666667, timestamptz '2026-08-19 06:00:00+00', true,'UnitTest','baseball_mlb'),
         ('WF0002',2.5,1.666667, timestamptz '2026-08-19 06:00:00+00', true,'UnitTest','baseball_mlb'),
         ('WF0003',2.5,1.666667, timestamptz '2026-08-19 06:00:00+00', true,'UnitTest','baseball_mlb'),
         ('WF0004',2.5,1.666667, timestamptz '2026-08-19 06:00:00+00', true,'UnitTest','baseball_mlb');
  select wf.verdict, wf.t_stat, wf.mean_gain, wf.n_with_market, wf.brier_market
    into txt1, num1, num2, n, num3
    from v2.fn_mlb_walk_forward(timestamptz '2026-08-01', timestamptz '2026-09-01','mlb-fixture-v1',4) wf;
  insert into v2.gate_run_log values (RUN,'S13_NO_PROMOTION_ON_NOISE',s,
    case when txt1='NO_SKILL_VS_MARKET' and n=4
              and num2 > 0                         -- the model DID beat the market on raw Brier
              and num3 > 0.30                      -- market Brier ~0.31
              and num1 between 0.95 and 1.05       -- t ~ 1.0, below the 2.0 bar
         then 'PASS' else 'FAIL' end,
    format('verdict=%s t=%s mean_gain=%s n_market=%s brier_market=%s', txt1, num1, num2, n, num3),
    'ganancia Brier POSITIVA (+0.10) con t~1.0 debe dar NO_SKILL_VS_MARKET; el signo no promueve');

  -- ══ STAGE 14: post-first-pitch ODDS must never be consumed ══════════════════
  -- prod's v_momios_confiables carries 159/1114 snapshots at or after first pitch (measured).
  s := s + 1;
  select disc_flag into txt1 from v2.v_mlb_event_gate
   where decision_time = D0 and canonical_event_id = '401816883';
  insert into public.v_momios_confiables (espn_event_id, home_ml, away_ml, over_odds, under_odds, over_line,
                                          snapshot_at, confiable, bookmaker, sport_key)
  values ('401816883', 1.01, 50.0, 1.01, 50.0, 8.5,
          timestamptz '2026-09-11 01:00:00+00', true, 'PostFirstPitchPoison','baseball_mlb');
  select disc_flag into txt2 from v2.v_mlb_event_gate
   where decision_time = D0 and canonical_event_id = '401816883';
  insert into v2.gate_run_log values (RUN,'S14_POST_START_ODDS_IGNORED',s,
    case when txt1 = txt2 then 'PASS' else 'FAIL' end,
    format('disc_flag_before=%s disc_flag_after_poison=%s', txt1, txt2),
    'un momio post-primer-pitcheo (home 1.01) no altera el diagnostico de una decision previa');

  -- ══ STAGE 15: removing the CHECK makes the harness REFUSE to report ═════════
  s := s + 1;
  alter table v2.mlb_prediction_snapshot drop constraint mlb_pred_snapshot_pre_first_pitch;
  insert into v2.mlb_prediction_snapshot
    (espn_event_id, decision_time, model_version, scheduled_at, model_status, p_home_ml, p_away_ml)
  values ('WF0001', timestamptz '2026-08-20 06:00:00+00','mlb-fixture-v1',
          timestamptz '2026-08-20 00:00:00+00','READY_UNVALIDATED', 99.0, 1.0);
  select verdict into txt1
    from v2.fn_mlb_walk_forward(timestamptz '2026-08-01', timestamptz '2026-09-01','mlb-fixture-v1',1);
  select count(*) into n from v2.v_mlb_post_first_pitch_violations;
  insert into v2.gate_run_log values (RUN,'S15_CORRUPTION_DETECTED',s,
    case when txt1='CORRUPT_SNAPSHOT_TABLE' and n=1 then 'PASS' else 'FAIL' end,
    format('verdict=%s violation_view_rows=%s', txt1, n),
    'si alguien quita el CHECK, el harness se niega a reportar y la vista de auditoria lo delata');

  -- restore the invariant: DELETE is trigger-blocked, so disable, clean, re-enable, re-add
  alter table v2.mlb_prediction_snapshot disable trigger trg_mlb_prediction_snapshot_immutable;
  delete from v2.mlb_prediction_snapshot where decision_time >= scheduled_at;
  alter table v2.mlb_prediction_snapshot enable trigger trg_mlb_prediction_snapshot_immutable;
  alter table v2.mlb_prediction_snapshot
    add constraint mlb_pred_snapshot_pre_first_pitch check (decision_time < scheduled_at);

  s := s + 1;
  select count(*) into n from v2.v_mlb_post_first_pitch_violations;
  select count(*) into n2 from pg_constraint
   where conname='mlb_pred_snapshot_pre_first_pitch'
     and conrelid='v2.mlb_prediction_snapshot'::regclass;
  select verdict into txt1
    from v2.fn_mlb_walk_forward(timestamptz '2026-08-01', timestamptz '2026-09-01','mlb-fixture-v1',4);
  insert into v2.gate_run_log values (RUN,'S15B_INVARIANT_RESTORED',s,
    case when n=0 and n2=1 and txt1='NO_SKILL_VS_MARKET' then 'PASS' else 'FAIL' end,
    format('violations=%s constraint_present=%s verdict=%s', n, n2, txt1),
    'la rama queda en estado valido: 0 violaciones, CHECK de vuelta, harness reportando otra vez');
end $gate$;

-- ── EVIDENCE ────────────────────────────────────────────────────────────────
select stage, status, metric, detail
from v2.gate_run_log
where run_id = (select run_id from v2.gate_run_log order by logged_at desc limit 1)
order by seq, stage;
