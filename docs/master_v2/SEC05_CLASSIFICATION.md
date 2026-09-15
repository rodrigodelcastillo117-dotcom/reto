# SEC-05 — CLASIFICACIÓN DE LAS 127 FUNCIONES RPC

```
SEC-05 = CRITICAL, ABIERTO
PATCH 1 = PREPARADO Y VALIDADO (38 de 127) · NO DESPLEGADO
```

**El universo:** funciones `SECURITY DEFINER` en `public` que escriben, **no** verifican identidad, **no** son de trigger, y `has_function_privilege('anon', …, 'EXECUTE')` = true.

---

## 1. Clasificación por riesgo

| Clase | Nº | Qué permite a un anónimo |
|---|---|---|
| **A · CUOTA DE API EXTERNA** | **59** | invocar `net.http_post`/`net.http_get` en bucle y **agotar cuota de APIs de pago** |
| **D · DESTRUCTIVO** | **53*** | ejecutar funciones que contienen `DELETE FROM` |
| C · CÓMPUTO CARO (DoS) | 10 | `correr_backtest`, `encolar_analisis_todos`, `recalcular_*` |
| E · INYECCIÓN DE DATOS | 3 | `fantasy_cargar_datos_externos`, `guardar_analisis_fixture`, `apifootball_registrar_uso` |
| B · DINERO | 2 | `crear_batalla` (stake arbitrario), `capturar_clv_usuario` |
| F · OTROS | 42 | varios |

\* Las clases se solapan: muchas destructivas son también de cuota. El total sin duplicar sigue siendo 127.

**La clase A es la más explotable en la práctica.** No requiere ingenio: basta llamar repetidamente. El daño es económico y directo.

## 2. Por qué NO hay revoke masivo

Instrucción explícita: no revocar a ciegas. Y el consumer map del frontend aún es parcial (`pg_stat_statements` llevaba 7 minutos acumulando). Revocar 127 funciones sin saber cuáles llama el frontend rompería producción.

## 3. Patch 1 — el subconjunto donde la evidencia sí alcanza

`shadow-patches/security/sec05_patch1_ingesta.sql` · **38 de 127**

Familia `*_pedir` / `*_recoger` / `absorber_*`. Es ETL puro: `_pedir` llama a la API externa, `_recoger` procesa la respuesta. **Ninguna es plausiblemente una superficie de frontend** — no devuelven datos de producto, mueven datos entre la API y las tablas internas.

```
REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ... TO service_role;
```

**Tres razones por las que es seguro:**

1. **`pg_cron` no se ve afectado.** Los jobs corren como `postgres`, que es el owner; el owner nunca pierde `EXECUTE`.
2. **`service_role` conserva acceso.** No hay evidencia de que las edge functions las llamen, pero tampoco de lo contrario. Mantenerlo es el lado conservador; si el consumer map demuestra que no las usa, se puede endurecer.
3. **`REVOKE FROM PUBLIC` es imprescindible.** Revocar solo de `anon` no cierra nada: PostgreSQL concede `EXECUTE` a `PUBLIC` por defecto y `anon` lo hereda. Esto se comprobó empíricamente en SEC-03, donde el primer patch parecía funcionar y no funcionaba.

### Validación en lab

| Assert | evaluated_rows | violations |
|---|---|---|
| P1 ingesta cerrada a `anon`/`authenticated` | 38 | 0 |
| P2 `service_role` conserva acceso | 38 | 0 |
| P3 cron corre como owner: no afectado | — | informativo |

Aplica → revierte → re-aplica limpio. Rollback probado.

## 4. Las 89 restantes

| Grupo | Qué falta para decidir |
|---|---|
| 21 de cuota **no** en la familia de ingesta (`futbol_estadios_geocodificar`, `apifootball_conciliar`, `disparar_reanalisis_prepartido`, `indexar_fixtures_*`, `sync_*`) | confirmar que ninguna es invocada desde el cliente |
| 10 de cómputo caro | podrían ser botones de administración en la UI |
| 3 de inyección de datos | `guardar_analisis_fixture` podría ser llamada por una edge function |
| 2 de dinero | **`crear_batalla` merece revisión prioritaria**: crea apuestas entre usuarios arbitrarios con stake arbitrario y sin verificar quién llama |
| 53 restantes | requieren el consumer map |

## 5. Recomendación estructural

La política por defecto está invertida. En un esquema expuesto por PostgREST, `EXECUTE` a `PUBLIC` sobre funciones `SECURITY DEFINER` que escriben debería ser **la excepción declarada**, no el default heredado.

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
```

Eso solo afecta a funciones **nuevas**; no arregla las existentes, pero detiene el crecimiento del problema. Es una línea, es reversible, y no rompe nada de lo que ya funciona.

## 6. Estado

```
SEC-05                = CRITICAL, ABIERTO
PATCH_1_INGESTA       = PREPARADO · VALIDADO EN LAB · NO DESPLEGADO (38/127)
RESTANTES             = 89 · bloqueadas por consumer map
PRIORIDAD_SIGUIENTE   = crear_batalla (dinero, sin control de identidad)
RECOMENDACION_GLOBAL  = ALTER DEFAULT PRIVILEGES para funciones nuevas
```
