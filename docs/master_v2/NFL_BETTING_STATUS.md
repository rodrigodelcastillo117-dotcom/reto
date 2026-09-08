# NFL BETTING — ESTADO Y PLAN

**Prioridad #2 tras Unified Picks. Fase 1 preparada. Fase 2 evaluada y con veredicto negativo por tamaño muestral.**

---

## FASE 1 — Corregir lo existente

### El defecto, probado aritméticamente

`nfl_partidos.p_home` / `p_away` son la probabilidad implícita **sin vig** del moneyline del sportsbook:

```
Minnesota Vikings vs Chicago Bears
  ml_home = -122 -> implícita = 122/222 = 0.549550
  ml_away = +102 -> implícita = 100/202 = 0.495050
  suma = 1.044600 ; vig registrado = 0.0446          <- coincide
  no-vig p_home = 0.549550/1.0446 = 0.526095
  p_home almacenado = 0.52609                        <- coincide
```

563/563 filas cumplen `p_home + p_away = 1`. `corr(p_home, −spread) = 0.9900` (n=562). **Cero componente de modelo.**

`nfl_mejor_pick()` lo sabe — su propio texto dice *"El moneyline implica X%"* — pero `nfl_picks_premium` lo publica como `round(100*b.ph,1) AS prob` y construye **dos ramas** (`WHERE b.ph IS NOT NULL` / `WHERE b.pa IS NOT NULL`), así que **cada partido genera dos "picks premium"**.

Además `nfl_picks_premium` es legible por `anon`, corre como OWNER (sin `security_invoker`) y no referencia `economic_eligibility_v1`, `v_pick_canonico`, `es_pick` ni `decision_pick_v1`.

### Fix preparado — `nfl_game_card_v1` (SHADOW)

`shadow-patches/nfl/nfl_game_card_v1.sql`, 36 columnas, compila limpio en lab.

- **Una fila = un PARTIDO.** Los mercados van dentro, no como filas hermanas.
- Ninguna columna se llama `prob`. Las probabilidades son `house_no_vig_prob_home` / `house_no_vig_prob_away`, con `prob_source = 'MARKET_NO_VIG'`.
- `model_prob_home` / `model_prob_away` existen pero son **NULL**: reservados para cuando haya modelo.
- `nfl_model_skill = 'INSUFFICIENT'`, `economically_eligible = false`, `eligibility_reason_code = 'NFL_MODEL_NOT_AUTHORIZED'`, `stake_final = 0`.
- La señal de `nfl_mejor_pick` se expone como `line_incoherence_*` con `line_incoherence_kind = 'MARKET_INTERNAL_DIAGNOSTIC'` — es un diagnóstico del mercado, no una predicción.
- La columna `clasificacion` llama a `clasificacion_pick_v1`, que con `prob_source='MARKET_NO_VIG'` devuelve siempre `ANALYSIS / NO_MODEL_PROBABILITY` (test CT-2, 4/4).

**No se altera `nfl_picks_premium`.** Cambiar su contrato exige el mismo cuidado ordinal que ISS-003/009 y saber antes qué pantalla la consume. La vista nueva es aditiva y no rompe nada.

### Qué es realmente la "señal"

`nfl_mejor_pick` compara la implícita del moneyline contra la implícita del spread vía `normal_cdf(−spread/sd)`, con `sd_margen ≈ 12` y `umbral_brecha ≈ 3` desde `nfl_parametros`. Es un **detector de incoherencia de línea**: legítimo como concepto, pero sus dos constantes no tienen validación out-of-sample documentada, ni medición de accuracy, Brier, ROI o CLV. Merece medirse antes de construir nada nuevo encima.

---

## FASE 2 — Model shadow: matriz de disponibilidad temporal

### Volumen real (conteos, no `n_live_tup`)

| Tabla | Filas | Columnas temporales | Uso as-of |
|---|---|---|---|
| `nfl_partidos` | 572 (**300 con resultado**) | `fecha`, `semana`, `temporada`, `actualizado` | **SAFE** |
| `nfl_odds_snapshots` | 922 | `snapshot_at`, `created_at` | **SAFE** — permite decision price y CLV |
| `nfl_clima_hora` | 1 541 832 | `hora_utc` | **SAFE** |
| `nfl_lesiones_semana` | 2 006 | `cargado_at`, `semana`, `temporada` | **SAFE** |
| `nfl_snaps` | 7 887 | `cargado_at`, `semana`, `temporada` | **SAFE** |
| `nfl_player_game_logs` | 6 271 | `created_at` | **PARCIAL** — sin semana/temporada explícitas |
| `nfl_h2h` | 992 | `actualizado` | **PARCIAL** — solo marca de refresco |
| `nfl_predicciones` | 284 | `fecha`, `generado_at` | **SAFE** |
| `nfl_fpi` | 32 | `actualizado`, `temporada` | **LEAKY** — un snapshot por equipo |
| `nfl_fpi_historico` | **32** | `guardado_at`, `temporada` | **LEAKY** — 32 filas para 32 equipos: **no hay serie temporal** |
| `nfl_equipo_totales` | 32 | solo `temporada` | **LEAKY** — agregado de temporada, contiene partidos futuros |
| `nfl_backtest` | **0** | — | **MISSING** |

### Features candidatas — veredicto por disponibilidad

| Feature | Fuente | Estado |
|---|---|---|
| Clima (temp, viento, precipitación) | `nfl_clima_hora` + columnas de `nfl_partidos` | **AVAILABLE / SAFE** |
| Lesiones y QB comprometido | `nfl_lesiones_semana`, `qb_comprometido_*` | **AVAILABLE / SAFE** |
| Snap share | `nfl_snaps` | **AVAILABLE / SAFE** |
| Descanso y viaje | derivable de `fecha` + equipos | **DERIVABLE / SAFE** |
| Home field | derivable | **DERIVABLE / SAFE** |
| Mercado (ML, spread, total) | `nfl_partidos`, `nfl_odds_snapshots` | **AVAILABLE / SAFE** |
| Techado / superficie | `techado` en `nfl_partidos` | **AVAILABLE / SAFE** |
| FPI (fuerza de equipo) | `nfl_fpi`, `nfl_fpi_historico` | **LEAKY** — sin serie temporal |
| Totales de equipo | `nfl_equipo_totales` | **LEAKY** — agregado de temporada completa |
| EPA/play, success rate, explosive rate | — | **MISSING** (no existe tabla) |
| Pressure, sacks, turnovers | — | **MISSING** |
| Red zone | `nfl_zona_roja_2025` (0 filas) | **MISSING** |
| Special teams | `nfl_pateadores`, `nfl_kicker_logs` (0 filas) | **MISSING** |
| Pace, neutral pass rate | — | **MISSING** |
| Coaching / continuidad de roster | — | **MISSING** |

**Las features que la literatura considera más predictivas para NFL (EPA/play, success rate, pressure, explosive rate) sencillamente no existen en la base.**

### El bloqueante decisivo: N = 300

Hay **300 partidos con resultado**, sobre 2 temporadas. Un holdout honesto deja ~200 para entrenar y ~100 para probar.

El benchmark obligatorio es el mercado no-vig, cuyo Brier en moneyline NFL ronda 0.21–0.23. Una ventaja realista de un buen modelo sobre el mercado es del orden de 0.003–0.008 de Brier. **Con n≈100 el error estándar de esa diferencia es más de un orden de magnitud mayor que el efecto que se quiere detectar.** No es una limitación del modelo: es que la muestra no puede sostener la afirmación.

Consecuencia honesta: **cualquier modelo NFL que se construya hoy dará `INSUFFICIENT`, y dará `INSUFFICIENT` aunque sea bueno.** Construirlo y "medirlo" con estos datos produciría exactamente la ilusión de tamaño muestral que la misión prohíbe.

**Por eso no construí un candidato NFL.** No es falta de tiempo: es que el resultado no sería interpretable, y presentarlo como shadow validado sería engañoso.

### Lo que sí desbloquea NFL, en orden

1. **Histórico de temporadas anteriores** (2020-2024 ≈ 1 400 partidos). Es el bloqueante real.
2. **Serie temporal de FPI** o equivalente de fuerza de equipo con `as_of` — hoy solo hay un snapshot.
3. **EPA/play y success rate** por equipo y semana, temporalmente acotados.
4. Recién entonces: modelo candidato con holdout intacto y benchmark de mercado.

Mientras tanto, medir el detector de incoherencia de línea con los 300 partidos existentes es barato y sí es interpretable como señal binaria.

---

## Estado

```
NFL_P_PROVENANCE        = HOUSE_NO_VIG_IMPLIED (probado)
NFL_MODEL_STATUS        = NO EXISTE MODELO PROPIO
NFL_MODEL_SKILL         = INSUFFICIENT
NFL_ECONOMIC_AUTHORITY  = FALSE
NFL_STAKE               = 0
NFL_PHASE1_FIX          = PREPARADO (nfl_game_card_v1, shadow, compila en lab)
NFL_PHASE2_MODEL        = NO CONSTRUIDO — N=300 no sostiene la afirmación
NFL_DATA_BLOCKER        = histórico de temporadas previas + serie temporal de fuerza + EPA
PRODUCTION_CHANGED      = NO
```

NFL queda conceptualmente **`MARKET_INFORMATION_ONLY`**, que es lo correcto hasta que exista un modelo validable.
