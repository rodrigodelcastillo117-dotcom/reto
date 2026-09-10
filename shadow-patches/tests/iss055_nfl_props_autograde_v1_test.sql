-- iss055 NFL player props autograde adversarial/regression suite
-- Run on disposable branch only.
-- Expected canonical historical fixture:
-- ESPN 401772960 PIT 26 - BAL 24
-- Derrick Henry: 126 rush yds; Lamar Jackson: 238 pass yds; Mark Andrews: 2 receptions.

DO $$
DECLARE j jsonb;
BEGIN
  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry Over 100.5 rushing yards',null);
  IF j->>'evaluation' <> 'ganado' OR (j->>'stat_value')::numeric <> 126 THEN RAISE EXCEPTION 'Henry over failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry Under 100.5 rushing yards',null);
  IF j->>'evaluation' <> 'perdido' THEN RAISE EXCEPTION 'Henry under failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry Over 126 rushing yards',null);
  IF j->>'evaluation' <> 'nulo' THEN RAISE EXCEPTION 'integer push failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry 100+ rushing yards',null);
  IF j->>'evaluation' <> 'ganado' THEN RAISE EXCEPTION '100+ failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Lamar Jackson Under 250.5 passing yards',null);
  IF j->>'evaluation' <> 'ganado' OR (j->>'stat_value')::numeric <> 238 THEN RAISE EXCEPTION 'Lamar under failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Mark Andrews Over 2.5 receptions',null);
  IF j->>'evaluation' <> 'perdido' OR (j->>'stat_value')::numeric <> 2 THEN RAISE EXCEPTION 'Andrews receptions failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry Más de 100.5 yardas terrestres',null);
  IF j->>'evaluation' <> 'ganado' THEN RAISE EXCEPTION 'Spanish over parser failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Lamar Jackson Menos de 250.5 yardas de pase',null);
  IF j->>'evaluation' <> 'ganado' THEN RAISE EXCEPTION 'Spanish under parser failed: %',j; END IF;

  j := v2.eval_nfl_player_prop_v1('401772960','Derrick Henry Over 1.5 fumbles',null);
  IF j->>'evaluation' <> 'no_evaluable' OR j->>'reason' <> 'UNSUPPORTED_MARKET' THEN RAISE EXCEPTION 'unsupported fail-close failed: %',j; END IF;
END $$;

-- Replay invariant after a live autograde: once rows are terminal, the second call returns zero rows.
-- SELECT count(*) = 0 AS replay_ok FROM v2.autograde_nfl_props_v1(false);
