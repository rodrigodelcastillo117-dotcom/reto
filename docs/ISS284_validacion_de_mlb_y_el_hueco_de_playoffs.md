# ISS284 — Validación de MLB: la respuesta de playoffs es "no se puede, n=0"

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-29**

El dueño pidió validar el modelo de MLB para playoffs *"y todo"*.

---

## La respuesta corta

**Los playoffs no se pueden validar hoy. n = 0.** La postemporada 2026 empezó
hoy y ningún partido con predicción ha terminado. No hay número que dar, y no
se inventa uno.

Y hay un matiz peor: **el modelo que publica no estaba siendo calificado en
absoluto**, ni en temporada regular.

## Tres nombres de modelo, y solo uno publica

| registro | model_version | partidos calificados |
|---|---|---|
| `v2.mlb_learning_snapshot` | **`mlb_one_brain_v2`** ← **el que publica** | **0** |
| `public.lab_mlb_forward` | `C0-prod-2026-09` | 110 |
| `v_mlb_canonical_release_authority_v1` | `mlb_canonical_v1` | 0 (`FORWARD_SAMPLE_INSUFFICIENT`) |

Lo tentador era usar los 110 de `lab_mlb_forward`. **No son el mismo modelo.**
Medido sobre los 81 eventos en común:

```
diferencia media  5.762 pp
diferencia maxima 19.100 pp
identicos         1 de 81
```

Usarlos habría sido repetir exactamente el error que cometí con NFL en ISS281:
validar un modelo con la evidencia de otro.

## Por qué el publicador no tenía calificaciones

`v2.mlb_learning_snapshot` guarda la predicción pero **no tiene columna de
resultado**, y su fuente de resultado —`live_scores`— es efímera:

```
eventos de mlb_one_brain_v2          97
con fila en live_scores               2
con marcador final en live_scores     0
```

El otro registro sobrevivió porque copió el resultado a su propia columna al
calificar. Éste no tenía dónde copiarlo.

### El resultado sí era recuperable

`public.mlb_prob_snapshot.gano_local` lo conservó para **87 de 97**. Antes de
usarlo lo crucé contra `lab_mlb_forward.resultado`:

```
108 eventos en ambas fuentes  ->  108 coinciden, 0 discrepan
```

Dos fuentes independientes, acuerdo perfecto. El dato es confiable.

## La validación, con las CUATRO ventanas

Preregistrado antes de ver números: población = predicciones `temporal_safe`;
resultado = `gano_local`; corte de playoffs = 29 de septiembre; **se reportan las
cuatro ventanas**, porque quedarse con la mejor es seleccionar sobre el
resultado.

### Temporada regular

| ventana | n | Brier | Δ vs 0.25 | upper95 | acierto | dice | brecha |
|---|---|---|---|---|---|---|---|
| **2h** | 87 | 0.22690 | −0.02310 | **−0.00048** | 66.7% | 59.4% | 7.25 pp |
| 6h | 87 | 0.22857 | −0.02143 | +0.00116 | 66.7% | 59.4% | 7.27 pp |
| 24h | 83 | 0.23491 | −0.01509 | +0.00553 | 60.2% | 58.0% | 2.21 pp |
| 48h | 78 | 0.23523 | −0.01477 | +0.00592 | 61.5% | 57.7% | 3.82 pp |

**Solo 1 de 4 ventanas cruza el cero, y por 0.0005.** Con cuatro ventanas
probadas, ese margen no es evidencia: es lo que produce elegir. Y las cuatro
están muy por debajo de los **150 partidos** que exige la política.

**Veredicto: PROMETEDOR, NO DEMOSTRADO.**

Un detalle a favor: donde falla la calibración, el modelo va **por debajo** de lo
que acierta (dice 59.4%, acierta 66.7%). Errar hacia la prudencia es la
dirección buena, pero sigue siendo descalibración.

### Postemporada

```
n = 0
```

`historico_partidos_espn` tiene **131 partidos de postemporada** (2023-2025) con
`season_type = 3`. **No hay predicciones para ninguno**: el registro de
predicciones arranca el 2026-09-14. Tenemos resultados de playoffs sin
predicciones, y predicciones sin playoffs. El hueco está del lado de la
predicción, y solo lo cierra jugar la postemporada.

## Lo construido

| objeto | qué hace |
|---|---|
| `public.v_mlb_live_validation_v1` | valida al modelo **que publica**, separando fase, con las 4 ventanas. Con n<150 devuelve `MUESTRA INSUFICIENTE` en vez de un veredicto |
| `v2.mlb_fase_temporada` | la fase se **declara**, no se adivina. `season_type=3` de ESPN manda; mientras el histórico no alcance la temporada en curso, esta tabla dice desde cuándo y **por qué** |
| **G50.8** | INFO cuando MLB publica en una fase donde tiene 0 observaciones; FAIL solo si la fase tiene muestra y el modelo reprueba |

Hoy: `G50.8 INFO — mlb_one_brain_v2 publicando en POSTEMPORADA: 0 partidos de
evidencia en esa fase`.

Publicar ahí no es necesariamente un error —la probabilidad sale del mismo
cerebro y es decisión del dueño—. Lo que no puede pasar es que nadie lo sepa.

## De paso: NFL ya aprueba

`G50.6` pasó de INFO a **PASS** en estos 8 días:

```
nfl_hybrid_ml_v1: n=32, brier=0.22538, brecha=6.38 pp
  -> DENTRO DEL LISTON / LE GANA A ADIVINAR
```

Era n=15 el 21 de septiembre. Sigue lejos de los 150, pero ya no está en el aire.

## Un defecto de etiquetado que dejo declarado, no arreglado

`historico_partidos_espn.tipo_temporada` dice `regular_o_playoffs` **tanto para
`season_type=2` como para `3`**: mete las dos fases en una sola etiqueta.
`season_type` sí las separa, así que la vista nueva usa `season_type` y no
`tipo_temporada`. Arreglar la etiqueta toca una tabla con 11,444 filas y no es
necesario para esto.

## Límites de lo comprobado

- Los 87 partidos son del **17 al 28 de septiembre de 2026**: doce días. No hay
  temporada completa.
- `mlb_prob_snapshot` no cubre los 97: faltan 10 sin resultado recuperable.
- **No se autorizó nada.** `product_release_authorized` y `money_authorized`
  siguen en false. Esta validación no promueve; mide.
- No se tocó el piso editorial de 58%, ni la ventana de 48 h, ni el modelo.

## Rollback

```sql
drop function if exists public.gate_mlb_fase_sin_evidencia();
drop view if exists public.v_mlb_live_validation_v1;
drop table if exists v2.mlb_fase_temporada;
```
