# ISS134 / ISS135 — Cross-sport publication authority postdeploy audit

Date: 2026-09-13
Production Supabase: `wpiztubmmmzclhlprgpd`

## Repairs
- ISS134: MLB/Soccer/legacy recommendation surfaces may publish only when `public.v_pick_canonico.es_pick=true` for the exact event/market/pick.
- `public.v_favorito_mlb`: preserves MLB event rows but no longer promotes `motor_cache` diagnostics to a user-visible favorite.
- `public.v_picks_futbol_calc.apostable`: exact canonical authorization only; raw probability thresholds cannot authorize.
- `public.mejor_pick_hoy`: canonical `es_pick` only; direct `picks_recomendados_hoy` bypass removed.
- `public.seleccionar_picks_seguro_valor`: legacy JSON selector fail-closed.
- ISS135: `public.nfl_mejor_pick` legacy RPC fail-closed; `public.v_publication_authority_leaks` added as a permanent zero-row invariant.

## Before ISS134
- MLB `v_favorito_mlb` rows with non-null favorite: 40.
- Soccer `v_picks_futbol_calc` rows with `apostable=true`: 7.
- Canonical authorized picks: 0.

## Postdeploy evidence
- `v_publication_authority_leaks`: 0 rows.
- NFL: daily candidates 0; unauthorized candidate leaks 0; public probability leaks 0; legacy `nfl_mejor_pick` rows 0.
- MLB: `v_favorito_mlb` 112 event rows, 0 published favorites; `v_picks_mlb_modelo` 160 diagnostic rows retained; canonical MLB picks 0.
- Soccer: `v_picks_futbol_calc` 7 discovery rows, 0 apostable; `v_picks_futbol_calibrado` 858 diagnostic rows retained; canonical Soccer picks 0.
- Global: `v_reto13m_lo_mejor` 0; `mejor_pick_hoy()` 0.
- Tampa Bay @ Cincinnati: `VALIDATION_BLOCKED`, no P_RETO, no legacy best pick.
- Green Bay @ Minnesota: `VALIDATION_BLOCKED`, no P_RETO, no legacy best pick.

## Why MLB/Soccer remain closed
Current `motor_modelo_mapa` has no model_version/calibration_version for the production sources `motor_mlb_cuantitativo`, `motor_futbol_calibrado`, or `motor_picks`; canonical reason = `SIN_MODEL_VERSION`.

Registry check:
- `mlb_ml_poisson_v1`: `MODEL_REJECTED`, zero locks.
- `mlb_totales_normal_v1`: `CHALLENGER`, zero locks (diagnostic skill evidence exists but no publication lock).
- `soccer_1x2_poisson_v1`: `CHALLENGER`, zero locks and no demonstrated OOS skill gate.

Therefore fail-closed is intentional: diagnostics stay available, recommendations stay unavailable until a versioned model/calibration passes the canonical publication gate.

Result: `CROSS_SPORT_PUBLICATION_AUTHORITY=PASS_PROD_VERIFIED`, `GLOBAL_AUTHORITY_LEAKS=0`.