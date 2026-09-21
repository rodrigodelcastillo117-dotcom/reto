# ISS274 — «No pudimos cargar lo mejor de hoy»: la app no tenía permiso

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## Cómo salió: una captura del dueño

Yo llevaba rato buscando un bug equivocado. Sospechaba que la página rotulaba mal
el día («hoy» sobre un partido de mañana). **Me equivoqué: no existe ese bug.**
La tarjeta dice *"ANÁLISIS DE LA SEMANA · SEMANA 2 · NFL"* y pone la fecha
`21/09 06:15 PM`. Está bien rotulada.

Lo que sí traía la captura, al pie:

> **"No pudimos cargar lo mejor de hoy. No lo sustituimos por la cartelera completa."**

Eso no es un estado vacío, es un **fallo de carga**. Y el mensaje está bien
escrito: se niega a rellenar el hueco con la cartelera completa en vez de fingir
que tiene algo. Fail-closed correcto. Lo que estaba mal era la causa.

## La causa, medida con el rol puesto

```
anon daily_best = ERROR(42501)   auth daily_best = ERROR(42501)
anon lo_mejor   = ERROR(42501)   auth lo_mejor   = ERROR(42501)
anon global_top = ERROR(42501)
```

`42501` = **permiso denegado**. La app nunca pudo leer esas vistas.

## Eran DOS problemas, no uno

Esto es lo importante y casi me lo pierdo:

| # | problema | cuándo se arregló |
|---|---|---|
| 1 | La vista materializada llevaba **congelada desde el 19 de septiembre** y su cron estaba apagado | ISS273, hoy más temprano |
| 2 | **Las vistas no tenían GRANT**: la app recibía 42501 | ISS274, esto |

**Arreglar uno sin el otro no cambiaba nada en pantalla.** Yo arreglé el primero
y di por hecho que la función revivía. El dueño siguió viendo el mismo error,
porque el segundo seguía ahí. Sin su captura no lo encuentro.

## Por qué este GRANT es el correcto y no un parche

| criterio | cómo se cumple |
|---|---|
| ¿Patrón nuevo? | **No.** Las cuatro vistas son de `postgres` con `security_invoker=false`, igual que `v_futpro_publication_v3`, que **sí funciona** (`anon=true`, `auth=true`). Es el patrón ya establecido. |
| ¿Se tocan tablas base? | **No.** La regla del dueño («no concedas SELECT a tablas base para reparar una vista») se respeta: la vista corre con los privilegios de su dueño para lo de abajo. |
| ¿Superficie mínima? | **Sí.** Solo las 4 que el frontend declara leer en `docs/BACKEND_SURFACE_USADA.md`. `v_reto13m_global_top_v2` **no** se concede: es eslabón interno. Verificado que sigue cerrado (42501) después del cambio. |
| ¿Qué se expone? | Partido, pick, probabilidad, versión del cerebro y su estado de validación. **Cero datos personales.** `money_authorized=false` en todas las filas. Misma clase de dato público que `v_futpro_publication_v3`. |

## Antes y después, leído como lo lee la app

| lectura | antes | después |
|---|---|---|
| `anon` → `v_reto13m_daily_best_by_sport_v1` | **ERROR 42501** | **2** |
| `anon` → `v_reto13m_lo_mejor` | ERROR 42501 | **6** |
| `anon` → `v_reto13m_mejores` | ERROR 42501 | **6** |
| `anon` → `v_reto13m_daily` | ERROR 42501 | **6** |
| `anon` → `v_reto13m_global_top_v2` (interno) | ERROR 42501 | **sigue cerrado** ✓ |
| `authenticated` → top pick | ERROR 42501 | **«Gana Atlanta Braves»** |
| filas con dinero autorizado | 0 | **0** |

## Corrección a mí mismo

Escribí que sospechaba un rótulo de día equivocado y estuve a punto de pedirle al
dueño que gastara créditos de Lovable en arreglarlo. **No existía.** Le dije que
mirara antes de pagar, y por eso no se gastó nada en una corazonada mía.

Dato adicional que trajo la captura y que no estaba en `model_learning_gate`: la
tarjeta muestra la evidencia sellada del modelo de NFL contra el mercado —
*"Le gana a un volado (Brier 0.22986 vs 0.25000, n=143) pero NO al mercado
(0.22702 vs 0.21822, t pareada −1.135)"*. Yo había reportado que NFL no tenía
referencia de mercado; eso era cierto **del gate**, pero el modelo sí trae su
propia comparación sellada. Refuerza la conclusión: el dinero sigue apagado con
razón.

## Rollback

```sql
revoke select on public.v_reto13m_daily_best_by_sport_v1 from anon, authenticated;
revoke select on public.v_reto13m_lo_mejor               from anon, authenticated;
revoke select on public.v_reto13m_mejores                from anon, authenticated;
revoke select on public.v_reto13m_daily                  from anon, authenticated;
```

Ninguna fila tocada. Solo permisos de lectura.
