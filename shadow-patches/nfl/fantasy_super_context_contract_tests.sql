-- FANTASY PLAYER SUPER CONTEXT V2 — CONTRACT TESTS (SHADOW)
-- Run on a disposable branch after installing fantasy_player_super_context_v2.

-- T1 exact player identity: a player appears at most once in this next-event view.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.fantasy_player_super_context_v2
    WHERE espn_player_id IS NOT NULL
    GROUP BY espn_player_id HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'FANTASY_PLAYER_CONTEXT_IDENTITY_NOT_UNIQUE';
  END IF;
END $$;

-- T2: no canonical projection means every projection/recommendation field is null.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.fantasy_player_super_context_v2
    WHERE projection_status='NO_CANONICAL_PROJECTION'
      AND (projected_floor IS NOT NULL OR projected_median IS NOT NULL OR projected_ceiling IS NOT NULL
           OR projection_uncertainty IS NOT NULL OR projection_data_quality IS NOT NULL
           OR projection_model_version IS NOT NULL OR projection_snapshot_at IS NOT NULL
           OR start_probability IS NOT NULL OR recommended_slot IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'FANTASY_FAKE_CANONICAL_PROJECTION';
  END IF;
END $$;

-- T3 prior season must never masquerade as current season.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.fantasy_player_super_context_v2
    WHERE baseline_season IS NOT NULL AND season IS NOT NULL AND baseline_season >= season
  ) THEN
    RAISE EXCEPTION 'FANTASY_BASELINE_NOT_PRIOR_SEASON';
  END IF;
END $$;

-- T4 injury/depth captures may not be after kickoff.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.fantasy_player_super_context_v2
    WHERE (injury_as_of IS NOT NULL AND kickoff IS NOT NULL AND injury_as_of > kickoff)
       OR (depth_as_of IS NOT NULL AND kickoff IS NOT NULL AND depth_as_of > kickoff)
  ) THEN
    RAISE EXCEPTION 'FANTASY_TEMPORAL_LEAK';
  END IF;
END $$;

-- T5 sportsbook fields are context only by contract; they must never populate projections.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.fantasy_player_super_context_v2
    WHERE sportsbook_total_context IS NOT NULL
      AND projection_status='NO_CANONICAL_PROJECTION'
      AND projected_median IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FANTASY_MARKET_TO_PROJECTION_CONTAMINATION';
  END IF;
END $$;

SELECT 'FANTASY_SUPER_CONTEXT_CONTRACT_PASS' AS result;
