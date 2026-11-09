# Calibración Platt (OOS) + Tier de Alta Confianza ≥70%

Fecha: 2026-11-09. Gatillo: "mejora todo, un paso más — que acertemos más". DINERO OFF.

## El análisis honesto que disparó todo (1,729 picks graderos con resultado)

Calibración real por zona de probabilidad (lo que el pick dice vs lo que de verdad gana):

| Zona prob | Dice | Gana real | Lectura |
|---|---|---|---|
| 50-55% | 52.5 | **49.4** | casi volado, pierde un poco |
| 55-60% | 57.5 | 59.5 | bien |
| 60-65% | 62.1 | 60.0 | ligera sobre-confianza |
| 65-70% | 67.2 | **60.5** | peor zona (contaminada por tenis) |
| 70-80% | 73.8 | **79.9** | oro |
| 80%+ | 84.3 | 77.8 | oro |

**Hallazgo clave:** el **tenis** miente en la zona media — ATP que dice 62% gana 47% (¡pierde!),
WTA que dice 67% gana 52%. Pero ATP/WTA a 70%+ sí están bien calibrados. El shrink lineal
actual no lo corrige porque el sesgo depende de la zona.

**Segundo hallazgo (robusto en TODOS los deportes):** la zona **≥70%** acierta ~78% real
(NBA 85%, fútbol 81%, NHL 80%, tenis 76-78%). Es la única zona donde el acierto sube de forma
consistente — y además esquiva la zona mala del tenis.

## Construido

### 1. Motor de calibración Platt (regresión logística) por deporte — con gate OOS
- **Función `recalibrar-platt-v1`**: por deporte, ajusta `p_cal = sigmoid(a·logit(p)+b)` (IRLS/Newton)
  en el 70% más antiguo por fecha (train) y valida en el 30% más reciente (test). Pagina el historial
  completo (evita el tope de 1000 filas de PostgREST).
- **Tabla `reto_calibracion_platt_v1`** (RLS on): a, b, brier_raw, brier_platt, n_train, n_test, validado.
- **Gate de integridad:** `validado=true` SOLO si mejora el Brier OOS y la curva es monótona (a>0).
- **Cron `reto-recalibrar-platt-semanal`** (jobid 604, lunes 10:18 UTC).

### 2. Resultado honesto de la primera corrida: NADA valida todavía
Con los datos completos y validación fuera de muestra, **Platt NO mejora el Brier OOS en ningún
deporte** (brier_platt > brier_raw en los 5). La sobre-confianza que se ve en la muestra completa
**no generaliza** a un ajuste estable (el periodo reciente se comporta distinto al de entrenamiento).

→ **Decisión:** NO aplicar un "arreglo" que no valida. (Principio: nada mal creado; nunca empeorar
lo publicado.) La infraestructura queda corriendo semanalmente: en cuanto haya un edge de calibración
real con más datos, el gate lo detectará y lo aplicará solo.

### 3. Lo que SÍ está validado y SÍ se envió: tier "🔒 Alta confianza (≥70%)"
- Nueva sección encabezando el email diario (`mejores-picks-diario` v8): lista los picks del día con
  probabilidad ≥70%, con la nota de que históricamente esa zona acierta ~78% (1,729 picks verificados).
- Es **puro filtro de selección** sobre lo ya publicado/calibrado — no inventa ninguna probabilidad.
- Convive con lo anterior: fútbol sigue anclado a mercado, tenis ATP con su shrink validado, etc.

## Por qué esto es "acertar más" de verdad (y qué NO es)
Subir el % de acierto honesto = mostrar y priorizar la zona ≥70%. No tocamos el modelo ni inventamos
confianza. La métrica que de verdad importa para rentabilidad sigue siendo el CLV (ya se mide aparte);
el tier de alta confianza es para la sensación y la disciplina de "jugar solo lo más seguro".
