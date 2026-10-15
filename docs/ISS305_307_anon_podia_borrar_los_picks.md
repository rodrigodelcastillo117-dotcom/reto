# ISS305-307 — `anon` podía borrar los picks publicados y reescribir el accuracy

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-15**

La primera foto completa del panel (ISS299) sirvió para algo el mismo día que se
construyó: **encontró una exposición que no existía hace dos días, y un defecto
que yo había introducido media hora antes.**

---

## 1. Lo grave: la llave pública tenía permiso de escritura

`gate_superficie_cruda` reportó superficies crudas nuevas. Al mirar los
privilegios, el hallazgo fue más amplio que lo que el guardia señalaba. **Siete
tablas de `public` con RLS DESACTIVADO y escritura para `anon`:**

```
grantee anon  y  grantee authenticated, identico en las tres primeras:
  DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE

reto_pick_snapshot_v1      600 filas   deporte, espn_event_id, mercado, partido,
                                       pick_titulo, pick_lado, prob_pct, linea,
                                       kickoff, capturado_at
reto_modelo_validacion_v1              deporte, mercado, muestra_oos,
                                       accuracy_pct, brier, metodo, actualizado
reto_clv_cache_v1                      deporte, picks_con_cierre,
                                       con_ambos_precios, drift_promedio_pp,
                                       pct_clv_positivo, desde, hasta
nba_rating_prod             53 filas   DELETE, INSERT, TRUNCATE, UPDATE
tmp_nba_res / tmp_tenis_surf / tmp_tenis_val
```

**`anon` es la llave publicable que viaja en el bundle del frontend.** Cualquiera
que abriera la app podía leerla y:

- `TRUNCATE reto_pick_snapshot_v1` → **borrar los picks publicados**
- `INSERT reto_pick_snapshot_v1` → **publicar un pick inventado**
- `UPDATE reto_modelo_validacion_v1` → **escribir "accuracy_pct 95, brier 0.05"**
  y la app lo presume como evidencia del modelo

La tercera es la peor en espíritu: `reto_modelo_validacion_v1` es una **superficie
de confianza**, los números con los que el producto se defiende. Dejarlos
escribibles desde el cliente es peor que no tenerlos.

Ninguna de estas tablas existía cuando audité las superficies el 13 de octubre.

### Lo que hice, y lo que deliberadamente no

**Revoqué solo la escritura.** La lectura (`SELECT`) se conserva intacta **a
propósito**: el frontend las usa y **no puedo probar el frontend** (la red a la
vista previa de Lovable está bloqueada por política de la organización). Quitar
la lectura podría vaciar una pantalla; quitar la escritura no puede romper una
lectura.

No se borró ni una fila. No se borró ningún objeto, ni las tres `tmp_*` que son
restos de trabajo. Todo reversible con un `grant`.

### Después: RLS, comprobando primero que no rompo el refresco

Habilitar RLS sin política **bloquea las lecturas**, así que primero medí quién
escribe:

```
public.refresh_reto_clv_cache_v1()  SECURITY DEFINER, dueño postgres
  <- cron reto-clv-cache-refresh [23 */6 * * *]
public.reto_snapshot_capturar_v1()  dueño postgres
  <- cron reto-snapshot-picks [7 * * * *]

puede el cliente llamarlas?   anon EXECUTE=false, authenticated EXECUTE=false
dueño de las tablas: postgres   relforcerowsecurity = false
```

Los escritores corren como el dueño de la tabla, que con
`relforcerowsecurity = false` **no pasa por RLS**. Habilitar RLS no los toca.

Y para la política, el mismo razonamiento medido que el precedente
`oraculo_prob_picks`: **cero** de sus columnas casan con
`apodo|user|usuario|email|auth_id|owner` en las tres. Sin columna de dueño no
existe predicado de dueño que escribir, y escribir uno falso sería peor que
declararlo. Así que RLS + política **solo de SELECT** + declaración explícita en
`v2.lectura_global_declarada`.

**No se creó política de escritura.** Si alguien quiere que el cliente escriba
estas tablas, tendrá que escribirla a propósito, y eso se verá.

### Verificado después

```
anon:  lee = true  |  inserta / actualiza / borra / trunca = FALSE   en las 4
anon leyendo de verdad:  640 / 3 / 1 filas       <- lecturas intactas
SUPERFICIE_CRUDA_SIN_RLS         FAIL(2) -> PASS(0)
RLS_PERMISIVA_QUE_NO_RESTRINGE   PASS, con las tres declaradas
```

## 2. El hueco de detector, que es lo que de verdad había que arreglar

`gate_superficie_cruda` atrapó **dos** de las siete — las que además eran "crudas"
por otros criterios — y se le fueron `nba_rating_prod` y las tres `tmp_*`.
**Ningún guardia hacía la pregunta directa: ¿puede el cliente ESCRIBIR esta
tabla?**

`public.gate_cliente_no_escribe_sin_rls()` (**G50.13**).

### Por qué no necesita lista blanca

Medido: **186 tablas** de `public`/`v2` aceptan escritura del cliente — `picks`,
`usuarios`, `parlays`, `fantasy_roster_semanal`, `agenda_espn`… — porque la app
legítimamente escribe en ellas. **Las 186 tienen RLS activo.**

Así que el invariante limpio no es *"nadie escribe"* sino **"quien escribe pasa
por RLS"**, y hoy se cumple sin excepciones. Un guardia con lista blanca invita a
que la lista crezca; este no tiene dónde esconder nada.

```
G50.13  PASS(0)  'Ninguna. 186 tablas aceptan escritura del cliente
                  y TODAS pasan por RLS.'
```

RLS activo no basta por sí solo —una política permisiva sobre escritura seguiría
abierta— pero eso ya lo cubre `RLS_PERMISIVA_QUE_NO_RESTRINGE`. G50.13 cubre el
hueco anterior: que no haya **ni** política.

## 3. Un defecto mío, encontrado por el panel que acababa de construir

```
gate_rls_no_se_esquiva / SECURITY_DEFINER_SIN_SEARCH_PATH  FAIL(1)
  public.gate_fantasy_ve_la_temporada_en_curso()
```

Esa es **la función que yo reescribí en ISS303, media hora antes.** La declaré
`security definer` **sin** `set search_path`, y además la cambié de `STABLE` a
`VOLATILE` sin motivo.

Un `SECURITY DEFINER` sin `search_path` fijo se puede secuestrar: basta que
alguien con permiso de crear objetos ponga una tabla o función con el nombre que
la función resuelve sin calificar, más arriba en el `search_path` de quien la
llama, y ese código corre con los privilegios del dueño de la función.

Verificado en el catálogo antes de corregir: `prosecdef = true`,
`proconfig = null`, `provolatile = 'v'`. Corregido a `STABLE` +
`SECURITY DEFINER` + `set search_path` explícito. → **PASS(0)**.

**Vale la pena decir por qué esto cuenta:** el panel lo encontró solo, treinta
minutos después de que yo lo introdujera, sin que yo lo buscara. Para eso existe.

## 4. Lo que NO firmé

Quedan dos renglones en `gate_superficie_cruda`:

```
SUPERFICIE_CRUDA_SIN_DECLARAR      FAIL(14)
SUPERFICIE_CRUDA_SIN_TEMPORALIDAD  FAIL(14)
  reto_clv_cache_v1, reto_pick_snapshot_v1, v_reto_calibration_curve_v1,
  v_reto_clv_v1, v_reto_mejores_picks_v1, v_reto_nba_mercados_v1,
  v_reto_nfl_mercados_v1, ...
```

Es una familia de ~50 objetos `reto_*` / `v_reto_*` construida en los últimos dos
días. `SIN_TEMPORALIDAD` significa que exponen filas **sin un corte previo al
saque**, o sea que pueden ser superficie de fuga hacia el cliente.

**No las declaro.** Declarar 14 superficies que no construí y cuyo diseño temporal
no he verificado sería silenciar una señal real para que un rojo se ponga verde.
Cada una necesita un veredicto, y la lista está arriba.

Lo que sí cerré de ese grupo es lo que no admite discusión: que `anon` pudiera
escribirlas.

## Rollback

```sql
-- ISS306: devolver la escritura al cliente (NO se recomienda)
grant insert, update, delete, truncate on public.reto_pick_snapshot_v1     to anon, authenticated;
grant insert, update, delete, truncate on public.reto_modelo_validacion_v1 to anon, authenticated;
grant insert, update, delete, truncate on public.reto_clv_cache_v1         to anon, authenticated;
grant insert, update, delete, truncate on public.nba_rating_prod           to anon, authenticated;
grant insert, update, delete, truncate on public.tmp_nba_res               to anon, authenticated;
grant insert, update, delete, truncate on public.tmp_tenis_surf            to anon, authenticated;
grant insert, update, delete, truncate on public.tmp_tenis_val             to anon, authenticated;

-- ISS307b: quitar RLS (NO se recomienda)
alter table public.reto_pick_snapshot_v1     disable row level security;
alter table public.reto_modelo_validacion_v1 disable row level security;
alter table public.reto_clv_cache_v1         disable row level security;
delete from v2.lectura_global_declarada
 where relacion in ('reto_pick_snapshot_v1','reto_modelo_validacion_v1','reto_clv_cache_v1');

-- ISS307
drop function if exists public.gate_cliente_no_escribe_sin_rls();
```

No se borró un dato, no se borró un objeto, no se tocó un modelo, no se movió un
pick, no se encendió dinero. Las lecturas de `anon` quedaron verificadas
funcionando después del cambio.
