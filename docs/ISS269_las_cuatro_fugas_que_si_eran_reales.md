# ISS269 — Las cuatro fugas que si eran reales

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

---

## Antes de nada: mi cuarto falso positivo de la misma familia

Empece este trabajo con una consulta que buscaba politicas con `USING (true)` y
me devolvio **decenas** de tablas. Una de ellas, `ajustes_cuenta`, parecia grave:
politica `ALL`, `USING(true)`, rol `authenticated`. Si eso fuera permisiva,
cualquier usuario podria leer, modificar y **borrar** los movimientos de cuenta
de otro.

Lo probe en vez de reportarlo:

```
A1 leer_ajustes_de_otro      = 0 filas
A2 modificar_monto_de_otro   = 0 filas afectadas
A3 borrar_ajustes_de_otro    = 0 filas borradas
A4 insertar_a_nombre_de_otro = BLOQUEADO (42501)
```

**Estaba equivocado.** `ajustes_apodo_coherente` es **RESTRICTIVA**, no
permisiva. Una politica restrictiva con `USING(true)` no restringe nada — se
combina con AND y `true` es el elemento neutro. Existe solo para imponer la
coherencia del apodo en su `WITH CHECK`. El control real lo hace
`Users see own ajustes`, correctamente atada a `auth.uid()`. La tabla estaba
bien.

Mi consulta no leia `polpermissive`. Es el **cuarto** falso positivo de esta
sesion con la misma causa raiz: **leer el texto de una politica en vez de medir
el comportamiento**. Los otros tres fueron `pa_audit_log`,
`respaldo_borrado_usuarios` y `usuarios_archivados`. La leccion ya no es nueva:
un GRANT o un `USING` no dicen quien puede leer qué; solo lo dice ejecutar la
consulta con el rol puesto.

## Lo que si era real

De la lista larga, cuatro tablas guardan datos de apuesta **por persona**,
identificada por la columna `apodo`, con politica de SELECT permisiva y
`USING(true)`. Ya estaban diagnosticadas en ISS250 y se habian dejado abiertas
por una razon honesta: cerrarlas a ciegas podia dejar una pantalla en blanco.

Medido como `anon`, con el rol puesto:

| tabla | filas que leia `anon` | que contiene |
|---|---|---|
| `user_patterns` | **33** | apodo, win_rate, roi, **net_pnl**, insight |
| `ai_generated_parlays` | **58** | parlays generados por IA, por apodo |
| `parlay_builder_log` | **71** | log de construccion, por apodo |
| `fantasy_start_sit` | 0 (politica solo `authenticated`) | consejo start/sit, por apodo |

Y un usuario autenticado (`el dos`) veia **las 33 filas de `user_patterns`
teniendo solo 11 propias**: 22 filas de las perdidas de otras personas.

### Por que esta es la peor que he encontrado en la sesion

No es un numero abstracto. Esto es lo que devolvia la tabla, ordenado por
dinero, a cualquiera con la llave publicable:

```
rongo      parlays_negativos   0/14 (0% WR, ROI -100.0%, $-6613)   alerta
rodelcast  liga_problematica   MLB: solo 2/8 (25% WR). Perdido $5258.
```

`rodelcast` es el apodo del dueño. Cualquiera en internet podia leer el apodo de
cada persona junto con **en que liga pierde dinero y cuanto**. No hay
contraseñas ni tarjetas, pero es historial de apuestas nominal — exactamente el
dato que nadie quiere publicado.

## El cierre

Una sola forma para las cuatro, porque las cuatro tienen la misma columna de
propiedad (`apodo`):

```sql
alter policy <politica> on <tabla>
  using (lower(btrim(apodo)) = lower(btrim(public.apodo_de_la_sesion())));
```

`public.apodo_de_la_sesion()` ya existia (STABLE, SECURITY DEFINER, resuelve
`usuarios.apodo` desde `auth.uid()`). Para `anon` devuelve NULL, y la comparacion
con NULL no es TRUE, asi que `anon` queda en cero **sin necesitar una regla
aparte**. No invente nada.

## Por que no rompe la app — verificado, no supuesto

La regla que me diste es no declarar el frontend intacto sin probarlo, y la
prueba visual sigue bloqueada por el login. Asi que la probe por donde si podia,
en tres capas:

1. **El frontend no lee ninguna de las 4.**
   `docs/BACKEND_SURFACE_USADA.md` del proyecto Lovable esta generado por grep
   sobre `src/` y lista tabla por tabla lo que la app consulta. Ninguna de las
   cuatro aparece.
2. **Quien si las lee, las lee por encima del RLS.**
   Las RPC publicas (`mis_patrones`, `devils_advocate`, `devils_advocate_parlay`,
   `diario_patrones`, `fantasy_reporte_semana`, `fantasy_week_hub_v3`) son
   **SECURITY DEFINER** y pasan por `apodo_scope()`. Las edge functions usan
   `service_role`. Ambos ignoran el RLS del que llama.
3. **Simulacro dentro de `BEGIN`/`ROLLBACK` antes de aplicar nada.**
   Aplique las 4 politicas, medi, y lo deshice. `mis_patrones()` devolvio una
   carga **identica de 924 bytes** antes y despues.

`MisLeaks.tsx` — la pantalla que muestra estos datos — llama a `fetchMisLeaks()`,
que es una edge function, no una consulta a la tabla. Por eso el cambio le es
invisible.

## Antes y despues, en el servidor real

Medido tras aplicar, con el rol puesto en cada caso:

| prueba | antes | despues |
|---|---|---|
| `anon` lee `user_patterns` | 33 | **0** |
| `anon` lee `ai_generated_parlays` | 58 | **0** |
| `anon` lee `parlay_builder_log` | 71 | **0** |
| `anon` lee `fantasy_start_sit` | 0 | **0** |
| autenticado ve filas **ajenas** | 22 | **0** |
| autenticado ve las **propias** | 11 | **11** |
| RPC `mis_patrones()` | 924 bytes | **924 bytes** |
| `service_role` (cron, edge) | 33 | **33** |

Las dos ultimas filas son las que importan para no haber roto nada: la pantalla
recibe lo mismo y los procesos de fondo siguen viendo todo.

## Limites de lo comprobado

- **No probe la pantalla real.** Sigue bloqueada por el login. Lo que probe es la
  RPC que la alimenta y la superficie que el frontend declara leer. Si existiera
  una lectura directa a estas 4 tablas fuera de `src/` —por ejemplo añadida
  despues del 2026-09-18, fecha del documento de superficie— no la habria visto.
  Declaro esa ruta **NO PROBADA**, no PASS.
- No toque `amigos` ni `ai_memory`. `amigos` tiene `USING(true)` para
  `authenticated` y `anon`, y su semantica es una relacion entre dos personas:
  cerrarla por `apodo` no es correcto sin decidir primero si ver a los amigos de
  otro es o no parte del producto. Queda declarada, no arreglada.

## Rollback

`shadow-patches/iss269/rollback_cuatro_fugas_de_lectura.sql` — devuelve las
cuatro a `USING(true)`. El archivo lleva escrito, en numeros medidos, exactamente
que reabre.

No se borro ni una fila. El cambio es de politica de lectura, reversible con una
sentencia por tabla.
