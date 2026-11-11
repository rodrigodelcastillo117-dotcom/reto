# UNIFIED_PICK_SURFACES_V1 — AUDITORÍA

**Estado: AUDITADO, NO UNIFICADO.** La unificación no se implementó esta noche; abajo está el motivo y el plan.

---

## 1. Limitación de alcance, declarada primero

**El frontend no está en este repositorio.** Inventario completo: 25 `.sql`, 25 `.md`, 4 `.sh`, 2 `.ts` (fragmentos de edge functions), 1 `.py`, 1 `.csv`, 1 `.json`. Cero `.tsx/.jsx/.vue/package.json`.

Por tanto **no pude auditar ni corregir**: copy de la UI, `mercados.length > 0 → PICK`, banners "PICK SUGERIDO", jerarquía visual, game cards, estados de producto, ni el manejo de `false/null/undefined` en el cliente. Todo eso vive en Lovable, fuera de aquí.

Lo que sí pude auditar —y donde está la raíz del problema— es **la capa de datos que esas superficies consumen**.

## 2. Hallazgo central: 23 de 26 superficies no tienen gate económico

Vistas que exponen picks en `public`, y si tocan la cadena de autoridad:

| Vista | `economic_eligibility_v1` | `v_pick_canonico` | `es_pick` | `decision_pick_v1` |
|---|---|---|---|---|
| `v_pick_canonico` | **SÍ** | — | SÍ | no |
| `v_oraculo_canonico` | no | **SÍ** | SÍ | no |
| `v_super_pick` | **SÍ** | no | no | **SÍ** |
| `nfl_picks_premium` | no | no | no | no |
| `picks_premium` | no | no | no | no |
| `v_picks_premium` | no | no | no | no |
| `picks_recomendados_hoy` | no | no | no | no |
| `picks_recomendados_hoy_raw` | no | no | no | no |
| `v_poisson_recomendaciones` | no | no | no | no |
| `v_poisson_picks` | no | no | no | no |
| `v_mejores_picks_mlb` | no¹ | no | no | no |
| `v_picks_futbol_calc` | no | no | no | no |
| `v_picks_futbol_calibrado` | no | no | no | no |
| `v_picks_futbol_limpio` | no | no | no | no |
| `v_picks_medibles` | no | no | no | no |
| `v_picks_mlb_modelo` | no | no | no | no |
| `v_picks_para_parlay` | no | no | no | no |
| `v_anti_picks` | no | no | no | no |
| `picks_reales` | no | no | no | no |
| `ai_picks_historial` | no | no | no | no |
| `v_oraculo_picks_activos` | no | no | no | no |
| `v_pick_momio_libro` | no | no | no | no |
| `picks_huerfanos` | no | no | no | no |
| `picks_con_liga_inconsistente` | no | no | no | no |
| `oraculo_calibracion` | no | no | no | no |
| `oraculo_roi_por_liga` | no | no | no | no |

¹ `v_mejores_picks_mlb` gana el gate **solo tras desplegar ISS-003/009 V2**. Hoy no lo tiene.

**Solo 3 de 26 superficies participan de la autoridad económica.** El trabajo de ISS-003/009 endurece dos de ellas; las otras 23 siguen fuera.

## 3. Todas son alcanzables desde el cliente

Consulta a `information_schema.role_table_grants` en producción: **44 objetos con `pick` en el nombre tienen `SELECT` concedido a `anon` y/o `authenticated`**, incluyendo todas las vistas sin gate de la tabla anterior, más:

- `_backup_picks_fantasma_20260526` — tabla de respaldo expuesta a `anon`
- `pick_debug_logs` — logs de depuración expuestos a `anon`
- `daily_picks_cache`, `picks_futbol_cache`, `oraculo_prob_picks`, `pick_learning_data`, …

Y **24 de 26 vistas corren como OWNER** (sin `security_invoker=true`), así que **no aplican RLS** de las tablas subyacentes. Solo `picks_recomendados_hoy_raw` y `v_picks_futbol_limpio` son `invoker`.

Consecuencia práctica: un cliente anónimo puede leer superficies llamadas "premium"/"recomendados" que **nunca pasaron por el gate económico**, con independencia de lo que muestre la UI oficial.

## 4. Taxonomía — estado actual vs objetivo

La taxonomía pedida (🔬 ANÁLISIS / 🔥 MÁS PROBABLE / 💰 VALUE PICK / 🏆 TOP PICK) **no existe como concepto en la capa de datos**. Hoy hay:

- `es_pick` (booleano) en `v_pick_canonico` — mezcla "hay análisis" con "es apuesta"
- `nivel` ∈ {`ojo`, `fuerte`, `flojo`} en `v_mejores_picks_mlb` (V2 añade `informativo`)
- `señal`/`confianza` en NFL, sin gate
- "premium" en tres vistas distintas, sin gate

Los cuatro conceptos que la misión exige separar (`P_DECISION`, `ACCURACY_EVIDENCE`, `EV_DECISION`, `ECONOMIC_ELIGIBILITY`, `STAKE_FINAL`) **sí están separados en el gate** `economic_eligibility_v1` (9 gates independientes: provenance, authorized, skill, empirical, semantic, data_readiness, price, abstention, ev) — ese diseño es correcto y no debe tocarse. El problema no es el gate: es que **23 superficies no lo llaman**.

## 5. Por qué no unifiqué esta noche

Unificar significa cambiar el contrato de ~23 vistas en producción. Acabamos de demostrar, con un fallo real, que **cambiar el contrato de una sola vista sin verificación ordinal rompe el deploy**. Hacer 23 a la vez, de noche, sin frontend visible para verificar qué consume cada una, y con `PRODUCTION_DEPLOY = FORBIDDEN`, habría sido temerario.

Además, la instrucción es explícita: primero una autoridad de picks segura, luego ampliar consumidores. ISS-003/009 V2 es esa autoridad y aún no está desplegada.

## 6. Plan de unificación propuesto (para revisión humana)

**Fase U0 — inventario de consumo (requiere frontend).** Determinar qué superficie consume cada pantalla. Sin esto, cualquier cambio es a ciegas.

**Fase U1 — clasificar las 23 sin gate en tres grupos:**
- *Diagnóstico interno* (`picks_huerfanos`, `picks_con_liga_inconsistente`, `pick_debug_logs`, `_backup_*`): **revocar `anon`**. No son producto.
- *Histórico/medición* (`v_picks_medibles`, `ai_picks_historial`, `oraculo_*`): mantener, pero prohibidas como superficie de recomendación.
- *Producto* (`nfl_picks_premium`, `picks_premium`, `v_picks_premium`, `picks_recomendados_hoy`, `v_poisson_recomendaciones`, `v_super_pick`): **deben adoptar `economically_eligible` + `reason_code`**, columnas nuevas **al final**, con el patrón y los asserts ordinales de ISS-003/009 V2.

**Fase U2 — contrato frontend fail-closed:** `economically_eligible !== true` ⇒ informativo. `false`, `null` y `undefined` tratados igual. Prohibido inferir pick de `mercados.length > 0`.

**Fase U3 — taxonomía explícita** como columna derivada del gate, no como score inventado.

## 7. Recomendación inmediata (bajo riesgo, alto valor)

Antes de tocar contratos: **revocar `SELECT` a `anon` sobre `_backup_picks_fantasma_20260526`, `pick_debug_logs`, `picks_huerfanos`, `picks_con_liga_inconsistente`**. Son superficies de diagnóstico/backup sin razón de ser públicas. Es un `REVOKE`, no cambia ningún contrato de vista y reduce superficie de exposición de inmediato.

*(No ejecutado: requiere producción. Preparado para GO humano.)*
