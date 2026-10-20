# Frontend: por qué no aparece NHL (ni tenis) + limpieza de coherencia (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-10-20. Dinero OFF.

## (a) Dónde se ve y dónde NO se ve cada deporte

El frontend ("Remix of Reto 13M", Lovable d243f279) NO lee `v_reto_mejores_picks_v1` ni
`reto_pick_snapshot_v1`. Lee el **cerebro**: `v_reto13m_*` (pool global), vistas de
publicación por deporte y `v_tarjeta_universal_v1`, todo gateado por autoridad de release.

- Pool global (`v_reto13m_global_candidate_source_v2`): hoy solo **soccer + baseball**.
- `v_tarjeta_universal_v1`: solo **futbol, nfl, beisbol**.
- NBA/NHL entrarían por `v_team_sports_publication_v1`, que está **VACÍA**: su fuente
  (`v2.team_elo_learning_snapshot`) dejó de generar snapshots ~2026-09-21.
- **Tenis NO está en el pool global** (no hay rama de tenis) y el cerebro **rechazó** su
  modelo ML (`tennis_elo_v1_k8`, MODEL_REJECTED, 50% acc).

**Conclusión honesta:** NHL, NBA y **tenis** no aparecen en el frontend. Todo lo que se
construyó en el sistema `reto` esta sesión (tenis O/U incluido) es **backend-only**;
"está en backend" ≠ "se ve en la app".

## (b) Por qué NHL/NBA están fuera — es una decisión de calidad, no un bug

`v2.team_elo_product_release_gate`, sellado 2026-09-14:

| Modelo | Estado | Evidencia |
|---|---|---|
| NHL `nhl_elo_v1_k12_h25` | **MODEL_REJECTED** | holdout n=863, acc 56.2%, Brier 0.248; "el intervalo de habilidad 95% cruza lo neutral y la calibración es débil" |
| NBA `nba_elo_v1_k24_h50` | RETIRED_OUT_OF_PRODUCT_SCOPE | — |
| WNBA | RETIRED_OUT_OF_PRODUCT_SCOPE | — |

El rechazo de NHL es **justo y más riguroso** que el registro del sistema reto (que lo
marcaba 58.5% sin test de significancia). El cerebro tiene razón.

Decisión del dueño (2026-10-20): **respetar el rechazo.** NHL/NBA NO se fuerzan al frontend.

## (c) Qué necesitaría NHL para aprobar

Un modelo cuyo holdout tenga **habilidad significativa sobre una moneda** (intervalo 95%
que NO cruce lo neutral) y **buena calibración**. 56.2%/Brier 0.248 no alcanza. Un Elo puro
no basta; haría falta señal real (portero, descanso, special teams, back-to-backs) y
re-validar contra esa vara.

## Limpieza de coherencia aplicada (backend-only, no afecta frontend)

El sistema `reto` contradecía al cerebro publicando NBA/NHL como "validados". Se eliminó esa
contradicción:
- `reto_snapshot_capturar_v1()`: quitados los bloques NBA (GANADOR+OU) y NHL. Ya no se
  capturan esos picks.
- `v_reto_mejores_picks_v1`: quitados los bloques NBA/NHL (ahora solo NFL, Soccer, Tenis).
- `reto_modelo_validacion_v1`: borradas las filas `nba` y `nhl` (contradecían al cerebro).

Queda una sola autoridad de producto: **el cerebro**. El tenis O/U permanece como candidato
de laboratorio (modelo nuevo, validado vs mediana, no en producto, sin CLV por falta de
cuotas de tenis) — honestamente etiquetado, no forzado al frontend.

## Nota sobre el trabajo de odds ESPN de esta sesión

`reto_odds_espn_v1` + `v_reto_clv_espn_v1` siguen capturando odds de NBA/NHL/MLB/NFL. Con
NBA/NHL ya sin picks en el sistema reto, `v_reto_clv_espn_v1` no tendrá qué medir para esos
dos; la captura de odds queda como infraestructura de evaluación (lab) por si algún día se
revisa el rechazo con un modelo mejor.
