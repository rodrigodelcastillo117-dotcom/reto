# GAP A — auditoría adversarial de TODAS las rutas de cierre de parlay (§26)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
estado: `READ_ONLY_VERIFIED` (defs de prod leídas) + `iss034 STAGED`.

## Todas las rutas que pueden cerrar un parlay (enumeradas, no sólo la de iss034)
Triggers en `public.parlays` (verificado en pg_trigger) + funciones batch/RPC:
| ruta | tipo | ¿verifica finalidad? |
|---|---|---|
| `auto_cerrar_parlay_si_leg_perdido` | BEFORE UPDATE (`a_auto_cerrar...`) | **SÍ tras iss034** (`v2.fn_leg_is_final`) |
| `auto_close_parlay_when_all_legs_decided` | AFTER UPDATE (`auto_close_parlay_trigger`) | NO por sí misma (confía en leg.resultado) |
| `cerrar_parlays_con_pata_perdida` | batch/cron | **SÍ tras iss034** |
| `autocalificar_parlays_pendientes` | cron | delega en el guard BEFORE UPDATE |
| `editar_resultado_parlay`, `corregir_apuesta` | RPC persona | MANUAL/ADMIN (permitido) |
| `recalc_parlay_on_result_change` | BEFORE UPDATE | recomputo, no cierre nuevo |

## Red de seguridad universal (YA en prod) — cubre TODAS las rutas
`protect_parlays_premature_grading` es un trigger **BEFORE UPDATE** en parlays que:
- actúa cuando `resultado` pasa a 'ganado'/'perdido' desde un estado no-final;
- exime sólo MANUAL/ADMIN_OVERRIDE (acción de persona);
- para 'perdido': permite el cierre **sólo si al menos una pata perdida es
  `is_truly_final`** (vía `live_scores` o `buscar_marcador_v2` o mundial final);
- en cualquier otra pata decidida no-final (y no pa_activado, no pospuesto-y-final)
  marca `v_any_premature` → **revierte** `NEW.resultado:='pendiente'`,
  `confianza='BLOQUEADO_PREMATURO'`.

**Orden de disparo BEFORE UPDATE** (alfabético por tgname): `a_auto_cerrar_parlay_leg_perdido`
→ `protect_parlays_premature` → `trg_bloquear_calificacion_parlay_legs_futuros` → …
Es decir: aunque `auto_cerrar` (o cualquier UPDATE de `auto_close`, cron o RPC) intente
cerrar prematuramente, **`protect` corre después y revierte** si no hay pata FINAL perdida.
`auto_close_parlay_when_all_legs_decided` dispara un UPDATE secundario que re-entra al
mismo BEFORE-UPDATE chain → también queda gateado por `protect`. **Ninguna ruta escapa.**

`bloquear_calificacion_parlay_con_legs_futuros`: permite 'perdido' con pata perdida
inmediata, pero bloquea 'ganado'/'nulo' si hay legs futuros pendientes.

## Casos adversariales (§26) → comportamiento verificado por código
| caso | esperado | mecanismo |
|---|---|---|
| C1: 3 legs, leg1 LIVE marcada 'perdido' EARLY_HIGH | **pending** | auto_cerrar exige fn_leg_is_final (iss034) + protect revierte |
| C2: leg1 FINAL realmente perdida | **lost** | auto_cerrar cierra; protect permite (is_truly_final) |
| C3: leg1 FINAL push, resto PRE | **pending** | push no es 'perdido'; no todos decididos; auto_close no cierra |
| C4: leg1 postponed (no final) | **pending** | is_truly_final=false → protect revierte / auto_cerrar no cuenta |
| C5: leg final→proveedor revierte a live/postponed | sin doble cierre irreversible | protect sólo actúa desde no-graded; recalc maneja el flip; idempotencia GAP B |

## Hallazgo clave
La protección contra "parlay perdido sin jugarse" **NO depende de una sola función**:
existe una red BEFORE-UPDATE (`protect_parlays_premature_grading`) que gatea TODAS las
rutas por `is_truly_final`. iss034 además arregla la ruta primaria (`auto_cerrar`) para
no depender exclusivamente del guard. `§26 "no arregles una ruta dejando otra vulnerable"`:
cubierto — la ruta adicional `auto_close_parlay_when_all_legs_decided` queda gateada por
el mismo guard universal (probado leyendo el orden de triggers y el UPDATE secundario).

## Gates
- `PARLAY_EARLY_LOSS_GATE = PASS` (guard universal en prod + iss034 endurece la ruta primaria).
- `GRADING_FINAL_ONLY_GATE = PASS` (todas las rutas gateadas por is_truly_final).
Regresión C1/C2 en `iss034_parlay_gapA_test.sql`; C3/C4/C5 en
`iss034_parlay_gapA_test_extra.sql` (branch, requiere set completo de triggers de prod).
