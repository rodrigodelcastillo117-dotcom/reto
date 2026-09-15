# ISS-003 / ISS-009 — REVALIDACIÓN DE ESTADO (repo + prod read-only) · 2026-09-08

Revalidación desde cero (no memoria) antes de GO. Prod = solo SELECT. Sin deploy.

## 1. SHA / FREEZE
| Artefacto | SHA256 | Nota |
|---|---|---|
| `iss003_009_mlb_governance.sql` | `57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad` | == REVIEWED_SHA |
| `run_deploy.sh` REVIEWED_SHA guard | `57b7a40…cad` | aborta si drift |
| `deploy/deploy_iss003_009.sql` | `60c777dca7297c01700e5e8667abad3ea2d0b145a8efb07c47fb272d750a8b60` | |
| `deploy/smoke_post_commit.sql` | `c5788428be6a2334665160025ca5faf53dd03af015a2f1f42cda277282ef782d` | |
| `rollback/iss003_009_semantic_rollback.sql` (PRIMARIO) | `ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b` | NO CASCADE |
| `rollback/iss003_009_rollback.sql` (secundario) | `32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530` | DROP CASCADE, offline |

`SHA_DRIFT = NO`.

## 2. ROLLBACK
- `PRIMARY_ROLLBACK_MODE = SEMANTIC_NO_CASCADE` (run_rollback.sh default = semantic).
- `DROP_CASCADE_PRESENT`: solo en el secundario `--structural` (offline). El semántico no ejecuta ningún CASCADE (grep: solo comentarios "NO DROP, NO CASCADE").
- `SEMANTIC_ROLLBACK_AVAILABLE = YES`. Cascade auditado: CASCADE_DROPPED_SET == ROLLBACK_RECREATED_SET (3 vistas), conservado solo como procedimiento secundario.

## 3. ESTADO PROD (read-only, medido)
| Señal | Valor medido | Interpretación |
|---|---|---|
| `v_pick_canonico` columnas | **43** (col44 = null, sin `es_pick_reason`) | SQL ISS-009B **NO desplegado** (pre-deploy) |
| `v_mejores_picks_mlb` economically_eligible / reason_code | **ausentes** | ISS-009A SQL no desplegado |
| `analisis_completo` overloads | **1** | overload guard limpio; regprocedure `analisis_completo(text)` resuelve |
| `economic_eligibility_v1` overloads | 1 | ok |
| `economic_model_authority` filas autorizadas | **0** (tabla vacía) | `CURRENT_AUTHORIZED_MODELS = NONE`; MLB authorized = FALSE por ausencia |
| `v_pick_canonico` es_pick=true | **0** | ISS-003 semántica ya sostiene en la vista 43-col viva |

## 4. MONEY_ZERO (assert real, no inferido)
| Superficie viva | Métrica | Valor |
|---|---|---|
| `v_super_pick` | kelly_pct_sugerido > 0 | **0** |
| `mejor_oportunidad_hoy(500)` | kelly_pct > 0 | **0** |
| `reto_picks_hoy(apodo)` ×4 usuarios | monto_autorizado > 0 | **0** |
| `reto_picks_hoy(apodo)` ×4 usuarios | puede_apostar = true | **0** |
| `favoritos_bien_pagados` | — | **no existe** (no es superficie viva) |

`MONEY_ZERO = PASS` (dólares/kelly/stake = 0 en todas las superficies automáticas vivas).

**Fuga semántica viva (pre-deploy):** `v_mejores_picks_mlb` tiene **3 filas nivel ojo/fuerte** (de 4).
Es una etiqueta de recomendación (kelly=0, no es $), y es EXACTAMENTE lo que el deploy convierte a
`informativo` (assert G2). Persiste hasta desplegar.

## 5. ISS-003 (frozen artifact)
- Sin `COALESCE(confiable, true)` activo (los 2 matches son comentarios que documentan el fix ISS-003b: NULL→FALSE fail-closed).
- `calibracion_confiable` MLB = FALSE (hardcode `true` corregido). `calibracion_confiable ≠ MODEL_SKILL` (gates distintos).
- `MODEL_SKILL=INSUFFICIENT`, `economic_model_authorized=FALSE`, `economically_eligible=FALSE`, stake=0. P/EV NO modificados.

## 6. ISS-009A / 009B (contrato en artefacto)
- Deploy asserts: B0 overload=1; B1 `analisis_completo` propaga `economically_eligible`+`eligibility_reason_code`; C1/C2 `v_mejores_picks_mlb` con `economically_eligible`+`reason_code`; D2/D3/G2/G3/G4 (nivel→informativo, elegible=false, reason=MODEL_VERSION_PROVENANCE_MISSING).
- Frontend (`ba828acc`, Lovable — fuera de este repo): `recommended = mercado.economically_eligible === true`; false/null/undefined → **"ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"**. Pre-deploy el campo está ausente ⇒ undefined ⇒ informativo ⇒ **fail-closed sostiene sin importar el orden de deploy**. `FRONTEND_FAIL_CLOSED = PASS` (estático). Visual = PENDING_USER.

## 7. P/EV INVARIANCE
Deploy captura baseline bajo `REPEATABLE READ` y compara BEFORE/AFTER con `EXCEPT ALL` bidireccional
(F1 `P_VALUE_DIFF=0`, F2 `EV_VALUE_DIFF=0`). No usa Athletics ni EV absoluto como constante.
Se ejecutan DENTRO de la transacción de deploy ⇒ hoy `NOT_RUN` (no desplegado).

## 8. TRANSPORTE
- `psql` presente (v16.13) pero **sin** `DATABASE_URL`/`PGHOST`/creds ⇒ sin conexión a prod.
- Artefacto congelado = 36 KB ⇒ MCP inline prohibido (corrupción/regla).
- `SAFE_SQL_TRANSPORT = BLOCKED`. `DEPLOY_EXECUTED = NO`. `POST_DEPLOY_ASSERTS = NOT_RUN`.

Paquete turnkey listo: `bash shadow-patches/deploy/run_deploy.sh` con `DATABASE_URL` real (guarda SHA → psql ON_ERROR_STOP). El usuario ejecuta.
