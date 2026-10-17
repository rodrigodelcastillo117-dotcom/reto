# ISS314 — El momio del grupo SGP se comió el del parlay, y fabricó un bono de $8,930

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-17**

El dueño compartió su pick y dijo: *"el pago está mal. Me dijo 2.3k del parlay y
no es así."* Y luego: *"viene por el momio."* Tenía razón en las dos cosas.

---

## 1. La tarjeta contenía la prueba de su propio error

La tarjeta de compartir mostraba cinco momios —**1.27, 1.36, 1.71, 1.67,
1.56**— y debajo declaraba `MOMIO 1.71` y `PAGO TOTAL $2.3K`.

**Un total de 1.71 es menor que el producto de dos cualesquiera de esos cinco.**
Aritméticamente imposible. No hacía falta la base de datos para saber que estaba
mal; la tarjeta se contradecía sola.

## 2. Qué pasó

Las patas 3 y 4 son el mismo partido (Bayern–Leipzig) en un grupo **SGP**: el
boleto imprime un momio combinado de **−140 = 1.714** para el grupo, y el
sistema guarda la pata 4 con momio `1.0` de relleno para no contarlo dos veces.
Ese diseño es correcto y está documentado en `scan-betslip/momios.ts`
(`esNeutroSgmValido`).

**El defecto es que ese 1.714 del grupo acabó en `momio_total`, el momio del
parlay entero.**

El boleto PlayDoIt (ID `5536281240`) es la autoridad:

```
Momios          +664           -> 7.64 decimal
Apuesta total   $1,354.85
Ganancia Total  $11,252.41
```

Y el producto de las unidades del propio parlay —contando el grupo SGP una
vez— da **7.6439**, que confirma el +664 de forma independiente.

```
momio_total guardado  1.7140   ->  1,354.85 x 1.7140 =  2,322.21   <- el 2.3K
momio real del boleto 7.6439   ->  1,354.85 x 7.6439 = 10,356.34
```

## 3. El momio malo contaminó un segundo campo: un bono inventado

```
11,252.41   Ganancia Total, leida correctamente del boleto
-  2,322.21   el pago FALSO (1,354.85 x 1.7140)
-----------
   8,930.20   = exactamente el campo `bono` guardado
```

A la centavo. **El boleto no imprime ninguna línea de bono.** Ese bono se
despejó restando el pago falso del pago real — exactamente lo que las reglas
escritas del propio escáner prohíben, dos veces:

```
"Si NO aparece ningún bono en la imagen, devolver bono: 0. NUNCA inventar un monto."
"Nunca lo inventes ni lo deduzcas restando cantidades."
```

Se puso en **0** antes de que el parlay liquidara, para que esos $8,930
fantasma no entraran al bankroll. Imagen previa completa de la fila en
`v2.parlay_dinero_preimagen_iss314`.

## 4. Un hueco que NO se rellenó

```
Ganancia Total del boleto        11,252.41
pago con el momio +664           10,356.34
                                 ----------
sin explicar                        896.10   (8.65%)
```

El propio boleto imprime `Momios +664` y `Ganancia Total $11,252.41`, y esos
dos números **no reconcilian entre sí**. `momio_efectivo = 8.3053` reproduce la
Ganancia Total (8.3053 = 11,252.41 / 1,354.85), pero +664 son 7.64.

**No se rellenó el hueco.** Poner `bono = 896.10` habría sido repetir
exactamente el defecto que se acababa de quitar: derivar dinero por resta.
Queda declarado y pendiente de que el dueño diga si PlayDoIt aplicó un
potenciador que el boleto no imprime.

## 5. El detector existía, mentía en los dos sentidos, y nadie actuaba

`public.parlays_momio_discrepante` ya marcaba este parlay con `dif_pct -77.58`
y el texto *"momio guardado MENOR que el producto — revisar"*. Nada lo leía.

Pero además **la vista estaba mal construida**: multiplica TODAS las patas,
incluidas las de un mismo grupo SGP. En un SGP el momio combinado es
**legítimamente menor** que el producto de sus patas, porque los mercados están
correlacionados. Un `dif_pct` negativo no prueba por sí solo que haya defecto.

Medido sobre los tres parlays que marcaba en negativo:

| parlay | unidades (SGP contado 1 vez) | guardado | producto real | dif real | veredicto |
|---|---|---|---|---|---|
| `a390001b` | **1** — las 3 patas eran UN solo SGP | 2.6200 | 2.6200 | **0.00%** | **falso positivo**: siempre estuvo bien |
| `a3135134` | 12 | 143.7368 | 149.5731 | −3.90% (la vista decía −5.80) | perdido, dentro de margen |
| `a9d1573a` | 8, **cero patas SGP** | 18.6564 | 29.3091 | **−36.35%** | **sin explicación** |

### `a9d1573a` es el hallazgo caro

8 patas, **ninguna en un grupo SGP**, así que no hay correlación que justifique
nada. Apuesta $300.

```
pago registrado   5,596.92   (300 x 18.6564)
pago por producto 8,792.73   (300 x 29.3091)
diferencia        3,195.81
resultado         GANADO
```

**No se tocó.** Está liquidado y no existe el boleto de ese día para
contrastarlo; corregirlo sería un arreglo manual de dinero sobre un resultado
cerrado. Queda señalado para que el dueño lo contraste contra su boleto de
PlayDoIt del 9 de septiembre.

## 6. G50.15 — El guardia que sí entiende SGP

`public.gate_momio_total_no_cuadra_con_las_piernas()`, dos renglones:

- **G50.15a** — `momio_total` por debajo del producto de las unidades, contando
  cada grupo SGP una vez y con 3% de tolerancia por el redondeo que la casa
  imprime. Solo marca el lado que **perjudica** al usuario: un momio de casa
  mayor que el producto es normal y no es defecto.
- **G50.15b** — el subconjunto que **ya se liquidó como ganado**, donde la
  diferencia no es teórica sino dinero posiblemente mal registrado.

```
G50.15a  FAIL(2)  rodelcast 2026-09-09 -36.35% (3195.81 pesos)
                  rodelcast 2026-09-09  -3.90% (1750.89 pesos)
G50.15b  FAIL(1)  guardado 18.6564 vs producto 29.3091 (3195.81 pesos)
```

Deja de marcar `a390001b`, que la vista vieja pintaba de rojo sin motivo.

## 7. Lo que NO está arreglado, declarado

- **La causa raíz sigue viva.** No toqué `scan-betslip`: el siguiente boleto con
  un grupo SGP puede volver a meter el momio del grupo en `momio_total`. Hoy se
  **detecta** con G50.15; no se **previene**. La prevención es la validación que
  el propio prompt del escáner ya exige y que aquí no se cumplió:
  *"producto(picks[].momio) debe ≈ momio_total (tolerancia 5%)"* — habría
  saltado con −77%.
- **El hueco de $896.10** entre `Momios +664` y `Ganancia Total` del boleto,
  sin explicar, pendiente del dueño.
- **`a9d1573a`**, $3,195.81 en un parlay ganado, pendiente de contraste contra
  el boleto. No se toca sin esa evidencia.
- La tarjeta de compartir dice `VIVAS 5/5` con dos patas ya ganadas (marcadas
  con ✓ en la misma tarjeta). Es ambiguo —"viva" puede querer decir "no
  perdida"— y es superficie de frontend, que es de Lovable. Se señala, no se
  toca.

## Rollback

```sql
-- ISS314 / ISS314b: devolver los campos economicos a su valor anterior
update public.parlays t
   set momio_total = (pi.fila_prev->>'momio_total')::numeric,
       bono        = (pi.fila_prev->>'bono')::numeric
  from v2.parlay_dinero_preimagen_iss314 pi
 where pi.parlay_id = t.id
   and pi.guardado_at = (select min(x.guardado_at) from v2.parlay_dinero_preimagen_iss314 x
                          where x.parlay_id = t.id);
-- OJO: vuelve a dejar el pago en 2,322.21 y el bono inventado de 8,930.20.

-- ISS314c
drop function if exists public.gate_momio_total_no_cuadra_con_las_piernas();
```

No se borró un dato, no se borró un objeto, no se tocó un resultado liquidado,
no se movió un pick. Los dos campos corregidos tienen la fila completa anterior
guardada, y la autoridad de la corrección es el boleto de la casa.
