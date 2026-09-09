-- ============================================================================
-- iss037 — CROSS-LEAGUE φ VERSIONADO PARA REPLAY (§65) · STAGED, NO APLICAR
-- ============================================================================
-- PROBLEMA (CROSS_LEAGUE_REPLAY_GATE=FAIL): `v2.liga_fuerza` guarda UN set φ actual
-- (se TRUNCATE en cada re-fit). Tiene `fit_at`/`model_version` pero NO un
-- `phi_training_cutoff` (la frontera temporal de datos usados para ajustar), y
-- `fn_crossleague_p_reto` lee la tabla VIVA. Un replay histórico (decision de mayo)
-- aplicaría el φ de HOY → no replayable, posible fuga (§65: "no uses el φ actual
-- silenciosamente; necesitas phi_model_version + phi_training_cutoff + phi_by_league").
--
-- FIX (staged): tabla de snapshots versionados de φ + resolver AS-OF que elige la
-- versión cuyo training_cutoff <= decision_time. El builder cross-league debe pasar
-- decision_time y usar este resolver, nunca `liga_fuerza` directo, en replay.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- 1) Snapshot versionado (append-only; NUNCA truncate). Reproduce φ de época.
create table if not exists v2.liga_fuerza_version (
  phi_model_version   text        not null,        -- p.ej. 'crossleague_v1'
  phi_training_cutoff timestamptz not null,        -- datos usados: kickoff < cutoff
  liga_id             integer     not null,
  liga_nombre         text,
  phi                 numeric     not null,
  n_cruzados          integer     not null,
  servible            boolean     not null default false,
  ridge               numeric,                      -- hiperparámetro del ajuste
  ref_liga_id         integer,                      -- liga de referencia (φ=0)
  fit_at              timestamptz not null default now(),
  primary key (phi_model_version, liga_id)
);

-- 2) Sella el ajuste v1 ACTUAL como versión inmutable con su cutoff de entrenamiento.
--    NOTA: el fit v1 se hizo con juegos cruzados FINAL hasta ~2026-09-08 (fecha del
--    backfill/lab). Ese es el phi_training_cutoff honesto de v1. Un replay a una
--    decisión ANTERIOR a ese cutoff NO puede usar v1 (φ vería el futuro): debe
--    fail-close hasta que exista una versión con cutoff <= esa decisión.
insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible, ridge, ref_liga_id)
select 'crossleague_v1', timestamptz '2026-09-08 00:00:00+00',
       liga_id, liga_nombre, phi, n_cruzados, servible, 10.0, 39
from v2.liga_fuerza
on conflict (phi_model_version, liga_id) do update set
  phi=excluded.phi, n_cruzados=excluded.n_cruzados, servible=excluded.servible,
  phi_training_cutoff=excluded.phi_training_cutoff;

-- 3) Resolver AS-OF: φ de la versión servible más reciente con cutoff <= decision.
--    Fail-close (NULL) si ninguna versión existía en esa fecha → no aplica φ del futuro.
create or replace function v2.fn_crossleague_phi_asof(
  p_liga_id integer, p_decision_time timestamptz, p_model_version text default 'crossleague_v1'
) returns table(phi numeric, servible boolean, phi_model_version text, phi_training_cutoff timestamptz)
language sql stable as $$
  select v.phi, v.servible, v.phi_model_version, v.phi_training_cutoff
  from v2.liga_fuerza_version v
  where v.liga_id = p_liga_id
    and v.phi_model_version = p_model_version
    and v.phi_training_cutoff <= p_decision_time      -- NUNCA φ entrenado con datos posteriores
  order by v.phi_training_cutoff desc
  limit 1;
$$;

-- 4) CONTRATO para el builder cross-league (§45/§65):
--    - En PRODUCCIÓN FORWARD (decision≈now): usa v1 (cutoff 2026-09-08 <= now).
--    - En REPLAY histórico (decision < 2026-09-08): fn_crossleague_phi_asof devuelve
--      0 filas → el pick cross-league fail-close (no se puede reproducir φ de época
--      hasta sellar versiones con cutoffs anteriores). Esto es CORRECTO: mejor
--      fail-close que aplicar φ del futuro.
--    - fn_crossleague_p_reto debe (en cutover) recibir decision_time y leer este
--      resolver en vez de v2.liga_fuerza directo.
--
-- Con esto CROSS_LEAGUE_REPLAY_GATE pasa de FAIL a STAGED_ONLY: φ versionado con
-- training_cutoff explícito + resolver as-of fail-closed. La aprobación de publicación
-- cross-league sigue siendo APPROVABLE_STAGED (UCL/UEL) — sin cambios de gate de validación.
