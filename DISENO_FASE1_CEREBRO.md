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

---

# ANEXO D — CIERRE OPERACIONAL FASE 1.5 (5-sep-2026)

## Dependencias temporales de `predecir_mlb` (inspección completa)

| capa | objeto | corte temporal |
|---|---|---|
| directas | `mlb_stats_cache` | `cached_at` (1,221/1,224 pre-juego) |
| directas | `mlb_forma_hasta()`, `mlb_liga_rpg_hasta()` | `fecha < game_date` ✅ |
| directas | `calibracion_coef`, `v_momios_confiables` | `vigente` / `snapshot_at` |
| puras | `ajuste_platoon`, `contraer_media`, `matriz_poisson` | sin tablas |
| aux | `calibrar_prob_motor` → `calibracion_coef`, `calibracion_rango_mercado` | `vigente` (deriva de calibración) |
| aux | `clima_partido_mlb` → `mlb_clima_hora`, `mlb_estadios`, `mv_temp_parque` | `mv_temp_parque` **sin fecha** |
| aux | `fuerza_alineacion` → `mlb_alineacion`, `mlb_bateador_temporada` | **`max(snapshot)` SIN corte** ⚠️ |

Los 5 usos de `now()` son todos `COALESCE(m.game_date, now())`: `now()` solo es respaldo cuando falta `game_date`.

## TAREA 1 — resultado

Partido 1 `401815421` Phillies vs Reds, 2026-05-20. Mutación: 20 partidos de agosto 30-0.
**Salida JSON completa byte-idéntica.** λ 5.264/4.991, p_local 53.5%, total 10.26.

Partido 2 `401816712` Cardinals vs Pirates, 2026-08-29 (elegido porque **sí** ejercita
`fuerza_alineacion`). Mutación: 25 partidos de septiembre 40-0 + snapshot de bateo
fechado **2026-12-31**.

| objeto | A | B | veredicto |
|---|---|---|---|
| λ local | 4.524 | 4.524 | idéntico |
| λ visita | 4.186 | 4.186 | idéntico |
| prob local | 54.5% | 54.5% | idéntico |
| `desglose.factor_alineacion_local` | **1.15** | **1.0000** | **CAMBIÓ** |
| `desglose.factor_alineacion_visita` | **0.9734** | **1.0000** | **CAMBIÓ** |

Rollback verificado en ambas: 42,317 → 42,317 filas de histórico, 1,420 → 1,420 de bateo,
`max(snapshot)` 2026-09-04 sin cambio, 0 residuo.

**Hallazgo #214 (nuevo, severidad MEDIA):** `fuerza_alineacion` línea 25 hace
`ult as (select max(snapshot) s from mlb_bateador_temporada)` — toma siempre el snapshot
más reciente, sin importar la fecha del partido. Para un juego de mayo usaría bateo de
septiembre. **Es fuga temporal viva.** Hoy NO llega a la predicción porque
`PESO_ALINEACION = 0.00`, así que λ y probabilidades son invariantes. Es una **fuga
dormida**: si alguien sube ese peso, se activa. NO se arregló (fuera del alcance de este
turno, por regla explícita).

## TAREA 2 — writer CLV

Regla de cierre determinista:
`snapshot_at < arranca_en` AND `arranca_en - snapshot_at <= 30 min`; entre varios, el de
`snapshot_at` mayor (desempate `bookmaker`, luego `id`); `T-5` si ≤5 min, si no `T-30`;
sin candidato válido **NO se inserta fila**.

Fórmula: `clv_pct = 100 * (momio_entrada / momio_cierre - 1)`. **No inventada**: las dos
implementaciones correctas existentes son algebraicamente idénticas —
`clv_capturar_cierre` usa `100*(momio_apostado/mc - 1)` y `capturar_clv_pick` usa
`((1/cierre - 1/apostado)/(1/apostado))*100`, que se reduce a lo mismo.

8/8 tests PASS. End-to-end real: **153 filas** (33 T-5, 120 T-30), 0 sin CLV,
0 violaciones post-saque, rango 0.07–29.96 min, idempotencia confirmada (2ª corrida = 0).

**Hallazgo #215 (nuevo, severidad ALTA — solo reportado):** el CLV medio de esas 153
filas es **+5.58%**, y hay casos como evento 401884811 con entrada 2.27 contra cierre
1.588 = **+42.95%**. Un CLV así de alto y consistente NO es creíble; lo más probable es
que `oraculo_picks_tracking.momio_mercado` no sea siempre un precio realmente capturado
(la tabla tiene una columna `momio_fantasma`). **La tubería CLV funciona; la calidad del
precio de ENTRADA que la alimenta no está validada.** No se tocó.

## TAREA 3 — shadow MLB

`mlb_shadow_predicciones` + `mlb_shadow_generar()`. Escribe dos filas por evento:
`prod_espejo_0.5` y `shadow_0.2`, sobre las MISMAS features leak-free (rolling con corte
en `game_date`, caché con `cached_at < game_date`). Excluye `fuerza_alineacion` por el
hallazgo #214, declarándolo en `features_input_json.excluidas`.

Aislamiento verificado con captura antes/después: `reto_picks_hoy` idéntico,
EV 62.7 = 62.7, stake 156.01 = 156.01, apostables 2 = 2, `predecir_mlb` con hash idéntico,
`picks` 34 = 34, `oraculo_picks_tracking` 3,462 = 3,462. **0 funciones, 0 vistas y 0 crons
leen la tabla shadow.**

**Nota de honestidad:** las 800 filas son un **backfill de partidos pasados**, generado
hoy. Por eso `prediction_timestamp > game_date` en las 800. Su integridad temporal viene
del **corte de features en `game_date`**, no del reloj de generación. Las filas futuras,
generadas antes del juego, sí tendrán `prediction_timestamp < game_date`. Ambas columnas
se guardan precisamente para poder distinguirlo.

---

# ANEXO E — TURNO QUIRÚRGICO: #214, calibracion_coef, forense del CLV (5-sep-2026)

## TAREA 1 — #214 CORREGIDO. PASS

**Semántica verificada antes de tocar:** `snapshot` es `date` (no timestamp), servidor en
UTC. Con granularidad de día **no se puede probar** que un snapshot del MISMO día del
partido sea anterior al primer lanzamiento → el corte es **estricto (`<`)**.

Solo existen **3 snapshots**: 2026-09-02 / 09-03 / 09-04.

**Consumidores de `mlb_bateador_temporada`:**

| objeto | tipo | ¿tenía corte? | acción |
|---|---|---|---|
| `fuerza_alineacion` | producción (vía `predecir_mlb`) | **NO** | **CORREGIDO** |
| `mlb_bat_pedir` / `mlb_bat_recoger` | cargadores (ingesta) | N/A | sin cambio |
| `mlb_shadow_generar` | observacional | **falso positivo**: 0 lecturas reales, el match era un literal de texto en `excluidas` | sin cambio |
| `v_equipo_platoon` | vista | **0 consumidores** (muerta) | sin cambio |

**Diff aplicado en `fuerza_alineacion`:**

```diff
-  select c.mlb_game_pk, ev.hid, ev.aid,
+  select c.mlb_game_pk, ev.hid, ev.aid, c.game_date,   -- corte_temporal_214

-ult as (select max(snapshot) s from mlb_bateador_temporada),
+ult as (select max(b.snapshot) s from mlb_bateador_temporada b, ctx
+         where b.snapshot < (ctx.game_date at time zone 'UTC')::date),

-   where al.lado = p_lado
+   where al.lado = p_lado and al.cargado_at < ctx.game_date   -- corte_temporal_214
```

**Segundo vector encontrado y cerrado:** la alineación misma. **459 de 936** filas de
`mlb_alineacion` cruzables tenían `cargado_at` **posterior** al inicio del juego.
Arreglar solo el snapshot de bateo habría dejado la feature contaminada por el otro lado.

**Prueba adversarial (3 vectores simultáneos: 25 partidos futuros 40-0 + snapshot de bateo
2026-12-31 + 9 bateadores cargados 5 días después del juego):**

| partido | fecha | factor home A→B | factor away A→B | λ local | prob local | JSON completo |
|---|---|---|---|---|---|---|
| `401816798` Phillies-Braves | 4-sep | **1.1014 → 1.1014** | **0.8978 → 0.8978** | 3.865 = 3.865 | 46.3 = 46.3 | **IDÉNTICO** |
| `401816712` Cardinals-Pirates | 29-ago | NULL → NULL | NULL → NULL | 4.524 = 4.524 | 54.5 = 54.5 | **IDÉNTICO** |

Rollback: 0 residuo en `historico_partidos_espn`, `mlb_bateador_temporada` y
`mlb_alineacion`; `max(snapshot)` de vuelta en 2026-09-04.

**Costo honesto del arreglo:** los juegos con factor de alineación pasan de ~la mayoría a
**14 de 1,224**. No es una regresión: es que la tabla de bateo guarda 3 días de historia y
la mitad de las alineaciones se cargan después del juego. Antes ese hueco se tapaba con
datos del futuro. Sin impacto en λ (`PESO_ALINEACION = 0.00`).

## TAREA 2 — `calibracion_coef`. **FAIL**

**Semántica temporal:** `calibracion_coef(id, ajustado_at, a, b, muestra, tasa_base,
vigente, nota, rango_min, rango_max, deporte, origen)`. **NO tiene versionado temporal**:
0 columnas `effective_from`/`effective_to`. 7 filas, 3 con `vigente=true`
(soccer id 7, baseball id 6, football id 3), todas ajustadas entre el 30-ago y el 2-sep.

`calibrar_prob_motor` selecciona así:

```sql
where c.vigente and c.deporte = p_deporte
order by c.ajustado_at desc limit 1
```

**`ajustado_at` solo ORDENA. Nunca se compara contra `game_date`.** Una predicción de un
partido de mayo usa el coeficiente ajustado el 2-sep, estimado sobre datos que incluyen
partidos posteriores a ese partido.

**Prueba adversarial** (coeficiente extremo a=0.90 b=0.02 fechado **2027-01-01**,
cuatro meses después del partido):

| partido | clave | A | B |
|---|---|---|---|
| `401816798` | `edge_vs_mercado.ev_local_pct` | **−17.51** | **+64.80** |
| `401816798` | `edge_vs_mercado.ev_visita_pct` | **+10.09** | **−81.62** |
| `401815421` | (sin diferencia) | — | — |

**Es el EV: el número que decide dinero.** Cambia de signo. El partido del 20-may no se
movió porque no tiene momios y su bloque `edge_vs_mercado` está vacío — ausencia de
precio, no inmunidad.

*Corrección de mi propia primera pasada:* el primer intento fechó el coeficiente extremo
30 días después del partido de mayo, o sea **antes** del vigente del 2-sep, así que
`ORDER BY ajustado_at DESC` ni lo eligió. Ese "idéntico" era un falso PASS del arnés, no
un resultado. Repetí con fecha 2027-01-01.

Rollback: 0 residuo, 7 filas, 3 vigentes.

**NO se arregló** (requiere rediseño: versionado temporal de coeficientes). Severidad
**ALTA**: es más grave que #214 porque #214 estaba dormido y este llega al EV.

## TAREA 3 — Forense del precio de entrada del CLV

**A) Cuándo se registra `momio_mercado`:** en el INSERT del pick. **B) Quién:**
`sync_analisis_a_tracking`, `track_ai_pro_picks_from_analisis`, `track_oraculo_prob_pick`,
`backfill_tracking_for_analisis`, `track_ai_generated_parlay`. **C) Fuente:** declarada en
`odds_source`. **D) ¿Timestamp propio? NO** — solo existen `created_at` y `updated_at` de
la fila. **E)** Por eso no se puede probar por columna si el precio se observó antes del
saque; hay que cruzarlo contra `radar_odds_snapshots`. **F)** Sí es modificable después
(`updated_at` existe y no hay candado sobre `momio_mercado`).

**G) `momio_fantasma`** es booleano y lo pone `flag_momio_fantasma`:

```sql
NEW.momio_fantasma := (NEW.momio_mercado IN (1.91, 4.35)
  AND coalesce(NEW.odds_source,'inventor') NOT IN (...lista de libros...)
  AND coalesce(NEW.odds_source,'inventor') NOT LIKE 'libro:%');
```

**H)** Es un detector de **dos números mágicos**, los que inventaba el LLM. Que sea `false`
NO prueba que el precio sea real: solo prueba que no es uno de esos dos.
La prueba real de procedencia es `es_precio_de_libro(odds_source)`.
**751 de 3,462 filas (21.7%)** tienen `momio_fantasma = true`.

Dato adicional: `trg_clv_odds_apertura` hace `odds_apertura := momio_mercado` cuando está
nula. **`odds_apertura` no es una apertura observada aparte: es una copia del mismo precio.**

### MUESTRA FORENSE — las 153 filas (n = 153, no una muestra: el universo completo)

Criterio ENTRY_VERIFICADO: `es_precio_de_libro(odds_source)` **Y** existe un snapshot real
del mismo evento y lado con precio a ±0.011 en un `snapshot_at <= pick_created_at`.

| categoría | n | % | CLV medio | mediana | p25 | p75 | p90 | mín | máx | sd | t vs 0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **ENTRY_VERIFICADO** | **69** | **45.1%** | **−0.31** | −1.32 | −4.57 | 2.17 | 6.29 | −30.85 | 46.40 | 9.69 | **−0.26** |
| ENTRY_NO_VERIFICABLE | 69 | 45.1% | **+8.98** | 1.68 | −5.58 | 13.13 | 36.37 | −41.82 | **225.58** | 36.79 | 2.03 |
| ENTRY_FANTASMA | 9 | 5.9% | −2.08 | −2.55 | −4.50 | −0.83 | 1.82 | −7.28 | 3.80 | 3.37 | −1.85 |
| TIMESTAMP_INCONSISTENTE | 6 | 3.9% | **+45.72** | 23.16 | 2.54 | 79.70 | 126.93 | −25.85 | 159.65 | 69.14 | 1.62 |
| **TOTAL** | 153 | 100% | **+5.58** | **−0.53** | −4.65 | 7.09 | 30.05 | −41.82 | 225.58 | — | — |

Dentro de los verificados, por calidad de cierre:
T-5 (n=13): **−0.54**, t = −0.57. T-30 (n=56): **−0.25**, t = −0.18.

### EXPLICACIÓN DEL +5.58% — DETERMINADA

El +5.58% **no es señal**. Se explica por completo:

1. Donde el precio de entrada está respaldado por un snapshot real de casa, el CLV es
   **−0.31% con t = −0.26**: indistinguible de cero, ligeramente negativo. Es exactamente
   lo que se espera de apostar sin ventaja pagando la comisión.
2. Todo el exceso vive en las categorías que **no se pueden verificar**: 6 picks
   registrados **después del saque** promedian **+45.72%**, y los 69 no verificables
   **+8.98%** con 4 colas por encima de +50%.
3. La **mediana global es −0.53%** contra una media de +5.58%: la media la arrastra una
   cola derecha extrema (máximo +225.58%), no un desplazamiento del centro.
4. Los verificados tienen **0 casos** por encima de +50%. Las otras categorías tienen 6.

**Conclusión:** la tubería de CLV funciona. El CLV **no** mide todavía fielmente la calidad
del precio de entrada, porque **el 54.9% de las filas tiene un precio de entrada que no se
puede verificar contra un precio de casa realmente observado.** El termómetro estaba
midiendo, en más de la mitad de los casos, su propio ruido.

---

## ANEXO F — CIERRE DEL BLOQUEANTE `calibracion_coef` (5-sep-2026)

### F.1 DDL aplicado

```sql
ALTER TABLE public.calibracion_coef
  ADD COLUMN IF NOT EXISTS effective_from          timestamptz,
  ADD COLUMN IF NOT EXISTS data_cutoff_at          timestamptz,
  ADD COLUMN IF NOT EXISTS data_cutoff_verificado  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cutoff_evidencia        text;

UPDATE public.calibracion_coef SET effective_from = ajustado_at WHERE effective_from IS NULL;
ALTER TABLE public.calibracion_coef ALTER COLUMN effective_from SET NOT NULL;

ALTER TABLE public.calibracion_coef ADD CONSTRAINT chk_cal_cutoff_no_futuro
  CHECK (data_cutoff_at IS NULL OR data_cutoff_at <= effective_from);
ALTER TABLE public.calibracion_coef ADD CONSTRAINT chk_cal_verificado_exige_evidencia
  CHECK (NOT data_cutoff_verificado OR (data_cutoff_at IS NOT NULL AND cutoff_evidencia IS NOT NULL));
```

### F.2 Definición de la selección temporal

Un coeficiente es elegible para un partido con fecha `G` si y solo si:

```
effective_from                              <= G     (disponibilidad: ya existía)
coalesce(data_cutoff_at, effective_from)     < G     (los datos terminaban antes)
```

Desempate: `ORDER BY coalesce(data_cutoff_at, effective_from) DESC, id DESC`.

- `<=` en disponibilidad: un coeficiente desplegado exactamente al saque **sí** estaba
  disponible.
- `<` estricto en el corte de datos: datos que llegan hasta el instante del partido
  podrían incluir el partido.
- `coalesce(...)` usa `effective_from` como **cota superior demostrable** del corte real
  cuando no hay evidencia: no se afirma equivalencia, se afirma `data_cutoff_at <= ajustado_at`.

### F.3 Procedencia por coeficiente

| id | deporte | vigente | `data_cutoff_at` | verificado | base |
|----|---------|---------|------------------|------------|------|
| 7 | soccer | sí | 2026-09-02 16:09 | **sí** | la `nota` documenta "21,252 partidos de 50 ligas (jul-2023 a sep-2026)" |
| 6 | baseball | sí | NULL | no | declara tamaño de muestra, **no** rango de fechas |
| 3 | football | sí | NULL | no | ídem |
| 1,2,4,5 | — | no | NULL | no | no vigentes |

Ninguna fecha fue inventada ni retro-fechada.

### F.4 Prueba adversarial A→B (3 partidos, 15 pares)

Baseline `a` y mutado `b` capturados espalda con espalda **dentro** de la misma
subtransacción, que después se aborta. Diff sobre el JSON completo a dos niveles.

| vector | condición inyectada | resultado |
|--------|---------------------|-----------|
| A | `effective_from` = G + 10 días | **JSON idéntico** en 3/3 |
| B | `data_cutoff_at` = G + 5 días | **JSON idéntico** en 3/3 |
| C | coeficiente legítimo (G − 1 día) | **cambia** en 3/3 (EV −17.51→+62.44, +5.55→+88.31, −20.56→+22.81) |
| D | coeficiente fechado 2027-01-01 | **JSON idéntico** en 3/3 |
| E | `data_cutoff_at` = G exacto (límite) | **JSON idéntico** en 3/3 |

B y E además **no se pueden insertar**: los rechaza `chk_cal_cutoff_no_futuro`. Para
auditar la compuerta del consumidor de forma independiente de la estructural, el CHECK
se suspendió únicamente dentro de la subtransacción abortada.

Vector C es la prueba de que el camino **no estaba dormido**: mueve EV y
`prob_local_calibrada` en los tres partidos.

### F.5 Defectos del arnés corregidos durante la prueba

1. Los `INSERT` de diagnóstico se hacían dentro de la subtransacción abortada y se
   revertían con ella. Solo sobrevivía lo escrito en el manejador de excepción. Se pasó
   a acumular en variables PL/pgSQL (que **sí** sobreviven) y escribir al salir.
2. La primera versión truncaba los valores a 220 caracteres y cortaba justo en la
   sub-llave que difería. Por eso el diff decía "distinto" sin poder decir dónde.
3. Vector C con fecha G − 10 días quedaba **dormido**: perdía el desempate contra el
   coeficiente productivo (2026-09-02). Se re-fechó a G − 1 día.

### F.6 Segundo lector sin compuerta (hallado por la prueba, corregido)

`predecir_mlb` tenía un `SELECT` aparte a `calibracion_coef` con
`ORDER BY c.ajustado_at DESC LIMIT 1` que alimenta `rango_medido_pct` y el texto de
`motivo_sin_ev`. Alineado a la misma selección temporal. Sin este arreglo A/B/D/E
seguían difiriendo en esa llave.

### F.7 Escritor

`reajustar_calibracion` no llenaba `effective_from` (ahora NOT NULL). Se parchó el
escritor en vez de poner un DEFAULT: declara `effective_from = now()` y
`data_cutoff_at = max(match_date)` de los mismos picks que estiman `a` y `b`, con
`data_cutoff_verificado` y evidencia. Probado transaccionalmente bajando el piso de
muestra solo dentro de la subtransacción: escribe cortes reales (2026-07-11 baseball,
2026-08-19 soccer) y satisface los dos CHECK.

### F.8 Integridad tras la prueba

7 filas, `max(id) = 7`, 0 residuos `VECTOR%`, ambos CHECK presentes, 0
`effective_from` nulos, piso de 300 intacto, `origen='backtest'` intacto en los 3
vigentes, `EXP_OFF = 0.50`, shadow con 800 filas y **0 lectores** fuera de su propio
generador, `picks`=34, `oraculo_picks_tracking`=3462, `clv_real`=153.

### F.9 Riesgo residual declarado

`filtro_pick` llama `calibrar_prob_motor(p, deporte)` con 2 argumentos, o sea `now()`.
En producción es correcto (la decisión se toma en el presente) y su fallo es
conservador: si no hay coeficiente vigente y válido devuelve NULL y **rechaza** el pick.
Pero cualquier backtest que pase por `filtro_pick` sí tendría fuga. No se toca en este
turno; queda declarado.

---

## ANEXO G — CANDADO TEMPORAL FINAL (5-sep-2026)

Motivo: en el Anexo F declare como riesgo residual que `filtro_pick` llamaba
`calibrar_prob_motor(p, deporte)` con 2 argumentos y por tanto `now()`. El auditor
rechazo cerrar Fase 1.5 con esa contradiccion abierta. Este anexo la cierra.

### G.1 Mapa de consumidores (inspeccion 360)

Lado base de datos, enumerado con `pg_proc` / `pg_class` / `pg_trigger` / `cron.job`
(exhaustivo por construccion):

| Consumidor | Llama | Clase | Evidencia de su ventana temporal |
|---|---|---|---|
| `v_mejores_picks_mlb` (vista) | `filtro_pick` | **1. produccion tiempo real** | su fuente `v_picks_mlb_modelo` filtra `fecha >= now()-3h and <= now()+4d` |
| `refrescar_destacados` (cron `destacados-refrescar`) | `filtro_pick`, `calibrar_prob_motor` x2 | **1. produccion tiempo real** | `a.fecha > now() and a.fecha < now() + p_horas` |
| `favoritos_bien_pagados` | `calibrar_prob_motor` | **1. produccion tiempo real** | `l.game_date > now()` |
| `mejor_oportunidad_hoy` | `calibrar_prob_motor` | **1. produccion tiempo real** | `v.arranca_en > now() - 1 hour` |
| `veredicto_vivo` | `calibrar_prob_motor` x3 | **1. produccion tiempo real** | veredicto sobre partido en curso |
| `vale_la_pena_cerrar` | `calibrar_prob_motor` | **1. produccion tiempo real** | cash out de apuesta viva |
| `predecir_mlb` | `calibrar_prob_motor` (4 args) | **3. compartida** | ya pasaba `game_date`; ver G.4 |
| **`calibracion_publica_kpis`** | `calibrar_prob_motor` | **2. RECONSTRUCCION HISTORICA** | lee `oraculo_picks_tracking` con `resultado in ('ganado','perdido')`: 3,136 picks YA JUGADOS |

Lado externo (app y edge functions). No se puede enumerar por catalogo, asi que se
midio y se acoto:

- `pg_stat_statements` (ventana 2026-09-02 14:19 -> 2026-09-05, 4,717 sentencias
  distintas): **0 llamadas PostgREST** a `filtro_pick` o a `calibrar_prob_motor`.
- Los grants de ambas siguen siendo el default de Postgres (`PUBLIC:EXECUTE`), a
  diferencia de toda funcion que la app si llama a proposito, a la que se le hizo
  `revoke all from public, anon` + `grant to authenticated` (p.ej.
  `calibracion_publica_kpis`, `mejor_oportunidad_hoy`).
- Esto es evidencia fuerte, **no prueba**. Por eso el diseno de G.2 hace que una
  llamada incompleta falle con 42883 en vez de caer callada en `now()`: cualquier
  consumidor externo que yo no pueda enumerar se delata en vez de filtrarse.

**Veredicto: CASO B.** `calibracion_publica_kpis` es una ruta historica real y
alcanzable que usaba el presente como fecha de referencia.

### G.2 Firmas finales

```
public.calibrar_prob_motor(numeric, text, text, timestamptz)   -- SIN defaults
public.calibrar_prob_motor_live(numeric, text, text)           -- pasa now() explicito
public.filtro_pick(numeric, numeric, text, text, timestamptz)  -- SIN defaults, y RAISE si p_as_of es NULL
public.filtro_pick_live(numeric, numeric, text, text)          -- pasa now() explicito
```

La separacion es semantica: el nombre dice el contexto. `_live` es el unico punto del
sistema autorizado a usar el presente. Nadie tiene que "acordarse" de pasar el tercer
argumento: si lo omite, no compila.

`filtro_pick` ademas juzga la EXISTENCIA de calibracion a la fecha, no en abstracto:
para un partido anterior a cualquier coeficiente el motivo ahora dice "nunca hemos
medido este deporte", que es la verdad, en vez de "fuera de rango".

### G.3 Pruebas F1-F4

| Prueba | Resultado |
|---|---|
| **F1** historico, coeficiente extremo posterior a G | `filtro_pick` JSON **identico**; `cal` 0.539005 -> 0.539005; ev 7.8 -> 7.8 |
| **F2** coeficiente legitimo anterior a G | **cambia**: `cal` 0.539005 -> 0.9275; ev 7.8 -> 85.5 (el camino NO estaba dormido) |
| **F3** produccion | `calibrar_prob_motor_live(0.55,'soccer')` = 0.539005; `filtro_pick_live` pasa con ev 7.8; los dos vetos medidos siguen firmes (Over/Under MLB y Moneyline futbol) |
| **F4a** `calibrar_prob_motor(0.55,'soccer')` | `ERROR 42883: function ... does not exist` |
| **F4b** `calibrar_prob_motor(0.55,'soccer','Over/Under')` | `ERROR 42883` |
| **F4c** `filtro_pick(0.55,2.00,'Over/Under','soccer')` | `ERROR 42883` |
| **F4d** `filtro_pick(..., NULL::timestamptz)` | `ERROR P0001: p_as_of es obligatorio y no puede ser NULL` |

Re-corrida completa de la bateria A-E del Anexo F sobre 3 partidos tras el refactor:
A/B/D/E **JSON identico 3/3**, C mueve EV en 3/3.

### G.4 `predecir_mlb`: el desvio silencioso que quedaba

Tenia **siete** `COALESCE(m.game_date, now())`. Con la fecha nula, TODOS los cortes
(forma, RPG de liga, calibracion, temporada) se movian al presente sin avisar. Se
sustituyo por una variable `v_as_of := m.game_date` con guarda explicita: sin fecha,
la funcion devuelve `ok=false` con motivo, no predice. Exposicion medida: **0 de 1,224**
filas de `mlb_stats_cache` sin `game_date`, asi que la guarda no apaga nada hoy.

### G.5 Diff funcional de la pantalla publica

`calibracion_publica_kpis` sobre 2,399 picks resueltos y activos:

| | antes (look-ahead) | ahora |
|---|---|---|
| picks calibrados | **1,661** | **24** |
| `brier_crudo` | 0.2544 | 0.2544 |
| `brier_calibrado` | 0.2543 | **0.2545** |
| `n_sin_fecha_de_partido` | (no existia) | 24 |

1,661 picks se estaban "calibrando" con un coeficiente que no existia cuando se
hicieron. Ahora solo se calibran los 24 posteriores al coeficiente vigente. El Brier
se mueve poco (0.2543 -> 0.2545) porque en ese rango la recta es casi la identidad;
lo que cambia es que el numero ya es honesto. Se agrego `n_sin_fecha_de_partido` para
no confundir "fuera de rango" con "sin fecha".

### G.6 Procedencia de `effective_from` en los coeficientes legacy

`track_commit_timestamp` esta **apagado**: no hay sello fisico de insercion. La
procedencia se sostiene, o no, con esto:

- **id 7 (soccer, vigente)** — `pg_stat_statements` conserva el INSERT que la creo
  (`with est as (...) insert into calibracion_coef (deporte,a,b,muestra,tasa_base,rango_min,rango_max,nota,vigente)`)
  y su lista de columnas **NO incluye `ajustado_at`**: el valor lo puso `DEFAULT now()`
  y no pudo ser backdateado. Cutoff **verificado** por la nota (jul-2023 a sep-2026).
- **id 6 (baseball, vigente)** — mismo tipo de evidencia a nivel de sentencia
  (`insert into public.calibracion_coef (deporte,a,b,muestra,tasa_base,rango_min,rango_max,nota,vigente) values ($1..$9)`,
  sin `ajustado_at`). Su `nota` declara muestra pero **no rango de fechas**, asi que
  `data_cutoff_at` queda NULL y la puerta usa la cota `data_cutoff_at <= effective_from`.
- **id 3 (football/NFL, vigente)** — es del 2026-08-30, **anterior a la ventana de
  `pg_stat_statements`**. NO hay evidencia a nivel de sentencia. Lo demostrable es
  solo circunstancial (DEFAULT now(), precision de microsegundo, orden monotono con
  el id serial, ningun escritor del sistema pasa `ajustado_at`). **Eso no es prueba y
  no se presenta como tal.** Exposicion medida: `oraculo_picks_tracking` tiene
  **0 picks de NFL resueltos**, o sea que no existe evento historico que esta fila
  pudiera calibrar; ademas el dinero de NFL esta apagado por `mercados_sin_modelo`.
  Queda declarado en `cutoff_evidencia`: si algun dia entran picks de NFL resueltos,
  el coeficiente debe re-derivarse con corte documentado antes de medir el pasado.

Ninguna fecha fue inventada, retro-fechada ni adelantada.

### G.7 Integridad

7 filas en `calibracion_coef`, `max(id)=7`, **0 residuos** de prueba, ambos CHECK
presentes, 0 `effective_from` nulos, `EXP_OFF = 0.50`, `predecir_mlb` sin desvio a
`now()`, shadow con 800 filas y **0 lectores** fuera de su propio generador,
`picks`=34, `oraculo_picks_tracking`=3462, `clv_real`=153.

Humo de produccion tras repuntar: `refrescar_destacados(48)` = 117 filas / 121
partidos evaluados (identico a antes), `mejor_oportunidad_hoy(10)` = 10 filas,
`favoritos_bien_pagados()` = 3 filas, `v_mejores_picks_mlb` = 6 filas,
`vale_la_pena_cerrar` responde, `veredicto_vivo('401885454','Mas de 2.5',2.0)`
devuelve ev 20.2%.

---

## ANEXO H — HARDENING POST-CIERRE (5-sep-2026)

Los dos pendientes no bloqueantes que el auditor nombro al firmar el cierre de
Fase 1.5. Ninguno cambia comportamiento productivo.

### H.1 Los invariantes dejan de ser una auditoria y pasan a ser un candado

`public.invariantes_temporales()` devuelve `{ok, reglas[]}` con tres reglas:

| regla | que prohibe | por que |
|---|---|---|
| **I1** `firmas_calibrar` | que `calibrar_prob_motor` recupere una firma corta o gane un DEFAULT | ese DEFAULT **era** la fuga |
| **I2** `firmas_filtro_pick` | lo mismo para `filtro_pick` | idem |
| **I3** `motor_sin_desvio_a_now` | que una funcion del motor reintroduzca `coalesce(<fecha del evento>, now())` | era el octavo escape, el de `predecir_mlb` |

Los envoltorios `*_live` **si** pueden tener defaults: su trabajo declarado es pasar
el presente. I3 **ignora las lineas de comentario** a proposito: dos veces en esta
auditoria un grep dio falso positivo sobre mi propio comentario, y el invariante no
puede heredar ese defecto. El orden va con `collate "C"` porque la colacion del
servidor ignora la puntuacion y pondria `_live` antes que la firma base, volviendo el
invariante dependiente de la configuracion regional.

`tg_candado_temporal` es un **event trigger** sobre `ddl_command_end` con tags
`CREATE FUNCTION, ALTER FUNCTION`: el DDL que rompa un invariante no entra. Salida
para migraciones legitimas en dos pasos, en la misma transaccion:

```sql
set local app.mantenimiento_candado_temporal = 'on';
```

Probado en las tres direcciones:

| prueba | resultado |
|---|---|
| DDL benigno (funcion cualquiera con DEFAULT) | **aceptado** — sin falso positivo |
| `create ... calibrar_prob_motor(p numeric, p_deporte text default 'soccer')` | **RECHAZADO**: `I1 ... hallado: calibrar_prob_motor(numeric,text) [PROHIBIDO: CON DEFAULTS] \| ...` |
| `create ... predecir_zz_prueba` con `coalesce(m.game_date, now())` | **RECHAZADO**: `I3 ... hallado: predecir_zz_prueba` |
| lo mismo con la salida de mantenimiento puesta | aceptado, y al limpiar `ok=true` |

**Limite declarado:** el trigger no cubre un `DROP FUNCTION` suelto (se dejo fuera de
los tags a proposito, porque haria que toda migracion en dos pasos necesitara la
salida). No es un hueco silencioso: borrar `calibrar_prob_motor` o `filtro_pick` sin
recrearlas revienta a la vista todos los consumidores vivos.

### H.2 La evidencia de procedencia deja de vivir en un buffer que se resetea

`pg_stat_statements` es memoria: la unica prueba de como se lleno `ajustado_at` en los
coeficientes 6 y 7 podia desaparecer con un reinicio. Se creo
`public.evidencia_procedencia` (objeto, fila, **afirmacion**, fuente, sentencia
verbatim, capturado_at) y se copiaron las dos sentencias **tal cual**, sin retipearlas:

- id 7 (soccer): 497 caracteres, `with est as (...) insert into calibracion_coef (deporte, a, b, muestra, tasa_base, rango_min, rango_max, nota, vigente) select ...`
- id 6 (baseball): 153 caracteres, `insert into public.calibracion_coef (deporte, a, b, muestra, tasa_base, rango_min, rango_max, nota, vigente) values ($1 ... $9)`

Ninguna incluye `ajustado_at` en su lista de columnas: el valor lo puso `DEFAULT now()`
y no pudo ser backdateado.

La tercera fila registra la **ausencia** para el id 3 (NFL) con fuente
`ausencia_verificada` y sentencia NULL, permitido por el CHECK
`chk_ev_sentencia_si_es_de_statements`. Guardar la ausencia con la misma formalidad
que la prueba es el punto: si manana alguien busca la evidencia del id 3, encuentra
por escrito que no existe, en vez de encontrar nada y suponer.

### H.3 Integridad tras el hardening

`invariantes_temporales().ok = true` · event trigger habilitado con tags
`CREATE FUNCTION, ALTER FUNCTION` · 4 firmas vivas y ninguna otra · 3 filas de
evidencia · 0 residuos de las funciones de prueba · `calibracion_coef` 7 filas ·
**`EXP_OFF = 0.50`** · humo `filtro_pick_live` ev 7.8%.

---

# FASE 2 — BLOQUE 2A: EV, SIZING Y MONTO DEL RETO 13M

## 2A.1 Mapa de la cadena economica (Tarea 1 — sin modificar nada)

Cadena unica, medida en produccion:

```
v_pick_canonico.probabilidad_pct   (probabilidad CALIBRADA por deporte)
        |  MLB: prob_recalibrada_lado()   Futbol: v_picks_futbol_calibrado (+ ajuste_h2h_over25)
        v
v_pick_canonico.ev_pct = (p/100 * momio - 1) * 100        <-- EV DECLARADO
        v
reto_picks_hoy  ->  kelly_stake(apodo, probabilidad_pct, momio_mercado, null, mercado)
        |
        |  1. p        = probabilidad_pct / 100
        |  2. tramo    = zona_realidad(mercado, p)          <-- BANDEA POR PROBABILIDAD
        |  3. sesgo    = zonas_confiables.prob_real - prob_dicha   (constante por tramo)
        |  4. recorte  = media - percentil10 de Beta(0.5+k, 0.5+n-k)
        |  5. p'       = clamp(p + sesgo - recorte)
        |  6. factor   = wilson_inferior(p_hat, n) / p_hat   (<= 1, constante por tramo)
        |  7. p_decide = clamp(p' * factor)
        v
   ev_pct = (p_decide * momio - 1) * 100                    <-- EV QUE DIMENSIONA
   f_full = (p_decide*b - (1-p_decide)) / b ;  b = momio - 1
   stake_kelly = bankroll_disponible * f_full * fraccion_kelly(0.25)
   stake_techo = bankroll_disponible * stake_max_pct(5.0) / 100
   stake_final = min(stake_kelly, stake_techo) ; si < stake_min(20) -> 0
        v
reto_picks_hoy aplica, en este orden: partido_fantasma, sin_modelo, abstencion,
sin_datos, rongol, muestra_chica, kelly, ev_negativo, bajo_minimo, y por ultimo
el CDaR de cartera (exposicion_viva + suma corrida) -> monto_autorizado
        v
UI Reto13M.tsx: "EV real" = ev_pct (el que dimensiona) ; "Prob. que decide" =
prob_que_decide_pct ; "Prob. del motor" = probabilidad_pct (declarada)
```

## 2A.2 #209 — CERRADO EN LA PANTALLA DEL RETO 13M

`reto_picks_hoy` devuelve los dos EV por separado y con nombres distintos:
`ev_pct` (el que dimensiona, viene de `kelly_stake`) y `ev_pct_declarado`
(el de `v_pick_canonico`). Grep de `src/pages/Reto13M.tsx`: `ev_pct` se pinta
como **"EV real"** (linea 2345) junto a **"Prob. que decide"** (2350) y
**"Prob. del motor"** (2340). `ev_pct_declarado` aparece **una sola vez**, en la
declaracion de tipo (linea 221): **no se pinta**. La pantalla no miente.

Los dos EV divergen mucho y por eso importa cual se muestra. Medido hoy en
produccion: Philadelphia 22.7 declarado contra 4.7 que dimensiona; Dortmund 16.6
contra **-19.4**. Un usuario que viera el declarado creeria que hay valor donde
el motor dice que se pierde dinero.

**Residual declarado:** `v_pick_canonico.ev_pct` (el declarado) sigue siendo
consumido por otras superficies (`picks_recomendados_hoy`, `mejor_oportunidad_hoy`,
`destacados_cache`). Que la pantalla del RETO 13M este bien no prueba que las
demas lo esten. No verificado todavia.

## 2A.3 #208 — CONFIRMADO EN EL EFECTO, REFUTADO EN EL MECANISMO

La hipotesis del ticket era "el monto lo decide SOLO el momio". **Eso ya no es
cierto**: el tope plano `least(p, tasa_base)` que producia ese sintoma se
reemplazo el 5-sep por el haircut de Wilson. Medido hoy: `prob_que_decide_pct`
va de 19.7 a 48.6 entre los 16 picks del dia; no es constante.

Pero el monto sigue sin estar gobernado por el modelo. **Lo gobierna la frontera
de tramo de `zonas_confiables`.**

### Barrido A — momio FIJO en 2.20, probabilidad declarada de 30 a 70

| p declarada | tramo (n) | sesgo | recorte | factor | p decide | stake |
|---|---|---|---|---|---|---|
| 39 | 1024 | -1.7 | 1.9 | 0.944 | 33.5 | $0 |
| **40** | **853** | **+4.9** | 2.2 | 0.956 | **40.9** | $0 |
| 49 | 853 | +4.9 | 2.2 | 0.956 | 49.5 | **$110.07** |
| **50** | **187** | **+1.2** | **4.6** | 0.913 | **42.5** | **$0** |
| 59 | 187 | +1.2 | 4.6 | 0.913 | 50.8 | **$145.70** |
| **60** | **sin medir** | 0.0 | **11.1** | 0.805 | **39.4** | **$0** |

**Subir la probabilidad declarada 1 punto tira el monto de $110 a $0, y de $146 a $0.**
La probabilidad que decide CAE 7.0 pp y 11.4 pp al SUBIR la declarada.

### Barrido B — EV declarado FIJO en +10%, momio de 1.60 a 6.00

Stake = **$0 en 10 de 12 momios**. Solo hay dinero en 2.40 y 2.60, que es
exactamente donde la probabilidad implicada cae en el tramo Moneyline n=853, el
unico con sesgo positivo grande (+4.9 pp). A EV declarado identico, lo que decide
si hay dinero no es el EV ni el momio: **es en que tramo cae la probabilidad.**

### Cuantificacion en los 4 mercados vivos (momio 2.20, p de 20 a 85)

| mercado | pares donde subir p BAJA el stake | peor salto de p_decide | peor caida de stake |
|---|---|---|---|
| BTTS | 2 | **-15.9 pp** | **-$235.91** |
| Moneyline | 2 | -11.4 pp | -$145.70 |
| Total Equipo | 1 | -3.4 pp | -$21.30 |
| Over/Under | 0 | -2.0 pp | $0.00 |

Over/Under sale limpio en dinero porque todos sus sesgos por tramo son chicos
(-3.1 a +0.9 pp). El defecto escala con la diferencia de sesgo entre tramos vecinos.

### Causa raiz

`zonas_confiables` mide el sesgo por tramo y `kelly_stake` lo aplica como un
**desplazamiento aditivo constante dentro del tramo**. Los tramos vecinos de
Moneyline tienen sesgos de -1.7, +4.9 y +1.2 pp; los de BTTS van de +9.1 a -13.7.
Como la banda se elige con la probabilidad declarada, la funcion
`p_decide(p_declarada)` es **escalonada y no monotona**. Ademas `zonas_confiables`
**no tiene deporte**: un Moneyline de MLB y uno de futbol comparten tramo (ya
documentado como limitacion en el propio codigo).

Corolario economico: el sistema solo autoriza dinero cuando la probabilidad cae en
una banda con sesgo medido positivo. Eso explica de forma mecanica el sintoma
viejo de #126 ("el motor solo produce no-favoritos").

## 2A.4 Tarea 4 — definicion canonica de EV

No hay que elegir arbitrariamente: los dos EV **ya tienen nombres distintos y
significados distintos**, y ninguno es redundante.

- `ev_pct_declarado = (p_modelo * momio - 1) * 100`
  Es el EV bajo la probabilidad del modelo tal cual. Sirve para auditar al modelo.
  **NO debe gobernar dinero** mientras el modelo tenga skill negativo (#191).
- `ev_pct = (p_decide * momio - 1) * 100`
  Es el EV bajo la probabilidad despues del sesgo medido y del descuento por
  incertidumbre. **Este es el canonico para dinero**, y es el que dimensiona y el
  que pinta la tarjeta.

Los dos responden a `EV = P(win)*(momio-1) - P(loss)*1`, con P distinta. No existe
hoy una variable llamada `ev` que signifique dos cosas: la ambiguedad esta resuelta
por nombre. Lo que falta es verificar que las demas superficies respeten esa
convencion (residual de 2A.2).

## 2A.5 Tarea 5 — propiedades medidas del sizing actual

| propiedad | estado |
|---|---|
| monotonicidad respecto al edge | **FALLA**: 5 puntos de ruptura medidos en 4 mercados |
| dependencia del momio | correcta dentro de un tramo (Kelly estandar) |
| cap | `stake_max_pct = 5.0%` -> $300.00 sobre bankroll 6,000. Solo aprieta |
| floor | `stake_min = 20` -> por debajo se anula a 0 (discontinuidad deliberada) |
| bankroll base | `bankroll_disponible()` vivo, no congelado (corregido el 2-sep) |
| fraccion | `fraccion_kelly = 0.25` |
| exposicion acumulada | CDaR con suma corrida y desempate explicito en `reto_picks_hoy` |
| redondeos | `round(..., 2)` en stake; sin efecto material |
| correlacion entre apuestas | **NO medido todavia** |
| parlays | **NO medido todavia** |

## 2A.6 Estado del bloque

Tareas 1, 2 y 3 completas con evidencia. Tarea 4 resuelta. Tarea 5 completa para
apuesta individual, pendiente a nivel de cartera. **Cero modificaciones a produccion
en este turno.** El criterio de salida de 2A NO se cumple todavia: se puede
reconstruir la cadena de un pick real de punta a punta, pero la regla de aceptacion
depende de una funcion no monotona de la probabilidad, y eso no es explicable ante
el usuario ("subiste la probabilidad y por eso te quitamos el dinero").

---

## 2A.6 — SUPERFICIES QUE USAN EV (auditoria exhaustiva)

Consumidores reales de `v_pick_canonico`, enumerados por catalogo (`pg_proc`,
`pg_class`, `pg_trigger`, `cron.job`). Nota: `picks_recomendados_hoy` **no es
consumidor, es fuente**: `v_pick_canonico` la lee a ella.

| superficie | que EV usa | prob que lo produce | ordena por el | filtra con el | UI | notif | dinero | puede recomendar lo que kelly rechaza |
|---|---|---|---|---|---|---|---|---|
| `reto_picks_hoy` | `kelly_stake.ev_pct` | P_DECIDE | si | si (`ev_negativo`) | si | no | **si** | no |
| `mejor_oportunidad_hoy` | **propio** `ev_pct` | `calibrar_prob_motor_live(P_CAL)` | **si (`orden`)** | **si (`ev_pct>0`, `piso_ev`)** | si | no | no directo | **SI** |
| `v_oraculo_canonico` | pasa `ev_pct` de canonico | P_CAL | no | no | via lectores | no | no | si |
| `analisis_completo` | calcula el suyo | P_CAL | no | no | si | no | no | si |
| `v_radar_mlb` | no usa ev | — | — | — | si | no | no | — |
| `revisar_apuesta` | no usa ev | — | — | — | si | no | no | — |
| `filtro_pick` | `ev` interno | P_CAL | no | si (`pasa`) | indirecto | no | si | no |

### HAY TRES EV, NO DOS

1. `ev_crudo_pct` (en `mejor_oportunidad_hoy`) = P_CAL x momio - 1.
   **Coincide al decimal con `v_pick_canonico.ev_pct`** en los picks solapados
   (22.7, 16.6, 7.1, 6.1, 3.2). Son el mismo numero con dos nombres.
2. `ev_pct` (en `mejor_oportunidad_hoy`) = `calibrar_prob_motor_live(P_CAL)` x momio - 1.
   Una **segunda** calibracion encima de la del motor.
3. `ev_pct` (en `kelly_stake`) = P_DECIDE x momio - 1. El unico que gobierna dinero.

### Contradicciones medidas hoy (16 picks vivos)

**7 de 16 tienen contradiccion de signo** (EV_CAL > 0 y EV_DECIDE < 0). Cuatro de
esos siete **se publican en `mejor_oportunidad_hoy` con EV positivo**:

| pick | EV_CAL | EV_DECIDE | sale en mejor_oportunidad | EV ahi | kelly_pct ahi |
|---|---|---|---|---|---|
| Borussia Dortmund | +16.6 | **-19.4** | si, **orden #7** | **+12.9** | 0.00 |
| Miami Marlins | +7.1 | **-8.9** | si, orden #14 | **+6.0** | **1.34** |
| San Diego Padres | +6.1 | **-9.2** | si, orden #15 | **+5.5** | **0.27** |
| Kansas City Royals | +3.2 | **-11.7** | si, orden #17 | **+2.7** | 0.00 |

Respuesta a la pregunta 8 del mandato: **SI**. `mejor_oportunidad_hoy` muestra,
ordena y en dos casos **publica un `kelly_pct` positivo** sobre picks que
`kelly_stake` considera de EV negativo.

### Defecto adicional en esa misma superficie

5 de 19 filas traen `fuera_de_rango = true`: `calibrar_prob_motor_live` devolvio
NULL y la funcion **cae a la probabilidad cruda** (72.5/72.5, 71.0/71.0, 78.8/78.8).
Una de ellas es el **orden #2 del dia con +22.5% de EV**, calculado sobre una
probabilidad que la calibracion se niega a tocar. El unico aviso es un booleano.

**#209 queda: CERRADO EN RETO13M / FALLA GLOBALMENTE.**

## 2A.7 — NOMENCLATURA CANONICA

La arquitectura encontrada tiene **cuatro** probabilidades, no tres.

| nombre propuesto | que es | donde vive hoy | ojo |
|---|---|---|---|
| **P_RAW** | salida cruda del motor por deporte | `oraculo_picks_tracking.probabilidad_real`; en MLB la salida de `predecir_mlb` antes de calibrar | — |
| **P_CAL** | P_RAW despues de la calibracion **del deporte** | `v_pick_canonico.probabilidad_pct`. MLB: `prob_recalibrada_lado()`. Futbol: `v_picks_futbol_calibrado` (+`ajuste_h2h_over25`) | **La UI del RETO la etiqueta "Prob. del motor" y `mejor_oportunidad_hoy` la llama `prob_cruda_pct`. Las dos mienten: ya esta calibrada.** |
| **P_CAL2** | P_CAL pasada por `calibrar_prob_motor_live` | solo dentro de `mejor_oportunidad_hoy` (`prob_pct`) | segunda calibracion encima de la primera; nadie la nombra |
| **P_DECIDE** | P_CAL + sesgo del tramo - recorte, por factor Wilson | `kelly_stake` (`prob_que_decide_pct`) | la unica que toca dinero |

Y por tanto: **EV_CAL** (sobre P_CAL) -> **EV_CAL2** (sobre P_CAL2, solo en una
pantalla) -> **EV_DECIDE** (sobre P_DECIDE). No es la cadena limpia
`EV_CAL -> EV_DECIDE` que el mandato propone: hay un eslabon intermedio no
declarado que solo existe en una superficie.

**"p_declarada" no debe usarse como concepto**: en el codigo significa P_CAL, pero
la palabra sugiere P_RAW. Es el nombre que causa la confusion.

## 2A.8 — PROCEDENCIA DE `zonas_confiables`

| campo | hallazgo |
|---|---|
| escritor | `recalcular_zonas_confiables()`, unico. Hace `DELETE FROM zonas_confiables` y reconstruye entera |
| quien lo llama | `rongol_afinar`, `rongol_ciclo`. Ningun cron lo llama directo |
| lectores | `kelly_stake`, `zona_realidad` |
| fuente | `modelo_backtest`, `WHERE muestra_min >= 8`, `HAVING count(*) >= 100` |
| bandeo | `width_bucket(prob_modelo, 0, 1, 10)` -> **deciles fijos**. Fronteras exactas en 0.10, 0.20 ... 0.90 |
| `prob_dicha` | `avg(prob_modelo)` del tramo |
| `prob_real` | `avg(acerto::int)` del tramo |
| sesgo | **no se almacena**: `kelly_stake` lo calcula como `prob_real - prob_dicha` |
| Beta / p10 | en `kelly_stake`: Beta(0.5+k, 0.5+n-k) con k = round(prob_real x n), p10 por aproximacion normal, z=1.2816 |
| Wilson | en `kelly_stake`, sobre `p_hat = k/n`, mismo z |
| cutoff temporal | **NINGUNO en el codigo**. Implicito por los datos: `modelo_backtest` va del 2026-02-12 al **2026-08-26** y no se actualiza desde entonces |
| train/test | **NO EXISTE** |
| versionado | **NO EXISTE**. `DELETE` + rebuild, sin historia. `actualizado` es un solo timestamp: 2026-09-05 07:40 |
| deporte | **la tabla no tiene la columna** |
| `nivel` y `brier` | se calculan y se guardan, y **`kelly_stake` no los lee**. Job C medido y descartado |

### El punto critico, medido

`modelo_backtest`: **30,876 filas, 20 ligas, 100% `deporte = 'soccer'`. Cero filas
de baseball. Cero de football.**

No es que mezcle deportes. Es peor: **no hay nada que mezclar.** La correccion de
Moneyline se estimo sobre 5,406 picks de futbol y se aplica tal cual a MLB.

Tramos de Moneyline, todos de futbol:

| tramo | banda | n | p_dicha | p_real | sesgo |
|---|---|---|---|---|---|
| 3 | 20-30% | 1963 | 0.259 | 0.245 | -1.4 |
| 4 | 30-40% | 1024 | 0.348 | 0.331 | -1.7 |
| 5 | 40-50% | 853 | 0.445 | 0.495 | **+4.9** |
| 6 | 50-60% | **187** | 0.528 | 0.540 | +1.2 |

**De los 16 picks vivos de hoy, 10 son de baseball.** Es decir, **62.5% del dinero
del dia se dimensiona con una correccion estimada sobre cero observaciones de su
deporte**, y el tramo que gobierna la banda 50-60% tiene apenas 187 partidos.

### Diagnostico: **D — hace mas de una funcion a la vez**

- **A (calibracion)**: si. `sesgo = prob_real - prob_dicha` aplicado como
  desplazamiento aditivo.
- **B (haircut de sizing)**: si. `recorte` Beta y `factor` Wilson salen de la misma
  fila (`n`, `prob_real`).
- **C (detector de zonas)**: se calcula (`nivel`, `brier`, `peor_que_volado`) y
  **no lo usa el dinero**.

Ese solapamiento **es la causa raiz de la no monotonicidad**: A deberia ser una
funcion monotona de la probabilidad, y B una funcion de la evidencia (n), no de la
banda. Al vivir los dos en una tabla de deciles, los dos quedan forzados a ser
escalones de la probabilidad, y las fronteras de decil producen los saltos de
-11.4 pp (Moneyline 49->50, 59->60) y -15.9 pp (BTTS).

## 2A.9 — ALTERNATIVAS (sin implementar)

| criterio | 1. Suavizar los deciles | 2. Calibracion monotona continua | 3. Separar calibracion de haircut |
|---|---|---|---|
| R1 monotonicidad | **NO garantizada** | garantizada por construccion | garantizada por construccion |
| R2 stake | hereda el fallo de R1 | si, si el haircut no depende de p | si |
| R3 fronteras | elimina saltos | sin fronteras | sin fronteras |
| R4 incertidumbre | **no separa**: n sigue atado a la banda | no la trata | **la trata aparte, por diseno** |
| R5 deporte | no lo resuelve | no lo resuelve solo | obliga a declarar el ambito |
| R6 temporalidad | hay que anadirla igual | hay que anadirla igual | hay que anadirla igual |
| R7 OOS | no testeable sin split | testeable | testeable |
| interpretabilidad | alta | media (isotonic) / alta (parametrica) | alta |
| leakage | igual que hoy | igual que hoy si no se corrige | igual que hoy si no se corrige |
| sobreajuste | moderado | **alto con n chico** (el tramo de 187) | bajo si el haircut es 1-parametrico |
| versionado | malo (DELETE+rebuild) | necesita el tratamiento de `calibracion_coef` | idem |

**Contraejemplo que descarta la alternativa 1.** Interpolar entre puntos medios
solo es monotono si el mapeo `p_dicha -> p_real` ya lo es. En Moneyline lo es
(0.245, 0.331, 0.495, 0.540). **En BTTS no**: p_dicha 0.360/0.455/0.547/0.637 mapea
a p_real 0.451/0.510/0.560/**0.500**. El ultimo tramo baja. Suavizar convierte un
salto en una rampa descendente: sigue violando R1, solo que mas despacio.

### Recomendacion: **alternativa 3**, con un bloqueo previo

Es la unica que cumple R1, R2 y R4 **por construccion** y no por suerte de los
datos, y es la respuesta directa al diagnostico D: si el objeto hace dos trabajos,
la reparacion es separarlos, no alisarlos juntos.

Forma propuesta (a validar, no a implementar todavia):

```
P_DECIDE = P_MERCADO + s(n) * ( CAL(P_CAL) - P_MERCADO )
```

- `CAL` = calibracion **monotona** por (deporte, mercado), versionada con
  `effective_from` / `data_cutoff_at` igual que `calibracion_coef`.
- `s(n)` en [0,1] = encogimiento hacia el precio del mercado, funcion **solo de la
  evidencia**, nunca de la banda de probabilidad.
- Monotonicidad: `CAL` monotona y `s(n)` constante respecto a p, asi que
  `dP_DECIDE/dP_CAL = s(n) * CAL'(P_CAL) >= 0`. **R1 se cumple sin depender de los
  datos.**
- R4 queda explicito: menos muestra encoge hacia el mercado, nunca invierte el orden.
- R8 se cumple: `EV_DECIDE = P_DECIDE x momio - 1`, reconstruible exacto.
- Es la misma forma de encogimiento hacia el mercado que el auditor ya habia
  propuesto en Fase 1 como candidato y que quedo pendiente de backtest.

**Bloqueo previo, no negociable por R5:** hoy no existe **ninguna** observacion de
baseball en `modelo_backtest`. Ninguna calibracion de Moneyline derivada de futbol
puede gobernar dinero de MLB. La primera consecuencia del diseno no es matematica,
es de alcance: o se estima MLB con datos de MLB, o MLB entra por la rama
"nunca medido". Cualquiera de las dos es defendible; aplicar futbol a beisbol no.

**Tolerancia de R3, derivada y no elegida:** el salto admisible de P_DECIDE ante
un paso de 1 pp en P_CAL debe acotarse por el error estandar del tramo adyacente
mas chico. Para Moneyline t6 (n=187, p~0.54) eso es
`sqrt(0.54*0.46/187) = 3.6 pp`. Hoy el salto real es **-11.4 pp**, o sea **3.2
veces** el ruido de la propia estimacion. Con la alternativa 3 el salto es 0 por
construccion y la tolerancia solo acota el lado positivo.

### Regresiones obligatorias registradas

- Moneyline momio 2.20: `p=49 -> $110.07` contra `p=50 -> $0`.
- Moneyline momio 2.20: `p=59 -> $145.70` contra `p=60 -> $0`.
- BTTS: peor ruptura **-15.9 pp** de P_DECIDE y **-$235.91** de stake.
- Malla de aceptacion: P de 1% a 99% x mercado x deporte x momios representativos,
  detectando `dP_CAL > 0 && dP_DECIDE < 0` y `dEV > 0 && dstake < 0` no explicados
  por una restriccion de cartera con nombre.

---

## 2A.10 — WALK-FORWARD DE `zonas_confiables`

Reconstruccion estricta: TRAIN con eventos `fecha < T` y misma receta que
`recalcular_zonas_confiables` (deciles, `HAVING count>=100`); TEST solo con
eventos en `[T, T+1 mes)`. Cortes: 1-may, 1-jun, 1-jul, 1-ago de 2026.

### Brier fuera de muestra, prueba pareada por observacion

| mercado | n OOS | mejora media de Brier | t | veredicto |
|---|---|---|---|---|
| **Corners** | 2,472 | **+0.012946** | **4.93** | **significativo** |
| Doble Oportunidad | 2,020 | +0.000714 | 1.67 | no significativo |
| Moneyline | 3,030 | +0.000459 | 1.40 | no significativo |
| BTTS | 1,010 | +0.000856 | 0.35 | no significativo |
| Total Equipo | 3,030 | **-0.000517** | -1.19 | no significativo |
| Over/Under | 5,050 | **-0.000657** | -1.83 | no significativo |
| Tarjetas | 1,806 | **-0.001404** | -1.33 | no significativo |
| TODOS | 18,418 | +0.001535 | 3.68 | significativo **solo por Corners** |

Quitando Corners, la mejora global es **-0.000234**: negativa.
Y **Corners tiene el dinero apagado** desde Fase 1 (`corners_sin_modelo`).

**En ningun mercado que gobierna dinero `zonas_confiables` mejora la probabilidad
fuera de muestra de forma significativa.** El unico donde funciona esta apagado.

### Supervivencia de los sesgos concretos que el mandato pide verificar

| sesgo | train por pliegue | test por pliegue | mismo signo | veredicto |
|---|---|---|---|---|
| **ML t5 (+4.9)** | +2.3 / +2.2 / +3.9 | +3.4 / +7.6 / +10.4 | **3/3** | **SOBREVIVE** (y crece) |
| **ML t6 (+1.2)** | -1.4 (1 solo pliegue, n_tr=142) | +9.5 (n_te=45, SE 7.2) | **0/1** | **NO SOBREVIVE** |
| ML t4 (-1.7) | -3.3 / -2.6 / -1.5 | -1.7 / +0.7 / -2.4 | 2/3 | debil |
| **BTTS t5 (+9.1)** | +8.8 / +8.2 / +7.1 | +8.0 / +5.0 / **-1.9** | 2/3 | se apaga con el tiempo |
| **BTTS t7 (-13.7)** | -16.3 / -15.3 | -13.5 / -5.9 | **2/2** | sobrevive en signo, se encoge |
| BTTS t6 (+4.2) | +4.2 / +3.4 | +1.8 / **-8.4** | 1/2 | **falla, y a mas de 2 SE** |

**El detalle que importa economicamente:** el tramo que produce la peor
discontinuidad de dinero (Moneyline t6, banda 50-60%, el que tira el stake de
$145.70 a $0) es precisamente **el que NO sobrevive**: un solo pliegue, n=45 en
test, error estandar de 7.2 pp y el signo invertido.

**Conclusion 2A.10:** `zonas_confiables` **queda invalidada como estimador de
probabilidad**. Algunos sesgos individuales son reales (ML t5, BTTS t7), pero el
objeto en conjunto no aporta valor OOS medible en los mercados que mueven dinero,
y su aporte agregado fuera de Corners es negativo.

## 2A.11 — EVIDENCIA MLB

**Corrijo mi propia hipotesis previa.** MLB **NO** esta sin evidencia:

| fuente | N | cobertura |
|---|---|---|
| `oraculo_picks_tracking` liga='MLB' resueltos | **2,152** | 2026-05-04 a 2026-09-05 |
| ... con probabilidad y `match_date` | 2,076 | idem |
| ... con momio | 2,124 | idem |
| por mercado | **Moneyline 1,101** / Over/Under 1,049 / Handicap 2 | |
| `mlb_shadow_predicciones` con brier | 800 | |
| `badrino_partidos` con ambos lados + resultado | 386 | 2026-07-31 a 2026-09-06 |

Los 1,101 picks resueltos de MLB Moneyline son **mas** que los 853 de futbol del
tramo 5 que hoy los gobierna.

### Walk-forward propio de MLB (cortes 1-jul, 20-jul, 10-ago)

| mercado / tramo | sesgo TRAIN | sesgo TEST | mismo signo | lo que recibe hoy de futbol |
|---|---|---|---|---|
| **ML t5 (40-50%)** | +1.9 / +1.4 / +0.7 | **-0.4 / -3.4 / -4.0** | **0/3** | **+4.9** |
| ML t4 (30-40%) | +9.1 / +6.3 / +7.8 | -3.5 / +16.1 / +8.4 | 2/3 | -1.7 |
| **O/U t6 (50-60%)** | -5.6 / -5.0 / -5.7 | **-3.4 / -9.5 / -9.8** | **3/3** | **+0.3** |

**MLB tiene sesgo propio, estable, y de signo CONTRARIO al que recibe.**

- MLB Moneyline en la banda 40-50%: su dato dice entre **-0.4 y -4.0 pp**. Le
  aplicamos **+4.9 pp** de futbol. Error de direccion de ~**7.5 pp** sobre la
  probabilidad que decide el dinero. **6 de los 10 picks de MLB de hoy caen ahi.**
- MLB Over/Under en 50-60%: sesgo **-3.4 / -9.5 / -9.8** en 3 de 3 pliegues, la
  senal mas estable que encontre en todo el sistema. Futbol le pasa **+0.3**.

**El veredicto correcto no es `MLB_SIN_EVIDENCIA_PARA_HAIRCUT`.** Es:
**`MLB_TIENE_EVIDENCIA_PROPIA_Y_LA_CORRECCION_ACTUAL_VA_AL_REVES`.**

Salvedad declarada: `oraculo_picks_tracking` son picks **publicados**, no un barrido
sistematico como `modelo_backtest`. Es la poblacion correcta para estimar el sesgo
de los picks que el sistema realmente emite, pero no es un backtest neutral y hay
que decirlo al usarlo.

## 2A.12 — P_MARKET: que se puede construir de verdad

| deporte / mercado | ambos lados | de-vig posible | cobertura temporal | overround |
|---|---|---|---|---|
| **MLB Moneyline** | **401** partidos (386 con resultado) | si, 2 vias | 2026-07-31 a 2026-09-06 (**5 semanas**) | mediana **1.78%**, p10-p90 **1.62%-4.62%**, 0 valores absurdos |
| **Futbol 1X2** | **197** con los TRES lados | si | — | — |
| Futbol 1X2 parcial | **87** con solo home/away | **NO**: falta el empate | — | — |
| Futbol Over/Under | **294** con over y under | si | — | — |

Nota de metodo: `badrino_partidos.ml_home/ml_away` son **momios americanos enteros**,
no decimales. Mi primera medicion dio 0 partidos por no convertir; el dato estaba
bien y la consulta mal. Convertido (`+n -> 1+n/100`, `-n -> 1+100/n`) aparecen 401.

`1/momio` **no es** P_MARKET_FAIR: con overround mediano de 1.78% en MLB, usarlo
crudo infla cada lado ~0.9 pp. Con ambos lados el de-vig proporcional es trivial y
verificable. **Sin la contraparte no se construye**, y en futbol 1X2 faltan 87 de
284 casos (el 31%).

**Limite duro:** P_MARKET_FAIR verificable existe para ~401 partidos de MLB y ~197
de futbol. Contra 2,152 picks de MLB resueltos y 30,876 filas de backtest de futbol,
**la cobertura es minoritaria**. Cualquier arquitectura que dependa de P_MARKET
solo puede validarse en ese subconjunto.

## 2A.13 — COMPARACION A vs B

| criterio | **A** calibracion + haircut de stake | **B** ensemble modelo+mercado |
|---|---|---|
| monotonicidad | garantizada si CAL es monotona y `confidence` no depende de P | garantizada si `w` no depende de P |
| continuidad | si | si |
| datos necesarios | solo historico propio: **2,152 MLB + 30,876 futbol** | **exige P_MARKET_FAIR: 401 MLB + 197 futbol** |
| validable OOS hoy | **si, en todo el historico** | **no: solo en el 19% de MLB y el 0.6% de futbol** |
| leakage | controlable con cutoff + walk-forward | idem, pero con muestra 5x menor |
| semantica | `confidence` reduce EXPOSICION, no reescribe la probabilidad | **cambia el significado de la probabilidad**: es otro modelo |
| versionado | igual que `calibracion_coef` | igual, mas la version del snapshot de mercado |
| riesgo | bajo | alto: encoge hacia un precio con 5 semanas de historia |

**A gana por disponibilidad de evidencia, no por elegancia.** B no es rechazable en
teoria — es **no evaluable hoy**: no hay P_MARKET_FAIR suficiente para demostrar
mejora OOS en Brier/log loss, y el mandato prohibe adoptarla sin esa demostracion.

**Consecuencia para mi propia recomendacion anterior:** la formula que propuse en
2A.9, `P_MERCADO + s(n)*(CAL(P_CAL) - P_MERCADO)`, **es arquitectura B**. Con
401 partidos de MLB y 197 de futbol con precio fair verificable, **no puedo
demostrarla**. La retiro como recomendacion y paso a A.

## 2A.14 — CANON ECONOMICO (diseno, sin implementar)

Una sola salida, un solo significado por nombre:

| campo | definicion | quien lo produce |
|---|---|---|
| `p_raw` | salida cruda del motor del deporte | motor por deporte |
| `p_fair` | `CAL_deporte_mercado(p_raw)`, **monotona**, versionada con `effective_from`/`data_cutoff_at` | calibracion unica |
| `ev_fair` | `p_fair * momio - 1` | derivado |
| `confidence` | en [0,1], **funcion solo de la evidencia** (n, varianza del tramo), nunca de la banda de P | motor de incertidumbre |
| `kelly_base` | `Kelly(p_fair, momio) * fraccion` | sizing |
| `risk_multiplier` | producto de restricciones con nombre (cartera, correlacion, veto) | riesgo |
| `stake_pre_portfolio` | `kelly_base * confidence` | sizing |
| `stake_final` | `stake_pre_portfolio * risk_multiplier`, con cap y floor | sizing |
| `reason_code` | por que se bloqueo o se recorto | todos |

Solo si B llegara a demostrarse: `p_market_fair`, `p_ensemble`, `ev_ensemble`.

`P_CAL2` **no sobrevive**: `mejor_oportunidad_hoy` deja de recalibrar por su cuenta.
Ninguna superficie recalcula: todas leen `p_fair` / `ev_fair` / `stake_final`.

Punto fino que el diseno resuelve: hoy la incertidumbre **reescribe la
probabilidad** (`p_decide`), asi que el numero que la pantalla llama "probabilidad"
ya no es una probabilidad, es una probabilidad castigada. En A la probabilidad
sigue siendo `p_fair` y el castigo vive en `confidence`, que es lo que reduce
exposicion. Eso es lo que hace auditable la cadena.

## 2A.15 — CONTRATO POR SUPERFICIE

| superficie | proposito | debe mostrar | debe ordenar/filtrar por | prohibido |
|---|---|---|---|---|
| **Reto13M** | recomendacion economica | `p_fair`, `ev_fair`, `confidence`, `stake_final`, `reason_code` | `ev_fair` / `stake_final` | recalcular nada |
| **mejor_oportunidad_hoy** | recomendacion economica | lo mismo | **`ev_fair`** (hoy ordena por un EV propio) | su `P_CAL2` y su `ev_pct` propio; publicar `kelly_pct` que no venga de la autoridad de sizing |
| **analisis_completo** | diagnostico | `p_raw`, `p_fair`, `ev_fair` **etiquetados como diagnostico** | no ordena dinero | presentarse como accionable |
| **destacados_cache** | vitrina | `ev_fair` | `ev_fair` | EV propio |
| **v_oraculo_canonico** | trazabilidad/histórico | `p_raw`, `p_fair`, `ev_fair` con su fecha | no aplica | servir de fuente a UI de recomendacion sin pasar por la autoridad |

Regla: **una superficie que recomienda una accion economica ordena y filtra por el
mismo EV que gobierna el dinero.** Una que muestra EV del modelo como diagnostico
lo etiqueta y no lo presenta como accionable.

## Elementos a deprecar

1. `zonas_confiables` **como estimador de probabilidad** (invalidada OOS). Su papel
   de medir evidencia (`n`) puede sobrevivir dentro de `confidence`.
2. El sesgo aditivo por decil dentro de `kelly_stake`.
3. `zona_realidad` como bandeador de deciles para dinero.
4. `P_CAL2` y el `ev_pct` propio de `mejor_oportunidad_hoy`.
5. `ev_pct_declarado` como campo publicable (queda solo para auditoria).
6. La etiqueta "Prob. del motor" sobre una probabilidad ya calibrada, y
   `prob_cruda_pct` como nombre de P_CAL.
7. El fallback silencioso a probabilidad cruda cuando `fuera_de_rango = true`.

## Pruebas adversariales que debera superar la implementacion

1. **Malla completa**: P de 1% a 99% paso 1, por mercado y deporte, con momios
   representativos. Cero casos de `dP_FAIR > 0 && dP_DECIDE < 0` y cero de
   `dEV > 0 && dstake < 0` no explicados por una restriccion con nombre.
2. **Regresiones obligatorias**: Moneyline momio 2.20 en 49->50 y 59->60 (hoy
   $110.07->$0 y $145.70->$0); peor ruptura BTTS (-15.9 pp, -$235.91).
3. **Cero transferencia entre deportes**: inyectar un sesgo extremo en la
   calibracion de futbol no puede mover ni un centavo de un pick de MLB.
4. **Corte temporal**: reconstruir un pick pasado no puede usar una calibracion
   posterior a su `game_date` (mismo candado que Fase 1.5).
5. **Coherencia de superficies**: para el mismo pick, el orden y el signo del EV
   deben coincidir en Reto13M y en `mejor_oportunidad_hoy`. Hoy fallan en 4 de 16.
6. **Sin fallback mudo**: si no hay calibracion valida, la salida es un
   `reason_code`, nunca la probabilidad cruda disfrazada.

---

## 2A.16 — MAPA DE POBLACIONES

| dataset | clase | N | fechas | mercados | incluye rechazados | seleccion depende de P/EV/momio | resultado en todas | version modelo | corte temporal |
|---|---|---|---|---|---|---|---|---|---|
| **`bt_mlb_ml`** | **A. universo completo** | **1,056** | 2026-05-20 a 2026-08-30 | MLB Moneyline, **lado LOCAL de cada juego** | si (no hay seleccion) | **no** | si (1056/1056) | no | implicito |
| **`badrino_backtest`** | **A. universo completo** | 2,580 | 2026-07-31 a 2026-08-19 | MLB: Total Equipo 1032, ML 516, Run Line 516, O/U 516 | si | **no** | si | no | implicito |
| `modelo_backtest` | A. universo completo | 30,876 | 2026-02-12 a 2026-08-26 | 7 mercados, **100% soccer** | si | no | si | no | implicito, **congelado el 26-ago** |
| `modelo_backtest_v2` | A. universo completo | 61,321 | **2023-07-01 a 2024-11-03** | 6 mercados | si | no | si | no | historico viejo |
| **`oraculo_picks_tracking`** | **B. picks publicados** | 3,462 (2,152 MLB) | 2026-05-04 a 2026-09-05 | ML 1101, O/U 1049 (MLB) | **NO** | **SI** | no (resueltos 2,152) | no | `match_date` |
| `mlb_shadow_predicciones` | **D. shadow** | 800 (400+400) | 2026-07-29 a 2026-08-30 | MLB ML | si | no | si | **si (`model_version`)** | `game_date` |
| `predicciones_modelo` | A/E, con mercado | 1,633 (385 baseball) | — | 1X2 + mkt_prob_* | si | no | 1,536 | no | `capturado_at`, `horas_antes` |
| `motor_snapshot` | A. universo, ventana corta | 2,640 | 2026-09-03 a 2026-09-06 | soccer 2112 / baseball 528 | si | no | 1,012 | no | `match_date` |
| `nfl_backtest` | vacio | **0** | — | — | — | — | — | — | — |

**Respuesta a la pregunta del auditor: SI existe el universo completo de MLB.**
`bt_mlb_ml` (1,056 juegos, un lado fijo, sin seleccion) y `badrino_backtest`
(2,580). Ese es el dataset correcto para calibrar, no `oraculo_picks_tracking`.

Nota: los 1,056 de `bt_mlb_ml` son exactamente el `juegos: 1056` que
`predecir_mlb` reporta en `rango_medido_pct`. Es la fuente del coeficiente id 6.

## 2A.21 — EFECTO DE SELECCION EN MLB: medido, y es enorme

| poblacion | N | P media | P sd | p10-p90 | tasa real | sesgo | Brier |
|---|---|---|---|---|---|---|---|
| **Universo** `bt_mlb_ml` | 1,056 | **0.5230** | 0.0455 | 0.467-0.582 | 0.5189 | **-0.41 pp** | 0.24732 |
| **Publicados** tracking | 1,074 | **0.4278** | 0.0911 | 0.334-0.495 | 0.4479 | **+2.01 pp** | 0.25114 |

- La media baja de **52.3% a 42.8%** y la dispersion **se duplica** (0.046 -> 0.091).
  El sistema publica casi exclusivamente **no-favoritos**. Es la explicacion
  mecanica de #126.
- **En el universo el motor esta practicamente insesgado: -0.41 pp.** El +2.01 pp
  de los publicados es **sesgo condicional a seleccion**.

**El auditor tenia razon.** El -4% de MLB que medi en el turno anterior sale de
`oraculo_picks_tracking`, o sea de `P(resultado | p_raw, publicado)`. **No puede
usarse como calibrador universal.** Sigue siendo prueba suficiente de que el
+4.9 de futbol es indefendible, pero no es el numero que va al codigo.

Salvedad de metodo: `bt_mlb_ml` es siempre el lado LOCAL; los publicados pueden ser
cualquiera de los dos. El desplazamiento de la media (52.3 -> 42.8) no se explica
solo por el lado: los rangos son comparables (37.6-65.4 local implica 34.6-62.4
visitante). La seleccion es real.

## 2A.17 — ¿MERECE EL P_CAL ACTUAL SER P_FAIR? **NO, EN NINGUN DEPORTE**

### MLB Moneyline, sobre el universo completo (`bt_mlb_ml`)

| ventana | n | Brier P_RAW | Brier P_CAL | tasa base | mejora de CAL | bias raw | bias cal |
|---|---|---|---|---|---|---|---|
| may-jun | 335 | 0.24846 | 0.25006 | 0.24998 | **-0.00160** | -1.50 | -2.73 |
| jul | 354 | 0.24739 | 0.24886 | 0.24980 | **-0.00147** | -1.20 | -2.14 |
| ago | 367 | 0.24620 | 0.24674 | 0.24865 | **-0.00054** | +1.35 | +0.28 |
| **TODO** | **1,056** | **0.24732** | **0.24850** | 0.24964 | **-0.00119** | **-0.41** | **-1.49** |

**P_CAL pierde en 3 de 3 ventanas** y empeora el sesgo de -0.41 a -1.49 pp.
**Veredicto MLB Moneyline: C — P_CAL empeora. No usar como P_FAIR.**

### Futbol, sobre `modelo_backtest` (**en muestra**: el coeficiente id 7 se ajusto
sobre jul-2023 a sep-2026, que incluye este periodo. Es una **cota superior** de su
desempeno)

| mercado | n | Brier raw | Brier cal | tasa base | mejora |
|---|---|---|---|---|---|
| Moneyline | 4,065 | 0.20936 | 0.20993 | 0.22222 | **-0.00058** |
| Over/Under | 6,775 | 0.20993 | 0.21025 | 0.24802 | **-0.00032** |
| Doble Oportunidad | 2,710 | 0.22265 | 0.22275 | 0.23544 | -0.00010 |
| Total Equipo | 4,065 | 0.20945 | 0.20942 | 0.23466 | +0.00003 |
| BTTS | 1,355 | 0.25304 | 0.25229 | 0.24989 | +0.00075 |
| **TODOS** | **18,970** | **0.21460** | **0.21479** | 0.24939 | **-0.00019** |

**Ni siquiera en muestra la calibracion de futbol aporta.** Es indistinguible de la
identidad, con signo ligeramente negativo. Y el sesgo crudo de Moneyline es
**0.00 pp exacto**: el motor de futbol ya esta insesgado; calibrarlo lo desvia a
-0.87.

**Veredicto futbol: B — indistinguible. Preferir la solucion mas simple: identidad.**

Dato que si importa y conviene no perder de vista: en futbol el motor **si tiene
discriminacion real** (Brier 0.2146 contra tasa base 0.2494). En MLB apenas
(0.24732 contra 0.24964). Son dos motores de calidad muy distinta.

## 2A.18 — CONTRATO DE P_FAIR

```
P_FAIR = mejor estimacion probabilistica disponible del evento antes del partido
```

En [0,1], con significado probabilistico intacto, y con provenance obligatoria:
`modelo`, `calibrador`, `version`, `data_cutoff`, `as_of`, `mercado`, `deporte`.

**Estado hoy, con la evidencia medida:**

| deporte / mercado | P_FAIR | `calibration_status` |
|---|---|---|
| MLB Moneyline | **P_RAW** | `CALIBRACION_RECHAZADA_OOS` (pierde 3/3 ventanas) |
| MLB Over/Under | **P_RAW** | `SIN_CALIBRACION_DEMOSTRADA` |
| Futbol (todos) | **P_RAW** | `SIN_CALIBRACION_DEMOSTRADA` (indistinguible incluso en muestra) |
| NFL | **P_RAW** | `SIN_MODELO` (dinero apagado, `nfl_backtest` vacio) |

Identidad explicita **no es un error**: es la conclusion honesta de la medicion.
`P_CAL2` no existe. Ninguna superficie recalibra.

## 2A.19 — DISEÑO DE `confidence`

**Definicion:** cuanta exposicion economica estamos dispuestos a asumir dada la
evidencia sobre la estimacion. **No toca P_FAIR.** `0 <= confidence <= 1`.

```
stake_pre_portfolio = kelly_base * confidence
stake_final         = stake_pre_portfolio * risk_multiplier   (cartera, CDaR, vetos)
```

Regla estructural que garantiza R1/R2: **`confidence` no puede tener a P_FAIR entre
sus argumentos.** Si no depende de P, no puede introducir no monotonicidad ni
fronteras. Eso es exactamente lo que rompio `zonas_confiables`.

### Fuentes candidatas, y si hay evidencia HOY para cada una

| fuente | evidencia disponible | veredicto |
|---|---|---|
| error OOS del calibrador | **ninguna**: no sobrevive ningun calibrador | **no usable** |
| discriminacion OOS del motor (Brier vs tasa base) | **si**: futbol 0.2146 vs 0.2494; MLB 0.24732 vs 0.24964 | **usable, y separa bien los dos motores** |
| tamano efectivo de muestra por deporte/mercado | si: 4,065 ML futbol / 1,056 ML MLB / 516 O/U MLB | usable |
| estabilidad entre ventanas walk-forward | si: la acabo de medir por ventana | usable |
| antiguedad / drift | si: `modelo_backtest` congelado el 26-ago (10 dias); `bt_mlb_ml` al 30-ago | usable |
| cobertura de mercado/liga | si | usable |
| calidad de inputs (`data_completeness_pct`) | **diseñada en Fase 1 y NUNCA poblada** | **no usable todavia** |
| `calibration_status` | si | usable como puerta, no como escala |

### Forma propuesta

```
confidence = min( c_skill , c_muestra , c_estabilidad , c_frescura )
```

- Un **minimo**, no un producto: cuatro factores multiplicandose producen recortes
  compuestos que nadie sabe explicar. Con `min` siempre hay **una** razon dominante,
  y esa razon es el `confidence_reason`.
- Cada factor es una funcion **continua y monotona de su propia evidencia**, acotada
  en [0,1], y **constante respecto a P_FAIR**.
- Cada factor se calcula **por (deporte, mercado)**, nunca compartido entre deportes.
- **Ningun factor se ajusta para maximizar ROI.** `c_skill` sale de la comparacion
  contra la tasa base, `c_muestra` del tamano efectivo, `c_estabilidad` de la
  dispersion entre ventanas walk-forward, `c_frescura` de la antiguedad del ultimo
  dato de entrenamiento.

Consecuencia directa y deseada de lo medido: MLB tendria `c_skill` bajo (su motor
apenas le gana a la tasa base) y futbol alto. **Eso es lo que hoy hace mal
`zonas_confiables`: castiga por banda de probabilidad en vez de por calidad del
motor.**

Lo que queda pendiente de medir antes de fijar cualquier forma funcional: la
relacion entre cada factor y el desempeño OOS. **No propongo numeros todavia.**

## 2A.20 — DESCOMPOSICION DE KELLY

`kelly_full = (P_FAIR*(momio-1) - (1-P_FAIR)) / (momio-1)`, y nada mas.
Entrada: `P_FAIR`, `momio`. Sin calibracion, sin Wilson, sin Beta, sin sesgo, sin
confidence, sin caps, sin cartera.

Mapa de lo que hoy vive dentro de `kelly_stake` y a que capa pertenece:

| componente actual | capa correcta |
|---|---|
| `p := p_prob/100` | 1. probability estimation |
| `zona_realidad` + `v_sesgo` (sesgo del tramo) | 1. probability estimation — **y queda DEPRECADO** |
| `v_recorte` (Beta p10, Jeffreys) | **3. confidence** (hoy mal ubicado: reescribe P) |
| `v_factor_n` (Wilson) | **3. confidence** (hoy mal ubicado: reescribe P) |
| `f_full` | **2. Kelly** |
| `v_fraccion` (0.25) | 2. Kelly (fraccional) |
| `stake_techo` = bankroll * `stake_max_pct` | 4. bankroll/risk caps |
| `v_min` (piso $20 -> 0) | 4. bankroll/risk caps |
| `bankroll_disponible()` | 4. bankroll/risk caps |
| `p_techo_custom` (solo aprieta) | 4. bankroll/risk caps |
| CDaR / `exposicion_viva` (en `reto_picks_hoy`) | 5. portfolio risk |
| `rongol_veto` | 5. portfolio risk |

**El defecto de arquitectura en una linea:** hoy las capas 1 y 3 estan fusionadas —
la incertidumbre reescribe la probabilidad en vez de reducir la exposicion. Por eso
`prob_que_decide_pct` no es una probabilidad, y por eso la cadena no es auditable.

## 2A.22 — OBJETO CANONICO

| campo | definicion unica |
|---|---|
| `p_raw` | salida del motor del deporte, sin transformar, en [0,1] |
| `p_fair` | mejor estimacion disponible. Hoy = `p_raw` en todos los deportes |
| `calibration_status` | `SIN_CALIBRACION_DEMOSTRADA` / `CALIBRACION_RECHAZADA_OOS` / `CALIBRADO` / `SIN_MODELO` |
| `calibration_version` | id del calibrador aplicado, NULL si identidad |
| `calibration_data_cutoff` | hasta que fecha llegan los datos del calibrador |
| `momio` | precio decimal usado, del lado del pick |
| `odds_source` | casa / tabla origen |
| `odds_timestamp` | cuando se capturo ese precio |
| `ev_fair` | `p_fair * momio - 1` |
| `confidence` | [0,1], multiplicador de exposicion, independiente de `p_fair` |
| `confidence_reason` | cual de los factores mando (el del `min`) |
| `confidence_version` | version del motor de confianza |
| `kelly_full` | Kelly puro sobre `p_fair` y `momio` |
| `kelly_fractional` | `kelly_full * fraccion_kelly` |
| `risk_multiplier` | producto de restricciones de cartera **con nombre** |
| `stake_pre_portfolio` | `bankroll * kelly_fractional * confidence` |
| `stake_final` | tras cap, floor y `risk_multiplier` |
| `reason_code` | por que se bloqueo o recorto |
| `as_of` | fecha de referencia usada (candado de Fase 1.5) |
| `deporte`, `mercado`, `espn_event_id` | identidad |
| `poblacion_evidencia` | **A/B/C/D**: de que poblacion salio la evidencia que sostiene `confidence` |

`poblacion_evidencia` es campo nuevo y no cosmetico: es lo que impide volver a
confundir `P(resultado|p)` con `P(resultado|p, publicado)`.

## 2A.23 — PLAN DE MIGRACION

| fase | que se hace | rollback |
|---|---|---|
| **A** | Crear `v_decision_canonica` (o funcion) que produzca el objeto completo **en paralelo**, sin que nadie lo lea. `p_fair = p_raw`, `confidence` en una version 0 conservadora | `DROP`; nada la lee |
| **B** | Tabla de comparacion shadow: para cada pick vivo, guardar lado a lado lo que dice `kelly_stake` y lo que dice el canonico. **Acumular >= 2 semanas** | truncar la tabla |
| **C** | Migrar superficies de LECTURA (`mejor_oportunidad_hoy`, `analisis_completo`, `destacados_cache`) a leer `ev_fair` del canonico. **El dinero sigue saliendo de `kelly_stake`** | revertir cada vista, una por una |
| **D** | Migrar el sizing: `reto_picks_hoy` pasa a leer `stake_final` del canonico | `reto_picks_hoy` vuelve a `kelly_stake`; ambas coexisten |
| **E** | Deprecar `zonas_confiables` de la cadena de dinero y borrar el sesgo aditivo de `kelly_stake` | la tabla sigue existiendo para diagnostico |

**Ajuste al orden propuesto por el auditor:** C antes que D es correcto, pero
**B debe durar lo suficiente para acumular picks resueltos**, no solo generados.
Con ~16 picks vivos por dia, dos semanas dan ~220 observaciones: suficiente para
detectar divergencias de decision, insuficiente para concluir sobre acierto. La
comparacion de B es de **coherencia**, no de rendimiento.

## PRUEBAS DE ACEPTACION (las 13, con su forma de verificacion)

| # | prueba | como se verifica |
|---|---|---|
| 1 | P_FAIR monotona respecto del calibrador | malla P=1..99 por deporte/mercado |
| 2 | Kelly base monotona | analitica + malla |
| 3 | 49->50 no reduce stake | regresion registrada (hoy $110.07 -> $0) |
| 4 | 59->60 no reduce stake | regresion registrada (hoy $145.70 -> $0) |
| 5 | BTTS sin salto de -15.9 pp | regresion registrada |
| 6 | soccer no mueve nada de MLB | inyectar sesgo extremo en calibracion soccer, medir 0 centavos de cambio en MLB |
| 7 | `P_CAL2` inexistente | grep de catalogo: 0 superficies llaman `calibrar_prob_motor*` fuera de la autoridad |
| 8 | ninguna superficie recalcula | idem, mas revision de las 5 superficies |
| 9 | EV mostrado = EV que decide en superficies accionables | hoy fallan 4 de 16; debe ser 0 de N |
| 10 | fallback explicito | `calibration_status` presente siempre; 0 casos de probabilidad cruda sin etiqueta |
| 11 | corte temporal respetado | reusar la bateria A-E de Fase 1.5 |
| 12 | no regresion de Fase 1.5 | `invariantes_temporales().ok = true` + event trigger activo |
| 13 | `EXP_OFF = 0.50` | grep en `predecir_mlb` |

---

# FASE 2 / 2A.24-2A.31 — IMPLEMENTACION V2 EN PARALELO

Nada de esto gobierna dinero. Ningun consumidor productivo lo lee.
`kelly_stake` intacta, `zonas_confiables` intacta, `EXP_OFF = 0.50`.

## 2A.25 — Kelly puro: `kelly_full_v2(p_fair, momio)`

```
f = (p*momio - 1) / (momio - 1) = EV_FAIR / b
```

Declarada **IMMUTABLE**, y eso no es cosmetico: una funcion IMMUTABLE **no puede
consultar tablas**. El aislamiento respecto de `zonas_confiables`, Wilson, Beta,
bankroll, CDaR y RONGOL es una propiedad del motor de Postgres, no una promesa del
comentario. Ademas Kelly resulta ser el EV dividido entre la ganancia neta, asi que
R8 (reconstruir el EV desde P_FAIR y momio) se cumple por identidad algebraica.

`df/dp = momio/(momio-1) > 0` para todo momio > 1: **estrictamente creciente, sin
depender de datos**.

| prueba | resultado |
|---|---|
| EV <= 0 implica Kelly <= 0 (299 casos) | PASS |
| monotonicidad (686 pasos) | PASS |
| formula analitica exacta | PASS, desviacion maxima 0.000000000000000 |
| limite P->1 = 1.0 ; P->0 = -1/(m-1) | PASS |
| momio invalido devuelve NULL | PASS |
| es IMMUTABLE (no puede leer tablas) | PASS (`provolatile = i`) |

No se recorta en 0 dentro de la funcion a proposito: un Kelly negativo es
informacion real. El recorte vive en la capa de sizing.

## 2A.24 — `calibracion_estado_v2` y `decision_canonica_v2`

`calibracion_estado_v2` (deporte, mercado) con `mercado = '*'` como regla por
defecto. **Todas las filas declaran identidad.** Un CHECK
(`chk_identidad_sin_version`) impide declarar `calibration_version` sin estado
`CALIBRADO`: no puede volver a existir una calibracion silenciosa como fue P_CAL2.

| deporte | mercado | estado | evidencia |
|---|---|---|---|
| baseball | Moneyline | `CALIBRACION_RECHAZADA_OOS` | pierde 3/3 ventanas en `bt_mlb_ml` |
| baseball | `*` | `SIN_CALIBRACION_DEMOSTRADA` | no evaluado |
| soccer | Moneyline, O/U, BTTS, Total Equipo, Doble Oportunidad | `CALIBRACION_NO_JUSTIFICADA` | empeora **en muestra**; no hay prueba OOS |
| soccer | `*` | `SIN_CALIBRACION_DEMOSTRADA` | no evaluado |
| football | `*` | `SIN_MODELO` | `nfl_backtest` vacio |

`decision_canonica_v2` produce los 21 campos + provenance. Si alguna fila llegara a
declarar `CALIBRADO` sin calibrador conectado, **lanza excepcion** en vez de devolver
identidad callada.

## 2A.26/2A.27 — confidence: componentes SI, formula NO

`confidence_componentes_v2` guarda la **variable cruda** de cada componente con su
dataset, poblacion (A/B/C/D), ventana, metodo, cutoff y **razon economica**. No
guarda un puntaje normalizado: la forma funcional no esta decidida y no se inventa.

`c_skill` medido como Skill Score contra la tasa base:

| deporte / mercado | Skill Score | lectura |
|---|---|---|
| soccer Over/Under | **0.1536** | el mejor motor del sistema |
| soccer Total Equipo | 0.1074 | |
| soccer Moneyline | 0.0579 | |
| soccer Doble Oportunidad | 0.0543 | |
| **baseball Moneyline** | **0.0093** | apenas le gana a la tasa base: **16 veces menos skill que O/U de futbol** |
| **soccer BTTS** | **-0.0126** | **NEGATIVO**: peor que la tasa base. Candidato a bloqueo, no a recorte |

Esa tabla es la razon economica del diseno: **la exposicion debe escalar con la
calidad del motor, no con la banda de probabilidad**. Es exactamente lo que
`zonas_confiables` hace al reves.

**Decision de 2A.27: no hay evidencia todavia para elegir agregador.** Por tanto en
V2 `confidence = 1.0` con `confidence_reason = PENDIENTE_DE_VALIDACION`. Un 1.0
declarado es preferible a un haircut inventado.

## 2A.28 — Monotonicidad: PASS

Malla P = 1%..99% x 5 momios x 5 combinaciones deporte/mercado = **2,475 filas,
2,450 pasos**. Cero violaciones de `dEV >= 0`, `dKelly >= 0`, `dStake_pre >= 0`.

Las tres regresiones obligatorias, V1 contra V2:

| caso | V1 P_decide | V1 stake | V2 P_fair | V2 stake |
|---|---|---|---|---|
| ML 49% | 49.5 | **$110.07** | 49.0 | $97.50 |
| ML 50% | **42.5** | **$0** | 50.0 | **$125.00** |
| ML 59% | 50.8 | **$145.70** | 59.0 | $300.00 |
| ML 60% | **39.4** | **$0** | 60.0 | **$300.00** |
| BTTS 59% | 54.0 | **$235.91** | 59.0 | $300.00 |
| BTTS 60% | **38.1** | **$0** | 60.0 | **$300.00** |

**Las tres discontinuidades desaparecen por completo.** No es "salto menor": el
salto no existe, porque no hay bucket que cruzar.

## 2A.29 — Aislamiento entre deportes: PASS

Prueba adversarial en subtransaccion con rollback. Se mutaron a la vez **todas** las
fuentes exclusivas de un deporte (`calibracion_estado_v2`, `confidence_componentes_v2`,
`calibracion_coef`) mas `zonas_confiables` completa:

| direccion | resultado |
|---|---|
| mutar soccer | **MLB identico bit a bit = true**, y soccer SI cambio (el camino estaba vivo) |
| mutar MLB | **soccer identico bit a bit = true**, y MLB SI cambio |

El aislamiento es **por diseno**: la busqueda en `calibracion_estado_v2` es por
(deporte, mercado) y no existe fila `'*'` global. No hay forma de que un deporte lea
la evidencia de otro.

## 2A.30 — Shadow V1 vs V2: mide COHERENCIA, y el resultado exige cautela

| clase | n | suma V1 | suma V2 |
|---|---|---|---|
| **V1 no apuesta / V2 si** | 7 | $0 | $1,094.24 |
| **contradiccion de signo** | 6 | $0 | $752.07 |
| mismo signo, stake distinto | 2 | $156.01 | $120.97 |
| **TOTAL (15 picks)** | | **$156.01** | **$1,967.28** |

**V2 dimensionaria 12.6 veces mas que V1. Esto NO significa que V2 sea mejor: es la
consecuencia directa de que su haircut todavia no existe.**

Desglose de por que V1 dice $0 donde V2 apuesta:

| motivo de V1 | n | V2 pondria |
|---|---|---|
| **rongol** (capa de cartera) | **9** | $1,322.43 |
| kelly (el haircut de V1) | 3 | $223.88 |
| muestra_chica | 1 | $300.00 |

**Lectura honesta: 9 de las 13 divergencias no son del modelo, son de la capa de
cartera**, que V2 todavia no tiene (`portfolio_multiplier = 1.0` por diseno en este
bloque). La divergencia atribuible a la capa de probabilidad son 4 picks, $523.88.

Conclusion operativa: **V1 esta mal construido pero esta conteniendo exposicion**.
Apagarlo antes de tener `confidence` validado y la capa de cartera portada
multiplicaria el riesgo. Ese es el argumento mas fuerte para respetar el orden de
migracion C -> D -> E y no adelantarlo.

## 2A.31 — Mapa de campos por superficie (sin migrar todavia)

| superficie | campo actual | campo V2 que lo reemplazara |
|---|---|---|
| Reto13M | `probabilidad_pct` ("Prob. del motor") | `p_fair` + `calibration_status` |
| Reto13M | `prob_que_decide_pct` | **desaparece** (la incertidumbre ya no reescribe P) |
| Reto13M | `ev_pct` ("EV real") | `ev_fair_pct` |
| Reto13M | `ev_pct_declarado` | **se elimina** (era el mismo numero con otro nombre) |
| Reto13M | `factor_muestra` | `confidence` + `confidence_reason` |
| Reto13M | `monto_autorizado` | `stake_final_v2` |
| Reto13M | `bloqueado_por` | `reason_code` |
| mejor_oportunidad_hoy | `prob_cruda_pct` | `p_raw` (y deja de llamarse "cruda" a una calibrada) |
| mejor_oportunidad_hoy | `prob_pct` (**P_CAL2**) | **se elimina** |
| mejor_oportunidad_hoy | `ev_crudo_pct` / `ev_pct` | **un solo** `ev_fair_pct` |
| mejor_oportunidad_hoy | `kelly_pct`, `techo_kelly`, `piso_ev` | `kelly_fractional`, `stake_final_v2`, `reason_code` |
| analisis_completo | `ev_pct` propio | `ev_fair_pct` **etiquetado como diagnostico** |
| destacados_cache | EV propio | `ev_fair_pct` |
| v_oraculo_canonico | `ev_pct` de canonico | `p_raw`, `p_fair`, `ev_fair_pct` con `as_of` |

## Invariantes de Fase 1.5 revalidados

| invariante | estado |
|---|---|
| `invariantes_temporales().ok` | **true** |
| `tg_candado_temporal` habilitado | **1** |
| `EXP_OFF` | **0.50** |
| shadow MLB: lectores fuera de su generador | **0** |
| `kelly_stake` intacta (sigue leyendo `zona_realidad`) | si |
| consumidores productivos de `decision_canonica_v2` | **NINGUNO** |

## Criterio de salida del bloque

| # | criterio | estado |
|---|---|---|
| 1 | objeto V2 existe en paralelo | **PASS** |
| 2 | P_FAIR con provenance explicito | **PASS** (`calibracion_estado_v2`) |
| 3 | Kelly puro aislado | **PASS** (IMMUTABLE) |
| 4 | no existe P_CAL2 | **PASS** (V2 no llama a ningun calibrador) |
| 5 | V2 monotonico antes de cartera | **PASS** (2,450 pasos) |
| 6 | soccer y MLB aislados | **PASS** (bit a bit, ambas direcciones) |
| 7 | ninguna superficie productiva cambio | **PASS** |
| 8 | ningun stake real cambio | **PASS** |
| 9 | EXP_OFF sigue 0.50 | **PASS** |
| 10 | comparacion V1 vs V2 reproducible | **PASS** (`shadow_v1_v2`) |

---

# FASE 2 / 2A.32-2A.39

## 2A.32 — Pureza de `kelly_full_v2`: CORRECCION ACEPTADA Y PRUEBA REAL

**Me equivoque.** Dije "Postgres le prohibe consultar tablas". Falso: `IMMUTABLE` es
una **declaracion al planificador**, no una restriccion. Postgres permite que una
funcion IMMUTABLE lea tablas; simplemente asume que no lo hace y cachea en
consecuencia, produciendo resultados incorrectos. No era prueba de nada.

Prueba verificada: la funcion tenia **cuerpo de cadena** (`prosqlbody IS NULL`), y
con cuerpo de cadena Postgres **no registra ninguna dependencia**. El resultado de
`pg_depend` habria sido "0 dependencias" para cualquier funcion, pura o no.

**Correccion:** se reescribio con **cuerpo SQL estandar** (`RETURN ...`), que Postgres
parsea al crear la funcion y cuyas referencias **si** quedan registradas.

Dependencias reales tras el cambio:

| clase | objeto | deptype |
|---|---|---|
| `pg_namespace` | `public` | n |

Nada mas. Ni `pg_class`, ni `pg_proc`. Los operadores numericos no aparecen porque
son objetos *pinned* del sistema, que `pg_depend` excluye por definicion. Cualquier
referencia a una tabla, vista o funcion de usuario **si** apareceria.

### `inv_kelly_puro_v2()`: siete comprobaciones

| # | comprobacion | por que |
|---|---|---|
| k1 | existe exactamente una | evita overloads |
| **k2** | **cuerpo parseado, no cadena** | **es la que hace valida a k3** |
| **k3** | **0 dependencias a `pg_class` / `pg_proc`** | la prueba de que no lee tablas |
| k4 | `provolatile = 'i'` | coherencia declarada |
| k5 | no `SECURITY DEFINER` | no escala privilegios |
| k6 | sin `proconfig` | no manipula `search_path` |
| k7 | sin tokens de estado | `now(`, `random(`, `current_setting`, `nextval`, `clock_timestamp`, `current_user`, `txid_`, `gen_random`... |
| k8 | dos argumentos | firma cerrada |

Conectada como regla **I4** al event trigger `tg_candado_temporal`.

### Prueba de que el candado funciona

| intento | resultado |
|---|---|
| version legitima | **aceptada**, `ok = true` en las 8 |
| impura con cuerpo estandar leyendo `calibracion_coef` | **RECHAZADA**: `clases_halladas: "pg_class"`, k3 = false |
| impura con **cuerpo de cadena** leyendo la misma tabla | **RECHAZADA**: k3 daba falso PASS (0 deps) pero **k2 = false** lo bloqueo |

El segundo intento es el importante: demuestra que el candado **no se deja enganar**
por la via que evadiria a k3. Ambas mutaciones revertidas; la version legitima sigue
en su sitio y `inv_kelly_puro_v2().ok = true`.

## 2A.33/2A.34 — RONGOL: **no es una capa de cartera**

Correccion a mi propio reporte anterior. Dije "9 de 13 divergencias son de la capa de
cartera". **RONGOL no controla riesgo de cartera.** `rongol_veto` es una **lista de
bloqueo por patron historico**, evaluada **pick a pick, sin estado y sin acumulacion**:

| fuente | efecto | condicion |
|---|---|---|
| `lecciones_aprendidas` con `bloqueo_total` | **bloqueo total** | mercado equivalente + liga del deporte |
| `rongol_hallazgos` severidad `fuga` | advertencia | la clave hace match con mercado o rango de momio |
| `ligas_calidad` no apta | advertencia | por liga |

| propiedad | respuesta |
|---|---|
| que riesgo controla | resultado historico del **patron**, no concentracion ni dependencia |
| depende de P o EV | **no** |
| mezcla deportes | `liga_es_de_deporte()` acota por deporte |
| depende del orden | **no**: es por pick, sin acumulador. Permutar la entrada no cambia su salida |
| puede llevar stake a 0 | **si**, total |
| puede reducir parcialmente | **no**: es binario |
| evidencia empirica | **ver abajo. Es el hallazgo grave** |
| activo en dinero real | **si** |

### La evidencia con la que bloquea

Solo hay **3** lecciones con `bloqueo_total` activas:

| liga / mercado | registro | muestra |
|---|---|---|
| MLB / OU | 3-3 | **n = 6** |
| MLB / ML | 15-27 | n = 42 |
| MLB / ML | 4-4 | **n = 8** |

**Dos de las tres son 50/50 exactos, con seis y ocho observaciones.** Un 3-3 no es
evidencia de nada, y esta apagando un mercado completo con dinero real.

Y el criterio es **resultado historico (wins/losses/unidades)**, es decir ROI — lo
mismo que el mandato prohibe expresamente como base para `confidence`, operando de
facto como control de tamano.

## 2A.35 — "CDaR": **el nombre no corresponde**

`exposicion_viva` **no calcula Conditional Drawdown at Risk**. Es un **tope de
exposicion bruta**:

```
expuesto = suma(apuesta) de picks pendientes + suma(apuesta) de parlays pendientes
limite   = bankroll * exposicion_max_pct/100     (default 20%)
```

| pregunta del mandato | respuesta |
|---|---|
| variable aleatoria modelada | **ninguna** |
| horizonte | ninguno |
| distribucion | ninguna |
| escenarios | ninguno |
| correlaciones asumidas | **ninguna** (suma aritmetica) |
| nivel de confianza | ninguno |
| funcion de perdida | ninguna |
| que significa el limite | "no mas del 20% del bankroll comprometido a la vez" |
| recalculo | incremental, suma corrida en `reto_picks_hoy` |
| apuestas correlacionadas | **no las distingue** |
| partidos simultaneos | **no los distingue** |

**Es una heuristica de exposicion bruta llamada CDaR.** Como heuristica es
defendible y conservadora; como CDaR es un nombre incorrecto. No la reemplazo.

La suma corrida de `reto_picks_hoy` **si depende del orden**: llena el presupuesto
`order by monto_cand desc, arranca_en, espn_event_id, pick_desc`. Es **determinista**
(el desempate es explicito) pero **greedy por monto, no por edge**: un pick de menor
ventaja puede entrar y uno de mayor ventaja quedarse fuera si su stake es mayor. Eso
no esta formalmente justificado en ningun lado.

## 2A.36 — Correlacion y parlays

| medicion | resultado |
|---|---|
| picks vivos / eventos distintos | **15 / 15** |
| eventos con mas de un pick hoy | **0** |
| **parlays vivos** | **2, con $1,003.36** |
| picks individuales autorizados | $156.01 |

**El parlay es la exposicion dominante: 6.4 veces el total de las sencillas.** Y es
justo donde la dependencia conjunta es real y no esta modelada. `exposicion_viva`
los suma al mismo saco que las sencillas, sin tratar la dependencia entre patas.

Hoy no hay clusters de mismo evento entre las sencillas, asi que **no se puede medir
correlacion con los datos vivos**: la muestra es cero. Lo que si esta medido es que
la exposicion viva esta concentrada en parlays sin control de dependencia.

## 2A.37 — Shadow apples-to-apples: **atribucion exacta**

| escenario | n | total |
|---|---|---|
| **S0** V1 completo (produccion) | 15 | **$156.01** |
| **S1** V2 Kelly fraccional puro, sin cap/piso/cartera | 15 | **$2,008.64** |
| **S2** S1 + techo 5% + piso $20 | 15 | **$1,985.29** |
| **S3** S2 + RONGOL | 15 | **$644.85** |

Atribucion del delta de **-$1,852.63** entre S1 y S0:

| componente | efecto | % del delta |
|---|---|---|
| techo + piso | **-$23.35** | 1.3% |
| **RONGOL** | **-$1,340.44** | **72.4%** |
| residual: haircut de V1 + tope de exposicion | -$488.84 | 26.4% |

**El 72% de la diferencia entre V1 y V2 es RONGOL** — un blocklist cuya regla mas
activa tiene **seis observaciones**. El haircut probabilistico de V1, que era lo que
yo suponia dominante, explica como mucho el 26%, y parte de eso es el tope de
exposicion.

Esto corrige mi conclusion del turno anterior: no es cierto que "V1 esta conteniendo
exposicion por su capa de cartera". **V1 contiene exposicion sobre todo por una lista
de bloqueo con n=6.**

## 2A.38 — Confidence: evidencia, no formula

Los Skill Score (0.1536 futbol O/U, 0.0093 MLB ML, -0.0126 BTTS) **no se convierten
en multiplicadores**. Describen desempeno predictivo relativo, no una funcion
economica de exposicion.

Lo que falta antes de proponer forma funcional:

| componente | evidencia disponible | lo que falta |
|---|---|---|
| `c_skill` | Skill Score puntual por deporte/mercado | **intervalo de confianza del propio Skill Score**, y que sea OOS de la misma version/poblacion |
| `c_muestra` | N del universo | relacion demostrada entre N y error de estimacion |
| `c_estabilidad` | rango del sesgo entre ventanas (MLB 2.85 pp, futbol 3.1 pp) | mas ventanas; 3-4 no bastan para una dispersion |
| `c_frescura` | dias desde el ultimo dato (futbol 10, MLB 6) | relacion demostrada entre antiguedad y degradacion |

**`confidence = 1.0` con `PENDIENTE_DE_VALIDACION` permanece en shadow.** Queda
registrado que esta **prohibido** calibrar `confidence` para reproducir los $156
actuales o para maximizar ROI historico.

## 2A.39 — Riesgo individual contra riesgo de cartera

| capa | que controla | quien lo hace hoy | estado |
|---|---|---|---|
| **confidence** | incertidumbre de la estimacion **individual** | nadie correctamente: V1 lo hace reescribiendo P | por disenar |
| **portfolio_multiplier** | concentracion y dependencia **conjunta** | `exposicion_viva` (bruta, sin correlacion) | heuristica, sin modelo |
| **blocklist** | patrones con historial perdedor | RONGOL | **evidencia insuficiente (n=6)** |

Queda escrito: **RONGOL no es cartera y no puede contarse como tal**; `confidence` no
puede usarse para tapar la falta de capa de cartera; y la capa de cartera no puede
usarse para corregir una probabilidad mala.

## Componentes de V1 que pueden portarse tal cual

1. `bankroll_disponible()` — fuente unica de bankroll, ya corregida en #142/#192.
2. Techo por porcentaje (`stake_max_pct`) — cap economico simple y solo aprieta.
3. Piso (`stake_min`) — decision de producto, no de modelo.
4. `exposicion_max_pct` como **tope de exposicion bruta**, renombrado honestamente.
5. Los desempates explicitos del orden (`espn_event_id, pick_desc`) — evitan no determinismo.
6. `mercados_sin_modelo` / `sin_modelo_independiente` — apagado por ausencia de motor, no por desempeno.

## Componentes que deben redisenarse

1. El sesgo aditivo por decil dentro de `kelly_stake` (invalidado OOS).
2. `zona_realidad` como bandeador para dinero.
3. Wilson y Beta como reescritura de P (pertenecen a `confidence`, no a la probabilidad).
4. **RONGOL**: el mecanismo es razonable, la evidencia no. Necesita piso de muestra.
5. El nombre "CDaR": o se implementa un CDaR real o se llama tope de exposicion.
6. La asignacion greedy por monto: debe ordenarse por ventaja, no por tamano.
7. El tratamiento de parlays dentro del tope de exposicion.

## Riesgos residuales antes de migrar una sola superficie

1. **`confidence` sin validar.** Migrar sizing hoy multiplicaria la exposicion.
2. **Correlacion sin medir.** Hoy hay 0 clusters entre sencillas, o sea que la muestra
   para estimarla es cero. Los $1,003 en parlays son dependencia real no modelada.
3. **RONGOL con n=6.** Si se porta tal cual, se hereda el defecto; si se quita sin
   reemplazo, la exposicion sube 72%.
4. **El universo de MLB para O/U y Run Line** (`badrino_backtest`, 516+516) sigue sin medir.
5. La comparacion shadow es de **un solo dia**, 15 picks. No permite concluir nada
   sobre estabilidad.

---

# FASE 2 — BLOQUE 2A.40–2A.50: CONTABILIDAD REAL DEL RIESGO
*(5-sep-2026. Nada de produccion fue modificado. Todos los INSERT de prueba se
revirtieron por transaccion: base y estado final identicos en $1,003.36.)*

## 2A.40 — Contabilidad total de exposicion

**Respuesta explicita a la pregunta: SI, los $1,003.36 de parlays cuentan dentro
del limite del 20%. La cadena exacta es:**

```
exposicion_viva(apodo)
  ├─ v_bankroll  := stake_techo(apodo,false)->>'bankroll'
  │                   └─ bankroll_disponible(apodo)
  │                        = get_bankroll_actual(apodo)      -- $7,003.36
  │                        - bankroll_expuesto(apodo)        -- $1,003.36
  │                        = $6,000.00
  ├─ v_limite_pct := config_staking.exposicion_max_pct       -- 20.0
  ├─ v_picks      := sum(picks.apuesta)   pendientes, no prueba   -- $0.00
  ├─ v_parlays    := sum(parlays.apuesta) pendientes              -- $1,003.36
  └─ v_expuesto   := v_picks + v_parlays                          -- $1,003.36
     limite_monto := 6000 * 0.20 = $1,200.00
     disponible   := 1200 - 1003.36 = $196.64
```

`bankroll_expuesto` tambien suma parlays (con filtro `created_at >= reto_desde`,
que hoy los incluye: reto desde 2026-09-02, parlays del 2026-09-05).

**Pero el limite no es del 20%.** El denominador ya trae restada la exposicion, asi
que el limite se mueve hacia abajo conforme sube la exposicion. Punto fijo:

```
E >= 0.20 * (C - E)   <=>   1.2E >= 0.20C   <=>   E >= C/6 = 0.166667*C
```

Con C = $7,003.36 el tope efectivo es **$1,167.23 (16.667%)**, no $1,400.67 (20%).
Margen real restante: **$163.87**. `exposicion_viva` reporta **$196.64**: sobrestima
un 20%. Confirmado contra los datos del test adversarial (el cruce cae exactamente
en E = C/6).

Ademas `expuesto_pct` = 16.7% es E/D, no E/C (14.33%). La pantalla sugiere holgura
donde queda el 14% de la capacidad real.

### Exposicion por evento / equipo / deporte

| evento | liga | apuestas que lo tocan | stake prorrateado | max_loss expuesta |
|---|---|---|---|---|
| Inter Miami - Atlanta United | MLS | 1 | $100.67 | $503.36 |
| Brighton - Leeds | Premier | 1 | $100.67 | $503.36 |
| AGF - Silkeborg | Danish | 1 | $100.67 | $503.36 |
| Tigres - Necaxa | Liga MX | 1 | $100.67 | $503.36 |
| Leverkusen - Union Berlin | Bundesliga | 1 | $100.67 | $503.36 |
| Athletic - Atletico Madrid | La Liga | 1 | $166.67 | $500.00 |
| Villarreal - Deportivo | La Liga | 1 | $166.67 | $500.00 |
| Rayo - Racing Santander | La Liga | 1 | $166.67 | $500.00 |

Deporte: **8 de 8 patas son futbol (100%)**. Lado: **7 de 8 al equipo LOCAL**.
Las 2 sencillas recomendadas hoy tambien son "Gana local". El libro entero apuesta
al mismo factor latente y nada lo mide.

## 2A.41 — Anatomia de cada parlay

**`b848fb29` — $500, momio 7.5048 (= 2.36 x 2.12 x 1.50, producto exacto)**
| pata | liga | momio | prob implicita |
|---|---|---|---|
| Atletico Madrid (visitante) | La Liga | 2.36 | 42.4% |
| Rayo Vallecano (local) | La Liga | 2.12 | 47.2% |
| Villarreal (local) | La Liga | 1.50 | 66.7% |

`ai_prob_combinada` 7.22% · `ai_ev_pct` **-45.80%** · calificacion **D** · ambar.
Break-even 13.32%. Sencilla equivalente: cada pata a su momio con Kelly habria
recibido a lo sumo $300 (5%); aqui las tres comparten un solo boleto de $500.

**`6c033d7d` — $503.36, momio 9.7331 (= 1.599 x 2.08 x 1.478 x 1.50 x 1.32)**
| pata | liga | momio | prob implicita |
|---|---|---|---|
| Tigres UANL (local) | Liga MX | 1.599 | 62.5% |
| Brighton (local) | Premier | 2.080 | 48.1% |
| Bayer Leverkusen (local) | Bundesliga | 1.478 | 67.7% |
| AGF Aarhus (local) | Danish | 1.500 | 66.7% |
| Inter Miami (local) | MLS | 1.320 | 75.8% |

`ai_prob_combinada` 5.89% · `ai_ev_pct` **-42.70%** · **D** · ambar.
Break-even 10.27%.

**Ninguna pata paso por el motor.** `tg_autoridad_stake` salta `es_pata_parlay`, y
el parlay entra como objeto unico contra el techo del 15%. Ni Kelly, ni RONGOL, ni
la lista de abstencion, ni la puerta de calibracion ven estas 8 selecciones.
**Cero funciones SQL escriben `ai_prob_combinada`**: el numero lo produjo un LLM.

## 2A.42 — Probabilidad conjunta: CORRELACION_NO_MODELADA

Las tres cifras que hoy conviven para el mismo parlay `b848fb29`:
- LLM (`ai_prob_combinada`): **7.22%** → EV -45.8%
- `parlay_ev_real`: sin pares del mismo evento devuelve **independencia exacta**
- `simular_parlay` con rho=0.12: **12.11%** → EV -9.1%

`simular_parlay` no usa la probabilidad del modelo: parte de `1/momio` (precio con
jugo) dividido entre un overround **asumido** de 1.05. Es una calculadora de jugo
compuesto, no de valor esperado.

Barrido de rho (40,000 sims, 5 repeticiones, CTE MATERIALIZED):

| rho | prob $500 | EV $500 | prob $503.36 | EV $503.36 |
|---|---|---|---|---|
| 0.00 | 11.60% | -12.95% | 8.00% | -22.19% |
| 0.05 | 11.61% | -12.88% | 8.15% | -20.68% |
| 0.12 (produccion) | 12.11% | **-9.13%** | 8.60% | **-16.33%** |
| 0.25 | 13.73% | **+3.05%** | 11.48% | **+11.75%** |
| 0.40 | 16.96% | +27.26% | 16.17% | +57.40% |

**El signo del veredicto lo decide una constante que nadie midio.** La unica tabla
de correlacion medida (`correlacion_mercados`, 20 filas, n=1,860) es 100% de pares
intra-partido. Cero evidencia sobre dependencia entre eventos distintos.

**Conclusion obligatoria: `CORRELACION_NO_MODELADA`.** No se convierte la ausencia
de evidencia en independencia, ni se adopta rho=0.12 como si estuviera medido.

## 2A.43 — Cadena de stake de parlays + prueba adversarial

Cadena: cliente → `INSERT parlays` → `tg_autoridad_stake` → `stake_techo(apodo,
es_reto_13m)` → 15% del disponible (RETO) o 5% (general). Fin. **No hay segundo
control.**

Los dos parlays vivos pasaron sin firma porque 15% de $7,003.36 = $1,050.50 y 15%
de $6,503.36 = $975.50; $500 y $503.36 caben. Por eso `stake_techo_al_guardar` y
`stake_sobre_techo_razon` estan NULL.

Prueba adversarial (INSERT reales, revertidos):

| caso | resultado | exposicion despues |
|---|---|---|
| 1. Sencilla $93.25 (MLS 761781) | **ACEPTADA** | 18.6% |
| 2. Parlay $500 con esa MISMA pata | **ACEPTADO** | **27.3%**, limite_alcanzado=true |
| 3. Sencilla $93.25 + parlay $500 sobre el mismo evento | **ACEPTADOS** | **29.5%** |
| 4. Dos parlays mas ($500 + $400) | **ACEPTADOS** | **37.3%** |
| 5. Parlay $1,200 | **RECHAZADO** (techo $900 = 15%) | — |

**El limite de cartera del 20% es informativo. Solo el techo por apuesta bloquea.**

## 2A.44 — Duplicacion de riesgo

Metricas definidas (no existen en produccion):
- `stake_equivalente_por_evento` = sencillas sobre el evento + `apuesta/n_patas`
  de cada parlay que lo contiene.
- `max_loss_expuesta_por_evento` = sencillas + **la apuesta completa** de cada
  parlay que lo contiene (una pata perdida mata el boleto entero).

Hoy: 8 eventos, 1 apuesta cada uno, **duplicacion cero**. Pero
`sum(max_loss) = $4,016.80` sobre $1,003.36 realmente en riesgo, y cada partido
individual carga entre 7.1% y 8.4% del bankroll contable como gatillo propio,
contra un techo de 5% para una sencilla sobre ese mismo partido.

El CASO 3 demuestra que la duplicacion real (sencilla + pata, mismo evento) se
acepta sin que nada la registre.

## 2A.45 / 2A.46 — RONGOL: validez, incertidumbre y walk-forward

Las 3 reglas activas con `bloqueo_total` (Wilson 95% sobre la tasa de acierto):

| regla | n | registro | ROI | Wilson 95% WR |
|---|---|---|---|---|
| MLB · OU · 1.01-1.50 | 6 | 3-3 | -38.3% | [18.8%, 81.2%] |
| MLB · ML · 1.01-1.50 | 8 | 4-4 | -33.1% | [21.5%, 78.5%] |
| MLB · ML · 1.50-1.80 | 42 | 15-27 | -41.3% | [23.0%, 50.8%] |

Los intervalos de las dos primeras cubren practicamente todo el espacio: no
distinguen una moneda de un desastre.

**Walk-forward (corte por mediana temporal dentro de cada celda):**

| celda | n train | ROI train | n test | ROI test | WR test |
|---|---|---|---|---|---|
| ML 1.50-1.80 | 21 | -37.7% | 21 | **-44.8%** | 33.3% |
| ML 1.01-1.50 | 4 | -63.8% | 4 | -2.5% | 75.0% |
| OU 1.01-1.50 | 3 | +23.3% | 3 | -100.0% | 0.0% |

**Solo ML 1.50-1.80 sobrevive fuera de muestra.**

**Defecto estructural (P0): el veto ignora el rango de momio.** En `rongol_veto`,
`v_rango` se calcula y nunca se usa; `la.rango_momio` no aparece en el WHERE.
Y aunque se usara, los buckets del veto y los de `rango_momio()` son vocabularios
distintos. El filtro de liga tambien es un no-op logico.

Consecuencia medida (ai_pro, MLB, ML, 120 dias):

| rango | n | ROI | IC95 |
|---|---|---|---|
| 1.01-1.50 | 8 | -33.1% | [-83.0, +16.8] |
| 1.50-1.80 | 42 | -41.3% | [-65.4, -17.1] |
| 1.80-2.20 | 350 | -4.5% | [-15.2, +6.1] |
| 2.20-3.00 | 504 | **+10.0%** | [-0.9, +20.9] |
| 3.00-5.00 | 118 | **+35.4%** | [+5.7, +65.2] |

Los 10 picks de MLB bloqueados hoy (momios 1.893 a 3.02) **no caen en ningun rango
medido**: 3 en 1.80-2.20, 6 en 2.20-3.00, 1 en 3.00-5.00.

Ademas `extraer_lecciones_de_perdidas` **nunca escribe `bloqueo_total`**: las tres
marcas son manuales y sobreviven cada reconstruccion, sobre una ventana movil de
120 dias de la misma fuente que despues se bloquea (in-sample por construccion).

**Clasificacion: `LEGACY_GUARD_NO_VALIDADO`**, con la unica excepcion de la celda
ML 1.50-1.80.

## 2A.47 — Orden greedy: sensibilidad a la permutacion

`reto_picks_hoy` no llena: **corta por prefijo**. Ordena por `monto_cand desc` y
descarta todo lo que cumpla `expuesto + acumulado > limite_monto`; si el primero
no cabe, mueren todos los siguientes.

Conjunto real de hoy (9 candidatos con Kelly > 0), presupuesto $196.64:

| orden | financiados | monto | EV capturado |
|---|---|---|---|
| **A. monto desc (PRODUCCION)** | **0** | **$0.00** | **$0.00** |
| B. monto asc | 3 | $187.99 | +$11.06 |
| C. EV desc | 0 | $0.00 | $0.00 |
| D. EV asc | 3 | $187.99 | +$11.06 |
| E. hora de arranque | 1 | $177.59 | **+$32.16** |
| F. prob que decide desc | 1 | $104.68 | +$8.98 |

Optimo de mochila: **+$35.71**. La produccion captura **$0.00**.
Hoy el defecto esta tapado: RONGOL borra 7 de 9 y los 2 restantes suman $156.01.

## 2A.48 — Nomenclatura correcta

- **`TOPE_EXPOSICION_BRUTA`** — suma de stakes vivos sobre el bankroll **contable**.
  Es lo que `exposicion_viva` intenta hacer, con el denominador corregido.
- **`EXPOSICION_POR_EVENTO`** — `max_loss_expuesta_por_evento`. No existe hoy.
- **`CDaR`** — reservado. No se usa mientras no haya distribucion, horizonte,
  escenarios y nivel de confianza.

No se renombra nada en produccion en este bloque.

## 2A.49 — Atribucion S0–S5

Bankroll disponible $6,000. 16 picks candidatos.

| escalon | monto | n | delta | % del recorte |
|---|---|---|---|---|
| S1 Kelly fraccional 0.25 sobre p_raw | $2,055.51 | 16 | — | — |
| S2 + techo 5% + piso $20 | $2,032.15 | 16 | -$23.36 | 1.2% |
| S3 + recorte V1 (sesgo + Wilson) | $1,161.35 | 9 | **-$870.80** | **45.9%** |
| S4 + RONGOL | $156.01 | 2 | **-$1,005.34** | **52.9%** |
| S5 + tope de exposicion (PRODUCCION) | $156.01 | 2 | -$0.00 | 0.0% |

Reduccion total **-$1,899.50 (-92.4%)**.

**Correccion a mi atribucion anterior**: antes reporte RONGOL = 72.4% del delta,
con el recorte V1 escondido en el residual. Separados, **el recorte V1 (45.9%) y
RONGOL (52.9%) pesan casi lo mismo**, y el tope de exposicion no aporta nada hoy.

**S_parlays = $1,003.36 y no pasa por ninguno de esos escalones.** Es 6.4 veces
toda la autorizacion de sencillas.

## 2A.50 — Clasificacion de cada guarda

| guarda | clasificacion | fundamento |
|---|---|---|
| `stake_techo` / `tg_autoridad_stake` (techo por apuesta) | **B — conservar, corregir** | Es el unico candado que realmente bloquea (CASO 5). Corregir: 15% por apuesta contra un tope de cartera de 16.667% permite 1.1 apuestas. |
| `exposicion_viva` (tope de cartera) | **B — conservar, corregir** | Denominador circular (16.667% real, no 20%) y `disponible` sobrestimado 20%. Ademas no es candado: hay que darle un trigger. |
| Llenado greedy de `reto_picks_hoy` | **C — reemplazar** | Corte por prefijo que captura $0 de $35.71 disponibles. Reemplazar por llenado real ordenado por ventaja. |
| RONGOL celda ML 1.50-1.80 (n=42) | **B — conservar, corregir** | Sobrevive walk-forward (-44.8% OOS). Corregir el alcance para que aplique SOLO a su rango de momio. |
| RONGOL celdas n=6 y n=8 | **D — retirar** | No sobreviven walk-forward; Wilson cubre casi todo el espacio. |
| `rongol_veto` (mecanica de alcance) | **C — reemplazar** | `rango_momio` ignorado, buckets incompatibles, filtro de liga no-op. |
| Recorte V1 (sesgo + Wilson en `kelly_stake`) | **A — portar tal cual (por ahora)** | Es el 45.9% del recorte y ya esta medido; su reemplazo es trabajo de 2B, no de este bloque. |
| `simular_parlay` / `evaluar_parlay` (rho=0.12) | **D — retirar de toda decision de dinero** | Constante no medida que decide el signo del EV; parte del precio de la casa, no del modelo. |
| `parlay_ev_real` + `correlacion_mercados` | **B — conservar, acotar** | Medido y correcto para pares intra-partido. Debe declarar explicitamente que no modela dependencia entre eventos. |
| `ai_prob_combinada` / `ai_ev_pct` (LLM) | **D — retirar de toda decision de dinero** | Sin escritor SQL; numero de un LLM que ya convive con otras dos estimaciones distintas. |

**No se aplica ninguna de estas decisiones en este bloque.** El mandato prohibe
retirar RONGOL, migrar V2 y tocar produccion.

## Riesgos que bloquean la migracion de V2

1. **La capa de cartera no existe como candado.** Migrar V2 sin cerrar el hueco del
   CASO 2/4 subiria el tamano individual dentro de un perimetro que no se cumple.
2. **`CORRELACION_NO_MODELADA`.** V2 dimensiona apuestas individuales; el 100% de
   la exposicion viva es un producto cuya dependencia conjunta no esta medida.
3. **RONGOL sostiene el 52.9% del recorte actual y esta mal dirigido.** Quitarlo sin
   reemplazo triplica la exposicion; dejarlo sigue bloqueando el unico tramo con
   ROI positivo significativo.
4. **El asignador de cartera captura $0 de EV cuando el presupuesto aprieta.**
5. **El techo por apuesta del RETO (15%) es incompatible con el tope de cartera
   (16.667%)**: una sola apuesta puede agotar el 90% de la cartera.

## Metodo: dos errores propios corregidos en este bloque

1. **Contrapuse "$156.01 en sencillas" contra "$1,003.36 en parlays"** como si fueran
   la misma clase de dinero. `picks_vivos = 0`: los $156.01 son una recomendacion,
   no exposicion.
2. **El primer barrido de rho salio internamente incoherente** (tres promedios
   distintos para el mismo grupo) porque `random()` dentro de una subconsulta
   escalar se re-evalua por cada agregado. Repetido con `WITH ... AS MATERIALIZED`.
