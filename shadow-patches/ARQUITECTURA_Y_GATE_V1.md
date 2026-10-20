# Arquitectura real, mapa de medibilidad y gate (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-10-20. Dinero OFF.

## Hallazgo estructural (lo más importante)

Hay **dos sistemas de picks casi disjuntos** (solo 6 eventos en común de 567):

| Sistema | Tabla | ¿Qué tiene? | ¿CLV? |
|---|---|---|---|
| **reto** (el que la app muestra) | `reto_pick_snapshot_v1` | NBA, NHL, MLB, NFL, Soccer, **Tenis** | **NO medía CLV** |
| **oraculo** (legacy/paralelo) | `oraculo_picks_tracking` | Soccer, MLB, NHL, NBA, NFL (sin tenis) | Sí, pero estancado ~2026-09-12 |

Consecuencia: el veredicto CLV que existía ("EDGE NEGATIVO") describe **oraculo**, NO los
picks que la app publica. El producto estrella (reto) estaba **sin medición de mercado**.

## Mapa de medibilidad de CLV (`v_reto_mercado_gate_v1`)

Se cruzaron los mercados publicados con las cuotas de cierre reales
(`radar_odds_snapshots` / `v_linea_de_cierre`, por `espn_event_id`):

| Deporte/Mercado | Picks | Validado vs mediana | ¿CLV medible? |
|---|--:|---|---|
| soccer ML | 199 | — | **SÍ** (146 eventos con cierre 3 patas) |
| soccer BTTS | 375 | — | sí (línea de cierre disponible) |
| soccer OU25 | 350 | — | NO (cierre usa línea 3.5, picks 2.5 → no comparable) |
| nba GANADOR/OU | 93 | 67.3% / 65.7% | **NO — sin feed de cuotas** |
| nhl GANADOR | 39 | 58.5% | **NO — sin feed de cuotas** |
| nfl GANADOR | 29 | — | parcial (6 eventos) |
| **tenis ATP/WTA** (GANADOR + OU) | — | 60-66% | **NO — no existe feed de cuotas de tenis** |

**Verdad dura sobre el tenis:** no hay ninguna cuota de tenis en el sistema. El CLV del
tenis O/U que se publicó **no es medible hoy**; requiere contratar/cablear un feed de
cuotas de tenis. Hasta entonces su edge de mercado es desconocido (solo validado vs
mediana).

## Primer CLV real del sistema reto (`v_reto_clv_soccer_ml_v1`)

Único rincón del producto estrella con feedback de mercado: soccer Moneyline, prob del
modelo vs prob de **cierre de-vigada** (3 patas, promedio de casas). No es CLV realizado
(reto no guarda momio de entrada); es ventaja modelo-vs-cierre.

- n=146 picks (82 resueltos).
- Ventaja media **+1.1 pp**, mediana **+2.1 pp**; el modelo supera al cierre **54%**.
- Win 59.8%; pero el subconjunto con ventaja >3pp NO gana más (57.5%).
- **Veredicto: levemente positivo, no concluyente.** Mejor que el oraculo (negativo), pero
  no es prueba de edge. Vigilar, no declarar.

## Lo que falta para un CLV honesto del producto estrella (no hecho)

1. **Guardar el momio de entrada** en `reto_pick_snapshot_v1` al capturar el pick (hoy solo
   guarda prob y línea) → sin esto el CLV realizado es imposible, solo el proxy modelo-vs-cierre.
2. **Feed de cuotas de tenis, NBA y NHL** (The Odds API las tiene; hay que pedirlas) → hoy
   esos mercados se publican a ciegas de mercado.
3. **Alinear la línea de OU de soccer** (2.5 del modelo vs 3.5 del cierre) para poder medir.
4. **Reactivar** la captura de cierres (varias ligas pararon ~2026-09-12).

## Objetos creados

- `v_reto_mercado_gate_v1` — superficie de control: estado de CLV por mercado publicado.
- `v_reto_clv_soccer_ml_v1` — ventaja modelo-vs-cierre, soccer ML.
- (ola previa) `clv_dashboard` honesto, `v_reto_clv_veredicto_sistema_v1`,
  `v_reto_realidad_vs_mercado_v1`.

Nada se despublicó (decisión del dueño: juntar más datos).
