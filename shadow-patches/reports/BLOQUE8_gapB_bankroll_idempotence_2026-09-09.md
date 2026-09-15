# GAP B — idempotencia de bankroll, auditoría adversarial (§28)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
estado: `READ_ONLY_VERIFIED` (prod) + `iss035 STAGED`.

## La verdad del bankroll es SUM sobre estado (idempotente por construcción)
`public.calcular_bankroll_actual__base(apodo)` (def leída de prod):
```
bankroll_inicial(usuarios)
+ SUM(ajustes_cuenta.monto)                                   -- desde reto_desde(apodo)
+ SUM(picks.ganancia_neta   WHERE resultado in ganado/perdido/push/nulo/retirado)
+ SUM(parlays.ganancia_total WHERE resultado in ...)          -- ganancia_total (con bono), NO neta
```
Es una **SUMA sobre el estado actual de las filas**, nunca un acumulador incremental.
=> Ejecutar la MISMA transición 1, 2 o 10 veces produce el MISMO bankroll: cada fila
cuenta una sola vez con su valor actual. Doble callback / retry / re-grade / PUSH /
early payout **no pueden doble-contabilizar** por diseño.

Nota histórica embebida en la función: antes sumaba `ganancia_neta` en parlays y el bono
se contaba dos veces; corregido 2026-09-02 a `ganancia_total`. Ya sin doble conteo.

## Prueba read-only de idempotencia (VERIFICADO)
`calcular_bankroll_actual('rodelcast')` llamada 3× en la misma query → **5035.00,
5035.00, 5035.00** (idéntico). Determinista, sin RNG, función STABLE.

## Casos §28 → resultado (garantizado por diseño state-based + fix de cache iss035)
| caso | resultado |
|---|---|
| double callback / retry (misma transición) | bankroll idéntico (la suma no cambia) |
| pending→won / →lost / →push | contribuye 1 vez con su ganancia_neta actual |
| won→lost / lost→won / push→won (corrección) | bankroll = valor corregido, sin acumular |
| early payout | ganancia_neta una vez → sumada una vez |
| re-grade / parlay / PA correction | recomputa de estado, sin doble conteo |
| ejecución repetida concurrente-like | mismo valor final (SUM idempotente) |

## Único residual (cache) → iss035
La columna cache `picks.bankroll_post`/`parlays.bankroll_post` sólo se refrescaba en la
transición pendiente→graded (el trigger exigía OLD.resultado='pendiente'). En una
CORRECCIÓN graded→graded quedaba STALE (no afecta la verdad, sólo el snapshot mostrado).
iss035 extiende los triggers `actualizar_bankroll_post_al_calificar` /
`_parlay` para recalcular también cuando cambia `resultado`/`ganancia_neta` en una fila
ya calificada → cache consistente con la verdad. **El cache nunca es autoridad monetaria**
(§28): la verdad siempre se deriva de estado vía calcular_bankroll_actual.

## Gate
`BANKROLL_IDEMPOTENCE_GATE = PASS` (verdad state-based idempotente, verificado read-only;
fix de cache staged en iss035). Test de transiciones (branch, tx ROLLBACK):
`shadow-patches/tests/iss035_bankroll_idempotence_test.sql`.
