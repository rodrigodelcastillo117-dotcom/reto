# BLOQUE 8 — GAP A (parlay early-loss) + GAP B (bankroll idempotente) · EVIDENCIA (STAGED)

Artefactos: `iss028` (raíz grading picks), `iss034` (GAP A parlay), `iss035` (GAP B).
Tests: `iss028/iss034` (tx ROLLBACK). NO aplicar bajo freeze.

## GAP A — un parlay sólo pierde con pata FINAL realmente perdida
Raíz (código de prod): `auto_cerrar_parlay_si_leg_perdido()` cerraba el parlay como
'perdido' si CUALQUIER pata tenía `resultado='perdido'`, SIN verificar finalidad.
`cerrar_parlays_con_pata_perdida()` igual. Una pata marcada 'perdido' en vivo (ruta
EARLY) cerraba el parlay = "parlay perdido sin jugarse".
Fix (iss034):
- `v2.fn_leg_is_final(leg)`: FINAL sólo si `live_scores` del evento es `is_truly_final`.
- Ambas funciones reescritas: una pata cuenta como perdedora del parlay **sólo si es
  FINAL y perdida**. Pata LIVE/PRE nunca cierra el parlay.
Regression (iss034_parlay_gapA_test, tx ROLLBACK):
- C1: parlay 3 patas, 1 pata LIVE marcada EARLY_HIGH 'perdido' → **parlay sigue pendiente** (PASS).
- C2: esa pata pasa a FINAL 0-2 → **parlay cierra 'perdido', ganancia -100** (PASS).

## GAP B — bankroll idempotente
HALLAZGO: el bankroll-VERDAD YA es idempotente por construcción.
`calcular_bankroll_actual__base` = bankroll_inicial + SUM(ajustes) +
SUM(picks.ganancia_neta graded) + SUM(parlays.ganancia_total graded). Es una **SUMA
sobre el estado actual**, nunca un acumulador. Por tanto doble callback, retry,
re-grade, PUSH y early payout **no pueden doble-contabilizar** (al recalcular, cada
fila cuenta una vez con su valor actual).
Residual: la columna cache `bankroll_post` sólo se refrescaba en pendiente→graded, así
que una CORRECCIÓN de resultado (graded→graded) la dejaba stale (no afecta la verdad).
Fix (iss035): los triggers de bankroll_post también recalculan cuando cambia
`resultado`/`ganancia_neta` en una fila ya calificada → cache consistente con la verdad.

Casos de idempotencia (garantizados por el diseño state-based + fix de cache):
| caso | resultado |
|---|---|
| doble callback / retry (misma transición) | bankroll idéntico (suma no cambia) |
| corrección de resultado (ganado→perdido) | bankroll = valor corregido, sin acumular |
| PUSH / nulo | ganancia_neta=0 → contribuye 0 |
| early payout | ganancia_neta una vez → sumada una vez |
| re-grade | recomputa de estado, sin doble conteo |

## Operaciones que requerirán autorización posterior
1. Ejecutar iss034 (reemplaza auto_cerrar_parlay_si_leg_perdido + cerrar_parlays_con_pata_perdida) y iss035 (triggers de bankroll_post).
2. Correr iss034/iss028 tests en Supabase branch.
3. (Opcional) backfill de bankroll_post en filas corregidas históricas.
