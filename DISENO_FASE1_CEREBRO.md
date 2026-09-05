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

### 1.3 Castigo de confianza: encoger hacia el mercado, no hacia 50%

```
p_usada = p_mercado + completeness · (p_modelo − p_mercado)
```

Con información completa cotizas tu modelo; sin información cotizas el mercado, que es
el estimador honesto por defecto. Encoger hacia 50% sería peor: inventaría ventaja en
favoritos claros. Se compone después con la temperatura de la sección 3.

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

## 7. ORDEN DE EJECUCIÓN PROPUESTO

| # | bloque | por qué en ese lugar |
|---|---|---|
| 1 | **Trazabilidad (§1)** | sin ella toda medición posterior es inauditable |
| 2 | **NFL apagado (§5) + CLV real (§4)** | son los dos que hoy desinforman activamente |
| 3 | **Compresión de sobreconfianza (§3)** | 77.4% que rinde 52.6% está dimensionando dinero |
| 4 | **Desacoplamiento y candado del LLM (§2)** | fija la frontera antes de meter variables nuevas |
| 5 | **Backtest de xG (§6)** | primero saber que la línea base es honesta |

Nada de esto se ejecutó. Queda a la espera de su visto bueno bloque por bloque.
