# NFL — backtest walk-forward 2025 · ¿son reales los porcentajes?

`RELEASE_GATE=HOLD` · `PROD_FREEZE=ON` · prod sólo-lectura · sin cutover.
Rama desechable: `mlb-decision-contract` / `ysuaktkawnljflrvozmk`.
Modelo: `nfl_points_lattice_v1` / `nfl-2026.09.1` (iss054).

## Cómo se midió

Walk-forward honesto: para cada fecha de juego de la temporada regular 2025 se ajustaron los
ratings **sólo con juegos estrictamente anteriores** a esa fecha, y con esos ratings se predijo.
Nada de mirar el futuro. Se exigieron ≥64 juegos de entrenamiento antes de emitir la primera
predicción, así que el backtest arranca el **2025-10-03** y corre hasta el **2026-01-05**.

**208 juegos predichos · 199 con precio de mercado.**

Nota de alcance: la línea de 2025 guardada en `nfl_partidos` es un único valor por juego (la
última conocida), no una serie con `snapshot_at`. Para la comparación de moneyline eso no
importa — el Brier contra el resultado es limpio — pero para spread/total significa que la
línea contra la que me comparo puede ser de cierre, que es la versión *más difícil de batir*
del mercado. Es el lado conservador, no el cómodo.

## Moneyline — el resultado

| Métrica | Valor |
|---|---|
| Brier modelo | **0.22750** |
| Brier volado (0.5) | 0.25000 |
| **Skill vs volado** | **+9.00 %** |
| Brier mercado no-vig | **0.21822** |
| Ganancia pareada vs mercado | **−0.00918** |
| Error estándar | 0.00808 |
| **t** | **−1.135** |
| Tasa real de victoria local | 0.5144 |
| Media modelo / media mercado | 0.5412 / 0.5429 |

**Lectura honesta:** el modelo tiene skill REAL — convierte 9 % de la varianza del volado, y eso
no es ruido. Pero **no le gana al mercado**: pierde por 0.0092 de Brier, con t = −1.135. Ese
déficit tampoco es estadísticamente significativo, así que lo correcto es decir *el modelo está
cerca del mercado y por debajo de él*, no "empata" ni "lo supera".

Para contexto, el mismo tipo de medición en MLB dio skill **+1.0 %** vs volado. NFL con este
modelo está mucho mejor planteado que MLB.

## Spread y total — aquí NO hay ventaja

| Mercado | n | modelo dice | real | Brier | Brier volado | sesgo |
|---|---|---|---|---|---|---|
| Cubre local (spread DK) | 208 | 47.37 % | 48.56 % | 0.27306 | 0.25000 | 1.19 pp |
| Over (total DK) | 208 | 53.66 % | 53.37 % | 0.26308 | 0.25000 | 0.29 pp |

El **sesgo agregado es excelente** (1.19 pp y 0.29 pp: el modelo no está sistemáticamente
inflado ni deflactado). Pero el Brier es PEOR que 0.25 en ambos, o sea: **no hay habilidad para
elegir lados de spread ni de total.** Es el resultado esperado contra una línea eficiente, y es
exactamente lo que un sistema honesto debe reportar en vez de maquillar.

## Qué tan lejos estamos, en puntos

| Métrica | Modelo | DraftKings | Diferencia |
|---|---|---|---|
| MAE del margen | 10.636 | **9.933** | DK mejor por 0.70 |
| RMSE del margen | 13.399 | **12.237** | DK mejor por 1.16 |
| MAE del total | 10.456 | **10.106** | DK mejor por 0.35 |
| Sesgo del margen | −0.168 | — | prácticamente nulo |
| Sesgo del total | −0.120 | — | prácticamente nulo |
| corr(margen modelo, margen DK) | 0.8255 | | |
| corr(total modelo, total DK) | 0.7364 | | |

**En totales estamos a 0.35 puntos del mercado.** Ahí es donde el modelo está más cerca y donde
conviene empujar primero.

## EL HALLAZGO MÁS IMPORTANTE — calibración por tramos

| El modelo dice | n | real | error |
|---|---|---|---|
| < 40 % | 20 | 35.0 % | −0.6 pp |
| **40–50 %** | **50** | **32.0 %** | **+14.0 pp** |
| 50–60 % | 81 | 50.6 % | +4.1 pp |
| 60–70 % | 43 | 69.8 % | −4.7 pp |
| **70 %+** | **14** | **92.9 %** | **−18.4 pp** |

El patrón es claro y direccional: **el modelo está SUB-confiado en los extremos.** Cuando dice
70 %+, la realidad fue 92.9 %. Su distribución predictiva es **demasiado ancha**.

### Esto revela un error mío en el modelo

Usé `sd_team_points = 9.897`, que es la desviación **cruda** de los puntos de un equipo. Pero los
ratings ya explican parte de esa variación, así que la sd del residual es menor. Medido aquí:

```
RMSE del margen = 13.399  =>  sd_equipo correcta = 13.399 / sqrt(2) = 9.474
yo usé                                              9.897  (demasiado ancha)
```

Y peor: la `early_season_sd_inflation = 1.15` que metí como juicio para Week 1 lleva la sd a
**11.38**, que empuja en la dirección EQUIVOCADA según estos datos. La inflación parecía prudente
y los números dicen que comprime las probabilidades justo donde ya estaban comprimidas.

No cambio el modelo en este commit: la corrección va versionada como `nfl-2026.09.2` con la sd
medida, para no mover el blanco después de haber medido. Pero queda escrito que **1.15 está mal
orientada** y que la sd correcta según el backtest es ≈ 9.474.

Advertencia de muestra: el tramo 70 %+ tiene n=14 y el <40 % n=20. El tramo 40–50 % (n=50, +14 pp)
es el más preocupante por tamaño. No voy a sobre-ajustar a tramos de n pequeño.

## Reproducción

```sql
-- en la rama desechable, después de iss054 y del seed de 2025:
select count(*) from v2.nfl_backtest_2025;   -- 208
```
Generador: `shadow-patches/tests/run_nfl_backtest_2025.sql`.
