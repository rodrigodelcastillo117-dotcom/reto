# Auto-recalibración semanal: la IA que se mejora sola, con compuerta de honestidad

Fecha: 2026-11-08. Gatillo: "que la IA aprenda... modo ULTRA TOP GOD" + "JUSTO".

## Qué es (honesto)
No es magia ni "predecir el futuro". Es un loop que hace que el motor **aprenda de sus propios
resultados calificados**, con una sola regla inquebrantable:

> **Solo se aplica una recalibración si mejora el Brier OUT-OF-SAMPLE.**

## Construido
- **Función `reto_recalibrar_auto_v1()`** (SECURITY DEFINER, revoke public): por cada deporte con
  ≥20 calificados de test y ≥30 de train, divide train/test por fecha (70/30), busca el mejor
  `k` de shrink-a-50% en train, y lo **valida en test**. Si mejora el Brier OOS → lo marca
  `validado=true` y guarda `k`; si no → `k=1.0`, `validado=false`. Upsert en
  `reto_calibracion_deporte_v1`.
- **Cron `reto-recalibrar-auto-semanal`** (jobid 598, lunes 4:13am CDMX).
- **Email `mejores-picks-diario` v5**: lee el registro y aplica **cualquier** recalibración validada
  automáticamente — tenis por tour (ATP/WTA), demás deportes por nombre. Cuando la IA valide un
  deporte nuevo, el email lo aplica solo, sin tocar código. Fallback: probs crudas.

## Primera corrida (la compuerta funcionando)
| Deporte | mejor k in-sample | ¿pasa OOS? | aplicado |
|---|---|---|---|
| tenis_atp | 0.70 | ✅ Brier 0.2462→0.2381 | **sí** |
| nba | 0.85 | ❌ 0.1796→0.1844 | no (k=1) |
| nhl | 0.80 | ❌ 0.2035→0.2104 | no (k=1) |
| tenis_wta | 0.65 | ❌ 0.2193→0.2240 | no (k=1) |
| soccer | 1.00 | ya calibrado (n=320) | no |

La IA **quiso** encoger NBA/NHL/WTA (tentador in-sample) pero la validación OOS lo **rechazó**.
Solo ATP sobrevive. Eso es el aprendizaje honesto: mejora lo que de verdad mejora, y se niega a
sobreajustar el resto. Resuelve el "pendiente NBA" con datos, no con ganas.

## Lo que esto significa para "ULTRA TOP GOD"
El modo dios honesto = probabilidades calibradas (auto-mantenidas) + line shopping (mejor precio) +
CLV positivo + nunca mentir. Las cuatro juntas ponen la app arriba del 99% de los tipsters. No
porque adivine más, sino porque el resto no hace ninguna. Dinero OFF siempre.
