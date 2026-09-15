# BLOQUE 8 — Grading / Pagos Anticipados · root fix SOCCER (STAGED)

Rama `claude/reto-13m-espn-matches-3uknie`. Read-only diagnóstico + guard staged.
NO aplicar bajo freeze. Foco SOCCER (raíz sport-agnóstica); NO se abrió track NFL/MLB.

## Raíces detectadas (SQL real de prod)
- **R1 — pérdida anticipada posible.** `protect_picks_premature_grading()` y
  `bloquear_calificacion_pick_futuro()` bloquean calificar en vivo, pero hacen
  **bypass cuando `confianza_calificacion IN ('EARLY_HIGH','EARLY_MEDIUM')`** y ese
  bypass NO distingue `ganado` de `perdido`. => la ruta de calificación temprana
  permite marcar **PERDIDO con el partido aún en vivo/por jugar** = "parlay/pick
  marcado perdido sin jugarse". Un pago/decisión anticipada sólo debe adelantar
  GANANCIA, nunca pérdida.
- **R2 — evidencia de PA inconsistente.** `dispatch_pa_para_pierna_parlay()` (patas
  de parlay) graba `pa_score_snapshot`+`pa_activado_at` y es idempotente
  (`pierna_ya_procesada`). Pero la **tabla `picks`** puede quedar con
  `pa_activado=true` SIN `pa_score_snapshot` ni `pa_activado_at`: **1 fila así hoy**
  (no auditable: no se sabe qué marcador ni cuándo disparó el pago anticipado).

## Fix staged (iss028)
- `guard_no_early_loss()` (BEFORE UPDATE, antes de los protectores): bloquea la
  transición a `perdido` si el evento no es `is_truly_final(...)`, aunque confianza
  sea EARLY_*. Persona → excepción; proceso → degrada a `pendiente`. `ganado`/`nulo`
  anticipados siguen permitidos.
- `guard_pa_evidencia_obligatoria()`: si `pa_activado` pasa a true exige
  `pa_score_snapshot` (excepción si falta) y autosella `pa_activado_at`. Constraint
  dura `chk_pa_evidencia` (NOT VALID) para no romper la fila histórica hasta sanearla.
- Saneo de la fila huérfana (G3) y nota de idempotencia de bankroll (G4) documentados.

## Test de regresión (iss028_grading_guard_test.sql)
Corre en transacción con ROLLBACK (no muta prod). Casos:
1. PÉRDIDA anticipada por EARLY_HIGH con partido en vivo → **bloqueada** (PASS).
2. GANANCIA anticipada legítima → **permitida** (PASS).
3. PA sin `score_snapshot` → **rechazado** (PASS).
4. PA con snapshot y `activated_at` NULL → **autosellado** (PASS).
Pendiente: ejecutar en un Supabase branch (bajo freeze no se corre contra prod).

## Operaciones que requerirán autorización posterior
1. Cargar iss028 (funciones guard) + instalar los 2 triggers en `picks` (y evaluar
   `guard_no_early_loss` también en `parlays`).
2. Sanear la fila huérfana de PA (G3) y validar el CHECK.
3. Auditar idempotencia de `actualizar_bankroll_post_*` (iss029, aparte).
