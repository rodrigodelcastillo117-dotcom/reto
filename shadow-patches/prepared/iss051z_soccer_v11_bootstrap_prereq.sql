-- iss051z — clean-bootstrap prerequisite for iss052 · STAGED ONLY
-- Ensures public.ligas_master exists before iss052 adds v1_1 mapping columns.
-- No production deployment in this commit.
create table if not exists public.ligas_master (
  id integer,
  nombre text,
  aliases text[],
  espn_endpoint text,
  api_sports_id integer,
  deporte text
);
