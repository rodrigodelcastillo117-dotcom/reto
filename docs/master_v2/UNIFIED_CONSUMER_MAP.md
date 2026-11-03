# UNIFIED_PICK_SURFACES — CONSUMER MAP

```
UNIFIED_PICK_CONTRACT  = PASS
UNIFIED_PICK_MIGRATION = 4/46
UNIFIED_PICK_STATUS    = IN_PROGRESS
```

Trazado con `pg_depend` (vista→vista) y búsqueda de referencias en cuerpos de función. El consumidor de frontend **no es observable desde este repo**; se infiere de la combinación *sin consumidor en BD* + *SELECT concedido a `anon`*.

---

## 1. Corrección importante al modelo mental

`v_pick_canonico` **lee de** `picks_recomendados_hoy`, `picks`, `v_picks_mlb_modelo`, `v_picks_futbol_calibrado` y `agenda_espn`.

Es decir: varias de las superficies "sin gate" **no son autoridades rivales, son insumos aguas arriba**. El gate está en el punto correcto — el cuello de botella canónico. **El problema es que `anon` puede leer los insumos directamente y saltarse el gate.**

Eso cambia la acción: no hay que "migrar" un insumo para que aplique el gate; hay que **impedir que sea alcanzable como si fuera una superficie de producto**.

## 2. Clasificación por consumo

### A. Sin consumidor en BD + legible por `anon` ⇒ solo-frontend

Migración de bajo riesgo en la BD: nada dentro de la base se rompe.

| Objeto | Semántica actual | Objetivo canónico | Riesgo |
|---|---|---|---|
| **`nfl_picks_premium`** | "picks premium" con P de la casa, 2 filas/partido | reemplazar por `nfl_game_card_v1` | **BAJO en BD · ALTO en producto** |
| `v_super_pick` | tiene gate (eev1 + decision_pick_v1) | auditar que el gate se aplique de verdad | BAJO |
| `v_oraculo_canonico` | hereda `es_pick` | adoptar `classification` | BAJO |
| `v_poisson_recomendaciones` | "recomendaciones" sin gate | renombrar o retirar | BAJO |
| `v_anti_picks` | diagnóstico | prohibir como superficie de producto | BAJO |
| `ai_picks_historial` | histórico con `kelly` | LEGACY_READONLY | BAJO |
| `oraculo_roi_por_liga`, `v_oraculo_picks_activos` | métricas | LEGACY_READONLY | BAJO |

### B. Sin consumidor en BD + legible por `anon` + no es producto ⇒ DEPRECATE ya

| Objeto | Por qué |
|---|---|
| `_backup_picks_fantasma_20260526` | backup con columna `stake`, expuesto a `anon` |
| `picks_liga_rename_backup_20260829` | backup de renombrado |
| `oraculo_picks_tracking_duplicados_20260829` | tabla de duplicados |
| `pick_debug_logs` | logs de depuración |
| `picks_huerfanos`, `picks_con_liga_inconsistente` | diagnóstico de integridad |
| `pre_pick_grading_log`, `alertas_pick_peligro` | operación interna |

Acción: **`REVOKE SELECT ... FROM anon, authenticated`**. No cambia contratos, no rompe dependencias (cero consumidores en BD), reduce superficie de inmediato.

### C. Insumos aguas arriba del canónico ⇒ NO migrar, restringir

| Objeto | Consumido por | Acción |
|---|---|---|
| `picks_recomendados_hoy` | `v_pick_canonico`, `v_oraculo_canonico`, `v_super_pick`, `v_pick_momio_libro`, `mejor_pick_hoy` | mantener como insumo; **revocar `anon`** |
| `picks_recomendados_hoy_raw` | `picks_recomendados_hoy` | idem |
| `v_picks_mlb_modelo` | `v_mejores_picks_mlb`, `v_pick_canonico` | idem |
| `v_picks_futbol_calibrado` | `v_pick_canonico`, `medir_contraste_motores` | idem |

### D. Alto acoplamiento ⇒ tocar solo con inventario de frontend

| Objeto | Vistas dep. | Funciones dep. |
|---|---|---|
| **`picks`** | 11 | **145** |
| **`oraculo_picks_tracking`** | 25 | 27 |
| `pick_learning_data` | 1 | 7 |
| `v_picks_para_parlay` | 0 | 4 |
| `pick_del_dia` | 0 | 3 |

`picks` con 145 funciones dependientes es el núcleo transaccional. **No se toca en esta fase.**

## 3. Estado de migración: 4 de 46

| Migrado | Cómo |
|---|---|
| `v_pick_canonico` | gate `economic_eligibility_v1` + `es_pick_reason` (ISS-003/009 V2, desplegado) |
| `v_mejores_picks_mlb` | gate + `economically_eligible`/`reason_code` en 23/24 (V2, desplegado) |
| `v_super_pick` | gate preexistente (**pendiente de auditar que se aplique de verdad**) |
| `v_oraculo_canonico` | hereda `es_pick` (**pendiente de adoptar `classification`**) |

Las otras 42 siguen sin `classification` ni `authorized_bet`.

## 4. Orden de migración propuesto

1. **REVOKE** en el grupo B (7 objetos). Cero riesgo en BD, beneficio inmediato.
2. **`nfl_picks_premium` → `nfl_game_card_v1`.** Cero consumidores en BD; solo requiere que el frontend apunte a la vista nueva. **Cierra NF-01.**
3. **REVOKE `anon`** en el grupo C (insumos). Requiere confirmar que el frontend no los lee directamente.
4. Auditar `v_super_pick` y `v_oraculo_canonico`.
5. Grupo D solo después del inventario de frontend.

## 5. Lo que sigue sin poder trazarse

El consumidor de frontend. Un `SELECT` concedido a `anon` significa *alcanzable vía PostgREST*, no *usado*. Sin el repo del frontend, los pasos 2 y 3 necesitan que alguien confirme qué pantalla lee qué. **Es el bloqueante central de la unificación.**
