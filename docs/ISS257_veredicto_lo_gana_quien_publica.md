# ISS257 — La insignia "Validado" la estaba ganando un modelo que no publica

Proyecto Lovable: **«Remix of Reto 13M»** `d243f279-2db6-4f18-a269-029cf284267f`
Supabase: **`wpiztubmmmzclhlprgpd`** (unico autorizado)
Fecha de la medicion: **2026-09-19**

---

## 1. PRIORIDAD 1 — Autorizaciones de Supabase: PROBADO

### Causa comprobada de los avisos

No habia ninguna politica externa. Faltaban dos cosas, y ninguna se arregla escribiendo
`settings.json` y declarandolo resuelto:

1. **El nombre real del servidor MCP es `Supabase` con S mayuscula.** Una regla
   `mcp__supabase__execute_sql` no autoriza `mcp__Supabase__execute_sql`. En
   `.claude/settings.local.json` quedan las 15 herramientas en **las dos**
   capitalizaciones (30 entradas).
2. **Una regla de permiso de una herramienta MCP no limita sus parametros.**
   `mcp__Supabase__execute_sql` autorizado vale para *cualquier* `project_id`. Por eso
   la guarda es un hook `PreToolUse`, no un permiso.

Quedaron **deliberadamente fuera** del allowlist, siguen pidiendo autorizacion:
`create_project`, `pause_project`, `restore_project`, `delete_branch`, `merge_branch`,
`reset_branch`.

### Prueba de que la configuracion esta CARGADA (no solo escrita)

La guarda escribe su propia bitacora en cada invocacion. Esa bitacora es el instrumento
objetivo: si crece cuando llamo a Supabase, el hook esta vivo.

```
2026-09-19T16:17:45Z  mcp__Supabase__execute_sql  project_id=wpiztubmmmzclhlprgpd
2026-09-19T16:17:58Z  mcp__Supabase__execute_sql  project_id=wpiztubmmmzclhlprgpd   <- dos seguidas, sin aviso
2026-09-19T16:19:08Z  mcp__Supabase__execute_sql  project_id=aaaaaaaaaaaaaaaaaaaa   <- BLOQUEADA
2026-09-19T16:19:29Z  mcp__Supabase__execute_sql  project_id=wpiztubmmmzclhlprgpd
2026-09-19T16:21:26Z  mcp__Supabase__execute_sql  project_id=wpiztubmmmzclhlprgpd
```

- **Dos llamadas consecutivas al proyecto autorizado, sin aviso:** 16:17:45 y 16:17:58.
- **Bloqueo de otro project_id:** la llamada con `aaaaaaaaaaaaaaaaaaaa` devolvio
  `PreToolUse:mcp__Supabase__execute_sql hook error` y no llego a la base.
- **No hay politica externa que obligue a preguntar:** no existe `managed-settings.json`
  en ninguna de las 4 rutas, no hay `~/.claude/settings.json`, y no hay variable de
  entorno forzando permisos.

### Correccion de portabilidad (este commit)

`.claude/settings.json` apuntaba a la ruta absoluta `/home/user/reto/.claude/hooks/...`.
En un contenedor con otro directorio de trabajo el hook no existiria y la guarda se
caeria en silencio — que es el peor modo de fallo posible para una guarda. Ahora:

```json
"command": "bash \"${CLAUDE_PROJECT_DIR:-/home/user/reto}/.claude/hooks/supabase-project-guard.sh\""
```

**Correccion honesta de algo que dije antes:** afirme que dos llamadas habian pasado sin
aviso cuando en realidad el usuario las estaba aprobando y yo no podia distinguir una
cosa de la otra. Por eso la bitacora existe: para no volver a depender de mi impresion.

---

## 2. PRIORIDAD 2 — El contrato de mercados de FUT Pro

### 2.1 GG es BTTS. Over/Under es otra cosa. Medido por separado.

| Superficie | Moneyline / 1X2 | BTTS (GG) | Over/Under |
|---|---|---|---|
| `v_futpro_publication_v3` (API, anon) | `canonical_market` = Moneyline en **121/121** | `btts_yes` no nulo en **121** | `p_over`/`p_under` no nulos en **116** |
| `v_tarjeta_soccer_v1` (API, anon) | `ganador_pct` en **102/102** | `btts_si_pct` en **102** | `over_pct`, `under_pct`, `over25_norm_pct` **NULL en 102/102** |
| Tarjeta FUT Pro (lista) | "RETO predice" | celda "Ambos anotan" | **no se pinta** |
| Detalle del partido | hero canonico | bajo acordeon, rotulado diagnostico | solo "Linea de la casa … referencia factual, sin probabilidad publicada" |

**Over/Under esta retirado de verdad en la tarjeta**, no escondido: la vista entrega NULL.
En `v_futpro_publication_v3` si viajan `p_over`/`p_under` (116 filas) — **PENDIENTE**, ver §4.

### 2.2 `mejor_pick`: viaja por la API, no lo pinta nadie

Medido en la API: `mejor_pick` **no es un mercado 1X2 en 102 de 121 filas** (36 "Ambos
anotan", 2 "No ambos anotan", 64 variantes de O/U) y `mejor_pick_prob > canonical_pick_prob`
en **101 de 121**. Es decir: si alguna pantalla lo pintara, mostraria un mercado no canonico
con un numero mas alto que el pick oficial.

**Ninguna pantalla lo pinta.** Leidos a HEAD (`3a7bbf1`) del Remix:
`FutV2.tsx`, `MatchCardV2.tsx`, `MatchSheetV2.tsx` — los tres deciden con
`mejorMercadoV2(row)` de `canonicalPick.ts`, que lee **solo**
`canonical_pick` / `canonical_pick_prob` / `canonical_market` / `canonical_line`.
`legacy_mejor_pick_is_authoritative` = false en 121/121.

`canonicalPick.ts` ademas retira O/U con fail-closed propio (`esTotalRetirado()`), y el
universo canonico es `{1x2:home, 1x2:draw, 1x2:away, btts:yes}`.

### 2.3 Un falso positivo mio, declarado

Busque filas con `canonical_pick` incoherente usando ILIKE `%under%` y me salio 1.
**Era mi patron, no un defecto:** Seattle So**under**s FC. La fila es
`canonical_market` = Moneyline, `canonical_pick` = "Gana Seattle Sounders FC", 53.5%.
**No hay ninguna fila con `canonical_pick` incoherente.**

---

## 3. EL DEFECTO REAL QUE SI ENCONTRE — y su arreglo

### Lo que veia el usuario

En **102 de 102** tarjetas de futbol, el mercado `ganador` mostraba veredicto
`MEJOR_QUE_ADIVINAR_CONCLUYENTE`, que el frontend pinta como **insignia VERDE
"Validado con resultados reales"** (`TEXTO_INSIGNIA[VEREDICTO_MEJOR]` en
`src/v2/components/soccer/EvidenciaMercadoSoccer.tsx`).

### Lo que decian los numeros

```
1X2  crossleague_v1       n=198  IC95 [-0.0877, -0.0084]  -> concluyente
1X2  soccer_canonical_v2  n= 66  IC95 [-0.1189, +0.0194]  -> CRUZA EL CERO
```

`crossleague_v1` es el **prior**. `soccer_canonical_v2` es, en palabras de la propia
vista, **"el que publica hoy"**. La insignia "Validado" la ganaba el prior.

### Por que es un defecto y no una decision de diseno

La regla contraria ya estaba escrita **en esta misma base**, en la funcion hermana
`public.fn_evidencia_mercado`, que degrada la evidencia del predecesor a
`veredicto_de_la_anterior` con la advertencia literal:

> "Esto NO es el veredicto de la version que estas viendo. La evidencia no se hereda"

y en el frontend, en `LinajeEvidenciaVista`: *"la evidencia no se hereda… el veredicto
grande sigue siendo el de la version actual"*.

`v_evidencia_mercado_soccer` era **la unica ruta que heredaba**. Su `CASE` del veredicto
leia solo `p` (el prior); `c` (el que publica) se calculaba, se exponia en
`evidencia_publicado` y despues se ignoraba.

### El arreglo (fail-closed, solo aprieta)

`shadow-patches/iss257/iss257_veredicto_lo_gana_quien_publica.sql`

- "Validado" exige ahora que el IC95 del **modelo que publica** quede entero por debajo
  de cero. Sin numeros propios: sin veredicto. No se hereda.
- `PEOR_QUE_ADIVINAR_CONCLUYENTE` se mantiene si **cualquiera** de los dos sale
  concluyentemente peor: la advertencia mas fuerte siempre manda.
- `total` no se toca: sigue RETIRADO con su texto propio.

### Antes / despues, medido

| | antes | despues |
|---|---|---|
| `ganador` = MEJOR_QUE_ADIVINAR_CONCLUYENTE | **102** | **0** |
| `ganador` = SIN_VEREDICTO_MUESTRA_INSUFICIENTE | 0 | **102** |
| `btts` = SIN_VEREDICTO | 102 | 102 (sin cambio) |
| `total` = SIN_VEREDICTO_CEREBRO_NUEVO | 102 | 102 (sin cambio) |
| **filas servidas** | **102** | **102** |
| **`ganador_pick` no nulo** | **102** | **102** |
| `ganador_pct` no nulo | 102 | 102 |
| `btts_si_pct` no nulo | 102 | 102 |
| `over_pct` no nulo | 0 | 0 |

**No se apago ningun pick, no se cerro ningun deporte, no se redujo cobertura.** Lo unico
que cambio es lo que la tarjeta **afirma sobre su propia evidencia**. Comprobado antes de
aplicar: el unico consumidor de la vista es `v_tarjeta_soccer_v1_calculo`, que la pasa a
la pantalla; **ningun gate de publicacion ni de dinero lee `veredicto`**.

Nota justa para el modelo: `soccer_canonical_v2` no es peor. Su diff en 1X2 (−0.0497) es
**mejor** que el del prior (−0.0481). Solo lleva 66 partidos, asi que su intervalo todavia
es ancho. No esta desaprobado: esta **sin probar todavia**, que es distinto.

> ⚠️ **CORRECCION (19:15:46 UTC del mismo dia).** Este parrafo ya no se sostiene. Con
> 77 partidos el que publica va en diff −0.0259 y el prior en −0.0386: **ahora el
> prior es el mejor de los dos**, y el Brier de `soccer_canonical_v2` EMPEORO al
> crecer la muestra (0.6169 -> 0.6408 de 66 a 77 partidos). No lo maquillo: el
> modelo no mejoro, se le noto mas. Lo unico que sigue siendo cierto es que **no
> esta probado**, y por eso el arreglo de ISS257 sigue siendo el correcto.

### Gates despues del cambio

```
G40.2_cada_mercado_nombra_al_modelo_que_lo_calcula   PASS  0
G40.3_el_marcador_no_contradice_al_pick              PASS  0
G40.4_el_margen_no_contradice_al_pick                PASS  0
G37.1_la_tarjeta_publica_no_esta_vacia               PASS  102
G37.2_la_cache_no_esta_rancia                        PASS  refresco hace 0 min
G37.3_el_calculo_y_lo_servido_coinciden              PASS  102 contra 102
G40.1_el_over_sale_de_los_goles_que_muestra          INFO  0 de 0 (O/U retirado)
```

### Rollback exacto

```
psql < shadow-patches/iss257/rollback_v_evidencia_mercado_soccer.sql
select public.refrescar_tarjeta_soccer_cache();
```

Restaura la definicion capturada con `pg_get_viewdef(...,true)` antes del parche. No se
borro ningun objeto: `create or replace view` conserva columnas, orden, tipos y grants.

### Trampa que casi me come (y que vale registrar)

Despues de aplicar el parche, `v_evidencia_mercado_soccer` ya decia SIN_VEREDICTO pero
`v_tarjeta_soccer_v1` **seguia diciendo 102 validados**. `v_tarjeta_soccer_v1` no es la
vista viva: es un passthrough sobre la tabla `tarjeta_soccer_cache`, que refresca el cron
538 cada 3 minutos. Si hubiera declarado PASS al ver la vista base, habria declarado un
arreglo que el usuario todavia no veia.

---

## 4. PRIORIDAD 5 — Por que no hay picks publicables

### El bloqueo es uno solo, y es el mismo para todos

`v_pick_canonico`: **399 de 399 filas** tienen `es_pick = false` con **un unico** motivo,
`SIN_CALIBRATION_VERSION`. No hay un segundo motivo. No es la puerta de Brier.

La cadena es: `v_pick_canonico` -> `elegibilidad_no_economica_v1(...)` ->
`calibracion_de_pick(fuente, deporte, mercado)` -> `motor_modelo_mapa.calibration_version`.

Esa columna esta **NULL en las 4 filas del mapa**:

| fuente | deporte | mercado | model_version | calibration_version |
|---|---|---|---|---|
| motor_mlb_cuantitativo | baseball | Moneyline | mlb_one_brain_v2 | **NULL** |
| motor_mlb_cuantitativo | baseball | Over/Under | mlb_one_brain_v2 | **NULL** |
| motor_nfl_hibrido | football | Moneyline | nfl_hybrid_ml_v1 | **NULL** |
| motor_futbol_calibrado | soccer | Moneyline | soccer_canonical_v2 | **NULL** |

### Y **NO** es un cable suelto

La tentacion obvia es "pues conecta el calibrador". **No hay ninguno que conectar.** El
registro versionado `public.calibracion_estado_v2` tiene `calibration_version` NULL en sus
9 filas, y cada NULL trae su medicion:

| deporte / mercado | estado | evidencia medida |
|---|---|---|
| soccer / Moneyline | `CALIBRACION_NO_JUSTIFICADA` | 30,876 filas. Calibrar **empeora** el Brier en −0.00058. El sesgo crudo es **0.00 pp EXACTO** (el motor ya esta insesgado) y calibrarlo lo desvia a −0.87 pp. No se declara RECHAZADA_OOS porque no existe prueba fuera de muestra. |
| soccer / BTTS | `CALIBRACION_NO_JUSTIFICADA` | mejora +0.00075, no significativa (t=0.35) |
| soccer / Over/Under | `CALIBRACION_NO_JUSTIFICADA` | empeora −0.00032 |
| soccer / Doble Oportunidad | `CALIBRACION_NO_JUSTIFICADA` | empeora −0.00010 |
| baseball / Moneyline | `CALIBRACION_RECHAZADA_OOS` | walk-forward sobre 1,056 juegos: **pierde en 3 de 3 ventanas**. Brier raw 0.24732 contra cal 0.24850; el sesgo empeora de −0.41 a −1.49 pp |
| football / * | `SIN_MODELO` | `nfl_backtest` VACIO (0 filas), 0 picks de NFL resueltos |

**Conclusion honesta: la app no publica picks porque la calibracion se probo y se RECHAZO
con evidencia, no porque algo este desconectado.** Poner un `calibration_version` hoy seria
exactamente "inventar un calibrador".

### La decision que si es del dueno (yo no la tomo)

Hay una asimetria real que vale la pena que el dueno vea, y **no la toco**:

En soccer/Moneyline la medicion dice que el motor **ya esta insesgado** (sesgo crudo 0.00 pp
exacto) y que calibrarlo lo **empeora**. Es decir: se le exige un `calibration_version` a un
modelo que **no necesita calibracion**. Eso puede ser un defecto del contrato de
elegibilidad, no del modelo.

Las dos salidas legitimas son:

- **(a)** construir un calibrador que demuestre mejora **fuera de muestra**. Hoy ninguno la
  demuestra; en MLB ya se intento y perdio 3 de 3.
- **(b)** cambiar la regla para que un modelo con sesgo demostradamente nulo pueda ser
  elegible **sin** calibrador, registrando esa exencion como version.

**(b) baja un umbral y toca dinero, asi que no es mia.** La dejo medida y nombrada.
Lo que **no** voy a hacer es poner una version de calibracion inventada para que la puerta
abra: eso convierte un bloqueo honesto en un permiso falso.

### Aparte: la puerta de Brier, para cuando la calibracion deje de ser el tapon

Aunque se resolviera lo anterior, estos son los modelos que **hoy** pasarian y no pasarian
`brier_vs_naive_upper95 < 0` (scope GLOBAL):

> ⚠️ **ESTA TABLA QUEDO DESACTUALIZADA EL MISMO DIA.** Se midio ~18:00 UTC. A las
> 19:15:46 UTC del 2026-09-19, con 11 partidos mas calificados, `crossleague_v1`
> en 1X2 paso de n=198 / upper95 −0.0084 a **n=209 / upper95 +0.0001**: ya **NO
> PASA**. Hoy **ningun** modelo de futbol pasa la puerta. Correccion completa, con
> las cifras nuevas, en `docs/ISS258_259_ou_fuera_del_api_y_linaje_visible.md` §0.

| deporte | mercado | modelo | n | upper95 | puerta |
|---|---|---|---|---|---|
| baseball | Moneyline | mlb_runtime_a7fb15853076 | 64 | −0.0047 | **PASA** |
| baseball | Moneyline | mlb_one_brain_v2 | 24 | +0.0067 | NO PASA |
| soccer | 1X2 | crossleague_v1 (prior) | 198 | −0.0084 | **PASA** |
| soccer | 1X2 | **soccer_canonical_v2 (el que publica)** | 66 | **+0.0194** | **NO PASA** |
| soccer | BTTS | soccer_canonical_v2 | 66 | +0.0031 | NO PASA |
| soccer | Over/Under | todos los caminos | 14–184 | +0.0488 a +0.1838 | NO PASA |
| football | Moneyline / Spread / Total | nfl-2026.09.2 | 16 | +0.1095 / +0.2629 / +0.2804 | NO PASA |
| hockey | Moneyline | nhl_elo_v1_k12_h25 | 863 | +0.0099 | NO PASA |

El que publica futbol **no pasa la puerta todavia**, y le faltan partidos, no calidad: su
diff (−0.0497) es mejor que el del prior (−0.0481) con n=66 contra 198. **Lo que falta es
temporada jugada, no un umbral mas bajo.**

---

## 5. PENDIENTE — declarado, no maquillado

| # | Pendiente | Estado |
|---|---|---|
| 1 | `v_futpro_publication_v3` sigue entregando `p_over`/`p_under` en 116 filas aunque O/U este retirado. Ninguna pantalla los pinta, pero la API los ofrece. Hay que decidir si se anulan en la vista (como ya se hizo en `v_tarjeta_soccer_v1`) o si se documentan como diagnostico. **No los toco sin decidirlo explicitamente: anular columnas de un contrato publico es un cambio de contrato.** | PENDIENTE |
| 2 | `mejor_pick` viaja por la API nombrando un mercado no canonico en 102/121 con probabilidad mas alta en 101/121. Hoy no lo pinta nadie, pero es una trampa cargada para la proxima pantalla que lo lea. | PENDIENTE |
| 3 | ~~`top_only_authoritative` = false en 117/117~~ — **NO es un defecto.** En `v_futpro_publication_v3` la columna es el literal `false AS top_only_authoritative`: esta apagada a proposito, igual que `money_authorized`. Corrijo mi propio encuadre anterior: no hay nada que arreglar aqui. | CERRADO |
| 4 | En la lista de FUT Pro, `TresPorcentajesSoccer` se renderiza con `compacto`, y en ese modo **no** se muestra la linea "Probabilidades del modelo de RETO. Son analisis, no una recomendacion de apuesta." Solo aparece en el detalle. Es frontend: **es de Lovable, no mio.** | PENDIENTE (Lovable) |
| 5 | Probar FUT Pro, Favoritos, Scanner y en-vivo en el Remix real, escritorio y movil, con capturas. **BLOQUEADO:** el Remix esta detras de login (`LoginScreen.tsx`) y no tengo credenciales. No las invento. Pedir un usuario de prueba, o correr la suite `vitest` del proyecto, que ya trae `crossScreenCanonical.test.ts` y `favoritosMismaTarjeta.test.ts` justo para el mismo-P_RETO-en-todas-las-superficies. | BLOQUEADO |
| 6 | El Remix **no tiene espejo en GitHub.** `rodrigodelcastillo117-dotcom/reto13` es el proyecto original, no el remix: le faltan `canonicalPick.ts` y `MatchSheetV2.tsx`. Todo lo de frontend se leyo por MCP de Lovable a HEAD `3a7bbf1`. | INFORMATIVO |
| 7 | `docs/USER_FACING_PICK_SEMANTICS_AUDIT.md` **dentro del Remix esta obsoleto**: describe `src/components/fut/`, `src/pages/Premium.tsx`, `src/lib/eligibilityGate.ts` y `MejorPickHoy.tsx`, que ya no existen a HEAD. Es anterior a la reescritura en `src/v2/`. No usarlo como verdad actual. | INFORMATIVO |
