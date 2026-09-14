# ISS136 — Release postdeploy evidence

Date: 2026-09-13 (America/Mexico_City)
Production Supabase: `wpiztubmmmzclhlprgpd`
Frontend project: `d243f279-2db6-4f18-a269-029cf284267f`
Live URL: `https://doos.lovable.app`

## Backend release change

Migration: `iss136_soccer_canonical_selector_release`
Source commit: `7957b3a443343486177e7ed469f46cea3d8225e4`

Purpose:
- enforce exact crossleague model identity at persistence boundary;
- repair UEL rows whose provenance engine was `crossleague_v1_1` but persisted model_version was `crossleague_v1`;
- freeze one event-level soccer selector: argmax of the canonical 1X2 distribution only;
- keep sportsbook odds, no-vig, EV and Kelly out of event-probability selection;
- route Reto13M Lo Mejor to the same FutPro V3 canonical brain;
- add permanent `v_soccer_publication_invariant_leaks`.

Postdeploy gates:
- `GLOBAL_AUTHORITY_LEAKS=0`
- `SOCCER_INVARIANT_LEAKS=0`
- `SOCCER_MODEL_ID_MISMATCH=0`
- `SOCCER_READY=172` at verification time
- `RETO13M_ROWS=169` at verification time
- `RETO13M_TOP_ROWS=1`
- `LEGACY_MONEY_PICKS=0`
- `NFL_PUBLIC_LEAKS=0`
- `MLB_PUBLISHED_FAVORITES=0`

Canonical selector version: `soccer_1x2_argmax_v1`.
Exact ties fail closed (`TIE_UNRESOLVED`). Non-approved competitions/models, bad temporal lineage or invalid distributions fail closed.

Top rows at verification time included:
1. Bayern Munich vs 1. FC Union Berlin — Bayern 78.9%, `crossleague_v1`
2. Sporting CP vs Arouca — Sporting CP 73.4%, `crossleague_v1`
3. Juventus vs NEC Nijmegen — Juventus 70.6%, `crossleague_v1_1`

## Frontend release change

Lovable canonical commit: `fb5923760a2ba96c55b0347f714b3bc8c750c69a`
Lovable edit: `edt-aaea751d-f4b2-4260-8c41-70b8176c3de0`
Deployment id: `bd3d08fa-9104-4976-91b9-6746d39c64f9`
Live URL: `https://doos.lovable.app`

Minimal compatibility repair:
- authority guard now accepts both `FROZEN` and `EVENT_SELECTOR_FROZEN` as explicit frozen rank policies;
- all other/missing values remain fail-closed;
- one permanent regression test added.

Verification:
- tests: 792/792 PASS in 86 files
- strict typecheck: PASS
- production build: PASS
- authority guards: PASS
- project status: completed / published / public URL live
- latest build identity resolves to `fb592376...`

## Remaining release gate

`REAL_E2E=BLOCKED_AUTHENTICATED_SESSION`.
The isolated Lovable runner still has no genuine authenticated Supabase browser session for this external/BYO Supabase project. No mock/stub/session fabrication is accepted as REAL_E2E.

This is a verification-transport blocker, not a newly observed product-code failure.

Current release classification:
- backend canonical publication: PASS_PROD_VERIFIED
- frontend code/build/deploy: PASS
- NFL: PASS_FAILCLOSED_PROD_VERIFIED
- MLB: PASS_FAILCLOSED_PROD_VERIFIED
- soccer canonical selector/Reto13M top: PASS_PROD_VERIFIED
- global authority leaks: 0
- REAL authenticated E2E: BLOCKED
- strict release gate: HOLD only on REAL_E2E
