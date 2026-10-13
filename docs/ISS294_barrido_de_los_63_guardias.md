# ISS294 — El barrido completo de los 63 guardias: lo cerrado y lo que queda

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

Primera vez que se corren **los 63 `gate_*()` de corrido**. Antes se revisaban
los que alguien recordaba. Lo que salió justifica el barrido: **tres FAIL que
nadie estaba mirando**, incluido el de ISS293 que tenía los picks sin refrescar
tres horas.

---

## 1. Cerrado hoy, con prueba

| qué | antes | después |
|---|---|---|
| `gate_censo_global` (3 renglones) | **FAIL** — censo del 21 de sep | **PASS** — `v2.refrescar_censo_global()` → 6 deportes, 20:03 |
| `gate_superficie_cruda` (5 renglones) | **FAIL ×2** | **PASS ×5** — superficies shadow cerradas |
| `gate_escritores_declarados` (4 renglones) | **FAIL (1)** — G45.6 | **PASS ×4** — escritor declarado |
| `reto-global-candidate-snapshot-v1` | 12 corridas seguidas fallidas | **49s, 49s** — dos corridas seguidas (ISS293) |

### Las superficies shadow que estaban abiertas

`v_soccer_pick_quality_shadow_latest_v1` y `v_soccer_pick_quality_shadow_scorecard_v1`
tenían privilegios **completos** para `anon` y `authenticated` — SELECT, INSERT,
UPDATE, DELETE, TRUNCATE — por haber nacido con los grants por defecto de `public`.

Son laboratorio, lo dice su propio texto: *"Shadow quality gate only… Never
changes the side; market/EV/Kelly are excluded"*, y exponen
`promotion_authorized = false`. No se borraron; se revocó la lectura del cliente,
como está revocada toda superficie de validación de esta sesión.

**Riesgo declarado:** no puedo probar el frontend real (salida de red bloqueada
por política de la organización). Si alguna pantalla leyera una vista shadow se
quedaría vacía. Lo creo improbable — no está entre las 15 vistas de producto del
inventario de ISS292 — pero **no lo declaro probado**. Rollback: un `grant`.

### El escritor que faltaba declarar, leído antes de firmarlo

```
G45.6_ningun_trigger_nuevo_sin_declarar  FAIL(1)
  analisis_partidos.zzz_enforce_active_soccer_1x2
```

`v2.escritor_autorizado` se sembró congelando el estado del 18 de septiembre
(ISS200), así que este trigger es **posterior**. El registro funcionó: detectó un
escritor nuevo sobre una tabla protegida.

**No lo declaré a ciegas.** Su cuerpo tiene **14 menciones de precio**, lo que
obligaba a mirarlas una por una antes de firmar nada. Y resultó lo contrario de
lo que temía:

```
linea  62-64  las claves que CONTROLA: home_odds, draw_odds, away_odds,
              _odds_provider
linea  81-82  pone _no_odds_available = true, con el motivo
              'P_RETO es probabilidad del modelo. Momios, EV, Kelly y stake
               no participan en la seleccion.'
linea 135     _odds_source, edge_total, confianza entre las que QUITA
linea 149     estampa 'Un solo cerebro: P_RETO decide el 1X2; precio y
              mercado no eligen.'
```

**Este trigger no usa el precio para decidir: es el que lo borra de la tarjeta y
deja escrita la prohibición.** Corre al final a propósito — el prefijo `zzz_` es
cómo se fuerza el orden alfabético de triggers en Postgres. Consistente con que
`gate_precio_no_decide` reporta `PRECIO_DECIDE_VIOLACION_ABIERTA = PASS(0)`:
nunca apareció ahí.

Declararlo no silencia nada: es la acción que el guardia pide, con el motivo
medido. **G45.6 → PASS.**

## 2. El FAIL que es una decisión tuya, no un defecto

```
gate_evidencia_hacia_adelante  FAIL(1)
  soccer_canonical_v2/BTTS ya tiene n=313 y sigue sin superar el baseline:
  toca decidir.
```

**313 partidos y BTTS no le gana a la tasa base.** El guardia no está roto: te
está pasando la pelota. Es el mismo patrón que el piso editorial del 58% de
ISS285-288 — evidencia suficiente, resultado negativo, decisión de producto.

No la tomo yo.

## 3. El FAIL de precio: cinco líneas sin clasificar, y las clasifiqué con evidencia

```
gate_precio_no_decide
  PRECIO_DECIDE_VIOLACION_ABIERTA    PASS (0)   <- ninguna fuga abierta
  PRECIO_DECIDE_P0_SIN_CLASIFICAR    FAIL (5)
```

**No son cinco violaciones: son cinco líneas que nadie ha firmado.** Las leí:

**Cuatro en `generar_parlay_seguro(text,integer,numeric,text[])`, líneas 228-231:**

```sql
IF    v_prob_total >= 0.40 THEN v_kelly_pct := 4.0;
ELSIF v_prob_total >= 0.25 THEN v_kelly_pct := 2.5;
ELSIF v_prob_total >= 0.15 THEN v_kelly_pct := 1.5;
ELSIF v_prob_total >= 0.08 THEN v_kelly_pct := 1.0;
```

**No leen ni un momio.** Mapean la probabilidad del propio modelo a un porcentaje
de apuesta. Eso **no es Kelly**: Kelly necesita el pago para existir. El detector
las marcó por el *nombre* de la variable, `v_kelly_pct`.

**La quinta, `v_soccer_pick_quality_shadow_scorecard_v1:98`:**

```sql
'Shadow quality gate only. … market/EV/Kelly are excluded.'::text AS policy
```

Es **el texto de la política que prohíbe Kelly**. El detector marcó las palabras
dentro de una cadena de documentación. Un literal de texto no decide nada: falso
positivo sin discusión.

**Ninguna de las cinco lee un precio.** Pero no las clasifiqué en la base: el
guardia existe justamente para forzar una firma humana, y ponerla yo para que un
rojo se vuelva verde es lo que no se hace. Queda la evidencia lista para que
firmes en una frase.

*(De paso, ese detector merece crédito:
`PRECIO_DECIDE_DETECTOR_VE_ARITMETICA = PASS (66)` — detecta por la aritmética
del precio y no por el nombre de la variable, así que no se esquiva renombrando.
El costo de eso son falsos positivos como estos cinco. Es el intercambio
correcto.)*

## 4. Lo que queda abierto, declarado y sin maquillar

| guardia | estado | qué dice |
|---|---|---|
| `gate_cron_sano` | **FAIL ×3** | `motor-cache-horizonte-largo` 100% muerto (240s contra techo 120s); 11 corridas perdidas en 24h por saturación de workers; 15 canceladas por timeout |
| `gate_cron_al_borde_de_su_techo` (G50.12) | **FAIL (6)** | seis crons al filo. `espejo-apifootball-live`: 102s de 120s, **cada 2 minutos** |
| `gate_captura_prospectiva` | **FAIL (4)** | cobertura de fútbol bajo 99% en 4 días-deporte. Motivos **declarados**: `SAMPLE_BELOW_MINIMUM`, `POLICY_NOT_APPROVED`, `PHI_NOT_SERVABLE`. `A_CAPTURA_PREEVENTO` = PASS(0): **no se perdió muestra** |
| `gate_probabilidad_sin_autoridad` | **FAIL ×2** | contrato dice `n_oos=` vacío y la tabla `n_oos=0 FORWARD_SAMPLE_INSUFFICIENT`; falta `brain_in_use` |
| `gate_un_solo_cerebro` | **FAIL (41)** | 41 filas de `fut_predicciones` en el hueco retiro (01:00:33) → barrera (02:46:23) del 18 de sep |
| `gate_fantasy_ve_la_temporada_en_curso` | **FAIL** | 2 de 14 jugadores con historial incompleto (Kyren Williams declara 21 juegos) |
| `gate_usuario_sin_enlace_de_sesion` (G50.10) | **FAIL (1)** | `rongo`, 6 picks, todas sus pantallas vacías (ISS292) |

**No toqué ninguno de estos siete.** Cada uno necesita o una decisión tuya, o una
captura de evidencia propia, y un arreglo por evidencia a la vez.

## 5. Nota de método: tres formas de guardia, y una que el panel no puede leer

De los 63, la mayoría devuelve `(gate, estado, n, detalle)`. **Seis devuelven un
`jsonb` suelto** con otra convención: claves en MAYÚSCULAS como contadores de
violación, que pasan cuando todas valen 0.

```
gate_identidad_exacta:
  VISTA_CON_FIRMA_SIN_LIGA=0  ALIAS_SIN_EQUIPO_EN_AGENDA=0
  IDENTIDAD_PARCIAL_ACEPTADA=0  ALIAS_COLISIONA_CON_OTRO_EQUIPO=0   -> PASS
gate_linaje_p_reto:
  P_RETO_SIN_LLAVE_TRAZABLE=0, 710 de 710 trazables                 -> PASS
```

`public.panel_de_guardias()` **no les adivina el veredicto**: los reporta como
`(no expone estado)` y los lista. Y está bien que no adivine — en
`gate_linaje_p_reto`, `P_RETO_TRAZABLE=710` es una clave en mayúsculas con valor
positivo que significa *bueno*. Un panel que aplicara "mayúscula > 0 = FAIL"
daría un rojo falso. **Se leen a mano, y el panel dice cuáles.**

## 6. Y el panel sí es lento, pero no por lo que dije

En ISS292 escribí que me había equivocado al llamar lentos a los guardias. **Esa
corrección era a medias.** Medido por tramos:

```
guardias  1-16    17s      (btts_no_monetizable 6.6s)
fantasy_alcanzable   28.7s  <- sola
linaje_de_writers    ~45s   <- sola
```

Los primeros 16 son rápidos; más adelante hay guardias de 7, 29 y ~45 segundos.
**El panel completo sí pasa de 60s**, solo que no por la razón que dije la primera
vez.

Por eso existe `public.panel_de_guardias_tramo(p_como)`, que además reporta los
milisegundos de cada guardia:

```
panel_de_guardias_tramo('gate_c%')  ->  cron_sano 1036ms, coherencia_soccer_v2 2684ms, ...
```

### Un DROP que no se completa, declarado

Lo natural era añadirle el parámetro a `panel_de_guardias()` con `DEFAULT`, pero
eso crea una llamada ambigua con la versión de 0 argumentos, así que habría que
borrarla. Y:

```sql
drop function if exists public.panel_de_guardias();
```

**no se completa.** Expira a los 60s, tres intentos, verificando cada vez que la
función sigue ahí. Con `set lock_timeout='8s'` **también** expira a los 60 — lo
que **descarta una espera por lock**, porque habría dado error a los 8 segundos.

**No sé por qué.** Queda declarado en vez de inventarle una causa, y se rodeó sin
borrar nada: dos funciones con nombres distintos, cero ambigüedad.

*(Esto es distinto del misterio de `absorber_agenda_espn` de ISS289, que sí quedó
explicado en ISS293: ahí eran lectores largos de crons solapados. Aquí el
`lock_timeout` prueba que no es eso.)*

## Rollback

```sql
-- superficies shadow (si alguna pantalla las leia)
grant select on public.v_soccer_pick_quality_shadow_latest_v1    to authenticated;
grant select on public.v_soccer_pick_quality_shadow_scorecard_v1 to authenticated;
-- el panel por tramos
drop function if exists public.panel_de_guardias_tramo(text);
```

El censo se refresca solo con `v2.refrescar_censo_global()`; no hay nada que
revertir ahí. No se borró un dato, no se tocó un modelo, no se movió un pick, no
se encendió dinero.
