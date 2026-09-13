# RETO 13M — FINAL RELEASE PACKAGE — 2026-09-13

## Release status

**PACKAGE METADATA = PASS**  
**INDEPENDENT BACKEND/DATA/MODEL VERIFICATION = PASS**  
**FRONTEND CODE VERIFICATION = PASS**  
**FRONTEND DEPLOYMENT = PASS**  
**REAL AUTHENTICATED BROWSER/E2E = BLOCKED**  
**PRODUCTION MODEL/READ CUTOVER = HOLD**  
**PROD_FREEZE = ON**

This package is reproducible evidence and an ordered cutover plan. It is **not** production model/read-cutover authorization.

## Exact candidate identity

- Backend repository: `rodrigodelcastillo117-dotcom/reto`
- Backend branch: `chatgpt/reto13m-closeout-20260912`
- **Runtime implementation candidate SHA:** `f32c7a06569138ecee9588eda2632cf5a310056d`
- Lovable project: `d243f279-2db6-4f18-a269-029cf284267f` (`doos / Remix of Reto 13M`)
- **Verified Lovable frontend commit:** `42be60e30be83b5b2b85866edb59ba368d074a65`
- Lovable edit: `edt-05bf4589-7f6e-4e66-a640-af94661e0697`
- Published frontend: `https://doos.lovable.app`
- Lovable deployment id: `120c3eb6-59d9-4baf-8af7-0189f8a3ff92`
- Fresh independent Supabase disposable: `vowtknduvkdvildidvli` (`reto13m-final-independent-20260913`)
- Production backend/model/read contracts remained untouched during independent verification and frontend deployment.

The backend SHA above is the exact implementation/test candidate. Subsequent commits that modify only this release-package documentation are metadata and do not replace the runtime candidate SHA.

## Final control-plane ledger

| Block | Final gate | Final evidence / repair identity |
|---|---|---|
| SOCCER | `PASS_INDEPENDENT` | Six owner fixtures traversed builder -> staged -> event gate -> candidates -> dossier on the fresh disposable. ONE BRAIN / ONE P_RETO preserved. Independent verification found and repaired the market/no-vig publication veto with `iss045c_soccer_market_diagnostic_only.sql` (`37fddcd844cd4bbd23bd0d8abdac7c8b3c351b67`). |
| result-event / WASTED | `PASS_INDEPENDENT` | Exact event identity, push/single authority, retry/reversal/correction/recovery/idempotence adversarials passed. Fresh-disposable support dependency versioned at `466f535d7a3018444e627991434f3a7dcf6eaada`; exact-composite gate repair at `993ac902b555e2cfea4fd5c7c973f9d9bdc5a0b8`. |
| MLB | `PASS_FAILCLOSED_INDEPENDENT` | Own-model temporal/OOS publication authority retained. Independent verification repaired sportsbook/no-vig discrepancy so it stays diagnostic-only: `iss128b_mlb_market_diagnostic_only.sql` (`5e4f34755e882b98b43a3fe796b7f4c6cef4ab9a`) plus diagnostic reason fix `1e2d566ea803c24ad62d66dcae770385ac9b097b`. Insufficient model evidence still fail-closes publication. |
| NFL | `PASS_FAILCLOSED_INDEPENDENT` | Own-model frozen snapshot + QB/injury/depth provenance + OOS release authority. Direct RPC/public/tablero surfaces remain fail-closed when validation authority is insufficient. |
| NFL Fantasy | `PASS_INDEPENDENT` | Native canonical projection authority remains temporal/OOS gated. Independent optimizer execution found and repaired canonical-slot join and PL/pgSQL ambiguity with `iss131a_fantasy_lineup_join_repair.sql` (`198f8d592792fed2b01b0f7dfb4a87c839b625d0`); deterministic optimizer acceptance gate versioned at `819a0a5191f2b6291d79edf100f234d6fa0d3596`. |
| GLOBAL TOP_ONLY | `PASS_INDEPENDENT` | ISS132 remains the last predictive selector: zero quota/filler, 0/1 legal output, one event identity, model-only canonical ordering, P_RETO copied verbatim, Pick del Día exact alias. Final regression gate commit: `f32c7a06569138ecee9588eda2632cf5a310056d`. |
| Lovable frontend code | `PASS_VERIFIED` | Exact diff limited to Tendencia/MatchSheet + regression test. Recent form HOME/AWAY uses published factual form contract; no fabricated last-5; H2H stays diagnostic; no mutation of canonical P_RETO. Lovable suite: 86 files / 791 tests PASS; strict typecheck PASS; production build PASS. |
| Lovable frontend deploy | `PASS` | Owner-authorized FRONTEND-ONLY publish executed after code verification. Lovable reports the project `is_published=true`, status `completed`, public URL `https://doos.lovable.app`, and latest screenshot/build identity `id-preview-42be60e3...`, matching the verified frontend commit prefix. No backend/model cutover was bundled with the publish. |
| Authenticated REAL_E2E | `BLOCKED_AUTHENTICATED_SESSION` | Runner has no genuine Playwright `storageState`/authenticated Supabase browser session. No stub was substituted. The clean disposable is not an equivalent full UI/account backend, so forcing UI E2E against it would be false evidence. |

`PASS_FAILCLOSED` means the safety/publication contract passed; it does **not** assert that the underlying predictive model has enough evidence to emit a recommendation. A closed sport stays closed.

## Dependency DAG

```text
SOCCER canonical chain
  -> result-event / WASTED grading identity
  -> MLB canonical candidate + forward-validation authority
  -> NFL canonical candidate + OOS release authority
  -> NFL Fantasy canonical projection/optimizer authority
  -> GLOBAL TOP_ONLY (ISS132; LAST predictive selector)
  -> canonical read-contract switches
  -> authenticated browser/E2E verification
  -> independent production release decision
```

Exact file/application order: `shadow-patches/deploy/RETO13M_FINAL_BOOTSTRAP_ORDER_20260913.md`.

## Independent clean-bootstrap verification

A fresh disposable branch was created and used for the closeout verifier:

- project/ref: `vowtknduvkdvildidvli`
- branch: `reto13m-final-independent-20260913`
- production untouched

The fresh run found real defects rather than rubber-stamping the prior package. Those findings were repaired, versioned, reapplied and retested before their blocks were marked PASS. In particular:

1. `iss026_soccer_universe_failclosed_validation.sql` was incorrectly classified as a clean-branch migration; it is now correctly conditional legacy/public compatibility validation (`535d72d76e3e14b2b85eab6bd1e5b279f132c6c9`).
2. SOCCER market/no-vig discrepancy was incorrectly able to suppress canonical candidates; repaired by `iss045c`.
3. WASTED disposable notification dependencies/gate setup were repaired without changing production semantics.
4. MLB market discrepancy was separated from predictive/publication authority.
5. Fantasy optimizer slot joins and PL/pgSQL conflicts were repaired and covered by deterministic regression.
6. GLOBAL TOP_ONLY received a final explicit canonical selector acceptance gate.

Final independently audited backend candidate after these repairs: `f32c7a06569138ecee9588eda2632cf5a310056d`.

## Frontend closeout

Lovable was used only for a concrete FRONTEND-ONLY task. The repair turn made no Supabase/backend/SQL/model edits.

Verified commit: `42be60e30be83b5b2b85866edb59ba368d074a65`.

Exact changed files:
- `src/v2/components/dossier/TendenciasSoccer.tsx`
- `src/v2/components/MatchSheetV2.tsx`
- `src/test/tendenciasResultadosRecientes.test.tsx`

Verified behavior:
- Tendencia shows factual recent-form sequence independently for HOME and AWAY from existing published form contracts.
- It uses the published sample size and does not invent/pad/truncate results to create a fake five-match history.
- Missing form renders `Sin datos suficientes` while the rest of the dossier remains usable.
- H2H/trends remain context only.
- No code in the repair chooses or mutates canonical market, canonical pick, P_RETO, ranking, odds, EV, Kelly or stake.

Machine verification reported on the exact edit:
- Vitest: 86 files / 791 tests PASS.
- strict typecheck: PASS / 0 errors.
- production build: PASS.
- changed-file lint: no new errors; only existing fast-refresh warnings.

After that verification, the owner explicitly requested the Lovable changes be sent live. A separate FRONTEND-ONLY deployment was executed:
- deployment id: `120c3eb6-59d9-4baf-8af7-0189f8a3ff92`
- public URL: `https://doos.lovable.app`
- Lovable project state after deployment: `status=completed`, `is_published=true`.

This frontend deployment did **not** authorize or execute the frozen production backend/model/read-contract cutover.

## Preflight

Immediately before any separately authorized production cutover, run the read-only preflight against the intended target and archive the output externally:

`shadow-patches/deploy/reto13m_final_preflight_readonly.sql`

Any missing canonical dependency, invalid probability, temporal violation, or inability to capture current definitions => **ABORT**.

## Rollback

Authoritative release-package rollback policy:

`shadow-patches/deploy/RETO13M_FINAL_ROLLBACK_PLAN_20260913.md`

Rules:
- reverse dependency order;
- restore captured view/function definitions first;
- retain raw/history/snapshot/OOS evidence;
- never `DROP ... CASCADE`;
- never roll back into a known contaminated probability authority;
- market/no-vig must remain diagnostic/economic only;
- safest fallback is fail-closed;
- after rollback: `PROD_FREEZE=ON`, `RELEASE=HOLD`.

## Read-contract switch order

No production backend/model/read switch is authorized while authenticated REAL_E2E is blocked. After that gate passes and a separate production release is explicitly authorized, the only permitted dependency order is:

1. Canonical sport candidate surfaces proven on the exact backend candidate.
2. Result/settlement consumers after event-identity/idempotence checks.
3. `v2.v_global_top_only_universe`.
4. `v2.v_global_top_only_ranked`.
5. `v2.v_reto13m_top_only`.
6. `v2.v_pick_del_dia_canonical` last, as an exact alias of Reto13M TOP_ONLY.
7. Frontend consumers only after DB smoke confirms equality and fail-closed states.

Older one-per-sport/filler selector semantics (`iss064`, `iss078`, `iss080`) are superseded by ISS132 and must not be reintroduced.

## Cron isolation

Cron/scheduler changes are **outside this release package**. Scheduler changes cannot be bundled as justification for changing predictive/model semantics.

## Remaining hard release gate — authenticated REAL_E2E

This is the only remaining global backend/model release blocker.

The existing real runner requires a genuine browser-authenticated session (`E2E_STORAGE_STATE` / equivalent real Playwright storage state) plus a target URL. The published target URL now exists at `https://doos.lovable.app`, but no genuine authenticated storage state is available in the current automation/Lovable environment.

The fresh backend disposable cannot honestly substitute for this because it does not contain the full connected account/profile UI contract, while the frontend currently points at its connected production Supabase backend. Creating or modifying production authentication solely to manufacture test credentials is outside the frozen production gate and was not done.

Required REAL_E2E evidence:
- authenticated app loads successfully using a genuine session;
- Reto13M, Pick del Día, Qué Apostar, Oráculo, Favoritos and FutPro resolve the same canonical event/market/P_RETO identity;
- Soccer dossier shows trend/recent form/H2H without creating a second predictive truth;
- PRE -> IN_PROGRESS -> FINAL/WASTED rendering preserves event identity and canonical P_RETO;
- MLB/NFL/Fantasy fail-closed states render as unavailable/diagnostic, never as fabricated recommendation;
- no stale one-per-sport/filler selector survives in UI;
- X / Escape / Back dossier behavior has no duplicate overlay/history loop on supported flows.

No stub or unauthenticated approximation may be labeled REAL_E2E PASS.

## Release decision matrix

| Condition | Decision |
|---|---|
| Package identity/DAG/rollback/preflight aligned to `f32c7a...` | `PASS` |
| Fresh exact-composite backend verification | `PASS_INDEPENDENT` |
| Lovable code + component/regression suite | `PASS_VERIFIED` |
| Owner-authorized Lovable frontend deployment | `PASS` |
| Any individual sport lacks predictive validation authority | Keep that sport fail-closed |
| Authenticated REAL_E2E unavailable/not passed | `RELEASE=HOLD` |
| Any backend/model/read production mutation before final release authorization | Release invalid; restore/hold |
| Authenticated REAL_E2E PASS + no drift + explicit backend/model production release authorization | Eligible for backend/model read-contract cutover |

## Final package gate

`SOCCER=PASS_INDEPENDENT`  
`WASTED=PASS_INDEPENDENT`  
`MLB=PASS_FAILCLOSED_INDEPENDENT`  
`NFL=PASS_FAILCLOSED_INDEPENDENT`  
`NFL_FANTASY=PASS_INDEPENDENT`  
`GLOBAL_TOP_ONLY=PASS_INDEPENDENT`  
`FRONTEND_CODE=PASS_VERIFIED`  
`FRONTEND_DEPLOY=PASS`  
`REAL_E2E=BLOCKED_AUTHENTICATED_SESSION`  
`RUNTIME_CANDIDATE=f32c7a06569138ecee9588eda2632cf5a310056d`  
`LOVABLE_COMMIT=42be60e30be83b5b2b85866edb59ba368d074a65`  
`LOVABLE_URL=https://doos.lovable.app`  
`PROD_FREEZE=ON`  
`RELEASE=HOLD`
