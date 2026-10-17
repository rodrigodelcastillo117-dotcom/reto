# ISS309-311 — El marcador de tenis estaba en la base sin usarse, y el alcance de ligas

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-17**

---

## ISS309 — Tenis: 45,297 partidos y cero marcadores

```
public.tenis_partidos_v1   45,297 filas, 45,297 con ganador
                           sets_winner NO NULO en CERO de ellas
public.tenis_linescore     10,923 filas en 2,259 eventos, con juegos por set
                           y puntos de tiebreak
ultimos 14 dias            521 partidos, 520 con linescore, 0 con sets
```

**El marcador sí está capturado, set por set, y no llegaba a ninguna parte.** La
pestaña de tenis (`v_reto_tenis_predicciones_v1`) no mostraba un solo resultado:
solo Elo, probabilidad y un pick que es el argmax de Elo.

### Identidad, verificada antes de cruzar nada

`tenis_linescore.competitor_id` casa con `tenis_partidos_v1.winner_id` y
`loser_id` en **520 de 521** partidos recientes. El cruce es por **ID exacto**,
nunca por nombre. El que no casa se queda fuera por falta de linescore; no se
rellena.

### Cómo se decide un set, que no es tan obvio

- Gana el set quien tiene más juegos en ese `period`.
- Si los juegos empatan, decide el tiebreak.
- **Un `period` con 0 o 1 juegos y tiebreak presente ES un match tiebreak** y se
  escribe `[10-5]`, no `1-0`, porque `1-0` no es un marcador de tenis.

`public.v_tenis_marcador_v1` produce **1,748 partidos** con marcador legible:

```
7-6(7-5), 6-4        Tommy Paul
6-0, 7-6(7-4)        Maristany
6-3, 3-6, 7-5        Bouzas Maneiro
4-1  (sets 1-0)      Davidovich Fokina   <- retiro
```

### Un falso positivo mío, cazado antes de que lo consumiera nadie

La primera versión marcó 7 partidos `coherente = false` y 3 con un set sin
resolver. Los miré uno por uno y **ninguno es un dato roto**:

```
Djokovic   vs de Minaur     7-6(7-3), 0-1   retiro al 0-1 del segundo set
Mannarino  vs Basilashvili  6-3, 2-2        retiro con el set empatado
Steiner    vs Da Silva Fick 4-6, 1-1        la rival se retira yendo arriba
Piros      vs O'Connell     5-7, 7-6(7-3)   abandono a 1-1 (US Open)
```

**Son 9 de 1,748 = 0.5%, del orden de la tasa real de retiros en tenis.** Con
`coherente = false` la app esconderia un marcador legítimo. Un detector que llama
"roto" a lo correcto-pero-inusual es un falso positivo, y en este sistema ya me
pasó tres veces (ISS279, ISS296, ISS303). **Esta es la cuarta.**

Corregido: `coherente` ahora significa lo que dice (el dato no se contradice, y en
un retiro no se contradice), y el estado va en columnas nuevas:

```
estado_marcador = COMPLETO | INCOMPLETO_PROBABLE_RETIRO | SIN_CLASIFICAR
COMPLETO 1,739   INCOMPLETO_PROBABLE_RETIRO 9
```

**Lo que no puedo afirmar:** la fuente **no trae campo de estado**. Ni
`tenis_partidos_v1` ni `tenis_linescore` tienen `retired` ni `status`. El retiro
es una **inferencia por la forma del marcador**, no un hecho declarado por ESPN,
y por eso la columna se llama `probable_retiro_o_abandono`. El marcador lleva
` (ret.)`, que es como se escribe en tenis.

### Límite

El linescore arranca el **2026-08-24**. Los 43,549 partidos anteriores no tienen
marcador y no se puede derivar. No se inventa.

## ISS310 — Solo primeras divisiones

Medido antes, en `v_futpro_v2` (372 filas):

```
Taca de Portugal  24 filas   de 26 partidos, solo 2 con AMBOS equipos de primera
Scottish Cup      20 filas   ej. "Penicuik vs Clyde", ambos de division menor
Copa Sudamericana  2 filas
```

44 de 372 (**12%**) de la pestaña de fútbol eran copas contaminadas por clubes de
división menor: Alpendorada, Brito, Sanjoanense, ACDR Lamelas, Académica de
Coimbra, Amarante.

### Las dos decisiones, consultadas y respondidas

1. **Las copas no se apagan: se filtran por división.** Solo entra el partido
   donde **ambos** clubes son de primera. Así, cuando llegue un Real Madrid vs
   Barcelona de Copa del Rey, sí aparece.
2. **Se mantiene Libertadores y se apaga Sudamericana.** El dueño ya había dicho
   "SUDAMERICANA NO" el 21 de septiembre, pero seguía `enabled=true`: estaba
   excluida solo del denominador de cobertura, **no del producto**. Ahora se apaga
   de verdad.

### Por qué el filtro es exacto y no una inferencia por nombre

`catalogo_equipos_espn.liga_casa` tiene **17 valores distintos y todos terminan en
`.1`** (usa.1, esp.1, tur.1, eng.1, ita.1, ksa.1, por.1, ger.1, fra.1, ned.1,
bel.1, nor.1, gre.1, mex.1, den.1, sco.1, aus.1), las 17 con `activa = true`, 386
clubes. Un club sin `liga_casa` **no está en el catálogo de primeras divisiones**.

Aun así el predicado exige explícitamente `liga_casa ~ '\.1$'`, para que si mañana
alguien mete un club con `liga_casa='soccer/por.2'` el filtro lo siga excluyendo.

Medido en la Taça: de 52 lados, **19 tienen `liga_casa` y los 19 son
`soccer/por.1`**; los 33 restantes no tienen ninguna. Esos 33 son exactamente los
de división menor.

### Resultado

```
Taca de Portugal   24 -> 2     AVS vs Moreirense, Tondela vs Alverca (los 4 de Primeira)
Scottish Cup       20 -> 0     todos eran de division menor
Copa Sudamericana   2 -> 0     apagada
Copa Libertadores   2 -> 2     mantenida
TODAS las ligas    IDENTICAS   MLS 31, Liga MX 26, Premier 19, LaLiga 18, Serie A 18...
```

Las 7 copas quedan declaradas en `v2.competencia_solo_primera_division`, con el
motivo medido de cada una. Declarado, no escondido en una vista.

### El sistema ya se había advertido a sí mismo

La evidencia de aprobación de esas copas en
`v2.crossleague_competition_policy`, escrita el 16 de septiembre, dice textual:

> *"En una copa doméstica una de las dos partes suele ser de división inferior,
> con phi de muestra corta, y el modelo no incluye efectos propios de copa
> (rotación, motivación)."*

El riesgo estaba declarado hace un mes. Este filtro es su ejecución.

## ISS311 — La liga argentina

Estado que encontré:

```
ligas_master id  14  Liga Argentina       soccer/arg.1  api 128  tier 1  activa=FALSE
ligas_master id 202  Argentine LPF        (sin endpoint) api 128  tier 1  activa=FALSE
ligas_master id 150  Primera B Argentina  soccer/arg.2  api 129  tier 3  activa=FALSE
v2.competition_catalog:  NO existia ninguna entrada de Argentina
historico_partidos_espn: CERO partidos argentinos
```

**Me pedías una liga que no estaba en el catálogo.**

### El duplicado que casi muerde

Los ids 14 y 202 comparten `api_sports_id = 128`. Esa es exactamente la forma del
fallo documentado dentro de `fn_crossleague_features_canonical`:

> *"esa tabla tiene filas DUPLICADAS para la misma api_sports_id … Con JOIN cada
> partido se cuenta dos veces. Ya pasó una vez: Fleetwood Town saltó de 29 a 120
> partidos en 540 días, que es imposible."*

Así que se encendió **solo el id 14** (el que tiene `espn_endpoint`) y el 202
queda apagado. Verificado después: **una sola fila activa con api 128.** La
Primera B (tier 3) se queda apagada: es división menor.

### Lo que sí hice

```
ligas_master id 14   activa=true, historico_activo=true, sync_apifootball=true
competition_catalog  ar_liga_profesional  enabled=true, display_order 360
liga_alias           "Liga Argentina" -> ar_liga_profesional
```

El alias es determinado, no adivinado: `pedir_agenda_espn` toma `liga_nombre` de
`ligas_master.nombre`, **no** de la respuesta de ESPN.

### Lo que NO hice, y es tu decisión

**No agregué la aprobación del modelo en `v2.crossleague_competition_policy`.**
Esa tabla lleva en su propia evidencia `decidido_por: "dueno"`. Mientras no exista
esa fila, los partidos argentinos aparecen en la agenda con motivo de política no
aprobada, que es el estado honesto.

**La buena noticia para cuando la apruebes:** en modo `SAME_LEAGUE` la propia
tabla dice *"phi se cancela"*. Argentino contra argentino **no necesita fuerza de
liga sellada**, solo forma doméstica real (≥15 partidos por equipo). Así que
Argentina **no depende** del hueco de phi que bloquea 1,385 eventos de torneos
continentales. Depende solo de que llegue su histórico.

### Tus goles: no te lo puedo contestar

`historico_partidos_espn` tiene **cero partidos argentinos**. Tu intuición de que
la liga argentina tiene pocos goles es plausible, pero **no la puedo confirmar ni
negar con nuestros datos**, y no te la voy a confirmar de memoria.

Lo que sí tenemos (2024 en adelante, goles por partido):

| liga | g/p | | liga | g/p |
|---|---|---|---|---|
| Super League Greece | 2.53 | | Ligue 1 | 2.91 |
| Serie A | 2.56 | | Premier League | 2.96 |
| Primeira Liga | 2.68 | | Danish Superliga | 3.08 |
| LaLiga | 2.68 | | MLS | 3.12 |
| Jupiler Pro League | 2.76 | | Eredivisie | 3.16 |
| Süper Lig | 2.82 | | Bundesliga | 3.20 |
| Scottish Premiership | 2.84 | | | |
| Liga MX | 2.85 | | | |

En cuanto entre el histórico argentino, la misma consulta lo contesta con datos.

## Rollback

```sql
-- ISS310
delete from v2.competencia_solo_primera_division;   -- las copas vuelven a entrar completas
update v2.competition_catalog set enabled = true where competition_id = 'conmebol_sudamericana';
--   y quitar el WHERE final de public.v_futpro_v2

-- ISS311
update public.ligas_master set activa=false, historico_activo=false, sync_apifootball=false where id=14;
update v2.competition_catalog set enabled=false where competition_id='ar_liga_profesional';
delete from v2.liga_alias where competition_id='ar_liga_profesional';

-- ISS309
--   drop view public.v_tenis_marcador_v1;  (OJO: el DROP VIEW de esta base no se
--   completa, documentado en ISS294/ISS309b. Alternativa: revocar el select.)
```

No se borró un dato, no se tocó un modelo, no se movió un pick, no se encendió
dinero.
