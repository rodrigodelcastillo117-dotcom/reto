# RETO 13M — FINAL RELEASE PACKAGE — 2026-09-13

## Release status

**PACKAGE = PASS_STAGED**  
**PRODUCTION MODEL/CUTOVER = HOLD**  
**PROD_FREEZE = ON**

This package is reproducible evidence and an ordered cutover plan. It is **not** production authorization.

### Exact candidate identity

- Repository: `rodrigodelcastillo117-dotcom/reto`
- Branch: `chatgpt/reto13m-closeout-20260912`
- **Runtime implementation SHA:** `91d69d0e372494b3ab017778ec000bbf4073ae44`
  - this is the exact runtime candidate through ISS132 GLOBAL TOP_ONLY.
- Release-support files were added after the runtime SHA without changing runtime/model SQL semantics:
  - read-only preflight commit `25e9580e1e2c26261b7999596e19939434946222`
  - clean-bootstrap order commit `0cb8abfb137940099463e548f6f6106b8af0d94a`
  - rollback plan commit `974de1abe09057c592644052fe397c0c1062ad37`

The commit containing this markdown is package metadata only and is deliberately not used as a self-referential runtime SHA.

## Control-plane block ledger

| Block | Milestone SHA | Staged gate | Key final evidence |
|---|---|---|---|
| SOCCER | `5ea7b5ea5ff003c526c38dfaa3d98375e1913e76` | PASS | Six owner fixtures full real path; price invariance; builder -> staged -> event gate -> candidates -> dossier; one canonical distribution / P_RETO. |
| result-event / WASTED | `92ee0dec8240824c035e95c9f968699c06329b3c` | PASS | Retry/reversal/correction/recovery/push dedupe adversarials after single outbox authority (`170aaf64828a96a1f36ea3ebf09cee3c74d92d42`). |
| MLB | `4e3ab722777898d506a5840a7d07c01c77e47c76` | PASS_FAILCLOSED | Exact forward-validation publication gate. Insufficient validation closes publication; it never licenses a fallback probability. |
| NFL | `45704823aba5bd504d53ca55e7d78b780b92553b` | PASS_FAILCLOSED | Validation authority gates direct RPC and public/tablero model surfaces. Insufficient OOS evidence closes publication. |
| NFL Fantasy | `90705baaa18e226ce826686f100281c7a16ef1f8` | PASS_FAILCLOSED | Native projection/ranking/Start-Sit requires canonical temporal snapshot + OOS authority; hostile 99-point leak test produced zero canonical leak. |
| GLOBAL TOP_ONLY | `91d69d0e372494b3ab017778ec000bbf4073ae44` | PASS_STAGED | One global model-only rank after hard gates; no quota/filler; P_RETO copied unchanged; 0/1 selected; Pick del Día exact alias. |

`PASS_FAILCLOSED` means the safety contract passed; it does **not** assert that the underlying predictive model has enough evidence to publish. A closed sport stays closed.

## Dependency DAG

```text
SOCCER canonical chain
  -> result-event / WASTED grading identity
  -> MLB canonical candidate + forward-validation authority
  -> NFL canonical candidate + OOS release authority
  -> NFL Fantasy canonical projection authority
  -> GLOBAL TOP_ONLY (ISS132; LAST predictive selector)
  -> canonical read-contract switches
  -> browser/E2E verification
  -> independent release decision
```

Detailed exact file ordering: `shadow-patches/deploy/RETO13M_FINAL_BOOTSTRAP_ORDER_20260913.md`.

## Preflight

Run, read-only, against the exact intended target immediately before any authorized cutover:

`shadow-patches/deploy/reto13m_final_preflight_readonly.sql`

The output must be archived as rollback evidence. Any missing canonical dependency, invalid probability, temporal violation, or inability to capture current definitions => ABORT.

## Rollback

Authoritative release-package rollback policy:

`shadow-patches/deploy/RETO13M_FINAL_ROLLBACK_PLAN_20260913.md`

Rules:
- reverse dependency order;
- restore captured view/function definitions first;
- retain raw/history/snapshot/OOS evidence;
- never `DROP ... CASCADE`;
- never roll back into a known contaminated probability authority;
- safest fallback is fail-closed;
- after rollback: `PROD_FREEZE=ON`, `RELEASE=HOLD`.

## Read-contract switch order

No switch is authorized yet. When independently authorized, the only permitted dependency order is:

1. Canonical sport candidate surfaces proven on the exact candidate.
2. Result/settlement consumers after event-identity/idempotence checks.
3. `v2.v_global_top_only_universe`.
4. `v2.v_global_top_only_ranked`.
5. `v2.v_reto13m_top_only`.
6. `v2.v_pick_del_dia_canonical` last, as an exact alias of the Reto13M top-only surface.
7. Frontend consumers only after DB smoke confirms equality and fail-closed states.

Older one-per-sport/filler selector semantics (`iss064`, `iss078`, `iss080`) are superseded by ISS132 and must not be reintroduced after the switch.

## Cron isolation

Cron/scheduler changes are **outside this release package**. Any previously authorized cron-stability change must remain independently versioned, audited and rollbackable. Scheduler changes cannot be bundled as justification for changing model semantics.

## Independent verification still required before release

The following are hard release gates, not cosmetic TODOs:

### Gate I — exact-composite disposable bootstrap

An independent verifier must create a **fresh disposable Supabase branch corresponding to the exact runtime candidate** and execute the clean-bootstrap order from empty/known baseline through ISS132, then rerun every block's acceptance tests. Reusing a partially evolved disposable is not enough for final release authorization.

Required proof:
- exact source SHA recorded;
- all ordered migrations apply without manual drift repair;
- six SOCCER owner fixtures pass end-to-end;
- WASTED adversarials pass;
- MLB/NFL/Fantasy remain correctly fail-closed where validation authority is absent;
- GLOBAL output is deterministic, contains no duplicate event, mutates P_RETO zero times, has zero filler, and Pick del Día alias diff is zero;
- rollback snapshot generated successfully.

### Gate II — real browser/E2E on final canonical reads

The published frontend project exists, but frontend work may be invoked only when a concrete frontend task exists **and** available credits are established. The concrete task is now final canonical-read E2E, but the workspace status query did not expose a credit balance; therefore no frontend edit/build turn was spent from this package.

Required browser evidence after exact-composite DB verification and before cutover:
- Favoritos/Top surfaces consume canonical GLOBAL/Pick-del-Día contract only;
- Soccer dossier shows canonical trend / last-5 / H2H without creating a second P_RETO;
- live-event rendering preserves event identity and does not bypass canonical gates;
- MLB/NFL/Fantasy fail-closed states render as unavailable/diagnostic, never as fabricated recommendation;
- no stale one-per-sport/filler selector survives in UI;
- same canonical event/P_RETO identity across list, detail and favorites views.

Until both Gate I and Gate II pass independently, global release remains HOLD.

## Known limitations / intentional safe states

- MLB, NFL and NFL Fantasy may legitimately emit no native recommendation when their validation authority is insufficient. That is the designed safe result, not a release defect.
- GLOBAL `RETO_SCORE_V1` is unvalidated ranking metadata over already-authorized candidates. It does not calibrate or replace P_RETO. The staged policy is intentionally conservative and selects global top-1 (or zero).
- Existing Supabase security-advisor findings on older public/security-definer/RLS surfaces remain separate hardening work unless an independent release audit finds one on a path actually exposed by this cutover. ISS132 itself introduced `security_invoker=true` views and no new advisor finding in its disposable test.

## Release decision matrix

| Condition | Decision |
|---|---|
| Package files/version/DAG/rollback/preflight complete | `PACKAGE=PASS_STAGED` |
| Any individual predictive sport lacks validation authority | Keep that sport fail-closed |
| Exact-composite disposable bootstrap not independently passed | `RELEASE=HOLD` |
| Browser/E2E canonical-read verification not independently passed | `RELEASE=HOLD` |
| Any production mutation before independent verification | Release invalid; restore/hold |
| Both independent gates PASS with no drift and explicit owner release authorization | Eligible for a separate production cutover decision |

## Final package gate

`RELEASE_PACKAGE=PASS_STAGED`  
`INDEPENDENT_VERIFICATION=PENDING`  
`PROD_FREEZE=ON`  
`RELEASE=HOLD`
