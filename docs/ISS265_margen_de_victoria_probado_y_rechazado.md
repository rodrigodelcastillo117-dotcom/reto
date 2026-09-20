# ISS265 — Elo con margen de victoria: probado y rechazado

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

## La hipotesis

El Elo actual de NFL trata igual ganar por 3 que ganar por 30. Eso tira
informacion, y anadir el margen es la mejora estandar del metodo. Se probo con el
multiplicador clasico (FiveThirtyEight):

```
mult = ln(|margen| + 1) * 2.2 / (ventaja_elo_del_ganador * 0.001 + 2.2)
```

El segundo factor corrige la autocorrelacion: una paliza del favorito mueve MENOS
que la misma paliza de un perdedor esperado.

## Disciplina

- Funcion **nueva y separada**, `v2.fn_team_elo_backtest_mov`. **No toca**
  `v2.fn_team_elo_backtest`, que es la que usan NBA, NHL y WNBA.
- Mismo split 70/30 cronologico, mismo `min_prior`, mismo criterio de puntuacion:
  la comparacion contra el modelo vivo es exactamente comparable.
- **Prerregistro antes de correr:** rejilla `k ∈ {4,6,8,10,12,16}` × `hfa ∈ {25,40,50}`.
  k mas bajo a proposito, porque el multiplicador ya amplifica.
- **Seleccion por `brier_train`** — la regla de la casa, no la mia.
- **Aprobacion solo si le gana al actual en el mismo holdout de 516.**

## Resultado

| k | hfa | brier_train | brier_holdout | acierto |
|---|---|---|---|---|
| **8** | **40** | **0.23877** ← gana en train | **0.23138** | 63.95% |
| 8 | 25 | 0.23881 | 0.23063 | 64.15% |
| 10 | 40 | 0.23883 | 0.23029 | 64.34% |
| 10 | 25 | 0.23887 | 0.22956 | 65.31% |
| 12 | 25 | 0.23912 | 0.22882 | 65.12% |
| 16 | 25 | 0.23996 | 0.22805 | 66.09% |
| **actual, sin margen (k=20,h=25)** | | **0.23913** | **0.23094** | **64.15%** |

**RECHAZADO.** La configuracion que elige el entrenamiento (k=8, hfa=40) gana
0.00036 de Brier en train —ruido— y **pierde en holdout**: 0.23138 contra
0.23094, con menos acierto (63.95% contra 64.15%).

## La tentacion que no se tomo

`k=10, hfa=25` da holdout **0.22956** y **65.31%** de acierto, mejor que el modelo
vivo. `k=16, hfa=25` da **0.22805** y **66.09%**. Elegir cualquiera de esos y
presentarlo como "el margen de victoria mejora el modelo" seria **seleccionar
sobre el conjunto de validacion**: el mismo error que ya se rechazo al elegir k
en ISS262 y al elegir lambda en ISS264. No se hizo.

## Observacion honesta que SI merece seguimiento

Hay un desacuerdo sistematico entre train y holdout: las configuraciones con k mas
alto son peores en train y mejores en holdout, tanto con margen como sin el. Eso
sugiere que **la ventana de entrenamiento (2021–2024) no es representativa de la
ventana reciente**, no que el margen de victoria sea inutil.

Para poder afirmar que el margen ayuda haria falta **validacion anidada**: elegir
k con una particion interna DENTRO del train, sin mirar nunca el holdout. Eso es
trabajo real y es el siguiente paso correcto. Lo que NO es correcto es quedarse
con el numero bonito del holdout.

## Estado

- `v2.fn_team_elo_backtest_mov` queda instalada **como laboratorio**, sin permisos
  para `anon` ni `authenticated`, y sin usarse en ninguna promocion.
- El modelo vivo sigue siendo `nfl_elo_v1_k20_h25`, sin cambios.
- Tercera cosa probada y rechazada en el dia, junto con los dos calibradores.

## Rollback

```sql
drop function if exists v2.fn_team_elo_backtest_mov(text,text,numeric,numeric,integer);
```
