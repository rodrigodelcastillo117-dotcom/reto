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
