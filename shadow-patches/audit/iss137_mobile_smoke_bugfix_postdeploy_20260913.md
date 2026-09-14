# ISS137 + mobile smoke bugfix postdeploy — 2026-09-13

## User-reported production defects

1. NFL mobile page showed `No pudimos cargar los partidos de NFL.`
2. MLB cards with no official probability showed the contradictory text `La probabilidad publicada está fuera de rango.`
3. Shared `ANÁLISIS COMPLETO` path blocked MLB/NFL even though canonical dossiers exist.
4. NFL dossier lost the backend's exact fail-closed validation reason and degraded it to generic snapshot-pending text.
5. MLB dossier had generic copy implying a winner probability was published when `favorito_pct` was NULL.
6. Fut Pro day/detail routing required regression coverage to guarantee exact event identity.

## NFL root cause and backend repair

`public.nfl_tablero_semana` itself had 16 rows. Authenticated reads failed because it calls `v2.fn_nfl_release_allowed(text)`, which executed with caller privileges and attempted to read `v2.nfl_model_validation_gate`; authenticated users had no direct schema-v2 privilege.

Patch: `shadow-patches/prepared/iss137_nfl_authenticated_read_fix.sql`
Commit: `e6f02d3874a01d86facc24388b3567cd3bc97f17`

Repair semantics: `v2.fn_nfl_release_allowed(text)` is now `SECURITY DEFINER` with a fixed `search_path`. Release-gate semantics are unchanged. It only lets public/authenticated readers evaluate the internal release gate without requiring direct access to `v2`.

Postdeploy authenticated verification:
- `public.nfl_tablero_semana`: 16 rows
- unauthorized NFL P_RETO / reto_pick leaks: 0
- GB@MIN `401872927` dossier retains `disponible=false`, `model_status=VALIDATION_BLOCKED`, `validation_status=FAIL_CLOSED_OOS_NOT_PROVEN`, reason `P_RETO bloqueado: validacion OOS independiente no demostrada`.

## Frontend root causes and repairs

Lovable project: `d243f279-2db6-4f18-a269-029cf284267f`

First frontend repair commit: `83003742c86b4141019bcea94b37b43a507c7bc7`
- `src/v2/lib/canonicalMlb.ts`: NULL/undefined/empty probability no longer becomes numeric zero (`Number(null)`). Missing probability now yields the honest no-P_RETO message and never derives P_RETO from odds.
- `src/components/partido/AnalisisCompletoModal.tsx`: FUT routes to canonical `MatchSheetV2`; MLB/NFL route to canonical `DossierModal` by exact `espn_event_id`; missing identity fails closed.
- regression coverage for NFL public contract, cross-sport analysis routing, MLB null probability, and Fut Pro day/event identity.

Second analysis-honesty commit: `911852a28d6d73d90ab9f8fbe8479ba56c8b68a6`
- NFL dossier preserves and displays backend blocked-state metadata instead of generic snapshot-pending text; no blocked probability is rendered.
- MLB dossier conditions copy/provenance on actual P_RETO publication. Expected-runs model is labeled diagnostic/context when winner P_RETO is absent.
- Added regression tests for NFL blocked-state visibility and MLB no-probability dossier honesty.

Frontend verification at final commit:
- 815/815 tests PASS in 92 files
- strict typecheck PASS
- production build PASS

Deployment:
- Lovable deployment `fed307f6-6c5e-4570-a862-ad6dd12728a5`
- live URL `https://doos.lovable.app`
- deployed latest frontend build identity `911852a2...`

## Production postdeploy invariants

- GLOBAL_AUTHORITY_LEAKS = 0
- SOCCER_INVARIANT_LEAKS = 0
- NFL_PUBLIC_LEAKS = 0
- MLB_TODAY_PUBLISHED = 0
- authenticated NFL rows = 16
- audited MLB user-reported events = 4; with official probability = 0
- Soccer canonical READY = 172

## Gate

`MOBILE_PROD_SMOKE_BUGFIXES=PASS_PROD_VERIFIED`
`NFL_AUTHENTICATED_READ=PASS_PROD_VERIFIED`
`CROSS_SPORT_ANALYSIS_ROUTING=PASS_TESTED_DEPLOYED`
`GLOBAL_AUTHORITY_LEAKS=0`

Authenticated automated browser E2E remains a separate gate until a genuine browser session is available; no fake E2E pass is claimed.
