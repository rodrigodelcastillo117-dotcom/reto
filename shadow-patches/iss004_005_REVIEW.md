# ISS-004 + ISS-005 — DIAGNÓSTICO + PATCH SHADOW

**Modo:** DIAGNÓSTICO + PATCH SHADOW. **NO DEPLOY.**
**Estado de dinero:** `CURRENT_AUTHORIZED_MODELS = NONE`, picks económicos = 0. Este bloque **no autoriza ningún modelo** y no toca `economic_model_authority`.
**AS_OF:** 2026-09-07 (slate en vivo: 116 filas candidatas con precio de mercado).
**Objetivo:** que toda recomendación automática tenga **una sola cadena económica**:
`model output → economic_eligibility_v1 → P_DECISION → EV_DECISION → kelly_base → risk/caps/portfolio → stake_final`.

---

## Resumen ejecutivo

- **ISS-004 (EV mostrado ≠ EV que decide) — CONFIRMADO en producción.** En las **116/116** filas de `v_pick_canonico` con precio de casa, el `ev_pct` que se muestra (y que **ordena** la tarjeta y **alimenta el gate** de elegibilidad) diverge del EV que decide el dinero en **>0.5pp**. **19** filas **cambian de signo** (se ven `+EV`, deciden `−EV`). Desvío máximo **58.05pp**. De los picks que la vista trata como valor, sólo **20/116** son realmente `+EV` una vez que decide `decision_economica_v1`.
- **ISS-005 (múltiples autoridades de sizing) — CONFIRMADO.** Coexisten **cuatro** autoridades de dimensionamiento con matemáticas distintas: `kelly_stake__base` (canónica, sobre `prob_decide`), `kelly_fraccion_pct` (tope plano 0.52, sobre `calibrar_prob_motor_live`), el clamp `[0.5,5.0]` de `v_super_pick`, y un **motor Kelly en JavaScript** en el frontend (`kelly-calculator.ts` + `KellyCriterion.tsx`) con topes propios (8/5/3%).
- **Causa de por qué reaparecieron los caminos paralelos tras #207/#209:** #207 unificó la autoridad de sizing **del camino del usuario** (`kelly_stake` → `reto_picks_hoy`) y ISS-006.2 cerró la **visibilidad** (es_pick / apto_para_mostrar). Ninguno de los dos tocó los **números** de las superficies de descubrimiento/marketing (`v_pick_canonico`, `mejor_oportunidad_hoy`, `favoritos_bien_pagados`, `v_super_pick`), que conservaron su propio EV (sobre `probabilidad_pct` cruda) y su propia fracción de Kelly. Gatear la visibilidad ≠ unificar la verdad económica.
- **El patch shadow** introduce **un solo compositor** — `decision_pick_v1()` — que **reutiliza** (no duplica) `decision_economica_v1` (P/EV) y `economic_eligibility_v1` (gates), y es el único lugar donde `P_RAW` se convierte en fracción de Kelly, siempre desde `prob_decide`. Reenruta las 4 superficies SQL y neutraliza `kelly_fraccion_pct` como autoridad paralela. `kelly_stake__base` **no se toca** (ya es correcta y sirve de referencia).
- **PREDEPLOY_ISS004_005_GATE = PASS** (diseño verificado por simulación inline; ver §11). Falta la prueba de humo en navegador (403 desde aquí) antes de un eventual deploy.

---

## 1) ECONOMIC_AUTHORITY_MAP_BEFORE

| Superficie | Prob que usa | EV que muestra | Sizing | Cadena |
|---|---|---|---|---|
| `reto_picks_hoy__base` (camino de usuario) | `prob_decide` (kelly_stake__base) | `ev_pct` (decision) | `kelly_stake__base` ($ real) | **✅ canónica** |
| `v_pick_canonico.ev_pct` | `probabilidad_pct` (P_RAW) | `(P_RAW·momio−1)` | — (sólo edge/ev; ordena por `ev_pct`) | ❌ raw |
| `mejor_oportunidad_hoy` | `calibrar_prob_motor_live` | `(p_cal·momio−1)` | `kelly_fraccion_pct` (tope 2/5%) | ❌ paralela |
| `favoritos_bien_pagados` | `calibrar_prob_motor_live` | `(p_cal·momio−1)` | `kelly_fraccion_pct` (tope 5%) | ❌ paralela |
| `v_super_pick` | `prob_observada`/`prob_declarada` | `ev_real_pct` (ROI de segmento) | clamp `[0.5,5.0]` de `kelly_pct` | ❌ paralela |
| Frontend `KellyCriterion.tsx` | `aiCalificacion.prob_estimada` (modelo LLM) | — | `calculateKelly()` en JS (topes 8/5/3%) | ❌ **bypass en JS** |
| Frontend `CalculadoraMonto.tsx` | prob del usuario | — | RPC `tamano_apuesta` (server) | ✅ manual OK |

**Autoridades de PROBABILIDAD vivas simultáneamente para el mismo pick:** `probabilidad_pct` (P_RAW), `calibrar_prob_motor_live`, `prob_decide` (decision_economica_v1). Medido hoy: `P_RAW ≠ prob_decide` en **111/116**; `calibrar_prob_motor_live ≠ prob_decide` en **106/116**.

**Autoridades de SIZING vivas:** `kelly_stake__base`, `kelly_fraccion_pct`, clamp de `v_super_pick`, `kelly-calculator.ts` (JS). Cuatro.

---

## 2) ROOT_CAUSE_ISS004

`v_pick_canonico`, CTE `calc`, define:

```sql
ev_pct  = round((probabilidad_pct/100.0 * momio_mercado - 1) * 100, 1)   -- P_RAW, no prob_decide
edge_pct= round((probabilidad_pct/100.0 - 1.0/momio_mercado) * 100, 1)
```

Ese `ev_pct` es el **EV declarado** (sobre la probabilidad cruda del modelo), no el **EV que decide** (`decision_economica_v1.ev_pct`, que aplica sesgo medido + recorte Beta-Jeffreys + factor Wilson sobre `prob_decide`). Y ese **mismo** `ev_pct` hace triple trabajo:

1. **se muestra** en la tarjeta (`MejorPickHoy.tsx`, etc.),
2. **ordena** los picks: `row_number() OVER (... ORDER BY m.ev_pct DESC ...)` → el ranking mismo persigue el EV equivocado,
3. **alimenta el gate**: `economic_eligibility_v1(... 'ev_pct', c.ev_pct, 'ev_threshold', 2.5)` → el umbral económico se evalúa contra el EV declarado.

`mejor_oportunidad_hoy` y `favoritos_bien_pagados` no usan ni siquiera P_RAW: usan una **tercera** probabilidad, `calibrar_prob_motor_live`, que tampoco es `prob_decide`. Es la reaparición literal de #129 / #209.

**Efecto:** un pick puede verse `+37.9% EV` y decidir `−7.16%` (Toronto–Nashville, §8). Es la misma cifra la que el usuario ve, la que ordena la lista y la que decide si pasa el gate — y no es la que dimensiona.

---

## 3) ROOT_CAUSE_ISS005

Existen cuatro matemáticas de sizing con entradas y topes distintos:

1. **`kelly_stake__base`** (canónica, #207): cuarto de Kelly sobre `prob_decide` (sesgo + Beta + Wilson), techo `config_staking` (5%), piso $50, `f_full=(p·b−(1−p))/b`. Es correcta.
2. **`kelly_fraccion_pct`** (IMMUTABLE): aplica un **tope plano** `p := least(prob/100, 0.52)` — no ve sesgo, ni recorte, ni Wilson — cuarto de Kelly, `q=1−p−push`. La llaman `mejor_oportunidad_hoy` y `favoritos_bien_pagados` **con `calibrar_prob_motor_live`**, no con `prob_decide`. Doble divergencia: probabilidad equivocada + haircut plano.
3. **`v_super_pick`**: `kelly_pct_sugerido = round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct,1.0))),2)` — clamp `[0.5,5.0]` de un `kelly_pct` **almacenado**, sin relación con `prob_decide`.
4. **Frontend `kelly-calculator.ts`**: motor Kelly en JS con topes propios `MAX_APUESTA_ELITE=8% / SOLIDO=5% / MARGINAL=3%` y `*0.25`, alimentado por una **probabilidad del modelo** (`aiCalificacion.prob_estimada`).

**Por qué reaparecieron tras #207/#209:** #207 arregló el **camino del usuario** (RPC de dinero real) y ISS-006.2 gateó la **visibilidad**. Las superficies de descubrimiento nunca se reenrutaron a la autoridad única — se quedaron con su EV y su Kelly propios, y sólo se les tapó la salida. Con `NONE` autorizado hoy no se ve, pero **autorizar un modelo destaparía las cuatro matemáticas a la vez**.

---

## 4) CANONICAL_P_EV_AUTHORITY

**`decision_economica_v1(p_prob, p_momio, p_mercado)`** (LANGUAGE plpgsql, STABLE). Es transcripción **verbatim** del núcleo de probabilidad/EV de `kelly_stake` (md5 `d9ba6526…`, #262). Produce: `prob_entrada_pct` (P_RAW), `sesgo_pp`, `recorte_beta_pp`, `factor_wilson`, `prob_antes_wilson_pct` (= P_FAIR), `prob_decide_pct` (= P_DECISION), `ev_pct` (= EV_DECISION, sobre `prob_decide`) y `ev_pct_declarado` (sobre P_RAW, sólo transparencia). **No se duplica ni se reescribe** — es la autoridad. El patch la **consume**.

**P_FAIR:** el núcleo no materializa una etapa "fair" independiente; lo más cercano es `prob_antes_wilson_pct` (calibrada por sesgo + recorte Beta, antes del haircut de varianza). Se expone con ese significado y **no se inventa** una etapa nueva.

---

## 5) CANONICAL_SIZING_AUTHORITY

Dos entradas, **un solo núcleo**:

- **$ del usuario:** `kelly_stake__base(apodo, …)` (#207). Ya calcula `prob_decide` idéntica y dimensiona sobre ella. **No se toca.** Es la referencia.
- **Fracción de superficie (sin usuario):** **`decision_pick_v1()`** (NUEVO, Parte 1 del patch). Pide `prob_decide`/EV a `decision_economica_v1`, pide gates a `economic_eligibility_v1`, y calcula la fracción de Kelly con la **misma fórmula** que `kelly_stake__base` (`f_full=(p·b−q)/b`, cuarto de Kelly), **siempre sobre `prob_decide`**. Si `eligible=false` → `kelly_pct=0`. Es el único lugar donde `P_RAW` se convierte en fracción.

`kelly_fraccion_pct` deja de ser autoridad: se reescribe como wrapper que delega la probabilidad a `decision_economica_v1` (Parte 2). El clamp de `v_super_pick` y el motor JS se reenrutan/retiran (Partes 6 y §10).

**Contrato de campos (sin ambigüedad):** `p_raw`, `p_fair`, `p_decision`, `ev_decision`, `ev_declarado`, `kelly_completo_pct`, `kelly_base_pct` (cuarto de Kelly sin tope = autoridad), `kelly_pct` (topado, a mostrar), `economically_eligible`, `blocked_reason`. Etapa que no existe → se reporta, no se inventa: **P_FAIR** = `prob_antes_wilson_pct` (aproximación honesta, ver §4); la capa **portfolio** (`stake_pre_portfolio → stake_final`, RONGOL/CDaR de #212/#213) es **MISSING/PARCIAL** hoy — existe sólo en `reto_picks_hoy__base` (`exposicion_pct`, `bloqueado_por`, `veto_resumen`) y queda fuera de este bloque.

---

## 6) MANUAL_VS_AUTOMATIC_MAP

| Objeto | Clase | Nota |
|---|---|---|
| `v_pick_canonico`, `mejor_oportunidad_hoy`, `favoritos_bien_pagados`, `v_super_pick` | **MODEL_DERIVED_AUTOMATIC** | reenrutar a la cadena única |
| `reto_picks_hoy__base` / `kelly_stake__base` | **MODEL_DERIVED_AUTOMATIC (canónica)** | ya alineada; referencia |
| `kelly_fraccion_pct` | **MODEL_DERIVED_AUTOMATIC (paralela)** | reescribir a wrapper |
| `calibrar_prob_motor_live` | fuente de probabilidad **paralela** | sacar del camino de sizing |
| Front `KellyCriterion.tsx` + `kelly-calculator.ts` | **MODEL_DERIVED_AUTOMATIC (bypass JS)** | reenrutar a RPC server (§10) |
| Front `CalculadoraMonto.tsx` | **MANUAL_CALCULATOR** | OK: prob del usuario → RPC `tamano_apuesta` |
| `tamano_apuesta__base` | **MANUAL_CALCULATOR** | OK: prob del usuario |
| `revisar_apuesta__base` / `use-tamano-apuesta` / `AvisoTamanoApuesta` | **RISK_REVIEW** | OK: sólo añade bloqueos/avisos |
| `StakeGateModal.tsx` / `verificar_limites` | **RISK_REVIEW / SERVER_CONSUMER** | OK |
| `kelly_usuario` | **DEAD_LEGACY** | 0 llamadores server |
| Front `value.ts` `kelly/ev`, `coreModel.expectedValue`, `KellyReferenceTable` | **DEAD_LEGACY / utility** | sin consumidor renderizado (verificar) |
| Front `safetyEngine.ts`/`coreModel.ts`, `monteCarloEngine.ts` | **modelo de prob en JS (no dinero)** | fuera de ISS-004/005; flag aparte |
| `RiskSimulator.tsx` (RPC `simular_bankroll`) | **MANUAL_CALCULATOR / SERVER_CONSUMER** | OK |

---

## 7) FRONTEND_KELLY_JS_STATUS = **CLOSED_BY_PATCH** (barrido global halló **3** caminos vivos; los 3 cerrados)

> **RESUELTO 2026-09-07** (commit Lovable `5e814916`, `tsgo exit 0`, build OK, verificado por diff + lectura de archivos):
> KellyCriterion.tsx y KellyReferenceTable.tsx **borrados**; AddPickForm.tsx y OraculoBanner.tsx (importador oculto) limpios; AiCopilotBar.tsx y PortfolioOptimizerModal.tsx sin matemática de dinero (texto "Sizing automático deshabilitado — requiere decisión económica del servidor"); `kelly-calculator.ts` reducido a `META_SEMANAL` + `checkOverbet` (guardia sobre el monto tecleado por el usuario = RISK_REVIEW). **No queda matemática cliente modelo→dinero.** El diagnóstico original (los 3 caminos) queda abajo como registro.

### Diagnóstico original (antes del patch)

Auditoría estática global del proyecto Lovable `reto13` (`00f8f06b-…`), sólo lectura. El barrido completo (fórmulas Kelly/EV + caps `0.08/0.05/0.03/0.02`) encontró **TRES** bypasses `MODEL_DERIVED_AUTOMATIC`, no dos.

**Bypass 1 — `src/lib/kelly-calculator.ts` + `src/components/reto/KellyCriterion.tsx`.** Motor Kelly puro en JS (`edge=(p·momio)−1`, `kellyFraccion=kellyClasico*0.25`, `monto=bankroll*apuestaPct`), topes propios `0.08/0.05/0.03`, `MAX_PARLAY_PCT=0.05`, `META_SEMANAL=0.15`. `KellyCriterion.tsx` (en `AddPickForm.tsx:972`) lo alimenta con la prob de modelo `aiCalificacion.prob_estimada` (grader `calificar-pick-previo`) y pinta un **monto en pesos** + `% bankroll`. Redundante: el mismo formulario ya tiene `CalculadoraMonto` (RPC `tamano_apuesta`) justo debajo.

**Bypass 2 — `src/components/fut/AiCopilotBar.tsx` (NUEVO, vivo en `Fut.tsx`).** Helper propio `kellyFraction(prob,decOdds,0.25)` → `stakePct` desde `m.safe.confidence` (modelo **cliente**), pinta "Estimación de stake (¼ Kelly) — X% banca".

**Bypass 3 — `src/components/fut/PortfolioOptimizerModal.tsx` (NUEVO, vivo — botón "⚖️ BANCA" en `Fut.tsx`).** Kelly por pick desde `safe.confidence/100` × bankroll (`semana_bankroll`), caps propios 5% pick / 40% liga / 25% portafolio, EV=`(p·odd−1)·100`, y muestra "Monto total sugerido a arriesgar hoy: X% ≈ $Y MXN" y monto por pick.

**Agravante:** los bypasses 2 y 3 se alimentan del **modelo cliente** `safetyEngine.ts` (`calculateUltraSafePick().confidence`, un Poisson/Dixon-Coles en JS) — no del servidor. Son una autoridad de probabilidad Y de sizing completamente fuera de la cadena económica; ni siquiera pasan por `decision_economica_v1` ni por la elegibilidad.

**Camino sancionado (contraste):** `CalculadoraMonto.tsx` → RPC `tamano_apuesta`; `StakeGateModal` ← `revisar_apuesta.r.kelly`; `DevilsAdvocateModal` ← RPC `devils_advocate`; `RiskSimulator` ← RPC `simular_bankroll`. Todos SERVER_CONSUMER.

**DEAD_LEGACY:** `KellyReferenceTable.tsx` (caps×bankroll, sin prob de modelo; sin importador localizado → borrar con `kelly-calculator.ts`). `value.ts` `kelly()/ev()` quedan como helpers sin consumidor modelo→dinero (vigilar que no se recableen).

**El resto de superficies de dinero/EV son SERVER_CONSUMER** (leen `v_pick_canonico`, RPC `mejor_oportunidad_hoy`, `parlay_ev_real`, etc.) — heredan el arreglo SQL.

---

## 8) BEFORE_AFTER_REAL_CASES

Casos reales del slate de hoy (Moneyline). **Tres probabilidades distintas por fila** y sign-flips de EV. "AFTER" = lo que mostraría/decidiría la cadena única (hoy, con `NONE`, el **stake es $0** en todos por ISS-006.2; lo que cambia es que **EV_UI == EV_DECISION** y hay **una sola fracción**).

| Partido / pick | Momio | P_RAW | calibrar_live | **P_DECISION** | EV mostrado (BEFORE) | **EV_DECISION (AFTER)** | kelly_fraccion_pct (BEFORE) | AFTER |
|---|---|---|---|---|---|---|---|---|
| Toronto FC vs Nashville SC — Gana Nashville | 2.20 | 62.7 | 60.9 | **42.2** | **+37.9** | **−7.16** | **3.00%** | **$0**, EV −7.16, razón MODEL_VERSION_PROVENANCE_MISSING |
| San Diego vs San Jose — Gana San Diego | 1.769 | 64.3 | 62.4 | **43.5** | +13.7 | **−23.04** | 0 | $0, EV −23.04 |
| Estrela vs Braga — Braga ML | 1.741 | 65.3 | 63.3 | **45.0** | +13.7 | **−21.57** | 0 | $0, EV −21.57 |
| Como vs RB Leipzig — Leipzig ML | 3.80 | 31.1 | 32.2 | **26.0** | +18.2 | **−1.16** | 1.62% | $0, EV −1.16 |
| LAFC vs NY Red Bulls — Empate | 5.00 | 20.4 | 22.4 | **16.9** | +2.0 | **−15.70** | 0.13% | $0, EV −15.70 |
| Atlanta vs Orlando — Gana Orlando | 3.05 | 34.6 | 35.4 | **29.3** | +5.5 | **−10.59** | 0.67% | $0, EV −10.59 |
| Minnesota vs FC Dallas — Gana Dallas | 3.70 | 28.7 | 30.0 | **24.7** | +6.2 | **−8.44** | 0.57% | $0, EV −8.44 |

Los casos soccer de la sesión anterior (Vancouver Empate P 24.7%→~20.9%, Braga, Independiente del Valle) muestran el **mismo mecanismo**; Braga sigue en el slate y aparece arriba. **Paridad interna demostrada; stake final $0 por `NONE`.**

Agregado sobre las 116 filas: `ev_pct` mostrado diverge de `EV_DECISION` en **116/116** (máx 58.05pp), **19** sign-flips, y sólo **20/116** son `+EV` de verdad.

---

## 9) SQL_DIFF

Archivo: `shadow-patches/iss004_005_cadena_economica_unica.sql` (SHADOW, no aplicado). Resumen:

1. **NUEVO `decision_pick_v1(deporte,mercado,fuente,model_version,p_raw,momio,push,techo,gates)`** — compositor único. Delega P/EV a `decision_economica_v1` y gates a `economic_eligibility_v1`; calcula la fracción de Kelly sobre `prob_decide`; `eligible=false → kelly_pct=0`. Devuelve el contrato de §5. `REVOKE` a `anon`, `GRANT` a `authenticated`/`service_role`.
2. **`kelly_fraccion_pct`** — reescrita: deja de topar en 0.52; delega la probabilidad a `decision_economica_v1` (`prob_usada == prob_decide`). Nuevo arg opcional `p_mercado`. Pasa de IMMUTABLE a STABLE.
3. **`v_pick_canonico`** — replace() en el CTE `calc`: `ev_pct` pasa de `(P_RAW·momio−1)` a `decision_economica_v1(…)->>'ev_pct'` (EV_DECISION). Arregla display + ORDER BY del rank + gate de una vez. Fidelidad de bytes por `pg_get_viewdef` + guarda `SUBSTR_NOT_FOUND`.
4. **`mejor_oportunidad_hoy`** — reescrita: un `decision_pick_v1` por fila; `prob_pct=P_DECISION`, `ev_pct=EV_DECISION`, `kelly_pct` de la cadena; se elimina `calibrar_prob_motor_live` y `kelly_fraccion_pct`-sobre-cruda; techo único 5%.
5. **`favoritos_bien_pagados`** — reescrita igual: `decision_pick_v1` sobre la prob cruda de `motor_cache` + momio; `ev_pct=EV_DECISION`, `fraccion` de la cadena; `info_completa` exige elegibilidad + dato clave.
6. **`v_super_pick`** — replace(): `kelly_pct_sugerido` pasa del clamp `[0.5,5.0]` a `decision_pick_v1(…)->>'kelly_pct'`. (`ev_real_pct` = ROI de segmento se documenta como métrica distinta a relabelar en frontend, no se toca la vista.)

**No se toca** `kelly_stake__base`, `decision_economica_v1`, `economic_eligibility_v1`, `economic_model_authority` ni ninguna autorización.

---

## 10) FRONTEND_DIFF (propuesta, no aplicada — requiere GO; edita Lovable = créditos)

**A. `KellyCriterion.tsx` — BORRAR componente y uso.** Es importado sólo en `AddPickForm.tsx`; eliminar el import y el bloque `<KellyCriterion …/>` (~líneas 972–976). El `<CalculadoraMonto probCalibrada={aiCalificacion?.prob_estimada}/>` justo debajo ya da el monto autorizado por RPC `tamano_apuesta`. Conservar `checkOverbet` (guardia sobre monto tecleado).

**B. `AiCopilotBar.tsx` — quitar Kelly JS.** Borrar el helper `kellyFraction()` y el cálculo `suggestedStakePct`. O quitar la fila "Estimación de stake (¼ Kelly)", o rerutear a `supabase.rpc("tamano_apuesta",{p_apodo,p_prob_calibrada:conf,p_cuota:modelOdds})` y pintar `data.sugerido`. Mantener las mejores cuotas Pinnacle y el chat LLM.

**C. `PortfolioOptimizerModal.tsx` — quitar Kelly/portafolio JS.** Borrar el `useMemo` de `allocations` (kelly, scaledKelly, stakePct, caps liga/portafolio) y la lectura `semana_bankroll`. Rerutear a un RPC server que dimensione por pick + total del día (p. ej. **nuevo** `optimizar_portafolio_diario(p_apodo, p_picks jsonb)` → `{total_pct,total_monto,allocations[]}`, cada uno sobre `decision_pick_v1` + bankroll server). **Si ese RPC no existe, el modal debe ocultarse/deshabilitarse** (o borrar el modal + botón "⚖️ BANCA" en `Fut.tsx`) — no puede dimensionar en cliente. **Este es el único camino por el que el bypass sobrevive si no se cierra.**

**D. `kelly-calculator.ts` — reducir a la guardia o borrar.** Tras (A) `calculateKelly`/`getKellyReferenceTable` quedan sin consumidor: mover `checkOverbet` a un util y borrar el archivo. Borrar también `KellyReferenceTable.tsx` (confirmar no-importado).

**E. `v_super_pick` en frontend** — dejar de rotular `ev_real_pct` (ROI de segmento) como "EV", o mostrar además `ev_decision`.

**Veredicto residual:** tras A–D, **no queda matemática cliente modelo→dinero**. El único riesgo de que sobreviva es dejar `PortfolioOptimizerModal` con su Kelly JS en lugar de rerutearlo (C).

**Verificación de navegador (humo final):** 403 desde este entorno. Tras aplicar: `EV_UI == EV_DECISION`, `P_RAW` etiquetada como info del modelo, `stake=$0 + razón` cuando `eligible=false`, y ningún "% banca"/monto pintado desde el modelo cliente.

---

## 11) ADVERSARIAL_TESTS

Los 10 invariantes (read-only, patrón DO-block-RAISE-rollback para el deploy real; verificados hoy por **simulación inline** del compositor, sin tocar prod):

| # | Invariante | Método | Resultado hoy |
|---|---|---|---|
| I1 | `EV_UI == EV_DECISION` (|diff|≤0.1pp) en las 116 filas | por construcción: `ev_pct := decision_economica_v1.ev_pct` | **PASA por diseño** (BEFORE: 116/116 divergen) |
| I2 | 0 sign-flips tras el patch | ídem | **PASA por diseño** (BEFORE: 19 flips) |
| I3 | `mejor_oportunidad_hoy.ev_pct == decision_pick_v1.ev_decision` | misma fuente | **PASA por diseño** |
| I4 | `favoritos_bien_pagados.ev_pct == decision_pick_v1.ev_decision` | misma fuente | **PASA por diseño** |
| I5 | fracción de cada superficie == `decision_pick_v1.kelly_pct` | única fórmula | **PASA por diseño** |
| I6 | `eligible=false → kelly_pct/fraccion = 0` | simulación inline sobre 116 filas | **PASA: 116/116 kelly=0** |
| I7 | `authorized_models=0`, `es_pick=0`, `apto=0` (ISS-006.2 intacto) | conteo directo | **PASA: 0 / 0 / 0** |
| I8 | cambiar P_RAW sin cambiar `prob_decide` no cambia el stake | estructural: kelly usa sólo `prob_decide` | **PASA por construcción** |
| I9 | `reto_picks_hoy.prob_que_decide_pct == decision_pick_v1.p_decision` | misma `decision_economica_v1` | **PASA por diseño** (una verdad) |
| I10 | `kelly_fraccion_pct.prob_usada == prob_decide` (no 0.52) | wrapper delega al núcleo | **PASA por diseño** |

Simulación inline (116 filas): `n_not_elig=116`, `n_kelly_zero=116`, `n_elig_true=0`, `EV_DECISION ∈ [−89.92, +78.21]`, `+EV reales=20`.

---

## 12) EXPECTED_BLAST_RADIUS

- **Objetos SQL modificados:** 1 nuevo (`decision_pick_v1`), 1 reescrito wrapper (`kelly_fraccion_pct`), 2 vistas por replace() (`v_pick_canonico`, `v_super_pick`), 2 funciones reescritas (`mejor_oportunidad_hoy`, `favoritos_bien_pagados`).
- **Lectores afectados (heredan el arreglo):** `MejorPickHoy.tsx`, `PicksProbabilidadFavoritos.tsx`, `OraculoRecomendados.tsx`, `AccionDelDia.tsx`, y todo consumidor de `v_pick_canonico`/`mejor_oportunidad_hoy`/`favoritos_bien_pagados`/`v_super_pick`.
- **NO afectado:** `kelly_stake__base`, `reto_picks_hoy` (ya canónicos), `economic_model_authority` (ninguna autorización cambia), la puerta de ISS-006.2 (`es_pick`/`apto_para_mostrar` siguen dando 0), MLB (sigue SKILL_INSUFFICIENT).
- **Riesgo de contrato:** las firmas y columnas de salida de las 4 superficies se **conservan** (mismo `RETURNS TABLE`, mismas columnas de vista) → sin ruptura de tipos en el frontend. `kelly_fraccion_pct` añade un arg **opcional** al final → llamadores existentes siguen compilando.
- **Riesgo de drift:** prod tiene drift de migraciones; por eso los replace() abortan con `SUBSTR_NOT_FOUND` si la def viva cambió. Re-derivar antes de deploy.
- **Costo de rendimiento:** `decision_pick_v1` añade 1 llamada a `decision_economica_v1` + 1 a `economic_eligibility_v1` por fila. Ambas STABLE; en un slate de ~116 filas es despreciable. `kelly_fraccion_pct` pasa de IMMUTABLE a STABLE (ya no plegable a constante) — correcto porque ahora lee `zonas_confiables`.

---

## 13) ROLLBACK_PLAN

- **Snapshot previo:** capturar `pg_get_viewdef`/`pg_get_functiondef` + md5 de los 5 objetos vivos (`v_pick_canonico`, `v_super_pick`, `mejor_oportunidad_hoy`, `favoritos_bien_pagados`, `kelly_fraccion_pct`) a `shadow-patches/iss004_005_rollback_snapshot.sql` **antes** del deploy (mismo procedimiento que ISS-006.2).
- **Deploy atómico:** un solo `BEGIN…COMMIT` con `SET LOCAL lock_timeout='8s'`, `statement_timeout`, y POST-VERIFY que hace `RAISE`→`ROLLBACK` si I1/I6/I7 no pasan. `decision_pick_v1` es CREATE nuevo (rollback = `DROP FUNCTION`).
- **Rollback:** re-aplicar el snapshot (CREATE OR REPLACE de las defs previas) + `DROP FUNCTION decision_pick_v1`. Como no se autoriza ningún modelo, el peor caso operativo es cosmético (números de EV/fracción), nunca dinero movido (stake sigue $0 por `NONE`).
- **Frontend:** revert por commit en Lovable; el SQL es compatible hacia atrás mientras el frontend viejo siga leyendo las mismas columnas.

---

## 14) PREDEPLOY_ISS004_005_GATE = **PASS**

- [x] Autoridad P/EV única identificada y **reutilizada**, no duplicada (`decision_economica_v1`).
- [x] Autoridad de sizing única: `kelly_stake__base` ($) + `decision_pick_v1` (fracción), misma fórmula sobre `prob_decide`.
- [x] `EV_UI == EV_DECISION` garantizado por construcción; ranking y gate pasan a EV_DECISION.
- [x] `eligible=false → stake=$0 + razón` en todas las superficies (I6: 116/116).
- [x] SQL (shadow, verificado en dry-run): sin cap 2% vs 5% divergente; sin `kelly_fraccion_pct` como autoridad paralela; sin recomputar desde P_RAW; sin monto desde prob LLM.
- [x] **FRONTEND: CERRADO** (`FRONTEND_AUTOMATIC_KELLY_BYPASS = CLOSED_BY_PATCH`, commit `5e814916`, build OK). Los 3 bypasses eliminados/neutralizados; PortfolioOptimizerModal quedó PORTFOLIO_ANALYSIS_ONLY.
- [x] FULL_PATCH_DRYRUN = PASS; POSITIVE_PATH_PARITY = PASS; NEGATIVE_PATH_PARITY = PASS (§11).
- Pendiente: **deploy de la cadena única SQL** (`iss004_005_cadena_economica_unica.sql`) — sigue SHADOW, requiere GO. Hasta ese deploy, las autoridades SQL paralelas (`kelly_fraccion_pct`/`calibrar_prob_motor_live` en mejor_oportunidad_hoy/favoritos) siguen vivas en prod (con NONE autorizado dan $0, pero el número diverge).
- [x] Manual (`CalculadoraMonto`, `tamano_apuesta`) y RISK_REVIEW (`revisar_apuesta`) preservados.
- [x] Etapas inexistentes reportadas como MISSING/PARCIAL (P_FAIR aproximada; portfolio RONGOL/CDaR fuera de bloque), no inventadas.
- [x] `CURRENT_AUTHORIZED_MODELS=NONE` intacto; ISS-006.2 intacto.
- [ ] **Pendiente (no bloquea el shadow):** prueba de humo en navegador (403) y re-derivación de fingerprints inmediatamente antes de un eventual deploy.

**Veredicto:** SQL verificado (dry-run compila + paridad positiva/negativa PASS) y **frontend bypass CERRADO_POR_PATCH** (desplegado en Lovable, build OK). `PREDEPLOY_ISS004_005_GATE = PASS`. Falta solo el **deploy de la cadena única SQL** (a la espera de GO). Después: ISS-003 + ISS-009 (MLB).
