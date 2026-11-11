-- ============================================================================
-- lab_ff_league_config_v1 — CONFIGURACIÓN EXPLÍCITA DE LIGA FANTASY
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY.
--
-- MOTIVO: las 11 tablas lab_ff_* están vacías y lab_ff_sync_contract no contiene
-- scoring, roster slots, nº de equipos, tipo de draft, posición de pick ni
-- keepers. Sin esos parámetros, "best available" y "best fit for my roster" NO
-- son computables: replacement value y escasez posicional dependen enteramente
-- del scoring y de los slots.
--
-- Esta tabla NO INVENTA NINGÚN VALOR. Define la forma y obliga a declararlos.
-- Todo lo que no se pueda derivar queda NOT NULL sin default, de modo que una
-- fila incompleta no puede insertarse y ningún motor puede operar sobre supuestos.
--
-- is_test marca explícitamente las ligas ficticias de prueba, para que nunca se
-- confundan con la liga real del usuario.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.lab_ff_league_config_v1 (
  league_id        text        PRIMARY KEY,
  league_name      text        NOT NULL,
  season           int         NOT NULL,

  -- ---- parámetros SIN default: deben declararse ----
  num_teams        int         NOT NULL CHECK (num_teams BETWEEN 2 AND 32),
  scoring_type     text        NOT NULL CHECK (scoring_type IN ('standard','half_ppr','ppr','custom')),
  ppr_value        numeric     NOT NULL CHECK (ppr_value >= 0),
  te_premium       numeric     NOT NULL DEFAULT 0 CHECK (te_premium >= 0),
  superflex        boolean     NOT NULL,
  draft_type       text        NOT NULL CHECK (draft_type IN ('snake','linear','auction')),
  my_pick_position int             NULL,          -- NULL válido solo en auction
  keepers_enabled  boolean     NOT NULL,
  keepers_count    int         NOT NULL DEFAULT 0 CHECK (keepers_count >= 0),

  -- roster: {"QB":1,"RB":2,"WR":2,"TE":1,"FLEX":1,"K":1,"DST":1,"BENCH":6}
  roster_slots     jsonb       NOT NULL,
  -- scoring detallado por evento, si es custom
  scoring_rules    jsonb           NULL,

  is_test          boolean     NOT NULL DEFAULT false,
  source           text        NOT NULL CHECK (source IN ('user_declared','platform_import','test_fixture')),
  declared_at      timestamptz NOT NULL DEFAULT now(),
  notes            text            NULL,

  -- coherencia: en snake/linear la posición de pick es obligatoria y válida
  CONSTRAINT pick_position_coherente CHECK (
    (draft_type = 'auction' AND my_pick_position IS NULL)
    OR (draft_type <> 'auction' AND my_pick_position IS NOT NULL
        AND my_pick_position BETWEEN 1 AND num_teams)),
  -- coherencia: si hay keepers, deben ser al menos 1
  CONSTRAINT keepers_coherente CHECK (
    (keepers_enabled AND keepers_count > 0) OR (NOT keepers_enabled AND keepers_count = 0)),
  -- coherencia: ppr_value debe concordar con scoring_type
  CONSTRAINT ppr_coherente CHECK (
    (scoring_type='standard' AND ppr_value = 0)
    OR (scoring_type='half_ppr' AND ppr_value = 0.5)
    OR (scoring_type='ppr'      AND ppr_value = 1)
    OR (scoring_type='custom'))
);

COMMENT ON TABLE public.lab_ff_league_config_v1 IS
'Configuración de liga fantasy declarada explícitamente. Ningún parámetro tiene default silencioso: una liga mal declarada no puede insertarse. is_test separa fixtures de prueba de la liga real del usuario.';

-- ---- Fixture de PRUEBA, marcado como tal. NO es la liga del usuario. ----
-- Existe solo para que los tests del motor tengan sobre qué correr.
INSERT INTO public.lab_ff_league_config_v1 (
  league_id, league_name, season, num_teams, scoring_type, ppr_value, te_premium,
  superflex, draft_type, my_pick_position, keepers_enabled, keepers_count,
  roster_slots, is_test, source, notes)
VALUES (
  'TEST_FIXTURE_12T_PPR', '[FIXTURE DE PRUEBA — NO ES LA LIGA REAL]', 2026,
  12, 'ppr', 1, 0, false, 'snake', 6, false, 0,
  '{"QB":1,"RB":2,"WR":2,"TE":1,"FLEX":1,"K":1,"DST":1,"BENCH":6}'::jsonb,
  true, 'test_fixture',
  'Fixture sintético para tests del motor de draft. NO usar para decisiones reales.')
ON CONFLICT (league_id) DO NOTHING;
