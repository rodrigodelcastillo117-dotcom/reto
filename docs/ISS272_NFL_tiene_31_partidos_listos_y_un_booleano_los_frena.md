# ISS272 — NFL tiene 31 partidos con pick listo, y un solo booleano los frena

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## Cómo llegué aquí

El dueño pidió "meterle mucho a los picks". En vez de discutir, medí qué publica
hoy `public.v_pick_canonico`, la superficie de picks de la app:

| deporte | mercado | filas |
|---|---|---|
| baseball | Moneyline | 38 |
| soccer | Moneyline | 18 |
| baseball | Over/Under | 6 |
| **football** | — | **CERO** |

**NFL no aparece.** Y NFL es el único deporte que (a) tiene habilidad demostrada
contra adivinar, (b) está en temporada ahora, y (c) juega en la ventana del
release.

## La cadena, compuerta por compuerta

`v_pick_canonico` se alimenta de una vista por deporte: `v_picks_futbol_calibrado`
y `v_picks_mlb_modelo`. **La de NFL nunca se construyó.** Pero la vista de
publicación sí existe: `public.v_nfl_publication_v1`, con la forma correcta
(`canonical_pick`, `p_home_pct`, `money_authorized`) y **cero filas**.

Sus tres compuertas, medidas por separado:

| compuerta | resultado |
|---|---|
| A. ¿Hay snapshots futuros? | **7,023** (`nfl_form_ml_v1`, `nfl_hybrid_ml_v1`, `nfl-2026.09.2`) |
| B. ¿Algún modelo con autoridad de release? | **SÍ**: `nfl_hybrid_ml_v1`, `scientific_ready=true`, `product_release_authorized=true`, n=143, gap=6.54 |
| C. ¿Ramas autorizadas a publicar? | `CURRENT_FORM=true`, `MATURE_MODEL_NATIVE=true`, **`ELO_HISTORICAL_PRIOR=false`** |

Las tres pasan por separado. El bloqueo está en el cruce:

> El modelo autorizado `nfl_hybrid_ml_v1` tiene **826 snapshots `READY` para 31
> partidos** (22 sep – 4 oct), y **todos** llevan `provenance->>'branch' =
> 'ELO_HISTORICAL_PRIOR'`, que es justo la rama con `publish_authorized = false`.

## Por qué NO es un bug

`v2.build_nfl_hybrid_ml_v1` decide la rama así:

```sql
if least(partidos_local, partidos_visita) < cfg.transition_min_games then
   v_branch := 'ELO_HISTORICAL_PRIOR';   -- bloqueada para publicar
else
   v_branch := 'CURRENT_FORM';            -- autorizada
```

Con `transition_min_games = 4`. Y la propia configuración lo documenta:

- `early_scope`: *"Use Elo prior while either team has <4 current-season regular games"*
- `mature_scope`: *"At >=4 current-season regular games for both teams, delegate to nfl_form_ml_v1"*
- `stability_note`: *"Bridge is deliberately limited to early season."*

Estamos en la semana 3. Los equipos no llegan a 4 partidos todavía, así que el
modelo se apoya en la fuerza de **la temporada pasada**, y alguien dejó escrito
que eso no se publica.

**Eso es la regla del dueño —"ESTA TEMPORADA VALE MÁS QUE LA PASADA"— convertida
en código.** No lo toco.

## Lo que sí vale la pena saber: el puente tiene evidencia

Esto es lo incómodo, y por eso es decisión del dueño y no mía. La rama bloqueada
**no es un invento**: está validada fuera de muestra.

| | n | Brier | vs 0.25 | acierto | gap calibración |
|---|---|---|---|---|---|
| Puente Elo (la rama **bloqueada**) | 143 | **0.22986** | mejor | — | **6.54 pp** (pasa el umbral de 7.5) |
| · 2024 | 64 | 0.25069 | ~neutro | 54.69% | 4.42 pp |
| · 2025 | 63 | 0.20533 | mejor | 68.25% | 6.54 pp |
| · 2026 semana 1 | 16 | 0.24309 | mejor | 56.25% | 5.42 pp |

Es decir: el puente pasa el gate científico y el de release. Lo frena **solo** la
decisión de producto de no publicar nada apoyado en la temporada pasada.

## Y lo que viene solo: el mejor modelo de toda la app

Cuando ambos equipos lleguen a 4 partidos, la rama cambia sola a `CURRENT_FORM`,
que delega en `nfl_form_ml_v1`. Su evidencia sellada:

| | n | Brier | acierto | gap calibración |
|---|---|---|---|---|
| **`nfl_form_ml_v1` (maduro)** | 123 | **0.21033** | **69.92%** | **4.79 pp** |

Comparado con todo lo demás del sistema:

| modelo | Brier | acierto |
|---|---|---|
| **nfl_form_ml_v1** | **0.21033** | **69.92%** |
| nba_elo_v1_k24_h50 | 0.41873 (escala de 2 comp.) | 67.97% |
| nfl_elo_v1_k20_h25 | 0.23094 | 64.15% |
| soccer_canonical_v2 | — | 50.00% |

**Es el mejor cerebro del sistema, y se enciende solo.**

### Cuándo, exactamente

Semana 1 arrancó el 10 de septiembre. Cada equipo necesita **4 partidos
jugados**, así que los partidos de la **semana 5 (≈ 8–13 de octubre)** ya tendrán
ambos equipos con 4+. A partir de ahí la rama pasa a `CURRENT_FORM`, deja de
estar bloqueada, y NFL empieza a publicar picks **sin que nadie toque nada**.

Estimación basada en el calendario, no medida: las semanas de descanso podrían
correr algún partido suelto. Lo marco como estimación.

## La única decisión, y es del dueño

Hay **un booleano** entre 31 partidos con pick listo y la app:

```sql
update v2.nfl_branch_release_authority
   set publish_authorized = true
 where branch = 'ELO_HISTORICAL_PRIOR';
```

**No lo ejecuto.** Razones:

1. Contradice la regla explícita del dueño sobre la temporada pasada.
2. Es un arreglo manual de publicación, de la misma familia que los que tengo
   prohibidos (dinero a mano, calificación a mano).
3. Alguien lo puso en `false` a propósito y dejó la nota "deliberately limited".

El intercambio real, sin adornos:

| si se deja en `false` (hoy) | si se pone en `true` |
|---|---|
| NFL sin picks hasta ~8 de octubre | 31 partidos con pick desde el 22 de septiembre |
| Se respeta "esta temporada vale más" | Se publica fuerza de la temporada pasada durante ~2 semanas |
| — | Evidencia real: n=143, Brier 0.22986, gap 6.54 pp |
| — | El dinero **sigue apagado** en cualquier caso (`money_authorized=false` está escrito duro en la vista) |

## Lo que NO hice

- No flipeé el booleano.
- No construí `v_picks_nfl_modelo` conectando el Elo que promoví ayer: sería un
  **segundo cerebro** de NFL en paralelo al híbrido, y la regla es uno solo por
  deporte. El Elo de ayer (`nfl_elo_v1_k20_h25`) sirve el timeline de análisis;
  el híbrido es el que tiene el contrato de publicación.
- No toqué ningún umbral.

## Pendiente real si se autoriza

Aunque se abra la rama, `v_pick_canonico` **sigue sin alimentador de NFL**.
Hay que construir `public.v_picks_nfl_modelo` espejo de `v_picks_mlb_modelo`,
leyendo de `v_nfl_publication_v1`, y unirlo. Es trabajo mecánico y reversible,
pero no lo hago hasta que la rama tenga sentido publicar.

---

# EJECUTADO — 2026-09-21

El dueño autorizó explícitamente abrir la rama. Queda firmado aquí porque un
cambio de autoridad de publicación sin firma es justo lo que no debe poder
rastrearse a «alguien lo movió».

## Lo que se hizo, en cuatro migraciones

| # | migración | qué hace |
|---|---|---|
| a | `iss272_el_dueno_autoriza_publicar_el_puente_elo_de_nfl` | `publish_authorized = true` en `ELO_HISTORICAL_PRIOR` |
| b | `iss272b_alimentador_de_picks_de_nfl` | crea `public.v_picks_nfl_modelo`, espejo del de MLB |
| c | `iss272c_nfl_entra_al_contrato_canonico_de_picks` | parche exactamente-una-vez que une NFL a `v_pick_canonico` |
| d+e | `iss272d/e` | dos correcciones a mi propio texto (ver abajo) |

## Simulacro antes de tocar producción

```
ANTES publicacion_nfl = 0 filas
rama_abierta_filas    = 1
DESPUES publicacion   = 32 filas, 32 READY, 32 partidos
con_dinero=0 | fuga_temporal=0 | prob_no_suman_100=0
```

## Resultado, medido en el servidor

| superficie | antes | después |
|---|---|---|
| `v_pick_canonico` total | 62 filas | **120 filas** |
| · football | **0** | **64 filas / 32 partidos** (22 sep – 5 oct) |
| · baseball | 44 | 44 |
| · soccer | 18 | 12 |
| picks con dinero | 0 | **0** |

**NFL es ahora el deporte con más picks de la app.**

### Fútbol bajó de 18 a 12 y NO fue mi parche

Lo verifiqué en vez de suponerlo: el alimentador crudo
`v_picks_futbol_calibrado` **ya produce 12 filas por sí solo**, y 3 partidos
habían arrancado entre una medición y otra. El parche es aditivo (`UNION ALL`);
no puede quitar filas.

## Dos correcciones a mi propio trabajo, encontradas leyendo la salida real

**1. Campos inútiles con apariencia de dato.** Mi primer `detalle` decía
`margen esperado ?` e `incertidumbre 45.8`. El primero es NULL siempre en esta
rama (el builder nunca asigna `v_exp_margin` ahí). El segundo es
`sqrt(p·(1−p))·100` — una función determinista de la probabilidad que ya se
muestra al lado, o sea cero información con aire de medición independiente.
Ambos fuera.

**2. La etiqueta decía lo contrario de lo que pasa.** Escribí
*"historia que lo respalda: 1 y 1 partidos"*. Falso: lo que respalda el pick es
el Elo de la temporada pasada **completa**; el «1 y 1» son los partidos de
**esta** temporada, que es exactamente la razón de no usar la forma actual. Tal
como estaba, el usuario leía «este pick se apoya en 1 partido» — falso y
alarmante. Ahora dice:

> *semana 2 | fuerza tomada de la TEMPORADA PASADA, porque en esta llevan 1 y 1
> partidos y el modelo exige 4 para fiarse de la forma actual*

## Lo que NO se movió

- `money_authorized`: **0 de 231** en el gate, **0** picks con dinero.
- Guardia G50.4: **PASS**.
- O/U fuera del API: **0**. Insignia falsa de «Validado»: **0**.
- Ningún umbral tocado. `transition_min_games` sigue en 4.
- **Solo Moneyline.** La config declara `MONEYLINE_ONLY` y
  `spread_total_authorized=false`; hay columnas de spread y total en la vista de
  publicación pero son contexto de mercado, no predicción nuestra. Publicarlas
  como pick sería inventar un mercado que el modelo no está autorizado a opinar.
- No conecté el Elo que promoví el 20-sep (`nfl_elo_v1_k20_h25`) a este tubo:
  sería un **segundo cerebro** de NFL en paralelo al híbrido, y la regla es uno
  solo por deporte. Ese sigue sirviendo el timeline de análisis.

## Lo que pasa solo alrededor del 8–13 de octubre

Cuando ambos equipos lleguen a 4 partidos, la rama cambia sola a `CURRENT_FORM`,
que delega en `nfl_form_ml_v1`:

| | n | Brier | acierto | gap |
|---|---|---|---|---|
| **nfl_form_ml_v1** | 123 | **0.21033** | **69.92%** | **4.79 pp** |

Es el mejor cerebro del sistema y entra **sin que nadie toque nada**. Este cambio
no estorba esa transición. Estimación por calendario, no medida.

## Rollback

```sql
-- 1. sacar NFL del contrato (volver a la version anterior de la vista)
--    o, mas simple y reversible:
update v2.nfl_branch_release_authority
   set publish_authorized = false
 where branch = 'ELO_HISTORICAL_PRIOR';
-- con eso v_nfl_publication_v1 vuelve a 0 filas y NFL desaparece del contrato
-- sin tocar la estructura.

-- 2. si ademas se quiere quitar la vista:
drop view if exists public.v_picks_nfl_modelo;  -- exige quitar antes la rama del UNION
```

Ninguna fila borrada. Ningún dato histórico tocado.
