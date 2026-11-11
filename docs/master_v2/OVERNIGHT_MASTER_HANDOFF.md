# RETO 13M — OVERNIGHT MASTER HANDOFF
Rama `claude/reto-13m-espn-matches-3uknie` · repo `rodrigodelcastillo117-dotcom/reto`

---

## 1. EXECUTIVE SUMMARY

Trabajo nocturno en rama y laboratorio efímero. **Cero cambios en producción durante este run.**

Lo más importante de la noche, en orden de gravedad:

1. **SEC-05 (CRITICAL, nuevo).** 127 funciones `SECURITY DEFINER` que escriben, sin control de identidad interno, invocables por RPC por `anon` sin autenticar. Incluye creación de apuestas con stake arbitrario y varias que **consumen cuota de APIs externas de pago**.
2. **SEC-03 reproducido y cerrado en lab (3/3 → 5/5).** Y el patch **falló en el primer intento mientras su propio test lo aprobaba** — el hallazgo metodológico de la noche.
3. **Evidencia empírica de que el mercado gana al modelo.** Sobre 2 977 predicciones registradas en vivo, IC95 del delta de Brier = [0.003026, 0.007845], excluye el cero. Con benchmark *con vig*, que penaliza al mercado.
4. **Dos autocorrecciones a la baja**: el leak temporal de MLB resultó **latente con 0 filas afectadas**, y `corregir_apuesta` resultó **bien defendida**. Ambas las había reportado como peores de lo que son.

## 2. PRODUCCIÓN

```
PRODUCTION_CHANGED_DURING_THIS_RUN = NO
DEPLOY_EXECUTED = NO
```

Único cambio previo en producción: el deploy autorizado de ISS-003/009 V2, en una sesión anterior. Durante este overnight, producción se consultó **solo read-only**, siempre con `BEGIN READ ONLY` y `transaction_read_only=on` verificado. Laboratorio apagado al terminar, sin procesos ni puertos residuales.

## 3. HALLAZGOS POR SEVERIDAD

### CRITICAL
| ID | Hallazgo | Estado |
|---|---|---|
| **SEC-05** | 127 funciones SECDEF escribibles por `anon` sin control de identidad | ABIERTO, documentado, sin patch masivo por diseño |
| **NF-01** | NFL presenta `MARKET_NO_VIG` como probabilidad propia | Fix preparado, **no cerrado** (faltan consumidores) |

### HIGH
| ID | Hallazgo | Estado |
|---|---|---|
| SEC-03 | Envenenamiento anónimo del ledger forward | **Reproducido 3/3, cerrado 5/5 en lab**, rollback probado |
| SEC-01 | 44 objetos de picks legibles por `anon`; 24/26 vistas como OWNER | Abierto, subconjunto seguro identificado |
| NF-09 | "MEJORES PICKS" ordena por EV DESC | Confirmado, renombrado propuesto |
| NF-03 | MLS con veredicto `callarse` aporta 112/275 filas canónicas | Gate preparado |
| NF-07 | Forward capture con 0 capturas | Bloqueado tras SEC-03 |
| NF-02 | Champions sin cobertura de modelo | Fail-closed por diseño |

### MEDIUM
SEC-02 (`search_path`, en patch) · leak temporal MLB **latente, 0 filas** · copy "bien calibrado"/"aguanta" · 15 ocurrencias de copy prescriptivo en BD (CT-8) · 21/35 partidos MLB sin odds.

## 4. UNIFIED PICK

```
UNIFIED_PICK_CONTRACT     = PASS (implementado y testeado)
UNIFIED_PICK_CONSUMER_MAP = PASS (lado BD) · BLOCKED (lado frontend)
UNIFIED_PICK_MIGRATION    = 4/46
UNIFIED_PICK_STATUS       = IN_PROGRESS
```

46 superficies mapeadas por dependencias reales (`pg_depend` + referencias en funciones).

**Corrección al modelo mental:** `v_pick_canonico` **lee de** `picks_recomendados_hoy`, `picks`, `v_picks_mlb_modelo` y `v_picks_futbol_calibrado`. Varias superficies "sin gate" no son autoridades rivales sino **insumos aguas arriba**. El gate está en el cuello de botella correcto; el problema es que `anon` puede leer los insumos y saltárselo.

`nfl_picks_premium` tiene **cero consumidores en BD**: migrarlo es bajo riesgo en la base. `picks` tiene **145 funciones dependientes**: no se toca.

Taxonomía `clasificacion_pick_v1` sin un solo umbral inventado, 12/12 tests. `TOP_PICK` inalcanzable hoy pero con el gate vivo.

## 5. NFL

```
NFL_NF01               = PREPARED, NOT_CLOSED
NFL_MARKET_PROVENANCE  = PROBADO ARITMÉTICAMENTE (p_home = no-vig del moneyline)
NFL_MODEL_STATUS       = NO EXISTE MODELO PROPIO
NFL_DATA_FOUNDATION    = INSUFICIENTE (300 partidos con resultado, 2 temporadas)
```

`nfl_game_card_v1` preparado: una fila por partido, `house_no_vig_prob_*` con `prob_source='MARKET_NO_VIG'`, `model_prob_*` NULL, señal de línea etiquetada `MARKET_INTERNAL_DIAGNOSTIC`.

**No construí modelo NFL, deliberadamente.** Con ~100 partidos de holdout, la ventaja realista sobre el mercado (0.003–0.008 de Brier) queda más de un orden de magnitud por debajo del error estándar. Cualquier modelo daría `INSUFFICIENT` aunque fuera bueno. Además EPA/play, success rate, pressure, explosive rate, red zone, special teams y pace **no existen en la base**, y `nfl_fpi_historico` tiene 32 filas para 32 equipos (sin serie temporal).

## 6. MLB

```
MLB_GATE                       = PASS (backend, desplegado)
MLB_VISUAL_SEMANTICS           = FAIL
MLB_TEMPORAL_INTEGRITY         = LEAK LATENTE · 0 de 1225 filas afectadas
MLB_RECORDED_PREDICTIONS_TRUST = ALTA
MLB_RERUN_BACKTEST_TRUST       = NULA
```

**Semántica híbrida confirmada.** `predecir_mlb`, una sola corrida, mismos λ:
```
matriz_poisson(5.03,4.03) -> under_85 = 44.8 %   (marcador y moda)
totales_nb(9.06,5.0)      -> under_85 = 51.7 %   (la P mostrada)
```
`SAME_ANALYSIS_RUN=YES` · `SAME_MEAN_PARAMETER=YES` · `SAME_DISTRIBUTION=NO`. Los números son correctos: la NB tiene media 9.06 y **mediana 8**, por eso media>línea y P(Under)>50 % conviven. El cambio a NB está justificado por Brier medido. **No se tocó el modelo.**

**CT-7** demuestra que `expected_runs − línea` discrepa de la CDF en **6 de 8 casos**: no es señal válida.

**Cuantificación del leak:** 1 225 filas de `mlb_stats_cache`, una por evento, **todas escritas en o antes de la fecha del partido**. Cero afectadas. Retiro mi afirmación previa de que un rerun MLB estaría contaminado por el caché. Lo que sí se mantiene: `modelo_backtest_v2` es un lote único generado 857 días después.

## 7. SOCCER

```
SOCCER_STATUS     = evidencia insuficiente en prácticamente todas las ligas
CHAMPIONS_STATUS  = 0 cobertura · LEAGUE_NOT_REGISTERED · fail-closed
```
`liga_evidencia_gate_v1` preparado, fail-closed por defecto. Con `n≥100` ninguna liga pasa; con `n≥50`, una. Las 5 con veredicto `usar_modelo` tienen n=50,38,34,34,33 y tres no tienen Brier de mercado.

## 8. TENNIS

```
TENNIS_STATUS = BLOCKED — agenda_espn no contiene ni un evento de tenis, nunca
```
Existe scaffolding de linescore en vivo, no de calendario. Sin schedule no hay cadena. **No avancé** porque el primer eslabón requiere ingesta desde fuente externa.

## 9. PICK INTELLIGENCE

```
MOST_LIKELY = IMPLEMENTED + TESTED (T6: "muy probable, mal precio")
VALUE_PICK  = IMPLEMENTED + TESTED (delega en economically_eligible)
TOP_PICK    = EVIDENCE_GATED · inalcanzable · gate vivo (T8)
```
Ninguno MIGRATED a superficies. `MEJORES PICKS` confirmado como ranking de EV (`mejor_oportunidad_hoy` ordena por `ev_cal DESC`, sin `model_skill`, `accuracy_evidence` ni `data_readiness`).

## 10. FORWARD CAPTURE

```
FORWARD_CAPTURE_AUTHORIZED = FALSE
```
0 capturas en las 5 tablas. Bloqueado hasta desplegar SEC-03. `CAPTURE_V4` sigue frozen; no se inventó V5.

## 11. SECURITY

Ver `SECURITY_MATRIX_V1.md`. SEC-03 preparado y probado; SEC-05 documentado sin patch masivo (instrucción explícita de no revocar a ciegas); SEC-01 con subconjunto seguro identificado; SEC-02 en el patch. **0 secretos en repo.**

## 12. UX / PRODUCT

Frontend **no está en este repo** (0 `.tsx/.jsx/.vue/package.json`). No afirmo haber auditado UI. Contrato de producto escrito en `UNIFIED_PICK_CONTRACT_V1.md` §5: vocabulario por clase, `authorized_bet` como única llave, prohibiciones de copy.

## 13. TESTS

| Suite | Asserts | violations | Estado |
|---|---|---|---|
| `test_clasificacion_pick_v1.sql` | 12 | 0 | PASS_NONEMPTY |
| `contract_tests_v1.sql` (CT-1…CT-8) | 41 | 0 | PASS_NONEMPTY |
| `test_sec03_adversarial.sql` | 3 vectores | — | CONFIRMÓ vulnerabilidad |
| `test_sec03_post_hardening.sql` | 5 | 0 | PASS_NONEMPTY |
| `sec_hardening_v1.sql` post-verify | 12 | 0 | PASS_NONEMPTY |
| `evidencia_suficiencia_v1` validación | 6 escenarios | 0 | PASS_NONEMPTY |
| `lab_runtime_validation.sh` (ISS-003/009) | 6 | 0 | PASS_NONEMPTY |

**BLOCKED:** test de leakage MLB con datos (resuelto por otra vía: medición directa) · medición del detector de incoherencia NFL · cualquier test de UI · aplicación de `evidencia_suficiencia_v1` por liga de fútbol (la vista no particiona por liga europea).

**PASS_EMPTY_COVERAGE** (del deploy previo en producción): E1, E2, E3, G5.

## 14. ARCHIVOS

```
shadow-patches/unified/clasificacion_pick_v1.sql
shadow-patches/unified/test_clasificacion_pick_v1.sql
shadow-patches/unified/contract_tests_v1.sql
shadow-patches/nfl/nfl_game_card_v1.sql
shadow-patches/security/sec_hardening_v1.sql
shadow-patches/security/sec_hardening_v1_rollback.sql
shadow-patches/security/test_sec03_adversarial.sql
shadow-patches/security/test_sec03_post_hardening.sql
shadow-patches/soccer/liga_evidencia_gate_v1.sql
shadow-patches/evidencia/evidencia_suficiencia_v1.sql
shadow-patches/fantasy/lab_ff_league_config_v1.sql   (previo a la pausa)
docs/master_v2/*.md                                   (8 documentos)
```

## 15. COMMITS

```
2f4fbc7  UNIFIED_PICK_SURFACES_V1 + NFL_PROVENANCE + SEC_HARDENING + MLB_TEMPORAL_AUDIT
a48165e  MLB_VISUAL_AUDIT + CONTRACT_TESTS + SOCCER_GATE + FANTASY_CONFIG
203b5cc  NFL_PROVENANCE_PHASE1 + CT7/CT8 + MASTER_HANDOFF_V2
1f7533b  EMPIRICAL_SUFFICIENCY_V1 + UNIFIED_CONSUMER_MAP
3a966ba  SEC-03 reproducido y cerrado en lab + SEC-05 (CRITICAL, nuevo)
```

## 16. QUÉ SE ARREGLÓ DE VERDAD

Nada en producción. En rama: el bootstrap de suficiencia empírica (bug de LATERAL no correlacionado), el patch SEC-03 (revoke a PUBLIC), y su assert (has_function_privilege).

## 17. QUÉ ESTÁ SOLO PREPARADO

`nfl_game_card_v1` · `sec_hardening_v1` · `liga_evidencia_gate_v1` · `clasificacion_pick_v1` · `evidencia_suficiencia_v1` · todos los contract tests. **Ninguno desplegado.**

## 18. QUÉ SIGUE SIENDO INSEGURO

Las 127 funciones de SEC-05 · el ledger forward mientras `anon` pueda escribirlo · cualquier % de NFL o Champions presentado como predicción propia · "MEJORES PICKS" como lista de resultados probables · `modelo_backtest_v2` como evidencia.

## 19. QUÉ NECESITA GO HUMANO

Desplegar `sec_hardening_v1` (confirmando antes el rol del productor legítimo) · inventario de consumo del frontend · desplegar `nfl_game_card_v1` y migrar la UI · barrido dirigido de las 127 de SEC-05 · decidir si aplicar el gate de liga sabiendo que apagaría casi todo el fútbol.

## 20. PRÓXIMAS ACCIONES

1. Smoke visual de MLB con el copy corregido (ISS-003/009 sigue `NOT_CLOSED` por `VISUAL_SEMANTICS = FAIL`)
2. Desplegar `sec_hardening_v1` tras confirmar el productor legítimo
3. Barrido de SEC-05 con mapa de consumo
4. Inventario de consumo del frontend
5. Migrar `nfl_picks_premium` → `nfl_game_card_v1` (cierra NF-01)
6. Renombrar "MEJORES PICKS"
7. Arrancar forward capture tras SEC-03
8. Histórico NFL 2020-2024
9. Aplicar `evidencia_suficiencia_v1` por liga con datos forward
10. Pipeline de calendario de tenis
