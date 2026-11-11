# MLB money — paquete de decisión para el AUDITOR

_Fecha: 2026-10-14 · prod `wpiztubmmmzclhlprgpd` · modelo `mlb_canonical_v1` / candidate `C0-prod-2026-09`_
_Preparado por: Claude (backend). **Nada aplicado. Money sigue hard-coded en false.** Esto es
evidencia para que el auditor DECIDA; no es una solicitud de encender dinero._

---

## La pregunta
El gate `v_mlb_canonical_release_authority_v1` exige **validación forward pura** y hoy falla por
muestra (116/120) y por la regla de calibración. El usuario preguntó si, dado que **tenemos mucha
historia**, se puede acreditar un **backtest walk-forward** como evidencia de apoyo para adelantar
el release — sin que yo baje el estándar por mi cuenta. Aquí está la evidencia medida y la
recomendación honesta.

---

## Dos pools de evidencia (no son lo mismo)

### A) Forward puro — la muestra del gate (gold standard de independencia)
Capturas hechas **antes** de cada juego, con datos congelados (`cache_timestamp ≤ decision_time`).
Arrancó el 7-sep-2026 al sellar el modelo. **n = 116** calificadas (119 crudas).

| criterio | umbral | valor | ¿pasa? |
|---|---|---|---|
| n OOS | ≥120 | 116 | ❌ (por 4) |
| Brier | <0.25 | 0.23835 | ✅ |
| LogLoss | <0.693 | 0.66953 | ✅ |
| Brier Δ sup95 (skill) | <0 | −0.00096 | ✅ (apenas) |
| Buckets soportados | ≥3 | 2 | ❌ |
| Gap calibración | ≤5pp | 10.0pp | ❌ |

Nota: el gate reporta hoy `n=0` por el bug de fuente del kickoff (`iss_mlb_authority_kickoff_source_fix.sql`,
pendiente). Los números de arriba son con la fuente corregida.

### B) Walk-forward backtest — `bt_mlb_ml`, **1,056 juegos** (20-may → 30-ago 2026)
Cada predicción usa SOLO datos previos al juego (cortes as-of: `mlb_forma_hasta`,
`mlb_liga_rpg_hasta`, cutoff de calibración). Sin look-ahead temporal.

| criterio | umbral | valor | ¿pasa? |
|---|---|---|---|
| n | ≥120 | **1,056** | ✅ |
| Brier | <0.25 | 0.24732 | ✅ (apenas) |
| LogLoss | <0.693 | 0.68774 | ✅ (apenas) |
| **Brier Δ sup95 (skill)** | <0 | **+0.00035** | ❌ **no significativo** |
| Buckets soportados | ≥3 | **3** | ✅ |
| **Gap calibración** | ≤5pp | **1.5pp** | ✅ |

Calibración por bucket (backtest):

| bucket | n | modelo | real | gap | z |
|---|---|---|---|---|---|
| 0.40 | 321 | 47.2% | 47.7% | 0.5pp | 0.16 |
| 0.50 | 680 | 54.0% | 53.2% | 0.8pp | 0.42 |
| 0.60 | 52 | 62.0% | 63.5% | 1.5pp | 0.22 |

---

## Lo que la evidencia combinada dice honestamente

1. **La "falla de calibración" del forward es ruido de muestra chica — CONFIRMADO.**
   El mismo modelo sobre 1,056 juegos calibra a **0.5–1.5pp** en 3 buckets. El 10pp del forward
   (bucket de 39 juegos, z=1.31) es una oscilación, no un defecto. La calibración del modelo es
   **buena**, demostrada sobre 10× más juegos.

2. **El problema real NO es la calibración — es el SKILL (discriminación).**
   En el backtest de 1,056 juegos el modelo **no supera significativamente** el Brier de referencia
   0.25 (Δ sup95 = +0.00035 > 0). Está bien calibrado pero su ventaja sobre "volado" es **delgada**.
   El moneyline de MLB es un mercado eficiente; ganarle es difícil. En forward el skill sale
   apenas significativo (−0.00096), pero sobre 116 juegos eso también es frágil.

   → **Un modelo bien calibrado pero con discriminación marginal NO es una máquina de dinero:**
   la ventaja no alcanza para superar el vig de la casa de forma confiable.

---

## Caveats (por qué forward sigue siendo el gold standard)
- **Los hiperparámetros del modelo** (`AMORTIGUA=0.70`, `EXP_OFF/PITCHER/DEF`, coef de calibración)
  **se afinaron sobre juegos que se traslapan con este backtest.** Por eso su calibración de 1.5pp
  es en parte **in-sample**: prueba integridad temporal (cortes as-of) y que la compresión está bien
  calzada con la realidad, pero **no** independencia total de parámetros.
- **Periodo distinto:** backtest = temporada regular (may–ago); forward = fin de temporada +
  postemporada (sep–oct). El beisbol de playoffs puede comportarse distinto.
- Por eso forward (captura en vivo, congelada) es la única evidencia **plenamente independiente**.

---

## Recomendación honesta (decisión del AUDITOR, no mía)

**Money: mantener APAGADO.** Pero la razón honesta cambia:

- La falla de **calibración** del gate puede considerarse **resuelta por el backtest walk-forward**
  (el auditor decide si lo acredita): la calibración real es ~1–2pp, no 10pp.
- El motivo de peso para NO encender dinero **no es la muestra ni la calibración** — es el **skill
  marginal**: el modelo no demuestra ventaja estadísticamente significativa sobre 0.25 en 1,056
  juegos. Esa es una barra más honesta y más difícil que "n<120".

Opciones para el auditor:
1. **Statu quo (recomendado):** money off; el modelo sirve **probabilidades/análisis** (ya es el caso),
   no apuestas. Es un gran producto de información sin prometer ganancias que el edge no respalda.
2. **Acreditar el backtest para los criterios de calibración** (gap + buckets) y dejar el release de
   money condicionado a que el **skill** (Brier Δ sup95 < 0) sea significativo en la evidencia
   combinada forward+backtest. Hoy NO lo es de forma robusta.
3. Si en algún momento se enciende: hacerlo con **límites de stake chicos y monitoreo de CLV**, nunca
   como "sistema ganador" — el edge demostrado no lo justifica.

**Qué NO hago por mi cuenta:** no bajo el umbral del gate, no acredito el backtest en el código, no
toco `money_authorized`, no modifico el modelo. Esto queda para tu sign-off.

---

## Reproducibilidad
Las consultas de evidencia están en `mlb_money_auditor_evidence.sql` (este directorio). Fuentes:
`lab_mlb_forward`, `historico_partidos_espn`, `bt_mlb_ml`, `v2.mlb_canonical_model_config_v1`.
