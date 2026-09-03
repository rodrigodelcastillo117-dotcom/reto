# RETO 13M — Pendientes

**Corte: 3 de septiembre de 2026.** Todo lo que quedó abierto, con el detalle necesario para
retomarlo sin volver a investigar. Las tareas cerradas ese día no aparecen aquí.

---

## LA REGLA QUE RIGE TODO

> **El LLM escribe lo cualitativo. Todo número que multiplique dinero se calcula en vivo desde
> SQL al momento de leer.**

Nació de encontrar siete puntos de pantalla donde un modelo de lenguaje inventaba fracciones de
Kelly, con errores de hasta 12×. El patrón correcto ya existía en el código (`ev_estimado` sí se
sobrescribe desde el motor); Kelly era el único campo de dinero sin dueño en TypeScript.

**Corolario:** un Kelly calculado NO se guarda dentro del análisis. El análisis se congela al
generarse y los momios se mueven; un Kelly guardado a las 00:45 estará desfasado a las 19:00.
El dimensionamiento vive solo en los RPC que recalculan al leer: `mejor_oportunidad_hoy`,
`construir_parlay_v2`, `pick_del_dia`.

---

## PRIMERO MAÑANA

### #171 — Parchar los prompts para que no emitan tamaños de apuesta
**Listo para ejecutar. Solo falta correr el deploy.**

El riesgo que lo frenó está descartado por dos vías:
1. `deploy_edge_function` acepta `verify_jwt` explícito → se pasa `false` y la bandera no se voltea.
2. Aunque se volteara, los cuatro llamadores de `analizar-partido` mandan `Authorization`:
   `trigger_analizar_partido_async`, `disparar_reanalisis_prepartido`, `reanalizar_analisis_vacios`
   (SQL, los tres con `http_post` + auth) y `procesar-cola-analisis` (edge, `Bearer ${SERVICE}`).

**Parche A — `analizar-partido/index.ts`: preparado y verificado.**
- md5 original `81290cfe13b14e79b28ebd037267312a` (226,914 bytes)
- md5 parcheado `717518ffc3d918009a751d6cd14052cc` (227,117 bytes)
- El ancla aparece **exactamente 1 vez**. Los otros dos archivos quedan intactos.

```diff
   "edge_total": "+5.8% vs mercado",
-  "kelly_sugerido": "3.2% del bankroll",
   "veredicto_final": "BET"
 }
 IMPORTANTE:
+- NUNCA emitas campos de tamaño de apuesta: ni kelly_sugerido, ni kelly_pct, ni monto,
+  ni porcentaje de banca. El dimensionamiento lo calcula el motor con kelly_fraccion_pct,
+  no tú. Si crees que falta ese dato, OMITE el campo por completo.
 - "confianza" DEBE ser número 0-100, NO texto ni 1-10
```

**Parche B — `construir-parlay-ai/index.ts`: falta prepararlo.** Quitar `apuesta_sugerida`,
`kelly_percent` y `pago_estimado` del esquema. `momio_total` y `probabilidad_total` se quedan
(esos sí los recalcula el código). `pago_estimado` sale porque se derivaba de la apuesta
alucinada: en 125 de 127 parlays se cumple `pago_estimado = apuesta_sugerida × momio_total`.

**Por qué se pospuso:** la herramienta exige el contenido inline, 227 KB ≈ 120,000 tokens de
contexto. En sesión nueva cuesta lo mismo sin sacrificar nada.

**Después del deploy:** confirmar que `verify_jwt` sigue en `false` y correr un análisis de
prueba para ver que el JSON ya no trae `kelly_sugerido`.

---

## DINERO — lo que puede costar pesos

### #169 — Calibración sobre picks publicados: PRIMERO descartar el confundidor
Sobre 2,377 picks de ligas activas el modelo pierde contra una constante:
Brier crudo 0.2549, con `calibrar_prob_motor` 0.2548, tasa base 0.2487. Y 726 de 2,377 (31%)
caen fuera del rango medido.

Las bandas se deforman al subir:

| Dice | Pasa | n | Desvío |
|---|---|---|---|
| 36.3% | 45.8% | 356 | +9.5pp |
| 45.2% | 44.9% | 644 | −0.3pp |
| 55.2% | 49.4% | 972 | −5.8pp |
| 63.5% | 48.5% | 165 | −15.0pp |
| 74.3% | 54.0% | 50 | −20.3pp |
| 84.4% | 58.3% | 24 | −26.1pp |
| 94.6% | 41.2% | 17 | −53.4pp |

**Dos hipótesis predicen la misma tabla. No dar ninguna por buena sin medir:**
- **A) Maldición del ganador.** `calibracion_coef` se ajustó sobre 148,764 selecciones de TODOS
  los partidos; los publicados pasaron un filtro de +EV, o sea justo donde el modelo sobreestima.
  *Prueba falsable:* el sesgo debe CRECER con el EV declarado.
- **B) Motor viejo.** 2,797 de 2,871 filas traen `espn_event_id` que no cruza con nada (IDs de
  API-Football, residuo del bug #66), y la muestra va de abril a septiembre, antes de Dixon-Coles,
  del xG estimado y de la recalibración de #139. *Prueba falsable:* el sesgo debe caer al cortar
  por fecha de cada cambio de motor.

**Paso 1 obligatorio:** correr las dos pruebas. Sesgo por decil de `ev_estimado`, y sesgo por mes
cruzado con las fechas de cambio de motor, **separando MLB del resto** (88% de la muestra es MLB).
**Paso 2, solo si A sobrevive:** ajuste isotónico sobre picks publicados y extender el rango
arriba de 70%. **Si gana B:** no se recalibra nada, se purga o marca la muestra vieja.

### #147 — El EV se calcula con precios de DraftKings pero se apuesta en PlayDoIt
Falta acumular ~30 pares DraftKings/PlayDoIt para sustituir el umbral de 2.0% de EV en Moneyline,
que hoy está puesto por criterio y no por medición.

### #156 residual / #159 — Cartelera de MLB
`v_radar_mlb` tiene tres filtros que hay que revisar. La prohibición de totales ya quedó aplicada
en `filtro_pick`, pero la causa raíz de la cartelera sigue abierta.

### #157 — `radar_odds_snapshots` mezcla precios de antes y de DURANTE el partido
Afecta cualquier medición de CLV y cualquier backtest que use esa tabla. **Al usarla siempre
filtrar `snapshot_at < fecha del partido`.**

### #158 — El chip GANA de MLB enseñaba la probabilidad previa con el partido en vivo

### #140 — La tarjeta enseñaba la probabilidad de la CASA con la etiqueta "justa"

### #123 — Bono: dos convenciones distintas y un parlay de $1,194 por confirmar

---

## CALIFICACIÓN Y DATOS SUCIOS

### #172 — Partidos de copa que van a penales se quedan atorados
Detectado en vivo: América 2-2 Monterrey (Leagues Cup, `401914296`) quedó con `status='live'`,
`status_detail='SIN SEÑAL'`, `period='5'`, reloj en 95'. En ESPN `period=5` es la tanda de penales.
`is_truly_final()` lo da **false** → el partido se queda pendiente para siempre.

**Alcance ese día: cero.** No había picks ni legs pendientes en ese evento.

**Son dos problemas distintos:**
1. **Atoro:** `is_truly_final()` debe aceptar `period>=5`, o marcador estable sin señal por N minutos.
2. **Cómo se califica:** ninguna de las 18 funciones de calificación menciona `penal` ni `shootout`.
   Un Moneyline a 90 minutos en un 2-2 que se define en penales se califica **EMPATE**, no victoria
   del que clasificó. Si el calificador tomara "quién clasificó" sería error de dinero.

Aplica a Leagues Cup, Copa MX, eliminatorias de Champions, Mundial. **Medir antes cuántos eventos
históricos quedaron atorados así.**

### #173 — El bloque `probabilidades` puede traer local y visitante invertidos
En `401914297` (Toluca vs León) el análisis guardó `home_win=29.6` y `away_win=41.0` con
`agenda_espn` diciendo home=Toluca. **Es al revés:** el EV guardado lo prueba —
`0.296 × 3.85 − 1 = +13.96%`, que es el `+14.1%` registrado. El pick usó 29.6% para León, así que
Toluca tenía 41.0% y era el favorito.

El bloque viene marcado `"_odds_provider": "inferred_from_picks"`: se reconstruyó hacia atrás desde
los picks y ahí se cruzaron los lados.

**Segundo defecto en el mismo análisis:** `goles_esperados` es `{local 1.1, visitante 1.1}`,
simétrico. Con lambdas simétricas el 1X2 tendría que salir simétrico, no 29.6/29.4/41.0. **El 1X2
no salió de esas lambdas.** Cualquier BTTS u Over derivado de ellas no es confiable.

**No se pudo determinar si es sistemático:** solo n=4 cruces útiles (2 bien, 2 invertidos), y de 49
análisis con momio, 15 (31%) discrepan del mercado sobre quién es favorito — alto pero no prueba.
En los 8 análisis de MLB del 2-sep las etiquetas SÍ cuadran (7 de 8 coinciden con el mercado).

**Regla:** cuando un bloque diga `inferred_from_`, no creerle sin cruzarlo contra la aritmética del EV.

### #113 — Marcadores cruzados: tenis congelado en 2-0 y MLB al revés en pantalla

### #120 — Tenis: 112 de 163 partidos de ATP con marcador imposible

### #36 — Verificar el arreglo de caché de análisis y decidir la UI de Batallas

### Partidos mudos en la cola
`procesar-cola-analisis` v4 arregló que la cola mentía (marcaba `completado` en respuestas
`skipped`, dejando mudos a Kobenhavn, Besiktas, Al Hilal y HEBC Hamburg). Ahora existen los
estados `omitido` y `sin_analisis`. **Falta revisar cuántos quedan ahí: son partidos sin análisis
que nadie reintenta.**

---

## MODELO

### #174 — MLB: Poisson sobredisperso 2.36× (mercado vetado). Fútbol limpio: razón 1.025

**Béisbol — el modelo está bien, Poisson es el que falla.** Sobre 1,056 juegos (`bt_mlb_mu`):
- λ total 9.154 vs carreras reales 9.001. Sesgo −0.154: insesgado.
- Curva por quintil monótona: 8.31→8.02, 8.72→8.56, 9.04→9.02, 9.42→9.12, 10.29→10.28.
- **Pero varianza real 21.21 contra media 9.001 → razón 2.36.** Poisson exige 1.0.
  Desviación real 4.61 vs 3.00 que asume Poisson. Las carreras llegan en racimos.

Error de Poisson por línea (n=1,056 cada una):

| Línea | Poisson dice Under | Real | Error |
|---|---|---|---|
| 7.5 | 31.4% | 44.3% | +13.0pp |
| 8.5 | 44.1% | 52.5% | +8.4pp |
| 9.5 | 56.9% | 60.3% | +3.5pp |
| 10.5 | 68.6% | 67.0% | −1.6pp |

Tabla de corrección por (línea − λ), monótona: **+12.8 / +11.2 / +6.3 / +1.5 / −3.6 / −6.2 pp**.

**Validada fuera de muestra** (ajuste mayo-julio, prueba agosto): Brier 0.23204 → 0.22456.
Poisson decía Under 50.8%, corregido 55.0%, real 56.4%.

**Prueba de dinero** (153 juegos con momio pre-partido): Poisson crudo 121 picks ROI −6.74%;
con corrección 127 picks ROI **−3.49%**. **Sigue negativo**, y con n=127 el error estándar del ROI
es ±8.9pp: −3.49% no se distingue de 0% ni de −6.74%.

> **EL VETO DE TOTALES DE MLB SE QUEDA.** Calibrar mejor no es ganar. La corrección arregla la
> honestidad de la probabilidad, no la rentabilidad contra el vig.

**Fútbol — limpio, no tocar nada.** 22,617 partidos: media 2.931 goles, varianza 3.003,
**razón 1.025**. Desviación real 1.733 vs 1.712 de Poisson. Correlación local-visita −0.114
(lo que corrige el `tau` de Dixon-Coles). Over 2.5 real 56.3%, BTTS real 54.6%.
**Over 2.5 y BTTS operan sobre un supuesto válido.**

Si algún día se retoma MLB: binomial negativa con el parámetro de dispersión medido, no la tabla
de tramos (6 cubetas arbitrarias sobre renglones no independientes — cada juego entra 6 veces).

### #125 residual — NBA Over/Under sigue pendiente

### #133 — Llevar clima, sabermetría y contexto a NFL, fútbol y NBA

### #145 — Fútbol: rotación medida (es ruido) y carga de stats por jugador desde ESPN

### #135 — MLB: usar la alineación real en vez del promedio del equipo

### KellyCriterion: probabilidad por verificar
`KellyCriterion.tsx` usa `calculateKelly` con **momio real tecleado por el usuario** (eso está
bien), pero la probabilidad viene de `aiCalificacion.prob_estimada` y **no se ha confirmado si
está calibrada**. Mismo patrón que #164: fórmula correcta, entrada sin verificar.

### `calibracion_curva` sigue viva
La tabla y `obtener_curva_calibracion()` siguen en la base aunque el motor JS que las consumía ya
se borró. Está degenerada: aplanaba todo lo de arriba de 60% a 53.9% con muestras de 2 a 23 casos
e inflaba tiros largos (15% → 39.1% en ML, 15% → 56.4% en BTTS). **Revisar quién más las llama
antes de darlas por muertas.**

---

## PANTALLA

### #126 — RETO 13M: pantalla nueva y el motor solo produce no-favoritos

### #42 — Acotar columnas del Feed de Comunidad

### #67 — Equipos favoritos con estrella en el menú de LIGA

### #70 — Historial por equipo A-F: construido y bueno, pero la app nunca lo pedía

### #155 — Notificaciones de marcador: dos sistemas mandando lo mismo

### Hueco de tendencias en MLB
`tendencias_partido()` se calcula al vuelo (no hay caché que refrescar). Fútbol: **30 de 31**
partidos con Local/Visita/H2H. **Béisbol: solo 5 de 25** — 20 devuelven "ESPN no tiene historial
suficiente". La pestaña TENDENCIAS está prácticamente vacía en béisbol.

### `tendencias_externas` NO está rota
37 filas de un solo día (30-ago) sobre 3 partidos, fuente 365scores. **Nunca hubo cron ni función
que la escribiera**: fue una carga manual para la medición de #54. No es un pipeline caído.

---

## NFL — el calendario manda

### #118 — NFL listo para el 10-sep: agenda sembrada, picks apagados hasta medir

### #35 — Resolver los deadlocks de `nfl-sync-cdn` en `live_scores` después del 9-sep
**NO tocar ni desactivar el cron `nfl-sync-cdn` ni `sync_nfl_desde_cdn()`** hasta después del
arranque del 9-10 de septiembre, y solo con confirmación explícita.

### #93 — NFL auto-actualización: lesiones LISTO, faltan snaps y novatos

### #87 — FANTASY/NFL: uso, zona roja, K, DEF y depth charts cargados. Solo falta ADP

---

## SEGURIDAD Y PUBLICACIÓN

### #63 — Rotar la service_role key
**Requiere que la generes tú.** Ya salió de los 40 lugares donde estaba.

### #105 — Seguridad: cerradas las 2 vistas de dinero abiertas a internet y 43 respaldos

### #38 — Bloqueantes para publicar: apodo, funciones rotas, correo

---

## OPERACIÓN

### #98 — Cierre del día: lo hecho por deporte y las cadencias reales

### #100 — Cierre: goles al cash out, bullpen apagado, foto de predicción NFL

### Documento maestro
No recoge nada de la jornada del 3-sep.

---

## NOTAS DE MÉTODO

Cosas que costaron caro aprender y conviene no repetir:

1. **`CREATE TABLE ... (LIKE ... INCLUDING ALL)` NO copia RLS ni políticas.** Toda tabla nueva
   necesita `enable row level security`, `force row level security` y `revoke all from anon, authenticated`.
2. **`pg_net` no despacha dentro de la misma transacción.** El patrón que funciona es
   `recoger(); pedir(N);`.
3. **`calibrar_prob_motor` devuelve NULL fuera del rango medido**, y un NULL tira filas en silencio
   a través de un `WHERE`. Fútbol topa en 70%, béisbol en 62%. Siempre `coalesce` + marcar.
4. **La URL del linescore de ESPN sale del propio JSON, nunca se arma a mano.** Pedir
   `.../competitors/{ID_EQUIVOCADO}/linescores` devuelve HTTP 200 con la línea de OTRO jugador.
5. **Cuando un bloque diga `inferred_from_`, cruzarlo contra la aritmética del EV antes de creerle.**
6. **Cada parche lleva pegada una pregunta de control.** Así aparecieron las fugas 4, 5, 6 y 7 de
   Kelly; ninguna estaba en el plan original.
7. **Antes de concluir de una tabla, verificar que no mezcle deportes.** `historico_partidos_espn`
   junta soccer, baseball y football; sin filtrar da 4.12 goles de media.
8. **Con muestra chica no se concluye.** Ese día me equivoqué dos veces por eso: "+2.10 carreras de
   subestimación" salió de n=25 (con n=1,056 el sesgo es −0.15), y leí un favorito al revés por no
   cruzar el bloque contra el EV.
