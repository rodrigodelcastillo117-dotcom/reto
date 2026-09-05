# FASE 1 — Reconstrucción del cerebro predictivo (DISEÑO, sin desplegar)

Fecha: 5-sep-2026. **Nada de esto está aplicado.** Cero cambios en funciones, vistas,
crons, tablas o UI. Todas las cifras salen de consultas de solo lectura contra producción.

---

## 0. DOS MEDICIONES QUE CAMBIAN EL MANDATO

### 0.1 La calibración no puede cumplir el objetivo 3 como está redactado

El objetivo pedía comprimir las bandas 60-65% y ≥65% hasta ~52% y bajar el Brier de
0.327 a "niveles competitivos". Corrí la búsqueda de temperatura sobre el corpus
completo calificado (n=2,028, sin placeholders, partido ya jugado):

`p_cal = σ( logit(p) / T )`

| T | Brier | LogLoss |
|---|---|---|
| 2.6 | 0.24888 | 0.69142 |
| 3.0 | 0.24852 | 0.69049 |
| 3.4 | 0.24834 | 0.69001 |
| 3.8 | 0.24826 | 0.68978 |
| **4.0 (borde de la rejilla)** | **0.24824** | **0.68972** |

La pérdida **decrece monótonamente hasta el borde**: el óptimo es `T → ∞`, es decir
**tirar la probabilidad y cotizar la tasa base**. Sí baja el Brier de 0.327 a 0.248 y
cumple el número pedido — pero lo cumple borrando el modelo.

### 0.2 Por qué: no hay poder discriminante que calibrar

AUC por mercado sobre el mismo corpus, con `z` bajo H0 (`SE = sqrt((n1+n0+1)/(12·n1·n0))`):

| deporte | mercado | n | tasa base | **AUC** | z |
|---|---|---|---|---|---|
| Fútbol | Over/Under | 201 | 0.5025 | 0.5669 | +1.64 |
| MLB | Moneyline | 1074 | 0.4479 | 0.5241 | +1.36 |
| MLB | Over/Under | 289 | 0.4740 | 0.4868 | −0.39 |
| Fútbol | BTTS | 161 | 0.5280 | 0.4724 | −0.60 |
| Fútbol | Moneyline | 179 | 0.3520 | 0.4469 | −1.17 |
| **Fútbol** | **Corners** | **119** | 0.5126 | **0.3109** | **−3.56** |

**Ningún mercado tiene discriminación significativa.** Y Corners está **invertido a
3.56 sigmas**: el motor ordena los partidos de corners al revés.

Consecuencia de diseño: hay que separar dos cosas que el mandato trata como una.

| objeto | qué es | qué lo arregla |
|---|---|---|
| **(a) Sobreconfianza** | decir 77.4% y acertar 52.6% | calibración — **sí, desplegar** |
| **(b) Falta de discriminación** | AUC ≈ 0.5 | **información nueva**, no calibración |

Comprimir es urgente aunque no dé ventaja: un 77.4% falso alimenta Kelly y dimensiona
dinero. Pero comprimir **no** produce ventaja, y presentarlo como si la produjera sería
la misma mentira con otro decimal.

---

## 1. TRAZABILIDAD: `features_input_json`

### 1.1 Principio: un fallback nunca puede parecer un dato

Lección de #107/#108: el motor trataba la ausencia como confirmación. Por eso **cada
hoja es una terna**, no un escalar:

```jsonc
{
  "schema": 1,
  "motor": "motor_probabilidades@2026-09-05",
  "generado_at": "2026-09-05T18:22:41Z",
  "deporte": "FUTBOL",
  "evento": { "espn_event_id": "...", "arranca_en": "...", "endpoint": "soccer.uefa.champions" },

  "entradas": {
    "xg_home":         { "v": 1.42, "src": "v_equipo_partido_espn_xg", "estado": "ok",       "n": 10 },
    "xg_away":         { "v": null, "src": "v_equipo_partido_espn_xg", "estado": "ausente",  "n": 0  },
    "dias_descanso_home": { "v": 6.0,  "src": "futbol_factor_descanso_espn", "estado": "ok" },
    "dias_descanso_away": { "v": null, "src": "futbol_factor_descanso_espn", "estado": "fallback", "v_usada": 1.0 },
    "clima_temp":      { "v": 19.4, "src": "futbol_clima_hora", "estado": "ok" },
    "clima_viento":    { "v": null, "src": "futbol_clima_hora", "estado": "ausente" },
    "lineup_status":   { "v": "confirmado", "src": "alineaciones_espn", "estado": "ok" },
    "h2h_score":       { "v": 0.61, "src": "h2h_por_espn", "estado": "ok", "n": 7 },
    "p_market_opening":{ "v": 0.512, "src": "radar_odds_snapshots", "estado": "ok", "at": "..." },
    "p_market_current":{ "v": 0.534, "src": "radar_odds_snapshots", "estado": "ok", "at": "..." }
  },

  "data_completeness_pct": 71.4,
  "faltantes": ["xg_away", "clima_viento"],
  "castigo_confianza": 0.714,
  "p_modelo_cruda": 0.681,
  "p_usada": 0.598
}
```

`estado` ∈ `ok | fallback | ausente | fuera_de_rango`. Es la garantía estructural:
no hay forma de escribir un valor por defecto sin declararlo.

### 1.2 `data_completeness_pct` ponderado, no contado

Contar variables trataría igual la falta del abridor de MLB (peso alto, medido) que la
falta de xG (peso 0 hoy). Se pondera por el peso **medido en backtest**:

```
completeness = Σ (peso_i · 1[estado_i = 'ok']) / Σ peso_i
```

Los pesos viven en una tabla `feature_pesos(deporte, mercado, feature, peso, medido_at,
n, fuente_medicion)` y **solo se escriben desde un backtest**, nunca a mano.

### 1.3 Castigo de confianza — **HIPÓTESIS A VALIDAR, no fórmula aprobada**

Candidato:

```
p_usada = p_mercado + w(completeness) · (p_modelo − p_mercado)
```

Conceptualmente: con información completa cotizas tu modelo; sin información cotizas
el mercado, que es el estimador honesto por defecto. Encoger hacia 50% sería peor:
inventaría ventaja en favoritos claros.

**Pero `w = completeness` (lineal, coeficiente 1) no está demostrado.** Con modelo 65%
y mercado 52%, una completitud de 0.50 da 58.5% — parece razonable y no lo es por eso.
Queda como candidato y se valida igual que todo lo demás:

| forma funcional | parámetros a ajustar |
|---|---|
| lineal | `w = c` (el candidato, 0 parámetros) |
| potencia | `w = c^γ`, γ por deporte y mercado |
| umbral | `w = 1` si `c ≥ c₀`, si no `c/c₀` |
| por tipo de faltante | `w = 1 − Σ peso_i · 1[falta_i]`, con pesos de `feature_pesos` |

La cuarta es la que recoge su observación: **no toda ausencia pesa igual**. Que falte el
abridor de MLB no es lo mismo que falte una variable secundaria. Se ajusta por
walk-forward con los mismos cuatro criterios de §3.4, y gana la que gane.

**Mientras no esté validada** rige la lineal por ser la más conservadora, marcada
`"w_forma": "lineal_provisional"` dentro del JSON — y el tamaño de apuesta va además
multiplicado por el Pick Quality Score de §8, de modo que un encogimiento sin validar
no puede sobreapostar por sí solo.

### 1.4 Migración (NO aplicada)

```sql
-- 1) Columnas
ALTER TABLE public.oraculo_picks_tracking
  ADD COLUMN features_input_json jsonb,
  ADD COLUMN data_completeness_pct numeric;

ALTER TABLE public.picks
  ADD COLUMN features_input_json jsonb,
  ADD COLUMN data_completeness_pct numeric;

-- 2) El esquema es obligatorio y versionado cuando la fila viene del motor
ALTER TABLE public.oraculo_picks_tracking
  ADD CONSTRAINT chk_features_input_schema
  CHECK (features_input_json IS NULL
         OR (features_input_json ? 'schema'
             AND features_input_json ? 'entradas'
             AND features_input_json ? 'data_completeness_pct'));

ALTER TABLE public.oraculo_picks_tracking
  ADD CONSTRAINT chk_completeness_rango
  CHECK (data_completeness_pct IS NULL
         OR data_completeness_pct BETWEEN 0 AND 100);

-- 3) Índices de consulta (GIN sobre las entradas, no sobre todo el documento)
CREATE INDEX idx_opt_features_entradas
  ON public.oraculo_picks_tracking USING gin ((features_input_json->'entradas'));
CREATE INDEX idx_opt_completeness
  ON public.oraculo_picks_tracking (data_completeness_pct)
  WHERE data_completeness_pct IS NOT NULL;

-- 4) Tabla de pesos medidos
CREATE TABLE public.feature_pesos (
  deporte text NOT NULL,
  mercado text NOT NULL,
  feature text NOT NULL,
  peso numeric NOT NULL CHECK (peso >= 0),
  n integer NOT NULL CHECK (n > 0),
  medido_at timestamptz NOT NULL DEFAULT now(),
  fuente_medicion text NOT NULL,
  PRIMARY KEY (deporte, mercado, feature)
);
```

### 1.5 Nota de diseño sobre `picks` — decisión que le corresponde a usted

`picks` es el libro mayor de apuestas **ya colocadas**, y la vía real de entrada es
`SmartUploadButton` / scan bet slip. Un boleto escaneado en la casa **no tiene insumos
de modelo**: no hubo predicción. Propongo que en `picks` la columna sea:

- **NULL por defecto y para todo boleto escaneado.** Jamás rellenada a posteriori:
  reconstruir los insumos después del partido es fabricar historia.
- **Llenada solo por `fn_snap_pick_prediction`** (el trigger que ya existe) cuando el
  pick nace del motor, copiando el JSON de la predicción vigente al momento del alta.

Si prefiere que se llene siempre, dígalo y se implementa — pero entonces habría que
marcar explícitamente `"origen":"reconstruido"` para no contaminar el backtest.

---

## 2. DESACOPLAMIENTO ESTRICTO: DATOS → MODELO → LLM

### 2.1 Tres capas con frontera dura

| capa | qué hace | qué NO puede hacer |
|---|---|---|
| **L1 — Feature store** | `v_features_futbol / _mlb / _nfl`: una fila por evento, cada insumo tipado, fechado y con `estado` | no calcula probabilidad |
| **L2 — Modelo** | SQL determinista. Escribe `probabilidad_real` **y** `features_input_json` en la MISMA transacción | no llama a ningún LLM |
| **L3 — LLM** | lee el número ya calculado y produce prosa | **no puede escribir ni un número** |

### 2.2 La prohibición como candado, no como promesa

Regla de la casa (#180): *una bandera es una promesa que N lectores deben cumplir;
una tabla o un trigger es una garantía estructural.* Por eso:

```sql
-- Trigger propuesto (NO aplicado): tg_prob_solo_del_motor
--  BEFORE INSERT OR UPDATE OF probabilidad_real ON oraculo_picks_tracking
--  Rechaza si:
--    a) probabilidad_real IS NOT NULL Y features_input_json IS NULL
--    b) features_input_json->>'motor' no está en la lista blanca de motores
--    c) el UPDATE cambia probabilidad_real sin cambiar features_input_json
--       (eso es exactamente la firma de un LLM reescribiendo el número)
```

La condición (c) es la importante: hoy nada impide que un paso posterior sobreescriba
la probabilidad. Con el candado, cambiar el número **obliga** a declarar de qué insumos
salió.

### 2.3 Variables avanzadas hacia la matemática

Hoy xG, clima, árbitro, lesiones y rotación en fútbol tienen **peso literal 0**: sus
únicos lectores son funciones de contexto para el LLM. Moverlas a la probabilidad es
el objetivo — pero **no se conecta ninguna sin coeficiente medido**. Disciplina de
#149 y #150: se midió carga de bullpen y NO se conectó porque no había señal; se midió
descanso y SÍ se conectó, encogido a la mitad por n=116. La sección 5 es el mecanismo.

---

## 3. CALIBRACIÓN OUT-OF-SAMPLE

### 3.1 El corpus correcto NO es el de picks

El corpus de picks (n=2,028, 5 meses) tiene dos defectos fatales:

1. **Sesgo de selección**: solo contiene los partidos que el motor eligió. Es el
   confundidor de #169.
2. **Tamaño**: la banda ≥60% tiene entre 13 y 120 filas por mes. Ajustar una isotónica
   por mercado ahí es sobreajuste garantizado — es exactamente lo que produjo el techo
   aplastado de #176.

El corpus correcto es el **backtest del motor contra `historico_partidos_espn`**:
25,673 partidos de fútbol (2024-03 → 2026-09, 58 ligas), donde **todos** los partidos
reciben predicción, se hayan convertido en pick o no. El corpus de picks queda como
conjunto de **validación final**, nunca de ajuste.

### 3.2 Escalera de complejidad, con piso de muestra

| método | parámetros | piso de muestra fuera de muestra |
|---|---|---|
| Temperatura `σ(logit(p)/T)` | 1 | n ≥ 200 por celda |
| Platt `σ(a·logit(p)+b)` | 2 | n ≥ 500 |
| Isotónica | k libre | n ≥ 1,000 **y** ≥ 8 bines con n ≥ 50 |

Se sube de escalón **solo si el escalón superior gana fuera de muestra**. Hoy, sobre
el corpus de picks, ninguna celda llega al piso de la isotónica — por eso #176 sigue
suspendida y esta propuesta no la levanta.

Encogimiento entre celdas: `T_celda = (n·T_ajustada + k·T_global) / (n + k)`, con
k = 200. Una celda con poca muestra hereda la temperatura global en vez de inventar la
suya.

### 3.3 Validación temporal, nunca aleatoria

Walk-forward de 5 pliegues por fecha de partido:

```
pliegue 1: entrena [t0, t1)  prueba [t1, t2)
pliegue 2: entrena [t0, t2)  prueba [t2, t3)
...
```

Partición aleatoria filtraría información del futuro (dos partidos de la misma jornada
del mismo equipo caerían a ambos lados). Prohibida.

### 3.4 Criterio de aceptación declarado ANTES de correrlo

Un método entra a producción solo si cumple **las tres**:

1. Gana en **LogLoss fuera de muestra en ≥ 4 de 5 pliegues** contra el modelo sin calibrar.
2. **Gana también al predictor constante de tasa base.** Si la tasa base gana, el
   mercado **se apaga**, no se calibra.
3. La banda ≥65% queda dentro de ±3 pp de su tasa real, con IC de Wilson que contenga
   la diagonal.
4. **Estabilidad entre pliegues.** Ganar 4 de 5 puede esconder un pliegue desastroso —
   y un pliegue desastroso es la firma del *drift*, no del ruido. Por eso:
   - se **reporta siempre** la desviación estándar de la mejora entre pliegues;
   - **ningún pliegue puede deteriorarse severamente** respecto al baseline sin
     investigación explícita y documentada;
   - "severamente" queda **[SIN UMBRAL FIJO]** a propósito: se fija por deporte y
     mercado cuando haya suficientes ciclos para saber cuál es la dispersión normal.
     Poner un número universal hoy sería la misma intuición sin medir que estamos
     tratando de erradicar.

El criterio 2 es el que convierte la calibración en **diagnóstico** en vez de cosmética.
Con los AUC de la sección 0.2, la predicción honesta es que **Corners y BTTS de fútbol
y Over/Under de MLB fallarán el criterio 2 y deben apagarse**, no calibrarse.

### 3.5 Relación con lo ya cerrado

- **#191** (Platt da 0.66σ en MLB Moneyline) queda **confirmado**, no contradicho:
  concuerda con AUC z = +1.36.
- **#176** (isotónica suspendida) **sigue suspendida**. Este diseño no la levanta;
  la reemplaza por temperatura ajustada sobre backtest.

---

## 4. PROTOCOLO DE CLV REAL

### 4.1 Qué se registra

Tabla nueva `clv_real`, identidad `(pick_id)`:

| columna | regla |
|---|---|
| `momio_entrada` | el precio **efectivamente tomado**. Jamás `odds_apertura`. |
| `momio_cierre_t5` | último snapshot con `snapshot_at < arranca_en` **y** `arranca_en − snapshot_at ≤ 30 min` |
| `snapshot_at_cierre`, `minutos_antes` | se guardan siempre: el retraso es auditable |
| `calidad` | `T-5` (≤5 min) / `T-30` (≤30 min) |
| `clv_pct` | `100 · (momio_entrada / momio_cierre_t5 − 1)` |

**Si no hay snapshot que califique, `clv_pct` queda NULL.** Nunca se aproxima con un
precio de hace 30 horas, y nunca se acepta un precio posterior al saque.

### 4.2 Qué se retira

- `capturar_clv_oraculo` calcula `(odds_apertura / cierre − 1)`: eso es **movimiento de
  línea**, no CLV. Se conserva la columna por historia, renombrada en el vocabulario de
  pantalla a `movimiento_linea_pct`.
- `reto_13m_estado` deja de mostrar `+1.57%` como "le ganamos al cierre". El número que
  mide precio capturado contra cierre es `clv_tracking` = **−7.54%** (n=30), y con n=30
  tampoco concluye: se muestra con su intervalo o no se muestra.
- Ventana `match_date + 5 minutos` (precio EN VIVO): eliminada en ambas funciones de captura.

### 4.3 El cuello de botella es de captura, no de ventana

Hoy solo el **3.8%** de los cierres es T-5 y el **79.3%** son "lejanos" con mediana de
**1,801 minutos (30 h)** antes del saque. La causa es que `snapshot-odds` corre cada 6
horas (`15 */6 * * *`). Ensanchar la ventana no arregla nada: **hay que capturar a T-30**.
Cobertura esperada tras el trabajo dirigido: **[SIN MEDIR]** hasta que corra.

---

## 5. NFL: `NO LISTO (SIN MODELO INDEPENDIENTE)`

### 5.1 Estado

`nfl_predecir` devuelve la cuota de la casa sin vig como si fuera probabilidad del
modelo (líneas 40-47 y 57-62, con `'fuente','mercado'` escrito literal). Los 15 de 15
picks NFL de los últimos 45 días traen `prob_placeholder = true`.

### 5.2 Implementación propuesta del apagado

`mercados_en_abstencion` no sirve aquí: su llave es `patron`, orientada a mercado, no a
deporte. El lugar correcto es la autoridad de dinero que ya existe:

- `reto_picks_hoy.bloqueado_por` ← nuevo valor **`nfl_sin_modelo`**
- `revisar_apuesta` ← rama que rechaza NFL con motivo explícito
- `nfl_predecir` ← etiqueta su propia salida `"es_modelo": false`, para que ningún
  consumidor río abajo pueda confundirla

Insignia en tarjeta: **`NFL — SIN MODELO INDEPENDIENTE`**.

### 5.3 Criterio de reingreso, declarado por adelantado

NFL vuelve a mover dinero cuando un modelo construido sobre `nfl_partidos` histórico +
FPI + `nfl_h2h` cumpla **las dos**:

1. AUC fuera de muestra ≥ 0.55 con n ≥ 250 sobre 2 temporadas, y
2. gane en LogLoss a la línea de la casa sin vig.

Antes de eso: NFL se muestra, no se apuesta.

---

## 6. BACKTEST INCREMENTAL DE xG EN FÚTBOL

### 6.1 Lo que hay (medido)

- **13,077** partidos de fútbol con tiros y tiros a puerta, de 25,673 (**50.9%**),
  **51 ligas**, 2024-03-05 → 2026-09-05.
- El "xG" **no es xG real**: es un proxy de tiros,
  `0.1994·tiros_a_puerta + 0.0648·(tiros − tiros_a_puerta)`.
- `xg_modelo_coef` está en **0 filas**.

### 6.2 Sonda de viabilidad (solo lectura, ya corrida — NO es el backtest)

Predecir los goles de un equipo con su propio promedio móvil de 10 partidos previos,
n = 24,980 filas equipo-partido con ≥6 previos:

| predictor | r con goles del partido | R² |
|---|---|---|
| goles previos | 0.2241 | 0.05023 |
| **proxy de xG previo** | **0.2383** | **0.05676** |

Delta **+0.0141**. El proxy le gana a los goles, poco pero con n grande. **No es prueba**:
es correlación a nivel de goles, no de probabilidad, y sin partición temporal.

### 6.3 Escalera de 4 peldaños, cada uno con criterio de muerte

| peldaño | qué se mide | criterio de muerte |
|---|---|---|
| **0 — nivel λ** | `λ = (1−α)·goles + α·xG_proxy` en `equipo_perfil`. Barrido α ∈ {0, 0.25, 0.5, 0.75, 1.0}, walk-forward por temporada. Métrica: RMSE de goles. | si el mejor α = 0, **se detiene todo aquí** |
| **1 — nivel probabilidad** | la λ ganadora entra a la rejilla Poisson/Dixon-Coles; se puntúan 1X2, O/U 2.5 y BTTS. Métrica: LogLoss y Brier fuera de muestra. | si no le gana al motor actual en ≥4 de 5 pliegues |
| **2 — discriminación** | AUC por mercado sobre el backtest | **AUC ≥ 0.55 con z ≥ 2**, o no toca dinero |
| **3 — contra el mercado** | solo donde pase el peldaño 2: modelo contra línea de cierre real (requiere la sección 4 ya viva) | CLV out-of-sample no positivo ⇒ no se conecta |

**Ningún peldaño se salta y el dinero solo se mueve después del 3.** Es la única prueba
de ventaja que no se puede fabricar desde adentro.

### 6.4 Restricción de cobertura que el diseño debe respetar

El 49.1% de los partidos no tiene tiros. La mezcla debe **degradar con gracia**: donde
falten tiros, `α = 0` para ese equipo y `features_input_json` registra
`{"estado": "ausente"}`. **Prohibido imputar**: imputar es exactamente el defecto de
#107/#108 con otra cara.

---

## 7. ORDEN DE EJECUCIÓN — aprobado por el Auditor Principal (5-sep-2026)

| # | bloque | por qué en ese lugar |
|---|---|---|
| 1 | **Trazabilidad (§1)** | sin ella no se puede auditar nada de lo que sigue |
| 2 | **Desacoplamiento + candado del LLM (§2)** | fijar la frontera datos → modelo → probabilidad → LLM **antes** de meter datos nuevos |
| 3 | **NFL apagado (§5)** | corrección de integridad, inmediata |
| 4 | **CLV real + captura T-30 (§4)** | hay que empezar a acumular el dato correcto cuanto antes: sin historia no hay peldaño 3 |
| 5 | **Modelo / calibración (§3)** | |
| 6 | **Backtest incremental de variables (§6)** | xG, tiros, lesiones, alineaciones, clima, árbitro, descanso |
| 7 | **Pick Quality Score, selección final y Kelly (§8)** | al final, porque consume la salida de todos los anteriores |

Cambio respecto a mi propuesta: el desacoplamiento sube de 4 a 2. Es correcto — poner
el candado antes de conectar variables nuevas evita que el LLM pueda "retocar" un
número que todavía estamos aprendiendo a medir.

---

## 8. PICK QUALITY SCORE (§8) — la capa que faltaba

### 8.1 El problema que resuelve

EV es una estimación puntual de una variable aleatoria cuya distribución conocemos mal.
Dos picks con el mismo EV no valen lo mismo si uno se apoya en datos completos y un
mercado calibrado y el otro en datos huecos y un modelo sin señal.

El PQS **no sustituye al EV**. Hace otras tres cosas: **filtra**, **ordena** y
**dimensiona**.

### 8.2 Componentes, todos en [0,1], todos medidos

| componente | qué mide | de dónde sale |
|---|---|---|
| `q_calibracion` | qué tan calibrado está ESE (deporte, mercado) fuera de muestra | brecha de LogLoss contra tasa base en el walk-forward de §3. **Cero si el mercado falla el criterio 2** |
| `q_discriminacion` | si el modelo ordena | AUC fuera de muestra, mapeado [0.50, 0.60] → [0, 1]. **Cero por debajo de 0.52** |
| `q_datos` | completitud ponderada de insumos | `data_completeness_pct` de §1 |
| `q_muestra` | incertidumbre por tamaño de muestra | límite de Wilson, **ya en producción** (#214) |
| `q_mercado` | acuerdo con el precio | penaliza `abs(p_modelo − p_mercado)` más allá del umbral medido. Generaliza la guarda de #206 |
| `q_clv` | CLV histórico de ese (deporte, mercado, casa) | §4. **NULL hasta que haya historia — nunca se asume 1.0** |
| `q_varianza` | dispersión del resultado | binario en O/U y BTTS; penaliza el precio largo en Moneyline |

### 8.3 Agregación: media **geométrica**, no aritmética

```
PQS = ( Π q_i ) ^ (1/k)      sobre los k componentes medibles
```

La media geométrica se destruye con **un solo** componente cercano a cero — que es
exactamente lo que queremos: un cero mata el pick. La aritmética permitiría que un EV
espectacular tapara la falta de datos. Los componentes NULL **se excluyen del producto
y de k**; jamás se imputan a 1.0 (mismo principio de §6.4).

### 8.4 Los tres usos

1. **Puerta.** `PQS < 0.40` ⇒ no es pick, sin importar el EV.
   Nuevo `bloqueado_por = 'calidad_insuficiente'`.
2. **Dimensionamiento.** `stake = kelly(p_calibrada, momio) × PQS`. Aquí es donde el
   PQS toca el dinero.
3. **Orden.** La lista corta se ordena por **PQS**, no por EV.

El umbral 0.40 está **[SIN MEDIR]**: se fija maximizando el CLV realizado del conjunto
que pasa la puerta, una vez que §4 tenga historia. Hoy es un marcador de posición
declarado, no un número con respaldo.

### 8.5 Su ejemplo, con el mecanismo aplicado

Valores de componente **ilustrativos** (no medidos todavía):

| componente | Pick A (EV +8%, 54%) | Pick B (EV +5%, 68%) |
|---|---|---|
| `q_calibracion` | 0.30 | 0.90 |
| `q_discriminacion` | 0.30 | 0.80 |
| `q_datos` | 0.50 | 1.00 |
| `q_muestra` | 0.80 | 0.95 |
| `q_mercado` | 0.30 | 0.90 |
| `q_clv` | 0.40 | 0.80 |
| `q_varianza` | 0.50 | 0.90 |
| **PQS** | **0.42** | **0.89** |

B ordena por encima de A y recibe **más del doble** de multiplicador de stake, aunque
su EV sea menor. Es exactamente la preferencia que usted expresó — y ahora es una
fórmula auditable, no un criterio de gusto.

Y responde a su preocupación original: un +300 con EV positivo pero `q_datos` bajo y
`q_discriminacion` ≈ 0 **no llega a la puerta**. Ya no depende de un filtro de 48%
puesto a mano.

---

# ANEXO A — RESULTADO DEL BACKTEST DE xG EN FÚTBOL (corrido el 5-sep-2026)

Solo lectura. **Nada conectado a producción.** Peldaños 0, 1 y 2 de §6.3 ejecutados
completos; peldaño 3 pendiente porque exige la infraestructura de §4.

## A.0 Montaje

- Universo: `v_equipo_partido_espn_xg`, partidos de fútbol con tiros y tiros a puerta.
- Medias móviles de los **10 partidos previos** por equipo y competencia, con piso de
  **6 partidos previos** por lado. Todas las ventanas excluyen el partido en curso.
- Ancla de liga: media **expansiva** por competencia hasta el partido anterior
  (`rows between unbounded preceding and 1 preceding`), separada local / visitante.
  Sin fuga temporal por construcción.
- 5 pliegues **temporales** por fecha:

| pliegue | n | desde | hasta |
|---|---|---|---|
| 1 | 2,390 | 2023-08-19 | 2024-05-10 |
| 2 | 2,390 | 2024-05-10 | 2025-01-25 |
| 3 | 2,390 | 2025-01-25 | 2025-08-17 |
| 4 | 2,390 | 2025-08-17 | 2026-02-08 |
| 5 | 2,389 | 2026-02-08 | 2026-09-04 |

Mezcla evaluada, con ambos lados normalizados por su propia media de liga para que la
diferencia de escala entre goles y proxy de xG no sesgue nada:

```
r_ataque  = (1−α)·(gf_prev/media_goles) + α·(xgf_prev/media_xg)
r_defensa = (1−α)·(gc_rival/media_goles) + α·(xgc_rival/media_xg)
λ = media_liga_por_localía · r_ataque · r_defensa
```

## A.1 Peldaño 0 — nivel λ. **PASA 5/5**

RMSE de goles del equipo (n = 23,898 filas equipo-partido):

| α | pl.1 | pl.2 | pl.3 | pl.4 | pl.5 | global |
|---|---|---|---|---|---|---|
| **0.00** (motor actual) | 1.26797 | 1.28423 | 1.27574 | 1.24885 | 1.26973 | **1.26936** |
| 0.25 | 1.22624 | 1.24144 | 1.23428 | 1.21303 | 1.22860 | 1.22875 |
| 0.50 | 1.20222 | 1.21605 | 1.20722 | 1.19093 | 1.20155 | 1.20362 |
| **0.75** | **1.19600** | **1.20798** | **1.19484** | **1.18287** | **1.18903** | **1.19417** |
| 1.00 | 1.20640 | 1.21675 | 1.19697 | 1.18898 | 1.19127 | 1.20012 |

- **α = 0.75 es el mínimo en los cinco pliegues, cada uno por separado.** Estabilidad total.
- α = 0 (lo que corre hoy) es el **peor** en los cinco.
- El óptimo es **interior** (0.75, no 1.00): es una mezcla real, no un resultado degenerado.
- Prueba pareada de errores al cuadrado, α=0 contra α=0.75:
  mejora media **0.185221**, sd 1.124563, **t = 25.46** con n = 23,898.

Criterio de muerte del peldaño 0 (“si el mejor α = 0, se detiene todo”): **no se activa**.

## A.2 Peldaño 1 — nivel probabilidad. **PASA 5/5, y luego 4/4 calibrado**

Poisson sobre las λ; O/U 2.5 con la suma de Poissons, BTTS con `(1−e^−λh)(1−e^−λa)`.
LogLoss fuera de muestra (n = 2,390 por pliegue):

| pliegue | O/U goles | **O/U xG** | BTTS goles | **BTTS xG** |
|---|---|---|---|---|
| 1 | 0.72304 | **0.69027** | 0.72702 | **0.69742** |
| 2 | 0.72209 | **0.68558** | 0.72414 | **0.68827** |
| 3 | 0.73433 | **0.68672** | 0.73181 | **0.69300** |
| 4 | 0.73485 | **0.68734** | 0.72936 | **0.68993** |
| 5 | 0.72788 | **0.67889** | 0.72603 | **0.67858** |

Gana en **5 de 5** en ambos mercados, sin un solo pliegue deteriorado (criterio 4).

Dato que conviene no maquillar: la versión de **solo goles** da LogLoss ≈ 0.727, **peor
que una moneda** (0.693). El motor actual, en estos dos mercados, es peor que no opinar.

### Calibración por temperatura, ajustada fuera de muestra

T ajustada sobre los pliegues **anteriores**, aplicada al pliegue de prueba.
Tasa base también sin fuga (media de los pliegues anteriores, no del propio):

| pliegue de prueba | T ajustada | sin calibrar | **calibrada** | tasa base |
|---|---|---|---|---|
| 2 | 2.0 | 0.68558 | **0.67961** | 0.68531 |
| 3 | 1.8 | 0.68672 | **0.68204** | 0.68973 |
| 4 | 1.8 | 0.68734 | **0.68259** | 0.69129 |
| 5 | 1.8 | 0.67889 | **0.67654** | 0.68409 |

- Criterio 1 (gana al no calibrado): **4 de 4**.
- Criterio 2 (gana a la tasa base): **4 de 4**.
- Criterio 4 (estabilidad): T estable en 1.8–2.0; la ventaja sobre la tasa base va de
  −0.0057 a −0.0087. Ningún pliegue deteriorado.

**T ≈ 1.8 significa compresión**, exactamente el diagnóstico de §0: el modelo ordena
bien y exagera la magnitud.

## A.3 Peldaño 2 — discriminación. **PASA 5/5 en O/U, 5/5 en BTTS**

AUC fuera de muestra, versión xG. `SE ≈ 0.012` por pliegue bajo H0:

| pliegue | tasa Over | **AUC O/U** | tasa BTTS | **AUC BTTS** |
|---|---|---|---|---|
| 1 | 0.5502 | 0.5944 | 0.5615 | 0.5573 |
| 2 | 0.5640 | 0.5813 | 0.5552 | 0.5555 |
| 3 | 0.5435 | 0.5761 | 0.5577 | 0.5381 |
| 4 | 0.5351 | 0.5709 | 0.5435 | 0.5493 |
| 5 | 0.5710 | 0.5825 | 0.5710 | 0.5693 |

Puerta del peldaño 2 (AUC ≥ 0.55 con z ≥ 2): **O/U la pasa en los 5 pliegues**
(z ≈ 5.9 a 7.9); **BTTS la pasa en 4 de 5** (el pliegue 3 con 0.5381 queda en z ≈ 3.2,
por encima de 2 pero por debajo del piso de 0.55).

## A.4 Qué significa y qué NO significa

**Significa** que el proxy de xG **sí añade señal fuera de muestra**, medido con
partición temporal, en tres niveles independientes y con estabilidad entre pliegues.
Es la primera variable del sistema con esa demostración.

**NO significa que haya ventaja de apuesta.** Todo esto es modelo contra **resultado**,
no modelo contra **precio**. La casa puede seguir siendo mejor que este modelo. Esa es
la pregunta del **peldaño 3**, que exige la línea de cierre real de §4 y hoy no se
puede responder: solo el 3.8% de los cierres registrados es T-5 de verdad.

**Ningún dinero se mueve hasta el peldaño 3.**

## A.5 Reservas honestas

1. **Es un proxy de tiros, no xG.** `0.1994·SOT + 0.0648·(tiros − SOT)`, con coeficientes
   que ya venían ajustados en la vista. No se re-ajustaron aquí: si se ajustaron alguna
   vez sobre este mismo histórico, parte de la ventaja podría ser residual de ese ajuste.
   **Pendiente:** re-ajustar los dos coeficientes solo con datos anteriores al pliegue 1
   y repetir. Hasta entonces el resultado queda marcado como **fuerte pero no definitivo**.
2. **Cobertura 50.9%.** El backtest solo ve partidos con tiros. En producción hay que
   degradar con α = 0 donde falten, y registrar `"estado":"ausente"`. Prohibido imputar.
3. **Piso de 6 partidos previos** por lado: los equipos recién ascendidos o de copa con
   pocos partidos quedan fuera del backtest y quedarán fuera del beneficio.
4. **Falta 1X2.** Solo se midieron O/U 2.5 y BTTS, que tienen forma cerrada. Moneyline
   exige la rejilla Dixon-Coles completa y queda pendiente.
5. **Corners no se tocó.** Sigue con AUC 0.3109 (invertido, 3.56σ) en producción, y este
   backtest no lo mejora: la vista no trae proxy de corners esperados.

---

# ANEXO B — EJECUCIÓN DE LOS 5 PASOS (5-sep-2026)

Regla 360°: inspección → diagnóstico previo → dependencias → cambio reversible → pruebas.

## PASO 1 — Trazabilidad + candado anti-LLM. APLICADO

**Diagnóstico previo:** `oraculo_picks_tracking` 3,458 filas (3,200 con `probabilidad_real`);
`picks` 34 filas y **0 columnas de probabilidad**. 6 escritores SQL, todos INSERT,
**ninguno hace UPDATE de `probabilidad_real`**; el único `ON CONFLICT` es `DO NOTHING`.

**DDL:** columnas `features_input_json jsonb` + `data_completeness_pct numeric` en ambas
tablas, `CHECK` de rango 0-100, índice GIN sobre `->'entradas'`, índice parcial de
completitud, tabla `feature_pesos`, y `COMMENT ON` documentando la prohibición de
reconstruir insumos a posteriori.

**Validador** `features_input_valido(jsonb)`: exige `schema=1`, `motor`, `entradas`, y por
cada hoja `{v, src, estado}` con `estado ∈ (ok|fallback|ausente|fuera_de_rango)`;
`fallback` obliga `v_usada`; `ok` con `v` nulo se rechaza (el defecto de #107/#108).

**Triggers:** `zzz_prob_solo_del_motor` (BEFORE INSERT OR UPDATE en
`oraculo_picks_tracking`) y `zzz_valida_features_picks` (en `picks`).
Regla central: **no se puede cambiar `probabilidad_real` sin cambiar
`features_input_json`.** Escotilla documentada: `app.mantenimiento_trazabilidad='on'`.

**Procesos AUTORIZADOS explícitamente** (probados, pasan sin fricción):
calificación de resultado, escritura de CLV/`odds_cierre`, aprendizaje, recalibración
(escriben en `calibracion_isotonica`, no aquí) y escritores aún no migrados
(insert con `features_input_json` NULL).

**Registros previos incompatibles: 0.** Las 3,458 filas quedan con `features_input_json`
NULL, que el validador acepta.

**Pruebas: 11 de 11.**

| # | prueba | esperado | resultado |
|---|---|---|---|
| 1 | insert con sobre válido | PASA | PASÓ |
| 2 | mover prob sin declarar insumos | BLOQUEA | `TRAZABILIDAD: no se puede cambiar probabilidad_real (0.55 -> 0.77)...` |
| 3 | mover prob declarando insumos | PASA | PASÓ |
| 4 | calificar resultado (legítimo) | PASA | PASÓ |
| 5 | escribir CLV (legítimo) | PASA | PASÓ |
| 6 | estado fuera de vocabulario | BLOQUEA | `...estado invalido: inventado` |
| 7 | dice ok con valor nulo | BLOQUEA | `...dice ok con v nulo` |
| 8 | fallback sin `v_usada` | BLOQUEA | `...dice fallback pero no declara v_usada` |
| 9 | escritor no migrado (compat) | PASA | PASÓ |
| 10 | escotilla de mantenimiento | PASA | PASÓ |
| 11 | limpieza de filas de prueba | 2 borradas | 2 borradas |

Nota: el primer arnés dio 4 falsos negativos porque `fuente='prueba'` viola
`oraculo_picks_tracking_fuente_check` y el INSERT nunca ocurrió. Se corrigió con
`fuente='oraculo'` y una guarda `IF v_id IS NULL THEN RAISE`.

## PASO 2 — NFL OFF + Corners OFF. APLICADO

Mecanismo: tabla `mercados_sin_modelo(etiqueta, patron_deporte, patron_mercado, motivo,
evidencia, criterio_reingreso, desde, activo)` + `sin_modelo_independiente(deporte, mercado)`.
**Reactivación = `activo=false`.** No se borró ni un registro histórico.

| etiqueta | evidencia registrada | criterio de reingreso |
|---|---|---|
| `nfl_sin_modelo` | `nfl_predecir` líneas 40-47/57-62 escriben `'fuente','mercado'`; 15/15 picks con `prob_placeholder=true` | AUC ≥ 0.55, n ≥ 250, 2 temporadas, Y ganar en LogLoss a la línea sin vig |
| `corners_sin_modelo` | AUC 0.3109, n=119, **z = −3.56** (invertido); banda ≥65% proyecta 81.6% y rinde 48.8% | AUC ≥ 0.55 con z ≥ 2 sobre backtest temporal con una fuente de corners esperados que hoy no existe |

Cirugía con candado de aborto en 3 funciones (1 sola versión de cada una después):
`revisar_apuesta` (nivel `bloqueado` + razón escrita), `reto_picks_hoy`
(`bloqueado_por='sin_modelo'`, prioridad máxima), `nfl_predecir`
(`"es_modelo": false` en el contexto **y entrada por entrada**).

**Pruebas de vocabulario: 12/12.** Atrapa `football`, `football/nfl`,
`🏈 Futbol Americano`, `NFL`, `NFL Pretemporada`, `Corners`, `Tiros de esquina`.
**Falsos positivos: 0** sobre todas las ligas/endpoints de la base
(`⚽ Fútbol`, `soccer`, `⚾ Beisbol`, `🏀 Baloncesto`, `🎾 Tenis` pasan).

**Prueba funcional:** NFL ML → `bloqueado/permitir=false/nfl_sin_modelo`;
Corners → `bloqueado/corners_sin_modelo`; control Fútbol O/U → `advertencia/permitir=true`
(sin cambio). MLB ML sale `bloqueado` pero por el veto RONGOL preexistente (EV −10.51%),
no por este cambio.

`nfl_predecir()` re-ejecutada: **272 partidos**, 272 contextos con `es_modelo:false`,
**1,376 entradas de mercado marcadas** una por una (solo 17 con `es_modelo:true`).

## PASO 3 — CLV: infraestructura SÍ, operación NO

`clv_real` creada con **4 garantías estructurales** (CHECK, no promesas):

1. `snapshot_at_cierre < arranca_en` — imposible guardar un precio en vivo.
2. `minutos_antes ∈ (0, 30]` — un precio de hace 30 horas **no cabe en la tabla**.
3. `clv_pct` NULL ⟺ sin cierre válido — jamás aproximado.
4. la calidad se deriva del reloj: `T-5` exige ≤5 min, `T-30` exige >5.

**Pruebas: 6/6** (4 negativas rechazadas por el CHECK correcto, 2 positivas aceptadas).

**COBERTURA REAL MEDIDA — NO declaro el CLV operativo:**

| métrica | valor |
|---|---|
| eventos jugados en 30 días | 1,734 |
| con algún snapshot | 466 (**26.9%**) |
| **califican a T-30** | **119 (6.9%)** |
| califican a T-5 | 25 (1.4%) |
| mediana de retraso | **129.9 minutos** |

Doble cuello de botella: el 73% de los eventos **no tiene ni un precio**, y de los que sí,
solo una cuarta parte llega cerca del saque. `snapshot-odds` corre `15 */6 * * *`
(cada 6 horas). **La infraestructura existente NO puede capturar T-30 de forma
suficiente.** `q_clv` sigue NULL en el PQS.

## PASO 4 — xG re-estimado SIN fuga. α=0.75 SE OFICIALIZA

**Fecha de corte: 2024-10-05** (percentil 33 de las 32,184 filas equipo-partido).
Ajuste de `a` y `b` por mínimos cuadrados **solo con datos anteriores** a esa fecha;
prueba solo con datos posteriores.

| | a (SOT) | b (tiros fuera) |
|---|---|---|
| **re-estimado limpio** (n entrenamiento = 10,588) | **0.353492** | **−0.024323** |
| en producción hoy | 0.1994 | 0.0648 |

El `b` sale **negativo**: con los mismos tiros a puerta, más tiros fuera predice MENOS
goles. Plausible (disparo desperdiciado) pero cambia la naturaleza del objeto — ya no es
"xG", es un índice de calidad de tiro. Se reporta, no se maquilla.

### Peldaño 0 — RMSE, 5 folds, solo periodo de prueba (n = 3,491 por fold)

| α | f1 | f2 | f3 | f4 | f5 | promedio | sd entre folds |
|---|---|---|---|---|---|---|---|
| **0.00** (motor actual) | 1.29525 | 1.26051 | 1.27915 | 1.22247 | 1.28799 | **1.26907** | 0.02911 |
| 0.25 | 1.26173 | 1.23091 | 1.24747 | 1.19419 | 1.25763 | 1.23839 | 0.02742 |
| 0.50 | 1.24149 | 1.21268 | 1.22869 | 1.17768 | 1.23887 | 1.21988 | 0.02616 |
| **0.75** | **1.23462** | **1.20630** | **1.22292** | **1.17351** | **1.23199** | **1.21387** | **0.02513** |
| 1.00 | 1.24100 | 1.21185 | 1.23010 | 1.18212 | 1.23712 | 1.22044 | 0.02417 |

**α=0.75 es el mínimo en 5/5 folds.** t pareado (α=0 vs α=0.75): **18.13** con n=17,454.

### Peldaño 1 — LogLoss

| fold | O/U goles | O/U xG | tasa base (sin fuga) | BTTS goles | BTTS xG |
|---|---|---|---|---|---|
| 1 | 0.72448 | 0.70167 | 0.69315 | 0.72863 | 0.70232 |
| 2 | 0.73010 | 0.69774 | 0.69143 | 0.73409 | 0.70413 |
| 3 | 0.73862 | 0.69544 | 0.68752 | 0.72988 | 0.69922 |
| 4 | 0.73663 | 0.69907 | 0.69022 | 0.73252 | 0.70058 |
| 5 | 0.72272 | 0.68838 | 0.68402 | 0.72027 | 0.68592 |

xG le gana al motor actual **5/5 en ambos mercados**. **Sin calibrar NO le gana a la tasa
base en ningún fold (0/5)** — dato incómodo que se reporta tal cual.

### Con calibración por temperatura ajustada fuera de muestra

| fold | T | sin calibrar | **calibrada** | tasa base |
|---|---|---|---|---|
| 2 | 2.4 | 0.69774 | **0.68334** | 0.69143 |
| 3 | 2.4 | 0.69544 | **0.68272** | 0.68752 |
| 4 | 2.4 | 0.69907 | **0.68436** | 0.69022 |
| 5 | 2.4 | 0.68838 | **0.67870** | 0.68402 |

Criterio 1: **4/4**. Criterio 2 (gana a tasa base): **4/4**. Criterio 4: T = 2.4 idéntica
en los cuatro folds. Brier calibrado 0.24283–0.24570, todos bajo 0.25.

### Peldaño 2 — AUC (SE ≈ 0.012 por fold)

| fold | AUC O/U | AUC BTTS | Brier O/U xG |
|---|---|---|---|
| 1 | 0.5674 | 0.5462 | 0.25204 |
| 2 | 0.5713 | 0.5327 | 0.25132 |
| 3 | 0.5722 | 0.5376 | 0.24988 |
| 4 | 0.5605 | 0.5408 | 0.25236 |
| 5 | 0.5841 | 0.5682 | 0.24631 |

O/U pasa la puerta (≥0.55) en **5/5**. BTTS solo en **1/5** — BTTS **no** pasa el peldaño 2.

### DECISIÓN

**α = 0.75 SE OFICIALIZA**, solo para **Fútbol Over/Under 2.5**, y solo como hallazgo
de backtest — **no se conectó a producción en esta interacción**. Cumple las cuatro
reglas: mantiene superioridad fuera de muestra, gana 5/5 folds, la mejora no depende de
un fold (sd 0.025, todos mejoran), y sobrevivió al reajuste limpio de `a,b`.

**BTTS no se oficializa**: falla el peldaño 2 en 4 de 5 folds.
**Peldaño 3 (contra el precio) sigue sin poder ejecutarse**: requiere el CLV del paso 3,
que hoy cubre 6.9%.

## PASO 5 — MLB, peldaño 0

### Criterio de disponibilidad temporal — dos hallazgos

1. **`mlb_stats_cache` SÍ prueba disponibilidad.** Tiene `cached_at`: **1,221 de 1,224
   filas capturadas ANTES del juego**, mediana 12.08 horas antes. 3 filas contaminadas
   (0.2%) excluidas.
2. **`mlb_forma_temporada` NO puede usarse: es fuga.** Su esquema es
   `(temporada, equipo, juegos, rpg, permitidas_pg)` — **sin fecha de corte**. Guarda el
   agregado de la temporada EN CURSO. Usarla para un juego de junio mete resultados de
   agosto. Y es la fuente del bloque de peso más alto en producción (`EXP_DEF = 0.50`,
   documentado como "las carreras permitidas resultaron más confiables que la ofensiva").
   Se **reconstruyó leak-free** desde el log de 7,323 juegos de `historico_partidos_espn`.

Corpus limpio: **1,086 juegos** (2,172 filas equipo-juego), 434 por fold, 2026-05 a 2026-09.

### Ablación incremental con los exponentes DE PRODUCCIÓN

| modelo | RMSE promedio | sd entre folds |
|---|---|---|
| **M0 base liga (local/visita)** | **3.27214** | 0.14533 |
| M1 + ofensiva propia | 3.28078 | 0.15569 |
| M2 + defensa rival | 3.28155 | 0.16112 |
| M3 + abridor rival FIP/ERA | 3.28485 | 0.15840 |
| M4 + platoon L/R | 3.28483 | 0.15842 |
| M5 + fatiga bullpen | 3.28969 | 0.15668 |
| M6 + park factor | 3.28360 | 0.15554 |

**Con los pesos de producción, TODAS las variables empeoran el modelo.** El platoon mueve
el RMSE en −0.00002: es indistinguible de no existir.

### Barrido del exponente — no era la variable, era el peso

| exponente | RMSE global |
|---|---|
| 0.0 (constante) | 3.27472 |
| **0.2** | **3.25892** |
| 0.4 | 3.27158 |
| **0.5 (PRODUCCIÓN HOY)** | 3.28237 |
| 0.8 | 3.35100 |
| 1.0 | 3.39340 |

| modelo | f1 | f2 | f3 | f4 | f5 | prom | t pareado |
|---|---|---|---|---|---|---|---|
| exp 0.0 (constante) | 3.3592 | 3.4545 | 3.2690 | 3.0750 | 3.2030 | 3.27214 | — |
| **exp 0.2** | **3.3549** | **3.4404** | **3.2590** | **3.0535** | **3.1729** | **3.25611** | **2.39** |
| exp 0.5 (producción) | 3.3984 | 3.4683 | 3.2971 | 3.0776 | 3.1810 | 3.28448 | — |

### Decisión MLB

- **Hay señal, pero es pequeña**: exp 0.2 gana al constante en 5/5 folds, t = 2.39.
- **Producción sobrepondera 2.5×**: con exp 0.5 el modelo es **peor que no pensar** en
  4 de 5 folds.
- **NINGUNA variable se conecta ni se reajusta hoy.** El exponente 0.2 se eligió barriendo
  sobre **todos** los folds, así que ese 5/5 y ese t=2.39 son **optimistas por selección
  sobre el conjunto de prueba**. Antes de oficializar hace falta un ajuste anidado
  (elegir el exponente solo con folds anteriores). Queda pendiente y declarado.
- Bullpen (`EXP_BULLPEN=0.00`) y alineación (`PESO_ALINEACION=0.00`) **ya estaban
  apagados** en producción con medición previa (#150, #135). El backtest lo confirma:
  ambos empeoran.

---

# ANEXO C — FASE 2, DESBLOQUEO: 4 RIESGOS OPERATIVOS (5-sep-2026)

## 1. P0 — Fuga temporal de MLB EXTIRPADA

**Diagnóstico previo, cuantificado.** Para juegos del **20-may-2026**,
`mlb_forma_temporada` reportaba **165-169 juegos jugados**: la temporada completa.
La versión leak-free ve 77-82. Sesgo real medido:

| equipo (juego 20-may) | juegos leak-free | juegos que reportaba | RPG real | RPG con fuga | sesgo |
|---|---|---|---|---|---|
| Philadelphia Phillies | 78 | **165** | 4.3718 | 4.564 | +0.1922 |
| Detroit Tigers | 77 | **163** | 4.3766 | 4.534 | +0.1574 |
| Miami Marlins | 77 | **163** | 4.0390 | 4.178 | +0.1390 |
| Washington Nationals | 77 | **166** | 4.8442 | 4.940 | +0.0958 |
| Los Angeles Angels | 82 | **169** | RA 5.4512 | RA 4.840 | **RA −0.61** |

**Funciones nuevas:** `mlb_forma_hasta(equipo, hasta)` y `mlb_liga_rpg_hasta(hasta)`,
ambas sobre `historico_partidos_espn` con `fecha < p_hasta` y misma temporada. Los 31
nombres de equipo del caché cruzan 31/31 con el histórico: **sin puente de alias**.
Dos índices parciales para el acceso.

### Diff aplicado en `predecir_mlb()`

```diff
-  SELECT round(avg(f.rpg),3) INTO liga_rpg
-    FROM mlb_forma_temporada f WHERE f.temporada = v_temp AND f.juegos >= 50;
-  liga_rpg := COALESCE(liga_rpg, 4.40);
-
-  SELECT * INTO ft_h FROM mlb_forma_temporada f
-   WHERE f.equipo = m.home_team AND f.temporada = v_temp;
-  SELECT * INTO ft_a FROM mlb_forma_temporada f
-   WHERE f.equipo = m.away_team AND f.temporada = v_temp;
+  -- === 5-sep-2026 (FASE 2 P0): EXTIRPADA LA FUGA TEMPORAL ===
+  -- mlb_forma_temporada guarda el agregado de la temporada COMPLETA y NO tiene
+  -- fecha de corte. Para un juego del 20-may reportaba 165-169 juegos jugados:
+  -- es decir, resultados de agosto alimentando una prediccion de mayo. Sesgo
+  -- medido en RPG: +0.09 a +0.19 carreras; en carreras permitidas hasta 0.61
+  -- (Angels 5.45 real hasta esa fecha contra 4.84 de fin de temporada).
+  -- Sustituida por acumulado movil ESTRICTO: solo partidos anteriores al juego.
+  -- El corte es game_date, no now(): asi un backtest reproduce lo que el motor
+  -- habria sabido ese dia, y no lo que se supo despues.
+  liga_rpg := COALESCE(public.mlb_liga_rpg_hasta(COALESCE(m.game_date, now())), 4.40);
+
+  SELECT * INTO ft_h FROM public.mlb_forma_hasta(m.home_team, COALESCE(m.game_date, now()));
+  SELECT * INTO ft_a FROM public.mlb_forma_hasta(m.away_team, COALESCE(m.game_date, now()));
```

**Verificación:** **0 líneas de CÓDIGO** referencian `mlb_forma_temporada` (queda 1
mención, en el comentario que documenta la extirpación); 3 líneas usan las funciones
leak-free; 1 sola versión de `predecir_mlb`.

*Corrección de mi propia verificación:* mi primer chequeo dio "sigue usando la tabla
con fuga" porque el grep abarcaba **mi propio comentario**. El chequeo estricto
(excluyendo líneas `--`) da 0.

**Prueba funcional** (Dodgers vs Nationals, 7-sep): `ok=true`, λ local **4.818**,
λ visita **4.316**, total esperado **9.13**, gana local **56.1%**, marcador más probable
5-4, `aviso_modelo: ok`. `liga_rpg` leak-free = **4.589**.

## 2. P0/P1 — Captura CLV a 15 minutos, DIRIGIDA

**Análisis de costo hecho ANTES de aplicar** (constante permanente: no comprometer
gasto recurrente en silencio). `snapshot-odds` consume The Odds API, que es de pago.

| variante | disparos/día | multiplicador | ¿apunta al cierre? |
|---|---|---|---|
| hoy (`15 */6 * * *`, condición "algún juego en 30h") | 4 | 1× | **no** |
| `*/15` literal, misma condición | 96 | **24×** | no |
| **`*/15` + condición T-30..T-5 (aplicada)** | **31.7** | **7.9×** | **sí** |

Medido sobre 673 slots de 15 min en 7 días: 222 (33.0%) tienen un partido entrando a la
ventana. Como la ventana dura 25 min y el reloj tiene paso de 15, **todo partido recibe
al menos un disparo dentro de ella**. La variante dirigida cumple las dos mitades de la
orden con **un tercio** del consumo de la literal.

```diff
- schedule: '15 */6 * * *'
+ schedule: '*/15 * * * *'

-  IF EXISTS (SELECT 1 FROM live_scores
-             WHERE status='scheduled'
-               AND game_date BETWEEN now() AND now() + interval '30 hours')
+  IF EXISTS (SELECT 1 FROM live_scores
+             WHERE status = 'scheduled'
+               AND game_date BETWEEN now() + interval '5 minutes'
+                                 AND now() + interval '30 minutes')
```

**Segundo cambio, no pedido pero necesario** — `cierre-momios-espn` (jobid 347) traía
precios de hasta 15 min **después** del saque, que son precios EN VIVO:

```diff
-    body:='{"antes_min":90,"despues_min":15,"limite":120}'::jsonb,
+    body:='{"antes_min":90,"despues_min":0,"limite":120}'::jsonb,
```

`clv_real` ya los rechaza por CHECK, pero la fuente no debe producirlos.

**Verificado:** jobid 246 → `*/15 * * * *`, activo, condición dirigida presente.
jobid 347 → `despues_min:0` presente, activo.

## 3. P1 — Contrato de frontend

Diff aplicado en `src/pages/Reto13M.tsx` (2 líneas, nada más en ese archivo):

```diff
           muestra_chica:{ texto: "SIN MUESTRA PARA MEDIRLO", ... },
+          sin_modelo:   { texto: "SIN MODELO INDEPENDIENTE",         color: "#fca5a5", fondo: "rgba(220,60,60,0.12)", borde: "rgba(220,60,60,0.38)" },
+          partido_fantasma:{ texto: "PARTIDO REPROGRAMADO O SUSPENDIDO", color: "#9ca3af", fondo: "rgba(160,160,160,0.10)", borde: "rgba(160,160,160,0.30)" },
         };
         const i = INSIGNIA[p.bloqueado_por];
```

Se agregaron **dos**, no una: `partido_fantasma` también faltaba y ya es un valor vivo
que devuelve `reto_picks_hoy` desde #205. Habría sido el mismo hueco silencioso.
Las 8 entradas previas, el tipo del `Record`, el lookup y el `if (!i) return null;`
quedan intactos. `src/integrations/supabase/types.ts` se regeneró solo.

## 4. P1 — Validación anidada del exponente MLB

**Protocolo:** 5 pliegues temporales. Para cada pliegue de prueba k (2..5), el exponente
se elige **únicamente con los pliegues < k**, y luego se evalúa sobre k. **Cero selección
sobre el pliegue de prueba.** Rejilla: 0.0, 0.1, 0.2, 0.3.

| pliegue de prueba | exponente elegido (sin ver la prueba) | n | RMSE anidado | RMSE constante | RMSE producción (0.5) | ¿le gana al constante? |
|---|---|---|---|---|---|---|
| 2 | **0.1** | 434 | **3.44427** | 3.45451 | 3.46826 | SÍ (+0.01024) |
| 3 | **0.2** | 434 | **3.25895** | 3.26898 | 3.29712 | SÍ (+0.01003) |
| 4 | **0.2** | 434 | **3.05347** | 3.07503 | 3.07763 | SÍ (+0.02157) |
| 5 | **0.2** | 434 | **3.17289** | 3.20299 | 3.18101 | SÍ (+0.03010) |

- **4 de 4 pliegues.** Prueba pareada agrupada: mejora media 0.115036, sd 1.799598,
  **t = 2.66** con n = 1,736.
- **Selección estable:** 0.2 en tres de los cuatro; 0.1 solo en el que menos datos de
  entrenamiento tiene.
- **Producción (0.5) es PEOR que el constante en 3 de 4 pliegues.**

**El hallazgo anterior sobrevive a la validación anidada**, y con esto se retira la
reserva que yo mismo había declarado ("optimista por selección sobre el conjunto de
prueba"). t=2.66 es significativo pero modesto: **el exponente NO se cambió en
producción en esta interacción** — el mandato pedía la validación, no el despliegue.
