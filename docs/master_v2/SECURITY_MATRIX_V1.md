# SECURITY — MATRIZ Y HALLAZGOS

Todo verificado read-only contra producción con `BEGIN READ ONLY` y guard confirmado. Patches preparados y probados en laboratorio. **Nada desplegado.**

---

## SEC-03 (HIGH) — envenenamiento del ledger forward · **REPRODUCIDO Y CERRADO EN LAB**

### El ataque, ejecutado

```
CONFIRMADO A1 · anon escribió en el ledger · decision_id=a0256e2cd6a525b932eba4980b5d5cb4
CONFIRMADO A2 · ON CONFLICT DO NOTHING descartó la captura legítima EN SILENCIO
              el ledger conserva p_raw_home=0.99 eligibility=ELIGIBLE
CONFIRMADO A3 · marca de integridad temporal forjada: available_at_decision=AVAILABLE_AT_DECISION
=== vectores confirmados: 3 de 3 ===
```

Un llamante anónimo pre-reclama `decision_id = md5(event|decision_time|model_version)` con datos fabricados. Cuando el productor legítimo captura el mismo evento, `ON CONFLICT DO NOTHING` **descarta la captura real sin error**. El ledger queda con `p_raw_home=0.99` y `eligibility=ELIGIBLE` en lugar de `0.5432` y `MODEL_VERSION_PROVENANCE_MISSING`.

Y `available_at_decision` se deriva de dos parámetros del propio llamante, así que la marca de integridad temporal también es forjable.

### El patch falló primero — y su propio test lo daba por bueno

La primera versión revocaba `EXECUTE` de `anon, authenticated`. Su post-verify **pasaba**. El test adversarial demostró que **anon seguía escribiendo**.

Causa: PostgreSQL concede `EXECUTE` a `PUBLIC` por defecto en toda función nueva. Revocar de `anon` no sirve mientras `PUBLIC` lo tenga, porque `anon` lo hereda. Y el assert miraba entradas ACL explícitas, que no ven el privilegio heredado.

Dos correcciones:
- `REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated`
- el assert pasa a usar `has_function_privilege()`, que sí ve la herencia

**Es el hallazgo metodológico de la noche: un patch de seguridad cuyo propio test lo aprueba mientras la vulnerabilidad sigue abierta.**

### Verificación post-hardening — 5/5

| Test | evaluated_rows | violations |
|---|---|---|
| H1 `ANON_CANNOT_PRECLAIM` | 1 | 0 |
| H2 `ANON_CANNOT_INJECT` (settlement) | 1 | 0 |
| H3 `LEGITIMATE_PRODUCER_CAN_WRITE` | 1 | 0 |
| H4 `IDEMPOTENCY_SAFE` | 1 | 0 |
| H5 `NO_SILENT_POISONING` | 1 | 0 |

Rollback probado: aplica → revierte → re-aplica limpio.

### `SEC03_CONSUMER_MAP` — RESUELTO

Era el bloqueante declarado para desplegar. La cadena de evidencia está completa:

| Eslabón | Evidencia |
|---|---|
| ¿Quién invoca `lab_mlb_fwd_capturar`/`_resultado`? | **Ningún cron directamente.** Una sola función en BD: `lab_mlb_drain_forward` |
| ¿Quién invoca `lab_mlb_drain_forward`? | job `lab_mlb_drain_forward`, `*/10 * * * *`, **activo** |
| ¿Con qué rol corre ese job? | **`postgres`** (los 247 jobs de `cron.job` corren como `postgres`) |
| ¿Quién es owner de las funciones del ledger? | **`postgres`** |

**El productor legítimo es el job `lab_mlb_drain_forward` corriendo como `postgres`, que es el owner.** En PostgreSQL el owner nunca pierde `EXECUTE` por un `REVOKE`.

⇒ **El patch es seguro de desplegar tal cual.** No hace falta conceder `EXECUTE` a ningún rol de servicio adicional.

```
BLOCKED_ON_PRODUCER_IDENTITY = RESUELTO
PRODUCTOR_LEGITIMO           = cron job lab_mlb_drain_forward, rol postgres (owner)
PATCH_LISTO_PARA_GO          = SÍ
```

⚠️ Observación aparte: `lab_mlb_drain_forward` **también** es `SECURITY DEFINER` y ejecutable por `anon`. Un anónimo puede disparar el drenado. No fabrica evidencia falsa (solo drena una cola), pero pertenece al conjunto de SEC-05 y merece el mismo tratamiento.

---

## SEC-05 (CRITICAL, NUEVO) — 127 funciones `SECURITY DEFINER` que escriben, sin control de identidad, alcanzables por `anon`

### Cómo se estrecha el hallazgo

| Filtro | Cuenta |
|---|---|
| `SECURITY DEFINER` en `public` | 512 |
| … que escriben (`INSERT`/`UPDATE`/`DELETE`) | 208 |
| … y `has_function_privilege('anon', …, 'EXECUTE')` | **156** |
| … sin control de identidad interno | **153** |
| … excluyendo funciones de trigger (no invocables por RPC) | **127** |

Solo **3 de 156** verifican identidad (`auth.uid()` / `apodo_de_la_sesion()` / `auth.role()`).

### Corrección a mi propia evaluación inicial

Marqué `corregir_apuesta` como crítica por permitir alterar el resultado y el cashout de una apuesta por UUID. **Es incorrecto:** la función sí valida

```sql
v_apodo := public.apodo_de_la_sesion();
IF v_apodo IS NULL THEN RAISE EXCEPTION 'Sesión no identificada'; END IF;
```

y `apodo_de_la_sesion()` deriva de `auth.uid()`, el JWT verificado por Supabase, no manipulable por el llamante. **Está bien defendida.** Lo mismo `registrar_perfil`. Es una de las 3 con control.

### Las que sí quedan expuestas (muestra de las 127)

| Función | Riesgo |
|---|---|
| `crear_batalla(p_reto_por, p_reto_contra, p_tipo, p_pick_a_id, p_apuesta_virtual)` | crea apuestas entre usuarios arbitrarios con stake arbitrario, sin verificar quién llama |
| `fantasy_cargar_datos_externos(p_json jsonb, …)` | inyección de datos arbitrarios |
| `guardar_analisis_fixture(p_fixture_id, …, p_analysis jsonb)` | escribe análisis arbitrarios |
| `apifootball_registrar_uso(…)` | falsea contabilidad de cuota de API |
| `correr_backtest`, `correr_backtest_nfl` | cómputo caro invocable sin límite → DoS |
| `encolar_analisis_todos(p_dias, p_tope)` | encola trabajo masivo → DoS |
| `futbol_clima_pedir`, `futbol_arbitro_pedir`, `futbol_jugador_pedir`, `apifootball_conciliar` | **consumen cuota de APIs externas de pago** |
| `absorber_agenda_espn`, `absorber_detalle_espn`, `absorber_historico_espn`, `absorber_tenis_espn` | disparan ingesta |

Las de cuota de API son especialmente prácticas de explotar: un anónimo puede agotar cuota de pago con llamadas repetidas.

### Por qué NO preparé un revoke masivo

La instrucción es explícita: *"No revocar a ciegas."* Varias de estas 127 podrían ser invocadas legítimamente por el frontend o por edge functions. Revocar `PUBLIC` sobre las 127 sin el inventario de consumo rompería producción.

**Lo que sí se puede afirmar:** la política por defecto está invertida. En un esquema expuesto por PostgREST, `EXECUTE` a `PUBLIC` sobre funciones `SECURITY DEFINER` que escriben debería ser la excepción declarada, no el default heredado.

**Acción recomendada:** `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` para funciones nuevas, y un barrido dirigido de las 127 con el mapa de consumo delante.

---

## SEC-01 (HIGH) — lectura anónima de superficies de picks

44 objetos con `pick` en el nombre tienen `SELECT` para `anon`/`authenticated`, incluidos `_backup_picks_fantasma_20260526`, `picks_liga_rename_backup_20260829`, `oraculo_picks_tracking_duplicados_20260829` y `pick_debug_logs`.

**24 de 26 vistas de picks corren como OWNER** (sin `security_invoker=true`), así que no aplican RLS de las tablas subyacentes. Solo `picks_recomendados_hoy_raw` y `v_picks_futbol_limpio` son `invoker`.

Subconjunto con cero consumidores en BD y ningún propósito de producto — **revocable sin riesgo de romper dependencias**: los 4 backups/debug/duplicados más `picks_huerfanos`, `picks_con_liga_inconsistente`, `pre_pick_grading_log`, `alertas_pick_peligro`.

---

## SEC-02 (MEDIUM) — `SECURITY DEFINER` sin `search_path`

8 funciones (`lab_ff_*`, `lab_mlb_fwd_*`). Mitigado hoy: `anon` y `authenticated` **no** tienen `CREATE` en `public` (verificado con `has_schema_privilege`), así que el vector de hijack está cerrado. Sigue siendo defensa en profundidad estándar. Incluido en `sec_hardening_v1.sql`.

---

## Estado

```
SEC-01 = ABIERTO (HIGH)   · patch parcial preparado, requiere consumer map
SEC-02 = PREPARADO (MED)  · en sec_hardening_v1.sql, probado
SEC-03 = LISTO PARA GO (HIGH) · reproducido 3/3, cerrado 5/5, rollback probado, productor identificado
SEC-05 = ABIERTO (CRIT)   · 127 funciones, documentado, sin patch masivo por diseño
SECRETOS EN REPO = 0
FORWARD_CAPTURE_AUTHORIZED = FALSE  (bloqueado hasta desplegar SEC-03)
```
