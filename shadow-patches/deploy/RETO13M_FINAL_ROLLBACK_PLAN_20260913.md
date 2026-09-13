# RETO 13M — Final rollback plan

**Status:** release-package artifact only. No production action is authorized by this file.

## Principle

Rollback is **read-contract first, destructive never**. Raw data, historical snapshots and model evidence are retained. The preferred recovery is to restore the exact pre-cutover view/function definitions captured by `reto13m_final_preflight_readonly.sql`, not to drop underlying data.

No rollback may use `DROP ... CASCADE`.

## Mandatory rollback snapshot before cutover

Before any independently authorized production change, archive externally:
- target database identity + timestamp;
- exact Git implementation SHA;
- `pg_get_viewdef` for every changed view;
- `pg_get_functiondef` for every changed function/RPC;
- grants/RLS for changed public objects;
- current cron definitions if any scheduler change is separately authorized;
- row counts and canonical read-contract smoke output.

If this snapshot is absent or incomplete: **ABORT**. There is no cutover.

## Block rollback order

Rollback is reverse dependency order.

### 1. GLOBAL TOP_ONLY

Restore/remove only these final read contracts using the captured pre-cutover definitions:
- `v2.v_pick_del_dia_canonical`
- `v2.v_reto13m_top_only`
- `v2.v_global_top_only_ranked`
- `v2.v_global_top_only_universe`

Do not touch the canonical sport candidate sources. If the target did not previously contain one of these views, it may be dropped **without CASCADE** only after dependency inspection proves no unexpected consumer remains. Otherwise restore the snapshot definition.

### 2. NFL Fantasy

Repoint/restore public Fantasy read/RPC surfaces to their captured definitions. Do not delete player, roster, scoring, snapshot, validation or external-context data. If the new native projection authority is uncertain after rollback, leave native prediction publication fail-closed rather than falling back to an external betting/projection proxy.

### 3. NFL

Restore the captured public/RPC read definitions first. Retain model snapshots, injury/depth provenance and validation tables. A rollback must never bypass `iss129*` validation by publishing an older unvalidated probability path; if the previous definition cannot be proven safe, NFL remains fail-closed.

### 4. MLB

Restore captured read contracts; retain decision snapshots, OOS evidence and dossier data. Never roll back to price-band-derived probability authority. If the previous public surface used a price band as probability or selection authority, the rollback target is **closed**, not that contaminated surface.

### 5. result-event / WASTED

Stop settlement writers before restoring any changed grading RPC/trigger/view. Restore captured definitions in reverse order:
1. single-authority/push cutover layer;
2. WASTED/result-event consumer layer;
3. canonical result-event layer.

After restore, run idempotence checks before writers resume. Never replay already-settled rows blindly. No corners market may be graded from goals, and same-city ML identity must remain exact during rollback.

### 6. SOCCER

Restore read contracts before any model/runtime definition. Retain canonical snapshots, six-fixture evidence, competition mappings and dossier records. Never restore a path in which market/no-vig, a parallel predictor or a noncanonical distribution replaces P_RETO. Unsupported competitions remain fail-closed.

## Existing explicit rollback assets

Where dependency-compatible, the repository contains historical explicit rollback SQL, including:
- `shadow-patches/rollback/iss034b_parlay_grading_trigger_set_rollback.sql`
- `shadow-patches/rollback/iss041_soccer_joint_matrix_single_source_rollback.sql`
- `shadow-patches/rollback/iss010_analisis_completo_af_identity_rollback.sql`

These are **not automatically authoritative** for the final candidate. Their definitions must be compared with the pre-cutover snapshot before use.

## Cron rollback

Cron is isolated from the final closeout package. If a separately authorized cron-stability change is deployed, snapshot and roll it back independently. Never bundle a scheduler rollback with predictive model/read-contract rollback unless both exact changes were part of the same independently approved release.

## Verification after rollback

Required before declaring recovery:
- all expected read contracts resolve;
- temporal violations = 0;
- probability-domain violations = 0;
- no competing canonical P_RETO source is exposed;
- settlement replay produces no duplicate financial/state effect;
- browser consumers either show the prior verified canonical data or fail closed;
- production model/cutover gate returns to HOLD until a new independent release audit.

**Default safe state after any rollback: `PROD_FREEZE=ON`, `RELEASE=HOLD`.**
