# ISS312-313 — El optimizador no podía sacar a un lesionado, y un parlay real quedó sin poder calificarse

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-17**

Dos defectos distintos, encontrados el mismo día. El primero lo buscaba yo. El
segundo lo vio el dueño en su pantalla, y era el más grave.

---

## 0. Primero, una suposición mía que estaba mal

Entré a Fantasy creyendo que el roster estaba una semana atrasado. Medido:

```
fantasy_semana_nfl() -> {"semana":6, "ya_arranco":true,
                         "primer_partido":"2026-10-16T00:15:00+00:00",
                         "ultimo_partido":"2026-10-20T00:15:00+00:00"}
cron fantasy-arrastrar-roster [20 9 * * *]  ultima corrida 09:20 succeeded
```

**La semana 6 es la semana en curso.** El roster estaba al día y el cron había
corrido esa mañana. Mi hipótesis era falsa y no había nada que arreglar ahí.

## 1. ISS312 — Una línea que volvía inamovible al lesionado

`v2.fn_fantasy_optimal_lineup_v2` decidía si un slot estaba bloqueado así:

```sql
is_locked := ( (c.kickoff is not null and c.kickoff <= p_decision_time)
            or (c.player_key is not null and c.model_status <> 'READY') )
```

Un slot bloqueado **fuerza** `p.player_key = sm.current_key`: conserva al
ocupante. La primera condición es correcta y es doctrina — *el partido ya
empezó, el pasado no se recalcula*. La segunda confunde **"no tengo proyección
publicable"** con **"no se puede mover"**.

El resultado en el roster real `rodelcast / 2026 / semana 6`:

```
titulares:  QB Mahomes 18.94 | RB Achane (IR, null) | RB Kyren 17.22
            WR JSN (saque pasado, null) | WR Egbuka 12.53 | TE Warren 12.98
            FLEX Montgomery (OUT, null) | K Dicker (null) | DST JAX (null)
banca:      Rico Dowdle 14.00 | Keenan Allen 11.77 | Shakir 10.61 | Lloyd 8.06

resumen:    cambios_start 0   cambios_sit 0   mejora_total 0.00
```

La propia tarjeta de Montgomery decía *"No se proyecta a alguien que no juega.
Sustituyelo"* — y el optimizador de abajo recomendaba **cero cambios**. El
jugador que más urgía cambiar era el único que no se podía tocar.

61.67 es exactamente 18.94+17.22+12.53+12.98: **tres slots titulares aportando
cero.**

### Por qué el arreglo es inequívoco, y no una opinión

Los estados posibles del snapshot, medidos:

| model_status | n | significado |
|---|---|---|
| `READY` | 903 | modelable |
| `UNSUPPORTED_POSITION` | 168 | K/DST |
| `NO_SCHEDULE` | 84 | no tiene partido (IR, sin calendario) |
| `UNAVAILABLE_OUT` | 61 | el reporte de lesionados lo marca fuera |

`UNSUPPORTED_POSITION` **nunca** llega a un slot de habilidad: el CTE filtra
`position in ('QB','RB','WR','TE')`. Así que los únicos estados que podían
bloquear un titular eran `NO_SCHEDULE` y `UNAVAILABLE_OUT`, **y los dos
significan que el jugador anota cero.** No existe entre ellos el caso "no sé,
igual es bueno". Por eso quitar la condición no es aflojar un criterio: es
dejar de tratar una ausencia medida como si fuera un dato faltante.

### Los otros dos cambios

**Cerrojo temporal en la elegibilidad.** `pool` exigía `model_status='READY'`
pero no que el partido no hubiera empezado. Ahora exige
`kickoff > p_decision_time`. Medido antes de aplicarlo: **1131 de 1131** filas
`READY` tienen saque futuro, así que hoy no cambia ninguna decisión. Es cerrojo
contra una fuga futura, no un cambio de comportamiento, y se declara como tal.

**Desempate que conserva.** A igual total, se prefiere la alineación que
conserva más titulares (`order by score desc, keeps desc, ...`). Sin eso el
primer resultado proponía mover a Egbuka a FLEX y meter a Allen en WR2: mismo
total, dos cambios donde basta uno.

**Los tres totales salen de las mismas filas** por función de ventana. Antes
venían de dos consultas aparte que reconstruían `player_key` de forma distinta
—una desde el snapshot, otra desde el roster— y podían no casar.

### Por qué se reemplazó en su sitio y no se creó un v3

`public.gate_fantasy_un_solo_modelo / G43.1` inspecciona la función **por
nombre**:

```sql
v_def := pg_get_functiondef('v2.fn_fantasy_optimal_lineup_v2(...)'::regprocedure);
```

Un v3 con el llamador movido habría dejado a G43.1 vigilando una función
muerta: verde, sin vigilar nada. El llamador ya tenía `p0` (el snapshot por
jugador), así que no hacían falta columnas nuevas y la firma quedó idéntica.

### ISS312b — La lista de cambios no podía nombrar al que sale

`v2.fantasy_start_sit_auto_v2` armaba `cambios` emparejando los que entran
(acción `START`) con los que salen (acción `SIT`) **por rango dentro de la
posición**. Dos defectos:

1. Un titular marcado OUT cae en la rama `'OUT'`, que va **antes** en la
   escalera, así que **nunca podía ser un `SIT`**. Incluso con ISS312 aplicado,
   el que entra no habría tenido con quién emparejarse y `cambios` habría
   seguido vacío.
2. Emparejar por rango puede casar a quien entra con quien no dejó ese slot.

Ahora el cambio sale de las filas `MOVE` del optimizador, que ya saben slot,
quién sale y quién entra.

**La ganancia solo se afirma cuando se puede sostener.** Si el que sale está
declarado fuera, anota cero *por el reporte de lesionados* y la ganancia es la
proyección completa del que entra. Si al que sale simplemente le falta el dato
(`SIN_PROYECCION`, `IDENTIDAD_NO_CONFIRMADA`), la ganancia queda **nula** y el
texto pide revisar. Eso es distinto de inventar un cero.

### Verificado

```
v2.fn_fantasy_optimal_lineup_v2('rodelcast',2026,6,'2026-10-17 16:00+00')
  RB/1   Achane (IR)       -> Rico Dowdle   14.00  MOVE
  FLEX   Montgomery (OUT)  -> Keenan Allen  11.77  MOVE
  WR/2   Egbuka            -> Egbuka        12.53  KEEP   <- el desempate conserva
  WR/1   JSN                                 bloqueado (saque pasado)
  total_current 61.67 -> total_recommended 87.44   mejora 25.77

resumen: cambios_start 2, cambios_sit 2, mejora_total 25.77
cambios: Dowdle entra por Achane  (SIN_PARTIDO,        +14.0)
         Allen  entra por Montgomery (AUSENCIA_DECLARADA, +11.8)
tarjeta de Montgomery, 2a razon:
  "En su lugar entra Keenan Allen (11.77 proyectados) en el slot FLEX."

G43.1 PASS  '2 lecturas del snapshot, 3 menciones de model_version'
G43.2 PASS  'resumen 61.67 = suma de titulares 61.67'
G43.3 PASS  'maximo en tarjeta 18.94 <= maximo en snapshot 18.94'
```

**+25.77 puntos por semana** que el defecto estaba tirando, reportando
`mejora_total 0.00`.

## 2. ISS313 — Lo grave: un parlay real que no podía calificarse

El dueño subió un boleto y reportó: *"me puso que los partidos son mañana, y ya
están en juego 2, 2 ya acabaron y se ganaron, solo faltaría 1, el de la Roma."*

**Tenía razón en los cinco puntos.** Lo que guardó el parlay contra lo que dice
la agenda canónica:

| partido | id guardado | fecha guardada | id real | fecha real | estado real |
|---|---|---|---|---|---|
| Man City – Ipswich | `401879259` | 17/10 14:00Z | igual | igual | FT 3-2 |
| Espanyol – Atlético | `af_1570416` | **18/10 15:00Z** | `401882843` | **17/10 12:00Z** | FT 0-1 |
| Betis – Barcelona | `af_1570413` | **18/10 15:00Z** | `401882846` | **17/10 16:30Z** | live 6' |
| Bayern – Leipzig ×2 | `af_1575185` | **17/10 13:30Z** | `401884772` | **17/10 16:30Z** | live 6' |
| Roma – Genoa | `af_1550148` | **18/10 16:30Z** | `401874935` | **17/10 18:45Z** | 18:45Z |

La pantalla no mentía: **el parlay guardó esas fechas.** Y cuatro piernas
quedaron con ids de otro proveedor en un campo llamado `espn_event_id`, así que
no podían casar con la agenda y **no se calificaban**.

### La causa raíz: `live_scores` tiene dos filas por partido

```
401874935  AS Roma - Genoa        17/10 18:45Z  scheduled  actualizado 17/10 06:02
af_1550148 AS Roma - Genoa        18/10 16:30Z  Prox       actualizado 15/10 16:30
401884772  Bayern Munich - RB Leipzig 17/10 16:30Z live 6' actualizado 17/10 16:38
af_1575185 Bayern München - RB Leipzig 17/10 13:30Z Prox   actualizado 14/10 13:30
```

Las filas `af_*` llevaban dos y tres días sin tocarse, con horarios
provisionales. Las de ESPN estaban vivas y correctas.

**Y no se pueden barrer en bloque.** Medido: de 242 filas `af_*` en la ventana
reciente, **66 tienen gemelo de ESPN** (las dañinas) y **176 existen solo en
apifootball** porque ESPN no cubre ese partido. Borrar el prefijo rompería 176
partidos. (El 66 es estimación con emparejamiento tosco —mismo torneo, 5
primeras letras del local, ±3 días— no un conteo probado.)

### Por qué el escáner eligió la fila mala

`scan-betslip`, función `fetchEspnScheduleWindow`: **se llama "Espn" pero lee
`live_scores`**, y toma el id con `String(f.espn_event_id)` **sin validar que
sea numérico** — a diferencia de las capas 4 y 6 del mismo archivo, que sí
exigen `/^\d{6,}$/`. Si `live_scores` trae un `af_*`, lo devuelve como id del
partido y hereda su `game_date`.

Un segundo efecto explica el caso del Espanyol: `vivas` **descarta los partidos
terminados**. La fila buena ya estaba `final`, se descartó, y solo quedó la
duplicada con fecha de mañana. Ahí el escáner no tenía alternativa.

Y el escaneo lo declaró perfecto:

```
total_picks 6 | matched_picks 6 | failed_picks 0 | match_rate 1
```

**`match_rate = 1` no medía "identifiqué el partido en la agenda canónica":
medía "encontré algo en apifootball".** Una pierna de seis acabó verificable.

### El hueco que de verdad había que cerrar

`public.resolver_huerfanos_parlay_a_espn` corre **cada 15 minutos** y no arregló
nada en las dos horas que el parlay llevaba guardado. Su primera línea:

```sql
-- Saltar patas ya trackeables (su eid existe en live_scores)
IF EXISTS (SELECT 1 FROM live_scores ls WHERE ls.espn_event_id = (leg->>'espn_event_id'))
THEN CONTINUE; END IF;
```

Los duplicados `af_*` **sí están** en `live_scores`. Las declaró "ya
trackeables" y las saltó — mientras doce líneas más abajo, al buscar
candidatos, el mismo código escribe `espn_event_id NOT LIKE 'af\_%'`.

**La prueba de trackeabilidad aceptaba un namespace que la propia lógica de
emparejamiento rechazaba.** Quien lo escribió sabía que `af_` no sirve para
calificar; el filtro de entrada no aplicaba esa regla.

### Mi primer arreglo propuesto era insuficiente, y lo midió la prueba

Probado contra la imagen previa, que conserva los valores malos:

| pierna | salto viejo | salto nuevo | candidatos ±2d |
|---|---|---|---|
| Betis – Barcelona | saltada | pasa ✓ | 1 → `401882846` ✓ |
| Roma – Genoa | saltada | pasa ✓ | 1 → `401874935` ✓ |
| Bayern – Leipzig ×2 | saltada | pasa ✓ | **0** |
| Espanyol – Atlético | saltada | pasa ✓ | **0** |

Las seis se saltaban: el hueco quedó probado. Pero corregir el salto y la fecha
resolvía solo 2 de 4. **Había un tercer defecto que no había visto:**

- `Bayern München` → el emparejador toma **solo el token más largo**,
  `münchen`, y la fila de ESPN dice `Bayern Munich`. No casa. Con `bayern`
  casaría.
- `Atletico Madrid` → token `atletico` contra `Atlético Madrid` acentuado. **La
  tilde lo tumba.**

`team_aliases_apifootball` tiene **cero filas** para Bayern, Atlético, Espanyol
y Leipzig, así que la tabla de alias no ayudaba.

### El arreglo completo

`unaccent` (1.1) en **ambos** lados, y basta que **cualquier** token de 4+
letras case en cada lado, con ventana de ±2 días. **La regla de exactamente 1
candidato no se toca:** la ambigüedad se niega, no se adivina. Usar cualquier
token ensancha las coincidencias —`madrid` casa con Real y con Atlético— pero
se exige que casen los dos equipos *y* que haya un único candidato, así que un
caso ambiguo se rechaza en vez de resolverse mal.

Probado antes de aplicarlo: **6 patas, 1 candidato cada una, el correcto en las
6** — confirmación independiente del mapeo que yo había hecho a mano.

Además la función **ahora guarda imagen previa**. Antes sobrescribía
`picks_data` sin guardar nada, lo que contradice que todo retiro sea
reversible. Y corrige **identidad y hora**, no solo el id: antes la pata se
calificaba bien pero la pantalla seguía diciendo "mañana".

### ISS313a — La reparación del parlay del dueño

Cuatro pares escritos a mano, cada uno verificado contra `agenda_espn` **y**
`live_scores` (mismo torneo, mismos dos equipos, partido real de hoy). Sin
emparejamiento difuso. Imagen previa completa en
`v2.parlay_preimagen_iss313` **antes** de tocar nada. **No se tocó `resultado`,
`ganancia_neta` ni dinero.**

Y la prueba de que la reparación servía llegó sola:

```
16:41  autocalificar-parlays (cada 2 min, calificador autorizado)
       pierna 5  Espanyol - Atletico Madrid  FT 0-1  ->  'ganado'
```

**No le escribí el resultado a mano.** La pierna se volvió calificable y el
cron normal la calificó. Eso es lo que debía pasar desde el principio.

### G50.14 — El guardia que faltaba

`public.gate_pata_de_parlay_sin_identidad_canonica()`, cuatro renglones:

| renglón | qué pregunta |
|---|---|
| `G50.14a` | ¿hay patas apuntadas a otro proveedor **teniendo** fila canónica? → FAIL |
| `G50.14b` | ¿hay patas sin `event_id`? → FAIL |
| `G50.14c` | ¿hay ids que `live_scores` no conoce? → FAIL |
| `G50.14d` | patas que dependen de un partido que ESPN no cubre → **INFO**, límite declarado |

El cuarto renglón existe a propósito: 176 partidos de la ventana reciente solo
viven en apifootball. Pintarlos de rojo invitaría a "arreglarlos" borrando
cobertura real. Se cuentan aparte.

Hoy da **PASS ×4**, pero eso es evidencia débil: pasa porque ya no hay nada
roto. Un guardia que nunca vi fallar no está probado, así que se corrió su
clasificador contra la imagen previa:

```
NO_CANONICO_CON_GEMELO  5   Betis(af_1570413); Bayern(af_1575185) x2;
                            Espanyol(af_1570416); Roma(af_1550148)
CANONICO                1   Manchester City (401879259)
```

**Habría dado FAIL(5)** nombrando las cinco patas. Cinco y no cuatro: el
partido del Bayern aparece en dos piernas.

### Un timeout que no era un rollback

El primer intento de crear G50.14 expiró a los 60s en MCP. Verificado en el
catálogo: **la función no existía**, el timeout sí correspondía a un
no-aplicado. La causa era mía: la declaré `stable` y dentro creaba una tabla
temporal, que es una escritura. Reescrita en SQL puro, sin tabla temporal.

## 3. Lo que NO está arreglado, declarado

- **La causa raíz sigue viva.** `live_scores` seguirá recibiendo duplicados
  `af_*`, y `scan-betslip` seguirá pudiendo elegirlos: no toqué la función de
  borde. Hoy el daño se **repara** en ≤15 minutos y se **detecta** con G50.14,
  pero no se **previene**. La prevención correcta son dos cambios que no hice
  en esta sesión: validar el id en `fetchEspnScheduleWindow` con la misma regla
  `/^\d{6,}$/` que ya usan las capas 4 y 6, y no descartar un partido terminado
  cuando la fecha del boleto es la de hoy. Los dejo declarados porque desplegar
  una función de borde que no puedo ejercitar con una imagen real es un riesgo
  que no voy a correr en silencio.
- **El resolvedor arreglado no está ejercitado de punta a punta.** Su predicado
  está probado 6/6 contra los valores reales previos, pero el ensayo en seco
  sobre todos los parlays pendientes devuelve 0 filas porque ya reparé el
  único. Nivel de prueba: predicado probado, ruta en producción **no ejercitada**.
- **K/DST siguen sin modelo** (`k_dst_modelled: false`): 2 de 15 slots del
  roster sin número. No se inventa uno.
- El frontend sigue **NO PROBADO** (red bloqueada por política de la organización).

## Rollback

```sql
-- ISS313a: devolver las patas del parlay a su contenido anterior
update public.parlays t set picks_data = pi.picks_data_prev
  from v2.parlay_preimagen_iss313 pi
 where pi.parlay_id = t.id
   and pi.guardado_at = (select min(x.guardado_at) from v2.parlay_preimagen_iss313 x
                          where x.parlay_id = t.id);
-- OJO: vuelve a dejar el parlay sin poder calificarse.

-- ISS313b/c
--   reponer en public.resolver_huerfanos_parlay_a_espn el IF EXISTS sin el
--   filtro af_/at_, el token mas largo sin unaccent y la igualdad exacta de
--   fecha. NO se recomienda: es exactamente lo que dejo el parlay sin calificar.
drop function if exists public.gate_pata_de_parlay_sin_identidad_canonica();

-- ISS312
--   reponer en v2.fn_fantasy_optimal_lineup_v2 la condicion
--     or (c.player_key is not null and c.model_status <> 'READY')
--   dentro de is_locked. NO se recomienda: vuelve inamovible al lesionado.
```

No se borró un dato, no se borró un objeto, no se tocó un modelo, no se movió
un pick a mano, no se encendió dinero. El único resultado que cambió lo escribió
el calificador autorizado por su cuenta.
