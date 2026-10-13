# ISS292 — Auditoría de cada pantalla, dos hallazgos reales y tres errores míos

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

El dueño pidió: *"dejalas perfectas, todo. es importantisisismo CADA UNA DE LAS
PANTALLAS!"*. El frontend es de Lovable, así que lo que me toca es **cada
superficie de backend que una pantalla lee**. Eso es lo que medí.

---

## 1. El mapa, construido desde la base y no desde un documento

`docs/BACKEND_SURFACE_USADA.md` no existe en este repo (vivía en el proyecto de
Lovable), así que no lo supuse: lo levanté del catálogo. **462 tablas/vistas y
914 funciones** son legibles por `anon` o `authenticated`. De ahí salen **15
vistas que son realmente de producto**, y esas son las que medí una por una.

## 2. Medido como `anon`

Todas sirvieron filas menos dos. Las dos excepciones **no eran defectos**:

| superficie | como `anon` | veredicto |
|---|---|---|
| `v_picks_usuario_historial` | `permission denied for table picks` | **correcto** |
| `v_mejores_picks_mlb` | 0 filas | **correcto y degradado** (§4) |

### El error que casi cometo

`v_picks_usuario_historial` es `security_invoker=true` sobre `select ... from
picks` **sin filtro por usuario**. La "reparación" obvia —ponerle
`security_invoker=false`— le habría entregado a `anon` **el historial de apuestas
de todos los usuarios**: exactamente la fuga de ISS269.

Leí `picks` antes de tocar nada:

```
RLS habilitado. Política "Auth users own picks", rol authenticated:
  lower(btrim(apodo)) = lower(btrim(apodo_de_la_sesion()))
anon_select = false
```

**La negación a `anon` es el comportamiento correcto.** El error era mi prueba:
medí una pantalla por usuario sin sesión de usuario.

## 3. Medido como `authenticated`, y el segundo error

Volví a medir con una sesión real. Primero con `usuarios.id` → `apodo_de_la_sesion()`
devolvió NULL y 0 filas. **`usuarios.id` no es `usuarios.user_id`**:
`apodo_de_la_sesion()` une por `user_id = auth.uid()`. Con el `user_id` correcto
(`0c631a09-03db-4cc1-8140-eb1e7a4363a7`):

```
apodo_de_la_sesion() = rodelcast
v_picks_usuario_historial        = 20     <- sus 20, no los 43 de todos
v_reto13m_daily_best_by_sport_v1 = 1      v_reto13m_lo_mejor      = 3
v_reto13m_mejores                = 3      v_reto13m_daily         = 3
v_futpro_publication_v3          = 244    v_mlb_publication_v1    = 4
v_nfl_publication_v1             = 28     v_evidencia_mercado_soccer = 3
v_favorito_mlb                   = 11     v_favorito_nfl          = 572
v_mejores_picks_mlb              = 0      v_picks_futbol_calibrado = 654
v_picks_medibles                 = 3705   v_picks_nfl_modelo      = 56
```

**El RLS filtra exactamente como debe**: 20 picks propios de 43 totales. El
mecanismo está bien; los dos ceros que vi antes eran mis pruebas mal hechas.

## 4. Hallazgo real #1 — `v_mejores_picks_mlb = 0` está BIEN

La cadena: `v_mejores_picks_mlb` ← `v_picks_mlb_modelo` ← `v_mlb_publication_v1`,
cuyas 4 filas son todas `DATA_UNAVAILABLE` con equipos **"TBD @ TBD"**.

La agenda de MLB tiene 11 partidos y los equipos **sí** aparecen más adelante:

```
Oct 14-17  TBD @ TBD                                 <- la ventana de publicacion
Oct 18     Tampa Bay Rays      @ CLE/CHW             <- ALCS, un lado sin resolver
Oct 19     Los Angeles Dodgers @ Milwaukee Brewers   <- NLCS, resuelto
Oct 21     Cleveland Guardians @ Tampa Bay Rays
```

`v_mlb_publication_v1` solo admite `dia_offset` 0..2, y **justo esos cuatro slots
son los que ESPN publica sin equipos**, porque las series divisionales no han
terminado. El modelo responde `DATA_UNAVAILABLE` y la cadena de picks emite cero.

**Es la respuesta correcta a un partido entre equipos que todavía no existen.**

Y lo que **no** hice: los nombres del 18 y 19 permiten adivinar quién juega el 14.
Eso es la sustitución de identidad que tengo prohibida — si se acierta mal, el
producto publica el análisis del equipo equivocado. ESPN los resuelve solo
conforme avanzan las series (`actualizado_at` = hoy, el cron corre).

### Lo que sí es defecto, y ahora se vigila

Que un partido siga sin equipos **después del saque**. Ahí ya no es degradación
honesta: es un partido fantasma en la pantalla.

`public.gate_partido_sin_equipos_identificados()` (**G50.11**), con alcance
`v2.deporte_del_producto`:

- algún TBD con saque ya pasado → **FAIL**, lo nombra
- TBD con saque en el futuro → **INFO** (estado normal de playoffs)
- ninguno → **PASS**

Hoy: `INFO (6)`. Los seis son de MLB con saque futuro. **Ni NFL ni fútbol tienen
un solo partido sin equipos.**

## 5. Hallazgo real #2 — un usuario con TODAS sus pantallas vacías

`public.usuarios` tiene 6 filas. Cinco con `user_id`, una sin:

```
rongo   user_id = NULL   y tiene 6 picks suyos
```

`apodo_de_la_sesion()` resuelve `select apodo from usuarios where user_id = auth.uid()`.
Con `user_id` NULL devuelve NULL, y **toda** política RLS que compara
`lower(btrim(apodo)) = lower(btrim(apodo_de_la_sesion()))` se vuelve falsa. Ese
usuario inicia sesión bien y ve **cero** en su historial, sus patrones, sus
parlays y su fantasy, **teniendo datos**.

**No le puse el `user_id` a mano.** Adivinar a qué cuenta de auth corresponde un
apodo es sustitución de identidad: si se acierta mal, se le entrega a alguien el
historial de apuestas de otro. Eso lo decide el dueño con evidencia (el correo
del usuario), no yo con una corazonada.

`public.gate_usuario_sin_enlace_de_sesion()` (**G50.10**): FAIL si un usuario sin
`user_id` tiene picks, INFO si no tiene, PASS si todos están enlazados.

Hoy: `FAIL (1) — rongo (6 picks propios, veria todo vacio)`.

## 6. El panel de guardias, en una sola llamada

Había **63 funciones `public.gate_*()`** sin argumentos y con firmas distintas, así
que `UNION ALL` falla por número de columnas y revisarlas significaba ~10
consultas a mano. Era fácil olvidar una, y un guardia que nadie corre es igual
que no tenerlo.

`public.panel_de_guardias()` las descubre por catálogo y las ejecuta todas, así
que **un guardia nuevo entra al panel sin tocar nada**. Lee el veredicto por
nombre (`estado` / `status` / `veredicto`); si una función no expone ninguno lo
reporta como `(no expone estado)` en vez de omitirla, y si revienta reporta
`ERROR` con el mensaje en vez de tragárselo para que el panel se vea limpio.

### Tercer error mío: dije que los guardias eran lentos

El panel completo expiró a los 60s y afirmé *"los guardias son lentos de verdad"*.
**Estaba equivocado.** Medidos por tramos:

```
guardias  1-4    7.5s   (btts_no_monetizable sola: 6.6s)
guardias  5-12   7.6s
guardias 13-16   2.0s
```

17 segundos para 16. Lo que había era un `refresh materialized view concurrently`
compitiendo por IO. Leí un síntoma y lo llamé causa, otra vez.

## 7. Límites de lo comprobado

- **El frontend sigue NO PROBADO.** La salida de red a la vista previa de Lovable
  y a `wpiztubmmmzclhlprgpd.supabase.co:443` está bloqueada por política de la
  organización. Medí las superficies que las pantallas leen, con los roles que
  las leen. **No vi una sola pantalla renderizada**, y no lo declaro como
  probado.
- Las **447 superficies restantes** legibles por `anon`/`authenticated` y las
  **914 funciones públicas** no están auditadas. Lo auditado son las 15 de
  producto.
- `rongo` queda **declarado, no arreglado**, a propósito.

## Rollback

```sql
drop function if exists public.gate_usuario_sin_enlace_de_sesion();
drop function if exists public.gate_partido_sin_equipos_identificados();
drop function if exists public.panel_de_guardias();
```

No toca datos, ni modelos, ni el gate de dinero, ni un solo pick. Los tres son
solo lectura.
