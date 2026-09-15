# RETO 13M — MASTER HANDOFF V2
Rama `claude/reto-13m-espn-matches-3uknie` · repo `rodrigodelcastillo117-dotcom/reto`

```
PRODUCTION_CHANGED = SÍ, una sola vez: el deploy autorizado de ISS-003/009 V2
DEPLOY_EXECUTED    = NO en esta fase (todo lo posterior es rama/lab)
```

---

## EXECUTIVE SUMMARY

ISS-003/009 V2 se desplegó con autorización explícita y COMMIT correcto (I1 = PASS_NONEMPTY sobre 140 filas). Todo lo demás de esta sesión es trabajo en rama y laboratorio, sin tocar producción.

**Los cuatro hallazgos que más importan:**

1. **NFL publica probabilidad de la casa como propia.** `p_home` es la implícita sin vig del moneyline — coincidencia exacta al quinto decimal. `nfl_picks_premium` la llama `prob` y emite dos "picks premium" por partido.
2. **La incoherencia MLB observada NO es un bug de cálculo, es de presentación.** `predecir_mlb` calcula el marcador con `matriz_poisson` y los totales con `totales_nb` (Binomial Negativa, r=5) en la misma corrida y con la misma media. Ejecutadas lado a lado: 44.8 % vs 51.7 %. Los números son correctos; mezclarlos en una sola narrativa no lo es.
3. **`expected_runs − línea` no es una señal válida**: discrepa de la CDF real en 6 de 8 casos probados.
4. **Un cliente anónimo puede envenenar el ledger de forward capture** (SEC-03, HIGH), que es justo la evidencia de la que dependerá TOP PICK.

---

## FASE A — UNIFIED_PICK_SURFACES_V1

```
STATUS = CONTRATO IMPLEMENTADO Y TESTEADO · SUPERFICIES NO MIGRADAS
```

**Inventario:** 46 objetos exponen picks. Solo `v_pick_canonico`, `v_mejores_picks_mlb` (desde V2) y `v_super_pick` tienen gate propio; `v_oraculo_canonico` lo hereda. **42 sin gate.** Diez tienen columnas de dinero (`kelly`/`stake`/`monto`) y son legibles por `anon`.

**Entregable:** `shadow-patches/unified/clasificacion_pick_v1.sql` — taxonomía ANALYSIS / MOST_LIKELY / VALUE_PICK / TOP_PICK, **sin un solo umbral numérico inventado**. VALUE_PICK delega en `economically_eligible`; MOST_LIKELY usa criterio relativo (ser el lado de mayor P en su mercado); TOP_PICK exige conjunción de evidencias y hoy es inalcanzable, pero el gate está vivo (T8 lo prueba).

`authorized_bet` es la única llave que el frontend debe consultar.

**Tests:** 12/12 PASS. Destacados: **T4** (P de mercado con todo forzado sigue dando ANALYSIS) y **T12** (lado no dominante → ANALYSIS, lo que impide estructuralmente dos picks por moneyline).

**No migré las 23 superficies peligrosas.** Cambiar el contrato de una sola vista sin verificación ordinal rompió un deploy esta semana; hacerlo sobre siete sin saber qué las consume sería repetir el error a escala. Plan U0–U3 documentado.

## FASE NFL BETTING (prioridad #2)

```
NFL_P_PROVENANCE       = HOUSE_NO_VIG_IMPLIED (probado aritméticamente)
NFL_MODEL_SKILL        = INSUFFICIENT
NFL_ECONOMIC_AUTHORITY = FALSE · NFL_STAKE = 0
NFL_PHASE1_FIX         = PREPARADO (nfl_game_card_v1, shadow, compila en lab)
NFL_PHASE2_MODEL       = NO CONSTRUIDO, deliberadamente
```

**Fase 1:** `shadow-patches/nfl/nfl_game_card_v1.sql`. Una fila = un partido. Ninguna columna llamada `prob`; son `house_no_vig_prob_*` con `prob_source='MARKET_NO_VIG'`. `model_prob_*` reservado y NULL. La señal de `nfl_mejor_pick` se etiqueta `MARKET_INTERNAL_DIAGNOSTIC`. No se altera `nfl_picks_premium` (requiere inventario de consumo primero).

**Fase 2 — por qué no construí el modelo:** hay **300 partidos con resultado** en 2 temporadas. Un holdout honesto deja ~100 de prueba. La ventaja realista de un buen modelo sobre el mercado es 0.003–0.008 de Brier, y con n≈100 el error estándar es más de un orden de magnitud mayor. **Cualquier modelo daría INSUFFICIENT, incluso siendo bueno.** Construirlo y medirlo produciría exactamente la ilusión de tamaño muestral que la misión prohíbe.

Además, las features más predictivas (EPA/play, success rate, pressure, explosive rate, red zone, special teams, pace) **no existen en la base**. Y `nfl_fpi_historico` tiene 32 filas para 32 equipos: no hay serie temporal, así que FPI no es usable as-of.

Matriz completa de disponibilidad temporal en `NFL_BETTING_STATUS.md`.

## FASE MLB — consistencia probabilística

```
MLB_SAFETY_GATE        = PASS (el gate de V2 funciona)
MLB_COPY_SEMANTICS     = FAIL
SAME_ANALYSIS_RUN      = YES (confirmado)
SAME_MEAN_PARAMETER    = YES (confirmado)
SAME_DISTRIBUTION      = NO
CROSS_MODEL_PRESENTATION = YES
PROBABILITY_COHERENCE  = PASS dentro de cada distribución · FAIL en la presentación conjunta
```

`predecir_mlb`, en una sola invocación y con los mismos λ:
```
matriz_poisson(5.03, 4.03) -> under_85 = 44.8 %   (marcador y moda salen de aquí)
totales_nb(9.06, 5.0)      -> under_85 = 51.7 %   (la P mostrada sale de aquí)
```
La NB tiene media 9.06 y **mediana 8** (varianza 25.5 vs 9.1). Por eso media > línea y P(Under) > 50 % conviven sin contradicción. **El cambio a NB está justificado por Brier medido** (0.22420 vs 0.23199), documentado en el propio código. **No toqué el modelo.**

**Copy insostenible:** "bien calibrado" junto a `MODEL_VERSION_PROVENANCE_MISSING`; "aguanta" con `economically_eligible=false`; "ventaja del modelo" sin provenance. Reemplazos descriptivos propuestos.

**"MEJORES PICKS" es un ranking de EV:** `mejor_oportunidad_hoy` ordena por `ev_cal DESC`, sin usar `model_skill`, `accuracy_evidence` ni `data_readiness`. `PRODUCT_SEMANTIC_BUG = CONFIRMED`. Renombrado propuesto: "Oportunidades de valor del modelo".

**Integridad temporal:** `predecir_mlb` tiene candado real y correcto para las features (`mlb_forma_hasta`, `mlb_liga_rpg_hasta`, calibración con doble cota). Pero selecciona la fila de `mlb_stats_cache` y la de `v_momios_confiables` por "más reciente" **sin cota**: correcto hacia delante, **CONDITIONAL_LEAK en backtest**. Ninguna métrica histórica obtenida re-corriendo el motor sirve como evidencia de skill.

## FASE SOCCER / CHAMPIONS

```
SOCCER_LEAGUES_WITH_SKILL = 0 a n>=100 · 1 a n>=50 · 5 a n>=30 (3 sin baseline de mercado)
CHAMPIONS_MODEL_COVERAGE  = 0 · LEAGUE_NOT_REGISTERED
```

`liga_competencia_modelo` ya emite veredictos y **nadie los consume**. MLS tiene veredicto `callarse` (Brier 0.6834 > naive 0.6667) y aporta 112 de 275 filas canónicas. Champions: 18 partidos, 18 con odds, **0 con modelo**.

**Entregable:** `shadow-patches/soccer/liga_evidencia_gate_v1.sql`. Fail-closed por defecto (Champions cae en `LEAGUE_NOT_REGISTERED`), `callarse` nunca se sobreescribe, y el `n` mínimo es parámetro obligatorio sin default silencioso.

## FASE SEGURIDAD

```
SEC-03 (HIGH)   = escritura anónima al ledger forward
SEC-02 (MEDIUM) = 8 SECURITY DEFINER sin search_path
SEC-01 (HIGH)   = 44 objetos de picks legibles por anon; 24/26 vistas como OWNER
```

**SEC-03:** `lab_mlb_fwd_capturar` y `lab_mlb_fwd_resultado` son `SECURITY DEFINER`, propiedad de `postgres`, escriben, y tienen `EXECUTE` para `anon`. Todos los campos de evidencia los aporta el llamante; `decision_id = md5(event|decision_time|model_version)` con `ON CONFLICT DO NOTHING`. **Un anónimo puede pre-reclamar un decision_id con datos falsos y hacer que la captura legítima se descarte en silencio.** Y `available_at_decision` se computa de dos parámetros del llamante, así que la marca de integridad temporal también es forjable.

**Patch:** `shadow-patches/security/sec_hardening_v1.sql` + rollback. Validado en lab: aplica, revierte y re-aplica limpio. No incluye revocar `SELECT` de `anon` sobre picks (exige inventario de consumo primero).

Mitigación vigente: `anon`/`authenticated` **no** tienen `CREATE` en `public` (verificado), así que el vector de hijack de `search_path` está cerrado hoy.

## FASE FORWARD CAPTURE

```
FORWARD_CAPTURE_STATUS = DISEÑADO · 0 CAPTURAS · integridad comprometida por SEC-03
```
`lab_mlb_forward`, `lab_ff_forward`, `lab_soccer_xg_forward`, `lab_dq_capture_queue`, `lab_dq_capture_misses`: todas a 0 filas. **No existe evidencia forward**, lo que confirma que TOP PICK debe seguir deshabilitado. Es el trabajo de mayor valor pendiente: cada día sin capturar es evidencia perdida.

## FASE FANTASY

```
FANTASY_STATUS = PAUSED_BY_USER
```
Pausado por decisión del usuario. No es blocker ni fallo de esta ejecución. Lo único que quedó, hecho antes de la pausa: `shadow-patches/fantasy/lab_ff_league_config_v1.sql` (esquema de configuración sin defaults silenciosos, 4 constraints de coherencia testeados). Los objetos `lab_ff_*` aparecen en la auditoría de seguridad solo como hallazgo, sin construir funcionalidad.

## FASE PRODUCT / UX

```
STATUS = CONTRATO ESCRITO · UI NO AUDITADA (frontend fuera del repo)
```
El frontend actual no está en este repositorio (0 `.tsx/.jsx/.vue/package.json`). `reto.py` y `reto` son apps Streamlit legacy sobre Google Sheets, sin conexión a la cadena de picks. El contrato de producto (vocabulario por clase, reglas fail-closed, prohibiciones de copy) está en `UNIFIED_PICK_CONTRACT_V1.md` §5.

## TESTS

| Suite | Bloques | Asserts | violations | coverage_status |
|---|---|---|---|---|
| `test_clasificacion_pick_v1.sql` | 12 | 12 | 0 | PASS_NONEMPTY |
| `contract_tests_v1.sql` | 8 | 41 | 0 | PASS_NONEMPTY |
| `lab_runtime_validation.sh` (ISS-003/009) | 6 | 6 | 0 | PASS_NONEMPTY |
| `sec_hardening_v1.sql` post-verify | 2 | 10 | 0 | PASS_NONEMPTY |
| `lab_ff_league_config_v1` constraints | 4 | 4 | 0 | PASS_NONEMPTY |

**NOT_RUN / BLOCKED:** test adversarial de leakage temporal MLB (el lab no tiene datos, por política de no usar datos de producción); medición del detector de incoherencia NFL; cualquier test de UI.

**PASS_EMPTY_COVERAGE en el deploy de producción:** `E1`, `E2`, `E3`, `G5` — `mejor_oportunidad_hoy` devolvió 0 filas y `usuarios` está vacía.

## ABIERTOS

**CRITICAL (1):** NF-01 NFL presenta probabilidad de casa como propia.
**HIGH (6):** SEC-03 escritura anónima al ledger · SEC-01 exposición anon · NF-02 Champions sin modelo · NF-03 MLS peor que naive con 41 % de las filas · NF-07 forward capture sin capturas · NF-09 "MEJORES PICKS" ranking de EV.
**MEDIUM (5):** SEC-02 search_path · MLB CONDITIONAL_LEAK en backtest · copy "bien calibrado"/"aguanta" · 15 ocurrencias de copy prescriptivo en la BD (CT-8) · 21/35 partidos MLB sin odds.

## BLOCKERS

Frontend fuera del repo · histórico NFL de temporadas previas · serie temporal de fuerza NFL · cobertura de modelo UCL · datos para el test de leakage MLB · deploy de cualquier patch (prohibido).

## PRÓXIMAS ACCIONES, EN ORDEN

1. Smoke visual humano de MLB tras el deploy de V2 (única tarea que cierra ISS-003/009).
2. Desplegar `sec_hardening_v1.sql` — SEC-03 es HIGH y el patch está probado.
3. Inventario de consumo del frontend (U0). Desbloquea todo lo demás.
4. Renombrar "MEJORES PICKS" y corregir el copy de MLB.
5. Desplegar `nfl_game_card_v1` y migrar la UI de NFL a esa vista.
6. Poner en marcha el productor de forward capture — cada día cuenta.
7. Conseguir histórico NFL 2020-2024.
8. Aplicar `liga_evidencia_gate_v1` tras decidir el `n` mínimo (decisión de producto).
9. Test de leakage MLB contra producción read-only.
10. Migrar las 7 superficies DANGEROUS con asserts ordinales.
