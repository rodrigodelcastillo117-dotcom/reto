-- NFL SUPER DOSSIER V2 — CONTRACT TESTS (SHADOW)
-- Run only on a disposable branch where nfl_super_dossier_v2 is installed.

-- T1: exact identity is unique.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    GROUP BY canonical_event_id HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'NFL_SUPER_DOSSIER_IDENTITY_NOT_UNIQUE';
  END IF;
END $$;

-- T2: own-model outputs must remain NULL while model_status says NO_OWN_MODEL.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    WHERE model_status='NO_OWN_MODEL'
      AND (p_reto_home IS NOT NULL OR p_reto_away IS NOT NULL
           OR projected_points_home IS NOT NULL OR projected_points_away IS NOT NULL
           OR score_distribution IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'NFL_FAKE_MODEL_OUTPUT';
  END IF;
END $$;

-- T3: temporal FPI snapshots may not be captured after kickoff.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    WHERE (fpi_home_snapshot_at IS NOT NULL AND fpi_home_snapshot_at > kickoff)
       OR (fpi_away_snapshot_at IS NOT NULL AND fpi_away_snapshot_at > kickoff)
  ) THEN
    RAISE EXCEPTION 'NFL_FPI_TEMPORAL_LEAK';
  END IF;
END $$;

-- T4: injury snapshots may not be captured after kickoff.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    WHERE (injuries_home_as_of IS NOT NULL AND injuries_home_as_of > kickoff)
       OR (injuries_away_as_of IS NOT NULL AND injuries_away_as_of > kickoff)
  ) THEN
    RAISE EXCEPTION 'NFL_INJURY_TEMPORAL_LEAK';
  END IF;
END $$;

-- T5: pregame events cannot claim a closing market snapshot.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    WHERE kickoff > now()
      AND market_line_history->'closing' IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'NFL_PREMATCH_FALSE_CLOSE';
  END IF;
END $$;

-- T6: market role must always remain contextual while no own model exists.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.nfl_super_dossier_v2
    WHERE market_role <> 'CONTEXT_ONLY'
       OR model_status <> 'NO_OWN_MODEL'
  ) THEN
    RAISE EXCEPTION 'NFL_MARKET_ROLE_CONTAMINATION';
  END IF;
END $$;

SELECT 'NFL_SUPER_DOSSIER_CONTRACT_PASS' AS result;
