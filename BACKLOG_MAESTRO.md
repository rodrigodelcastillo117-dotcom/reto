# BACKLOG MAESTRO — RETO 13M
Censo numerado. Protocolo: Regla 360° (Backend + Frontend + Validación + Cierre).
Última actualización: 2026-09-05.

> Regla de este archivo: nada entra aquí sin estar **medido**. Si un número no se
> midió contra producción, va marcado como `[SIN MEDIR]`.

---

## A. CERRADAS HOY (evidencia, no memoria)

- ~~**A1. Saturación del haircut de Kelly en N≥300.**~~ El factor `sqrt(N/300)` daba
  1.0000 exacto para los dos tramos vivos (n=853, n=1963), o sea cero recorte.
  Medido: la alternativa `ln(1+N)/ln(1+500)` tiene el MISMO defecto movido a N≥500
  (también 1.0000 en 853 y 1963) — habría sido un no-op. Implementado el **límite
  inferior de Wilson**: 0.9067 (187), 0.9562 (853), 0.9711 (1963), 0.9749 (2612).
  Nunca satura. Exposición autorizada $311.36 → $185.37.  *(commit 3a74e6a)*
- ~~**A2. Deadlocks de `nfl-sync-cdn` (#35) con SKIP LOCKED.**~~ `sync_nfl_cdn_tick()` y
  `espejar_nfl_a_live()` tomaban candados de `live_scores` en órdenes distintos.
  Ambos ordenan ya por `espn_event_id` y pre-candan con `FOR UPDATE SKIP LOCKED`
  (no se puede pegar a un `INSERT ... ON CONFLICT`). **Medido: 0 deadlocks en 7 días**;
  los 18 fallos eran `job startup timeout` (#88). Es prevención para el kickoff.
  De paso, un solo vocabulario de `deporte`.  *(commit 3a74e6a)*
- ~~**A3. Línea de cierre CLV a T-5, aislando el live.**~~ `v_odds_prematch` (identidad
  canónica `espn_event_id, mercado, linea, casa, snapshot_at`) y `v_linea_de_cierre`.
  Medido: solo 0.93% de los snapshots ligables son en vivo, pero **76% de los cierres
  están a más de 6h del saque** (mediana 18h) y solo 10 caen en T-5. T-5 quedó como
  ETIQUETA de calidad, no filtro: filtrarlo dejaría el CLV en n=10.  *(commit 3a74e6a)*
- ~~**A4. Sizing invertido: el monto lo decidía el momio (#208).**~~
- ~~**A5. El EV de la tarjeta no era el EV que dimensiona (#209).**~~
- ~~**A6. Abridor visitante vacío por caché vencido (#210).**~~ 29 vencidos → 4.
- ~~**A7. "Gana local" en vez del nombre del equipo (#211).**~~
- ~~**A8. La pantalla ofrecía lo que RONGOL rebota (#212).**~~
- ~~**A9. Sin techo de cartera; 24.8% del bankroll en 8 apuestas (#213).**~~ CDaR 20%.
- ~~**A10. Botón "Apostar en Playdoit" no abría nada.**~~ `window.open` con `noopener`
  devuelve `null` por especificación; la pestaña nunca se navegaba.

---

## B. ABIERTAS — LOTE 1 (en ejecución ahora)

~~1. **Oráculo: `limpieza-nocturna` borra el marcador antes de calificar (#181).**~~ **CERRADO**
   MEDIDO: 185 picks sin calificar; 59 ya jugados; **42 sin fila en `live_scores`**
   (borrada) y 6 con marcador final disponible que nadie calificó.
   Causa: `DELETE FROM live_scores WHERE status IN ('post','final') AND updated_at <
   now() - interval '72 hours'` (cron 32, 11:00 UTC). Un pick no calificado en 72h
   pierde su marcador para siempre. Es pérdida de datos irreversible.

~~2. **404 de ESPN: ni registro ni evasión.**~~ **CERRADO — DIAGNÓSTICO RETRACTADO**
   MEDIDO: 235 respuestas 404 en 2 horas = **13.5% de todo el tráfico saliente**.
   El 100% cae en minuto ≡ 0 mod 10 → cron `futbol-jugadores-pedir` (`*/10`,
   `futbol_jugador_pedir(60)`): 35-45 de cada 60 peticiones son 404. Nada registra
   qué id murió, así que se reintenta el mismo id para siempre (~6,500 llamadas
   desperdiciadas al día).

~~3. **RETO 13M: 5 de los 7 motivos de bloqueo no tienen insignia.**~~ **CERRADO**
   `bloqueado_por` devuelve `abstencion | sin_datos | rongol | kelly | ev_negativo |
   bajo_minimo | exposicion`. La UI solo pinta insignia para `rongol` y `exposicion`.
   Hoy 14 de 16 picks caen en "descartado" y el usuario ve un muro sin taxonomía.
   (Hueco que yo mismo dejé al desplegar A8/A9 — entra por la Regla 360°.)

---

## C. ABIERTAS — SIGUIENTES (por prioridad, con su número histórico)

~~4. **#193** El 0.55 hardcodeado.~~ **CERRADO.** La escritura ya estaba muerta: última
    fila con 0.5500 el **1-sep**; del 2 al 5-sep hay 0. Lo que seguía vivo era la
    contaminación del corpus (935 filas) y que **el termómetro no las excluía**.
    Backfill de la marca (935/935) + `v_termometro_motor` ahora filtra
    `prob_placeholder`. Efecto medido en el veredicto:
    | ventana | mercado | t antes | t después | veredicto |
    |---|---|---|---|---|
    | 90d | Over/Under | −2.97 | **−1.14** | PIERDE → EMPATE |
    | 90d | TODOS | −3.27 | **−1.93** | PIERDE → EMPATE |
    | todo | TODOS | −4.20 | **−3.24** | sigue PIERDE |
    | todo | Corners | — | **−4.27** | PIERDE (el perdedor real) |

5.  **#191 — NO EJECUTADO, premisa falsificada.** La orden era vetar MLB Moneyline
    "dado que el Brier Score es peor que la tasa base". Con el corpus limpio (#193)
    eso ya no se sostiene: **MLB Moneyline n=1074, exceso de confianza −0.020,
    Brier motor 0.25114 vs base 0.24728, ventaja −0.00385, t = −1.35.** No es
    significativo a ningún umbral convencional. Moneyline global: t=−0.71 (90d, n=851)
    y t=−0.30 (todo, n=1253). El dinero ya está bloqueado por el veto RONGOL
    (ROI −41.3% en 42 picks), así que **no hay exposición mientras se decide**.
    Requiere confirmación explícita del usuario para vetar sobre otra base.
~~6. **#202** Cobertura del torniquete.~~ **CERRADO. Auditoría de las puertas de dinero:**
    | puerta | RONGOL | CDaR | abstención | techo |
    |---|---|---|---|---|
    | `reto_picks_hoy` | ✅ | ✅ | ✅ | vía kelly |
    | `revisar_apuesta` | ✅ | ✅ | **✅ (era ❌ — cerrado hoy)** | ✅ |
    | `tamano_apuesta` | ❌ | ❌ | ❌ | ❌ |
    | `devils_advocate` | ❌ | ❌ | ❌ | ❌ |
    | `devils_advocate_parlay` | ❌ | ❌ | ❌ | ❌ |
    | `autodiagnostico` | ✅ | ❌ | ❌ | ❌ |
    (`kelly_stake`, `stake_techo`, `rongol_veto`, `kelly_fraccion_pct` NO son puertas:
    son las guardas mismas.) El hueco real era **`revisar_apuesta` sin abstención**: un
    mercado vetado pasaba sin que nadie lo dijera. Cerrado — no bloquea, **exige razón
    escrita**, porque un betslip escaneado es una apuesta YA COLOCADA y rechazarla
    rompería el registro contable. Verificado: O/U → `advertencia` + `requiere_razon`;
    ML normal → `ok`; MLB → `bloqueado` por RONGOL.
~~7. **#176** Isotónica aplastada.~~ **CERRADO: SUSPENDIDA.** Medido: las 15 anclas se
    ajustaron el **30-ago**, y el ancla `ai_pro:OU` `0.547 → 0.452` con muestra **1059**
    ES la constante 0.55 — la curva de Over/Under aprendió del relleno. Además aplasta:
    en `ai_pro` la entrada va de 0.241 a 0.769 (52.8 pp) y la salida de 0.299 a 0.511
    (**21.2 pp**); dice 76.9% y entrega 51.1%. `ai_pro:ML` topa en 0.454 → 0.454 (identidad).
    `calibrar_probabilidad` devuelve NULL mientras `updated_at` sea anterior al 5-sep;
    **la suspensión se levanta sola** al reajustar con datos limpios. No se borró la tabla.
    Verificado sin romper nada: 16 picks con dinero, 2 apostables (igual que antes).
~~8. **#182** Piso de muestra + reloj.~~ **CERRADO.** Medido: de 16 picks, **1 nunca
    medido** (kelly_stake usaba n=30 como PRIOR, que no es medición sino "no sé") y
    **0 con n<30 real**. Nuevo valor `bloqueado_por = 'muestra_chica'` con su propio
    motivo, para que la pantalla no diga "el precio no compensa" cuando lo que pasa es
    que no hay con qué compararlo. Reloj: `horaCorta` YA guardaba contra NaN y el eje
    de la gráfica ya tenía su arreglo de Infinity; lo que faltaba era la fecha en el
    **pasado**, que se pintaba como hora normal (ESPN reprograma y la fila queda vieja).
    Ahora dice "ya comenzó". Dinero intacto: 2 apostables, $159.29.
9.  **#158** El chip GANA de MLB enseñaba la probabilidad previa con el partido en vivo.
~~10. **#159** Cartelera de MLB.~~ **CERRADO — Y MI PROPIO DIAGNÓSTICO CORREGIDO.**
    Son **5 filtros, no 3**. Embudo: 416 → 34 (no muy viejo) → 19 (corte de día) →
    15 (no final) → 15 (con momio) → 15 salida.
    Parecía que el corte de día era el cuello (34→19), pero al quitar **todo tope
    superior el resultado sigue siendo 15**: lo que ese corte quitaba ya estaba
    `final` o sin momio. El filtro de momios tampoco corta (15→15).
    **La causa real es cobertura de precios:** el 6-sep hay 17 juegos cargados y
    **solo 3 con momio**; el 7-sep, 1 juego y 0 con momio. Es la clase de #40, y se
    llena solo conforme avanza el día.
    Cambios hechos igual, por higiene: (a) el corte de día dependiente de zona horaria
    → ventana rodante de 36h, más simple y sin sorpresas de DST; (b) nueva columna
    `over_en_abstencion` para que el radar no pinte Over/Under como accionable cuando
    el mercado está vetado (15 de 15 filas marcadas).
11. **#120** Tenis: 112 de 163 partidos de ATP con marcador imposible.
~~12. **#205** Partidos fantasma.~~ **CERRADO (candado preventivo).**
    Medido hoy: de 282 filas canónicas, **0 sin fila en `live_scores`, 0 con estado
    no apostable y 0 con deriva > 12h** (deriva máxima 0.0h). El fantasma no se está
    manifestando. Igual se armó el candado en `reto_picks_hoy`, que ahora hace
    LEFT JOIN a `live_scores` y manda a `partido_fantasma` cuando el estado ya no es
    `pre/scheduled/in/live` o cuando la hora que traemos se separó más de 12h de la
    oficial de ESPN. Sin efecto colateral: 2 apostables y $159.29, igual que antes.
~~13. **#206** Discrepancia entre motores.~~ **CERRADO — Y EL UMBRAL NO SE RELAJÓ.**
    Medido en `contraste_motores_futbol`: el umbral vivo es **10.0 pp**, más estricto
    que los 15 pp del ticket. Estados: 107 `ok` (media 4.3 pp), **43 `discrepancia`**
    (media 14.4, máx 25.4) y 390 `sin_contraste`. De las 43, solo 18 pasan de 15 pp:
    **subir el umbral a 15 habría dejado pasar 25 picks que hoy están frenados.**
    No se tocó.
    El hueco real: `v_pick_canonico` SÍ llama a `pick_sin_discrepancia_motores`
    (0 picks con dinero en discrepancia), pero **`revisar_apuesta` NO lo checaba** —
    la ruta manual (AddPickForm / betslip) pasaba por encima, con 43 discrepancias
    vivas en partidos por jugar. Cerrado con un parámetro nuevo `p_espn_event_id`
    (DROP+CREATE, porque un parámetro nuevo crea una SOBRECARGA, no reemplaza).
    Verificado: 1 sola versión de la función, la llamada vieja de 8 args sigue en `ok`,
    y con evento en discrepancia devuelve `advertencia` + `requiere_razon=true`.
~~14. **#175** Orquestación de crons.~~ **CERRADO.** Auditoría empírica sobre
    `cron.job_run_details` (7 días), no sobre mi lectura del cron. Dos colisiones reales:
    | cuándo | crons | frecuencia |
    |---|---|---|
    | 08:00 diario | `calibrar-ai-sql-12h` + `calificar-oraculo-madrugada` + `oraculo-madrugada` | 7 de 7 días |
    | cada 15 min | `capturar-clv-oraculo` (7,22,37,52) vs `grade-oraculo-picks` (7-59/15 → 7,22,37,52) | **100%: horarios idénticos** |

    Nueva malla:
    - `capturar-clv-oraculo` 7,22,37,52 → **12,27,42,57**
    - `calibrar-ai-sql-12h` `0 8,20` → **`3 8,20`**
    - `calificar-oraculo-madrugada` `0 8` → **`6 8`**
    - `oraculo-madrugada` se queda en `0 8` (ancla)
    Ninguno de los tres toca dinero: son medición y aprendizaje.
15. **#200** Residuales de #179/#180: pisos de muestra y el veto blando de Uruguay.
16. **#169** Calibración sobre picks publicados: primero descartar el confundidor.
~~17. **#174** Poisson sobredisperso.~~ **CERRADO — PREMISA DEL TICKET INVERTIDA.**
    Re-medido sobre 365 días:
    | deporte | partidos | media | varianza | var/media | veredicto |
    |---|---|---|---|---|---|
    | FÚTBOL (goles) | 10,939 | 2.826 | 2.871 | **1.016** | Poisson es razonable |
    | MLB (carreras) | 2,611 | 9.124 | 22.482 | **2.464** | SOBREDISPERSO |
    La sobredispersión está en **MLB, no en fútbol**. Pasar fútbol a Binomial Negativa
    habría metido un parámetro de dispersión donde el ajuste es 1.016: inflar colas sin
    evidencia. NO SE HIZO.
    Tampoco se tocó `v_termometro_motor`: es el **instrumento de medición** (Brier vs
    tasa base), no el modelo de goles. "Limitar el peso del Brier" ahí sería corromper
    el único termómetro honesto que hay.
    MLB O/U ya está cubierto por el veto global `over/under` en `mercados_en_abstencion`,
    así que **no fluye dinero por el modelo sobredisperso**.
18. **#203** Poblar el hueco: cargar segundas divisiones (ya en `ligas_master`, apagadas).
19. **#204** FUT PRO usa otro motor y otro formato que Favoritos.
20. **#189** `v_goles_equipo_futbol` creada (528 equipos, 29 ligas): falta conectarla.
21. **#188** Mapeo de ligas, escritor Tier 1, `v_poisson_picks`.
22. **#155** Notificaciones de marcador: dos sistemas mandando lo mismo.
23. **#145** Fútbol: carga de stats por jugador desde ESPN (ligado al punto 2 de arriba).
24. **#133** Llevar clima, sabermetría y contexto a NFL, fútbol y NBA.
25. **#87**  FANTASY/NFL: falta ADP.
26. **#118** NFL: picks apagados hasta medir (revisar después del 10-sep).
27. **#123** Bono: dos convenciones distintas y un parlay de $1,194 por confirmar.
28. **#42**  Acotar columnas del Feed de Comunidad.
29. **#38**  Bloqueantes para publicar: apodo, funciones rotas, correo.
30. **#36**  Verificar caché de análisis y decidir la UI de Batallas.
31. **#98 / #100** Cierres de día pendientes de redactar.
32. **#63**  Llaves legacy: sigue en `in_progress`; requiere acción del usuario, no mía.
33. **#105** Seguridad: 2 vistas de dinero cerradas; queda revisar los 43 respaldos.
34. **#113** Marcadores cruzados en pantalla (tenis congelado, MLB al revés).
35. **#67 / #70** Equipos favoritos con estrella; historial por equipo A-F sin consumir.
36. **Deep-link de Playdoit:** `build_bookmaker_link` devuelve solo la raíz
    (`deep_link_quality: home_only`). No se pudo verificar una ruta `/login` porque
    Playdoit responde 403 a todo lo que no sea navegador real (Cloudflare).
    Requiere que el usuario pegue la URL exacta.
37. **Prueba de humo en navegador** del candado de dinero (#207): mi proxy bloquea
    `reto13.lovable.app`.

---

## D. HALLAZGOS NUEVOS (anotados sin desviarse)

38. **El grader del Oráculo salta el 100% de los pendientes, y hace bien.**
    `grade-oraculo-picks` respondió 200 con `graded:0, voided:0, skipped:185`.
    Al mirar los 6 que yo había contado como "recuperables": 3 son de **Corners**
    (`af_*`) y `live_scores` solo guarda goles, nunca tiros de esquina — ese mercado
    **no se puede calificar desde ahí, nunca**. Los otros 3 son el evento `401874394`
    con marcador final 0-0 y picks "Over 36.5 Goles" / "Over 37.5 Puntos" en el mismo
    partido: dato basura de origen. Saltarlos es lo correcto.
    → **Corrección a mi propia medición del punto 1:** los 6 no eran recuperables.
    Lo recuperable de verdad son 0. Falta: una fuente de corners para calificar ese
    mercado, o marcar Corners del Oráculo como no calificable.

39. **`v_salud_espn_404` reporta "AVISO: hay 429 (cuota)".** 11 respuestas 429 en la
    ventana de 2h. Cuota de ESPN rozada mientras se drena el padrón de jugadores.
    No es urgente (el drenado termina solo) pero hay que vigilarlo.

40. **40 picks del Oráculo perdidos sin remedio.** Ya jugados, sin fila en
    `live_scores` y sin fila en `historico_partidos_espn`. NO los toqué: marcarlos
    a mano cambia el corpus de aprendizaje y eso es decisión del usuario, no mía.
    Opciones: dejarlos `pendiente` para siempre (hoy) o marcarlos `nulo`.


~~41. **La isotónica hay que reajustarla, no solo suspenderla.**~~ **CERRADO.** Filtro
    inyectado como sub-consulta en las **4 lecturas** de `oraculo_picks_tracking`
    (2 por función), así no depende del `WHERE` particular de cada una.
    Muestra que vería el reajuste: **2,776 → 1,894** filas (882 placeholders fuera, 31.8%).
    NO se corrió el reajuste a propósito: correrlo movería `updated_at` y levantaría
    la suspensión de #176, desplegando una curva nueva sin visto bueno.
42. **El termómetro cambió de veredicto al limpiar el corpus.** Toda conclusión previa
    basada en `t = −2.97` para Over/Under queda invalidada. Corners es el único mercado
    que pierde de verdad (t = −4.27, n=119) y ya está en abstención.
43. **El contador `omitidos_por_candado` es invisible donde importa.** `sync_nfl_cdn_tick()`
    lo devuelve en su texto de retorno, pero pg_cron guarda `return_message = "1 row"` para
    un `SELECT`, así que en `cron.job_run_details` nunca se ve. Verificado el 5-sep:
    11 corridas, 1 solo mensaje distinto, y es literalmente "1 row". Si en el kickoff
    empiezan a omitirse filas por contención, nadie se va a enterar. Arreglo: que la
    función escriba el contador en una tabla de salud (o `RAISE LOG`), no solo en el
    retorno. NO urgente: la omisión es segura por diseño y se recupera al tick siguiente.

~~44. **Puertas crudas.**~~ **CERRADO. Auditoría de UI (grep sobre `src/`):**
    | función | ¿llega a la UI? | dónde |
    |---|---|---|
    | `tamano_apuesta` | **SÍ** | `components/reto/CalculadoraMonto.tsx:42` |
    | `devils_advocate` | **SÍ** | `hooks/useDevilsAdvocate.ts:43` → `AddPickForm` |
    | `devils_advocate_parlay` | **SÍ** | `components/reto/CalificarIAModal.tsx:251` |
    | `autodiagnostico` | **NO** | solo en `types.ts` (tipos generados) |

    **Corrección a mi propia nota:** dije "CERO guardas" y era falso. `tamano_apuesta`
    YA traía el tope 0.52 por tasa base (#191), techo de 2% del bankroll y aviso de
    ventaja negativa. Lo que le faltaba era el **CDaR**: con la cartera al 20% seguía
    sugiriendo montos. Cerrado — se recorta a `exposicion_viva(...).disponible` y
    devuelve `recortado_por_cartera` + veredicto propio.
    Los dos `devils_advocate` **no emiten monto**: devuelven un semáforo, y
    `CalificarIAModal.tsx:326` ya los trata como informativos con su propio gate Kelly.
    No se renombró nada: renombrar una función que la UI llama la rompe.


45. **`sin_contraste` es el 72% de la tabla de contraste.** 390 de 540 filas en
    `contraste_motores_futbol` no tienen medición (`prob_af` o `prob_espn` ausente),
    así que la guarda de discrepancia no puede opinar sobre ellas: pasan por defecto.
    No es una fuga de dinero (el resto de las puertas siguen aplicando), pero la
    cobertura real del contraste es 28%, no 100%.

---

## E. AUDITORÍA DEL CEREBRO PREDICTIVO (5-sep-2026) — solo medición, cero cambios

46. **`features_json` NO guarda ni una sola variable de entrada.** Barrido de las 1,178
    filas de `oraculo_picks_tracking` de los últimos 45 días: las claves son
    `prob`, `edge`, `momio_justo`, `momio_ia`, `ev_estimado`, `confianza`, `razon`…
    es decir **salidas**. No hay xG, ni abridor, ni clima, ni descanso, ni muestra.
    Consecuencia: el inventario de variables NO se puede reconstruir desde el registro
    del pick; hubo que rearmarlo leyendo el código de cada motor. Tampoco se puede
    hacer atribución (qué variable movió la probabilidad) ni auditar un pick viejo.

47. **NFL no tiene modelo: `nfl_predecir` devuelve el precio del mercado sin vig.**
    Líneas 40-47 y 57-62: la `probabilidad` de Moneyline y Total sale de `g.ml_home` /
    `g.over_odds` normalizados, con `'fuente','mercado'` escrito literal en el JSON.
    Por construcción el EV contra ese mismo mercado es ≈ 0 menos la comisión.
    Concuerda con el dato: **15 de 15** picks NFL de los últimos 45 días traen
    `prob_placeholder = true`.

48. **El clima de NFL está desconectado del motor.** `nfl_clima_hora` tiene 1,541,736
    filas y dos crons vivos, pero `nfl_predecir` lee `nfl_partidos.temperatura` /
    `viento_rafaga` / `techado`, que **nadie llena**: 100% nulo en 2025, 99.3% en 2026,
    100% en 2027. Las alertas de frío/calor/viento del motor nunca han disparado.

49. **MLB: alineación real 65% ausente, clima 35% ausente.** Muestra de 40 juegos
    (3-sep a 6-sep): `fuerza_alineacion()` devuelve NULL en 26 → cae al fallback 1.0;
    `clima_partido_mlb()` NULL en 14 → fallback 1.0. Además `mlb_stats_cache`:
    FIP/ERA del abridor 15.3% local / 14.6% visita nulos, mano del abridor 15.3% /
    13.9%, y con ella los splits vs zurdo/derecho. Bullpen, park factor y últimos-10
    están bien (1.4%). **El 71.5% del caché está vencido** aun con el cron de #210.

50. **Fútbol es el motor mejor alimentado y el más pobre en variables.** Muestra de
    60 partidos de las próximas 72h: 0% sin perfil de equipo, 0% de ligas sin base,
    muestra mínima promedio 17.2 partidos, solo 6.7% por debajo de 8.
    Pero `motor_probabilidades` solo consume **goles a favor / goles en contra** de
    `historico_partidos_espn` (vía `equipo_perfil`/`liga_base`), el factor de descanso
    y el H2H. xG, clima, árbitro, lesiones y rotación **tienen peso literal 0**: sus
    únicos lectores son funciones de contexto para el LLM (`contexto_para_llm`,
    `bloque_equipo_futbol`, `dossier_contexto`), ninguna toca la probabilidad.
    `xg_modelo_coef` está en **0 filas**.

51. **NO hay look-ahead bias.** Barrido de los 7 objetos que mencionan
    `clv_pct|odds_cierre|momio_cierre`: 34 menciones, **0 no triviales** — todas son
    columnas de proyección, ninguna entra en un `WHERE`, `CASE` ni expresión de
    probabilidad. `sync_pick_to_learning_data` solo escribe con el resultado ya
    definitivo, y de los 4 lectores de `pick_learning_data` ninguno lee un campo de
    cierre. La regla T-5 como variable post-mortem se está respetando.

52. **Lo que la app llama "CLV" en la pantalla NO es CLV.**
    `capturar_clv_oraculo` calcula `(odds_apertura / cierre − 1)`: eso es el
    **movimiento de la línea**, no el valor del precio capturado. Y el "cierre" es
    flojo por dos lados: acepta snapshots de hasta `match_date + 5 minutos`
    (precio EN VIVO) y no exige recencia mínima (la ventana abre en `−10 días`).
    Medición sobre `v_linea_de_cierre`: de 1,040 cierres, **3.8% son T-5 de verdad**,
    10.2% T-30, 6.6% T-6h y **79.3% son "lejanos", con mediana de 1,801 minutos
    (30 horas) antes del saque** — o sea una apertura disfrazada de cierre.
    Los dos números viven al mismo tiempo y tienen signo opuesto:
    `oraculo_picks_tracking.clv_pct` = **+1.57%** (n=699, es el que ve el usuario en
    `reto_13m_estado`) contra `clv_tracking.clv_pct` = **−7.54%** (n=30, este sí mide
    `momio_apostado` contra el cierre). El mensaje "le estamos ganando al cierre" se
    apoya en el número equivocado.

53. **`calibracion_coef` era un vector de look-ahead vivo, y el arreglo destapó un
    SEGUNDO lector sin compuerta.** La tabla no tenía ninguna noción de tiempo: 7
    filas, 3 vigentes, cero columnas de versionado. `calibrar_prob_motor` elegía con
    `ORDER BY ajustado_at DESC LIMIT 1`, así que un coeficiente ajustado DESPUÉS de un
    partido cambiaba el EV de ese partido pasado (medido: `ev_local_pct` −17.51% →
    +64.80%). Se separaron dos conceptos que se estaban confundiendo:
    `effective_from` (desde cuándo el coeficiente existía y podía usarse) y
    `data_cutoff_at` (hasta qué fecha llegan los datos con que se estimó).
    Solo el coeficiente de fútbol (id 7) tiene evidencia documental del rango de datos
    ("jul-2023 a sep-2026") y quedó `data_cutoff_verificado = true`. Los demás quedan
    **NO verificables**, sin fecha inventada: la única afirmación defendible es la cota
    `data_cutoff_at <= ajustado_at` (no se puede ajustar sobre datos que aún no existen),
    y usar esa cota como puerta es estrictamente conservador — puede excluir un
    coeficiente válido, nunca admitir uno contaminado.
    Al re-correr la prueba adversarial apareció el segundo defecto: `predecir_mlb`
    tenía **otro** `SELECT` a `calibracion_coef` (`ORDER BY c.ajustado_at DESC LIMIT 1`)
    que alimenta `rango_medido_pct` y el texto de `motivo_sin_ev` **que ve el usuario**.
    No movía el EV, pero sí cambiaba el rango mostrado de un partido pasado
    ({43.2–62.2, n=1056} → {0.0–100.0, n=999}) y podía describir un coeficiente
    DISTINTO del que realmente se aplicaba. Quedó alineado al mismo orden y a las
    mismas dos condiciones que `calibrar_prob_motor`.
    Impacto productivo medido: **30 de 30 partidos próximos conservan calibración**
    (cero efecto sobre dinero vivo); 263 de 303 partidos de los últimos 30 días la
    pierden, que es lo correcto — son anteriores al coeficiente y llamarlos
    "calibrados" era ficción retroactiva.
    Regresión propia detectada y corregida en el mismo turno: `effective_from` quedó
    NOT NULL y el INSERT de `reajustar_calibracion` no la llenaba, así que el
    recalibrado semanal habría reventado. Se parchó el **escritor** (no se puso un
    DEFAULT que permitiera omitirla): ahora declara `effective_from = now()` y
    `data_cutoff_at = max(match_date)` de los mismos picks que estiman `a` y `b`.

54. **El candado temporal final: la contradiccion que impedia cerrar Fase 1.5.**
    En el punto 53 declare como "riesgo residual" que `filtro_pick` usaba `now()`.
    Ese residual no era teorico: la inspeccion 360 de todos los consumidores de
    `filtro_pick` y `calibrar_prob_motor` encontro **una ruta historica real y
    alcanzable**, `calibracion_publica_kpis`, que alimenta la pantalla publica
    "¿LA IA DICE LA VERDAD?" y reconstruia el Brier calibrado de 3,136 picks YA
    JUGADOS usando el coeficiente de hoy — ajustado, en parte, sobre esos mismos
    picks. Medido: **1,661 picks se calibraban con un coeficiente que no existia
    cuando se hicieron**; ahora solo los 24 posteriores al coeficiente vigente.
    La correccion no fue pasar la fecha en un lugar, sino hacer imposible el olvido:
    `calibrar_prob_motor` y `filtro_pick` ya no tienen NINGUN valor por omision, asi
    que una llamada incompleta falla con `42883: function does not exist` en vez de
    caer callada en el presente. El tiempo real pasa por `calibrar_prob_motor_live`
    y `filtro_pick_live`, que dicen en su nombre lo que hacen. Verificado con cuatro
    intentos de omision, los cuatro rechazados.
    De paso aparecio el ultimo desvio silencioso: `predecir_mlb` tenia **siete**
    `COALESCE(m.game_date, now())`. Con la fecha nula, todos los cortes temporales se
    movian a hoy. Hoy son 0 de 1,224 filas sin fecha, asi que la guarda no apaga nada;
    existe para que no vuelva a ser silencioso.
    Sobre los coeficientes legacy: `track_commit_timestamp` esta apagado, no hay sello
    fisico. Para los ids 6 y 7 `pg_stat_statements` conserva el INSERT que los creo y
    su lista de columnas no incluye `ajustado_at`, o sea que lo puso `DEFAULT now()`
    y no pudo ser backdateado. Para el **id 3 (NFL) no hay evidencia**: es anterior a
    la ventana. No se inventa una fecha; se declara no verificable y se mide la
    exposicion, que es **cero picks de NFL resueltos**.

55. **Hardening post-cierre: los invariantes ya no dependen de que alguien los corra.**
    `invariantes_temporales()` codifica las tres reglas que la auditoria comprobo a
    mano (sin defaults en la API temporal, sin `coalesce(fecha, now())` en el motor)
    y `tg_candado_temporal`, un event trigger sobre `CREATE/ALTER FUNCTION`, rechaza
    el DDL que las rompa. Probado en las tres direcciones: DDL benigno pasa, los dos
    intentos de regresion se rechazan con el invariante y la regla exacta en el
    mensaje, y la salida `app.mantenimiento_candado_temporal='on'` permite migraciones
    legitimas en dos pasos. Limite declarado: no cubre un DROP suelto, que de todas
    formas revienta a la vista.
    Y la evidencia de procedencia salio de `pg_stat_statements` (memoria, se resetea)
    a `evidencia_procedencia`, con las dos sentencias copiadas verbatim — ninguna
    incluye `ajustado_at`, o sea que lo puso el DEFAULT — y con la **ausencia** del
    id 3 registrada con la misma formalidad que la prueba, para que nadie la
    confunda manana con "no busque".

56. **#209 CERRADO en la pantalla del RETO 13M; #208 confirmado en el efecto pero
    REFUTADO en el mecanismo.** La tarjeta si muestra el EV que dimensiona
    (`ev_pct`, etiquetado "EV real") junto a "Prob. que decide"; `ev_pct_declarado`
    esta tipado pero no se pinta. Importa, porque los dos divergen fuerte: Dortmund
    marca +16.6% declarado contra **-19.4%** real.
    Sobre #208: el monto YA NO lo decide solo el momio — el tope plano que causaba
    eso se reemplazo el 5-sep. Pero tampoco lo decide el modelo. **Lo decide la
    frontera de tramo de `zonas_confiables`.** Medido con el momio fijo en 2.20:
    subir la probabilidad declarada de 49 a 50 tira el monto de **$110.07 a $0**, y
    de 59 a 60 lo tira de **$145.70 a $0**, porque al cruzar de tramo el sesgo pasa
    de +4.9 a +1.2 y el recorte de 2.2 a 4.6. Y con el EV declarado fijo en +10%,
    el stake es **$0 en 10 de 12 momios**: solo hay dinero donde la probabilidad
    cae en el unico tramo con sesgo positivo grande.
    Causa raiz: el sesgo por tramo se aplica como desplazamiento aditivo constante
    dentro de la banda, y la banda se elige con la probabilidad declarada, asi que
    `p_decide(p)` es escalonada y **no monotona**. Peor caso medido: BTTS, salto de
    **-15.9 pp** y **-$235.91** al subir la probabilidad un punto.
    Esto explica mecanicamente el sintoma viejo de #126 (el motor solo produce
    no-favoritos). Diagnostico completo, cero modificaciones a produccion.

57. **HAY TRES EV, y la segunda pantalla mas usada publica picks que el motor de
    dinero rechaza.** `mejor_oportunidad_hoy` (109 llamadas reales en 3 dias)
    calcula su propio EV sobre una SEGUNDA calibracion
    (`calibrar_prob_motor_live` encima de la del deporte) y **filtra y ordena por
    el**. Medido hoy: 7 de 16 picks vivos tienen contradiccion de signo entre
    EV_CAL y EV_DECIDE, y **4 salen ahi con EV positivo** — Dortmund en el puesto
    #7 con **+12.9% mostrado contra -19.4% real**. En dos de ellos la pantalla
    publica ademas un `kelly_pct` positivo. Y 5 de 19 filas traen
    `fuera_de_rango=true`, o sea que la calibracion devolvio NULL y la funcion cae
    a la probabilidad cruda: una de ellas es el **orden #2 del dia con +22.5%**.
    #209 pasa a **CERRADO EN RETO13M / FALLA GLOBALMENTE**.

58. **`zonas_confiables` es 100% futbol, y el 62.5% de los picks de hoy son de
    beisbol.** `modelo_backtest`, su unica fuente, tiene 30,876 filas de 20 ligas y
    **todas son soccer: cero de baseball, cero de football**. La correccion de
    Moneyline se estimo sobre 5,406 picks de futbol y se aplica tal cual a MLB.
    El tramo que gobierna la banda 50-60% tiene **187 partidos**.
    Ademas: sin cutoff temporal en el codigo (implicito, los datos paran el
    26-ago), **sin train/test**, sin versionado (`DELETE` + reconstruccion), y sin
    columna de deporte. `nivel` y `brier` se calculan y **el dinero no los lee**.
    Diagnostico: **hace calibracion Y haircut de sizing en el mismo objeto**, y ese
    solapamiento es la causa raiz de la no monotonicidad — `zona_realidad` bandea
    con `width_bucket(p,0,1,10)`, deciles fijos, asi que las fronteras caen exactas
    en 0.50 y 0.60, justo donde medimos los saltos.

59. **`zonas_confiables` NO sobrevive fuera de muestra, y MLB tiene sesgo propio de
    signo contrario al que recibe.** Walk-forward con 4 cortes sobre 18,418
    observaciones: la mejora de Brier es significativa en **un solo mercado,
    Corners** (t=4.93) — que tiene el dinero apagado. Moneyline t=1.40,
    Over/Under **t=-1.83 (negativo)**, BTTS t=0.35. **Quitando Corners la mejora
    global es -0.00023: negativa.**
    Del detalle: el sesgo ML t5 (+4.9) sí sobrevive 3/3 pliegues, pero **ML t6
    (+1.2) no sobrevive** — y es justo el tramo que produce la peor discontinuidad
    de dinero (el que tira el stake de $145.70 a $0): un pliegue, n=45 en test,
    SE 7.2 pp y el signo invertido.
    **Corrijo mi hipotesis previa sobre MLB**: NO esta sin evidencia. Hay 2,152
    picks resueltos, 1,101 de Moneyline — mas que los 853 de futbol que hoy los
    gobiernan. Y su walk-forward propio dice lo contrario que futbol: MLB Moneyline
    40-50% mide **-0.4 / -3.4 / -4.0** en 3 pliegues y le aplicamos **+4.9** de
    futbol; MLB Over/Under 50-60% mide **-3.4 / -9.5 / -9.8** (3/3, la senal mas
    estable del sistema) y le pasamos **+0.3**. **6 de los 10 picks de MLB de hoy
    reciben una correccion de ~7.5 pp en la direccion equivocada.**
    El veredicto no es MLB_SIN_EVIDENCIA: es MLB_TIENE_EVIDENCIA_Y_LA_CORRECCION_VA_AL_REVES.

60. **Retiro mi propia recomendacion de 2A.9.** La formula
    `P_MERCADO + s(n)*(CAL - P_MERCADO)` es arquitectura de ensemble con el
    mercado, y **no se puede demostrar hoy**: P_MARKET_FAIR verificable existe para
    **401 partidos de MLB** (overround mediano 1.78%) y **197 de futbol con los tres
    lados de 1X2**; 87 de 284 casos de futbol no tienen empate, o sea que no se
    puede quitar el vig. Contra 2,152 picks de MLB y 30,876 filas de backtest, la
    cobertura es minoritaria. Se recomienda en su lugar la arquitectura A:
    calibracion monotona por deporte y mercado, y la incertidumbre reduciendo
    EXPOSICION (`confidence`) en vez de reescribir la probabilidad.
    Nota de metodo: `badrino_partidos.ml_home/ml_away` son momios AMERICANOS
    enteros. Mi primera medicion dio "0 partidos con ambos lados" por no convertir;
    el dato estaba bien y la consulta mal.

61. **SI existe el universo completo de MLB, y el sesgo de seleccion es enorme.**
    `bt_mlb_ml` (1,056 juegos, lado local de cada partido, sin seleccion) y
    `badrino_backtest` (2,580) son las poblaciones correctas. Comparadas con los
    picks publicados: la probabilidad media baja de **52.3% a 42.8%** y la
    dispersion se **duplica** — el sistema publica casi solo no-favoritos, que es la
    explicacion mecanica de #126. Y sobre todo: **en el universo el motor esta
    practicamente insesgado (-0.41 pp)**, mientras que en los publicados marca
    +2.01 pp. **El auditor tenia razon**: el -4% de MLB que medi el turno anterior
    es sesgo condicional a seleccion y NO puede ir al codigo como calibrador.
    Sigue siendo prueba de que el +4.9 de futbol es indefendible.

62. **El P_CAL actual no merece ser P_FAIR en NINGUN deporte.** MLB Moneyline sobre
    el universo completo: la calibracion **pierde en 3 de 3 ventanas** (Brier raw
    0.24732 vs cal 0.24850) y empeora el sesgo de -0.41 a -1.49 pp. Futbol,
    evaluado **en muestra** (el coeficiente se ajusto sobre ese mismo periodo, o sea
    en condiciones favorables): mejora global **-0.00019**, es decir empeora; y el
    sesgo crudo de Moneyline es **0.00 pp exacto** — el motor ya esta insesgado y
    calibrarlo lo desvia a -0.87.
    Conclusion: **P_FAIR = P_RAW** hoy, con `calibration_status` explicito
    (`CALIBRACION_RECHAZADA_OOS` en MLB ML, `SIN_CALIBRACION_DEMOSTRADA` en el
    resto). Identidad explicita no es un error: es el resultado de medir.
    Dato que conviene no perder: en futbol el motor SI discrimina (Brier 0.2146
    contra tasa base 0.2494); en MLB apenas (0.24732 contra 0.24964). Son dos
    motores de calidad muy distinta, y eso es lo que `confidence` debe reflejar,
    no la banda de probabilidad.

63. **V2 construido EN PARALELO: Kelly puro aislado, monotonicidad demostrada y
    aislamiento entre deportes bit a bit.** `kelly_full_v2` se declara IMMUTABLE, y
    eso hace que Postgres **le prohiba consultar tablas**: el aislamiento respecto de
    `zonas_confiables`, Wilson, Beta, bankroll y CDaR es una propiedad del motor, no
    una promesa del comentario. Malla de 2,475 filas y 2,450 pasos: **cero
    violaciones** de monotonicidad. Las tres regresiones obligatorias desaparecen —
    ML 49->50 pasa de $110.07->$0 a $97.50->$125.00, y ML 59->60 de $145.70->$0 a
    $300->$300. Prueba adversarial de aislamiento: mutar TODAS las fuentes de un
    deporte deja al otro **idéntico bit a bit**, en las dos direcciones, y cada
    mutación sí movió su propio deporte.
    `confidence = 1.0` con estado `PENDIENTE_DE_VALIDACION`: no hay evidencia todavía
    para elegir agregador y un 1.0 declarado es preferible a un haircut inventado.

64. **AVISO DE SEGURIDAD del shadow: V2 dimensionaría 12.6 veces más que V1.**
    Sobre 15 picks vivos: V1 autoriza $156.01 y V2 pondría $1,967.28. **Eso NO
    significa que V2 sea mejor** — es la consecuencia directa de que su haircut aún
    no existe. Y el desglose importa: **9 de las 13 divergencias no son del modelo,
    son de la capa de cartera** (RONGOL, $1,322.43) que V2 todavía no tiene. La
    divergencia atribuible a la probabilidad son 4 picks, $523.88.
    Conclusión operativa: **V1 está mal construido pero está conteniendo
    exposición**. Apagarlo antes de validar `confidence` y portar la capa de cartera
    multiplicaría el riesgo. Es el argumento más fuerte para respetar el orden
    C -> D -> E y no adelantarlo.

65. **CORRECCION: IMMUTABLE no demuestra pureza.** Sobreafirme que "Postgres le
    prohibe consultar tablas". Es falso: IMMUTABLE es una declaracion al
    planificador. Y peor: `kelly_full_v2` tenia **cuerpo de cadena**, con lo que
    Postgres **no registraba ninguna dependencia**, asi que un `pg_depend` vacio
    habria dado falso PASS para cualquier funcion. Reescrita con cuerpo SQL estandar
    (`RETURN`), que si se parsea y si registra: su unica dependencia es el esquema
    `public`. `inv_kelly_puro_v2()` hace siete comprobaciones y se conecta al event
    trigger como regla I4. Probado en las tres direcciones: version legitima
    aceptada; version impura con cuerpo estandar **rechazada** (`clases_halladas:
    pg_class`); y la via astuta —cuerpo de cadena leyendo la misma tabla, que evade
    k3— **rechazada por k2**.

66. **RONGOL no es una capa de cartera, y bloquea con n=6.** Corrijo mi lectura del
    turno anterior. `rongol_veto` es una lista de bloqueo por patron historico,
    pick a pick, sin acumulacion y **sin depender del orden**. Solo hay **3**
    lecciones con bloqueo total activas: MLB/OU **3-3 en n=6**, MLB/ML 15-27 en
    n=42, y MLB/ML **4-4 en n=8**. Dos de las tres son 50/50 exactos. Y el criterio
    es ROI historico, justo lo que el mandato prohibe como base de sizing.
    Atribucion exacta del delta V1 vs V2 sobre 15 picks: S1 (Kelly puro) $2,008.64,
    S2 (+techo/piso) $1,985.29, S3 (+RONGOL) $644.85, S0 (V1 real) $156.01.
    **RONGOL explica el 72.4% del delta** (-$1,340.44); el techo y el piso el 1.3%;
    el haircut de V1 mas el tope de exposicion, el 26.4%.
    Ademas: `exposicion_viva` **no es CDaR** — no hay variable aleatoria, horizonte,
    distribucion, escenarios, correlacion ni nivel de confianza. Es un tope de
    exposicion bruta del 20% con llenado greedy **por monto y no por ventaja**.
    Y la exposicion viva real esta en los parlays: **$1,003.36 en 2 parlays contra
    $156.01 en sencillas**, sin ningun control de dependencia entre patas.

---

## FASE 2 — BLOQUE 2A.40–2A.50 (5-sep-2026). PARLAYS COMO P0

67. **CORRECCION DE MI PROPIO REPORTE: los $156.01 NO son exposicion viva.**
    `exposicion_viva('rodelcast')` devuelve `picks_vivos = 0`, `detalle.picks = 0`.
    No hay UNA sola sencilla pendiente. Los $156.01 son el `monto_autorizado` que
    `reto_picks_hoy` **recomienda** (2 picks de MLS), dinero que todavia no sale.
    La exposicion REAL es **$1,003.36, 100% en parlays**.
    En mis reportes anteriores contrapuse "$156.01 en sencillas" contra "$1,003.36
    en parlays" como si fueran dos bolsas del mismo tipo. No lo son: una es
    propuesta y la otra es dinero ya entregado a la casa.

68. **SI, los parlays cuentan dentro del 20% — pero el 20% no es 20%.**
    Cadena verificada extremo a extremo:
    `exposicion_viva` -> `stake_techo(apodo,false)->bankroll` -> `bankroll_disponible`
    -> `get_bankroll_actual - bankroll_expuesto`. Y `bankroll_expuesto` **si suma
    parlays pendientes**. Numeros vivos: contable $7,003.36; expuesto $1,003.36
    (2 parlays, 0 sencillas); disponible $6,000.00; limite 20% = $1,200.
    **El defecto**: el limite se mide contra un bankroll del que YA se resto la
    exposicion. Con `E` expuesto y `C` contable:
    `E >= 0.20*(C - E)  <=>  1.2E >= 0.20C  <=>  E >= C/6`.
    El tope efectivo es **16.667% del bankroll contable**, nunca 20%. Con C=$7,003.36
    el techo real es **$1,167.23**, no $1,400.67.
    Y `disponible` miente: reporta **$196.64** cuando el margen real hasta el punto
    de corte es **$163.87** (`C/6 - E`). Sobrestima 20%.
    Verificado contra los datos del test: E=$1,096.61 -> bankroll $5,906.75, limite
    $1,181.35 (no alcanzado, C/6=$1,167.23 aun por encima); E=$1,503.36 -> bankroll
    $5,500, limite $1,100, alcanzado. El punto de cruce cae exactamente en C/6.
    Detalle adicional: `expuesto_pct` = 16.7% es `E/D`, no `E/C` (14.33%). La pantalla
    dice "16.7% de un limite de 20%" cuando en realidad va al **86% de su capacidad**.

69. **P0 GRAVE: el limite del 20% NO SE APLICA AL ESCRIBIR. Es solo informativo.**
    `exposicion_viva` tiene exactamente 3 consumidores: `reto_picks_hoy`,
    `revisar_apuesta` y `tamano_apuesta`. **Ninguno es trigger.** El unico candado
    de escritura es `tg_autoridad_stake`, que compara contra `stake_techo`
    (techo POR APUESTA), nunca contra la exposicion total.
    Prueba adversarial (INSERT real con rollback transaccional, base y final
    identicos en $1,003.36):
    - CASO 1 sencilla $93.25 -> **ACEPTADA**, exposicion 18.6%
    - CASO 2 parlay $500 -> **ACEPTADO**, exposicion **27.3%**, `limite_alcanzado=true`
    - CASO 3 sencilla $93.25 + parlay $500 sobre el MISMO evento -> **ACEPTADOS**
    - CASO 4 dos parlays mas ($500 + $400) -> **ACEPTADOS**, exposicion **37.3%**
    - CASO 5 parlay $1,200 -> **RECHAZADO** ("supera el techo de $900.00, 15.0%")
    Lo unico que rebota es el techo POR APUESTA. La cartera no tiene puerta.

70. **Por que los dos parlays de $500 pasaron sin firma.**
    `config_staking.stake_max_pct_reto = 15.0` y ambos traen `es_reto_13m=true`,
    asi que `stake_techo` autorizo 15% del disponible ($1,050 y luego $975), no el
    5% general ($350). `stake_techo_al_guardar` y `stake_sobre_techo_razon` estan
    NULL porque nunca hizo falta firmar. El candado #207 funciono como fue escrito.
    Consecuencia estructural: con techo por apuesta de 15% y tope de cartera de
    16.667%, **caben 1.1 apuestas RETO antes de agotar la cartera entera**.

71. **Anatomia de los parlays vivos: el sistema los califico D y se apostaron igual.**
    - `b848fb29` $500, momio 7.5048, 3 patas de La Liga, `ai_prob_combinada` 7.22%,
      `ai_ev_pct` **-45.80%**, `ai_calificacion` **D**, semaforo ambar.
    - `6c033d7d` $503.36, momio 9.7331, 5 patas (Liga MX, Premier, Bundesliga,
      Danish, MLS), `ai_prob_combinada` 5.89%, `ai_ev_pct` **-42.70%**, **D**, ambar.
    8 patas en total, **100% futbol**, **7 de 8 al equipo LOCAL**. Ninguna de las 8
    patas paso por `kelly_stake`, `rongol_veto`, `mercado_en_abstencion` ni por la
    puerta de calibracion: `tg_autoridad_stake` **salta explicitamente** las patas
    (`if v_pata then return NEW`) y el parlay se juzga como un solo objeto.
    **CERO funciones SQL escriben `ai_prob_combinada`**: viene de un LLM.

72. **CORRELACION_NO_MODELADA (conclusion obligatoria).**
    Existen dos maquinarias y ninguna sirve para estos parlays:
    - `parlay_ev_real`: solo aplica factores de `correlacion_mercados` a pares
      **del MISMO evento** (`a->>'evento' = b->>'evento'`). `correlacion_mercados`
      tiene 20 filas (n=1,860), todas de pares intra-partido (BTTS x Over, etc.),
      **cero filas de dependencia entre eventos distintos**. Los dos parlays vivos
      tienen 0 pares del mismo evento -> la funcion devolveria independencia exacta.
    - `simular_parlay` / `evaluar_parlay`: un factor comun gaussiano con
      **`p_rho` = 0.12 hardcodeado como DEFAULT**, sin ninguna medicion detras;
      ademas parte de `1/momio` (precio de la casa) dividido por un overround
      **asumido de 1.05**, o sea nunca ve la probabilidad del modelo.
    Barrido de 5 valores de rho, 40,000 sims, 5 repeticiones, CTE MATERIALIZED:
    | rho | EV parlay $500 | EV parlay $503.36 |
    |-----|----------------|-------------------|
    | 0.00 | -12.95% | -22.19% |
    | 0.05 | -12.88% | -20.68% |
    | 0.12 | **-9.13%** | **-16.33%** |
    | 0.25 | **+3.05%** | **+11.75%** |
    | 0.40 | +27.26% | +57.40% |
    **El signo del veredicto cambia entre rho=0.12 y rho=0.25 en los dos parlays.**
    Una constante no medida decide si la apuesta es buena o mala. Ausencia de
    evidencia, no independencia: **CORRELACION_NO_MODELADA**.
    (Nota de metodo: el primer barrido salio incoherente porque `random()` dentro
    de una subconsulta escalar se re-evalua por cada agregado. Se repitio con
    `WITH ... AS MATERIALIZED`; los numeros de arriba son los buenos.)

73. **Duplicacion de riesgo: hoy 0, pero la metrica no existe y el candado tampoco.**
    Definidas y medidas sobre el libro vivo:
    - `stake_equivalente_por_evento` (prorrateo `apuesta/n_patas`)
    - `max_loss_expuesta_por_evento` (la apuesta COMPLETA, porque una sola pata
      mata el parlay entero)
    8 eventos, cada uno tocado por 1 sola apuesta -> **sin duplicacion hoy**.
    Pero `sum(max_loss) = $4,016.80` sobre $1,003.36 realmente en riesgo, y sobre
    todo: **cada uno de los 8 partidos puede destruir $500 o $503.36 por si solo**
    (7.1% a 8.4% del bankroll contable), cuando una sencilla sobre ese mismo partido
    tendria techo de $300 (5%). El envoltorio de parlay convierte 8 eventos de <=5%
    de riesgo autorizado en 8 eventos con su propio gatillo de 7-8%.
    El CASO 3 del test demuestra que sencilla + pata sobre el MISMO evento se
    aceptan y **nada en el sistema lo nota**.

74. **RONGOL: el veto ignora el rango de momio en el que fue medido.**
    En `rongol_veto` la variable `v_rango` se calcula y **nunca se usa**:
    `la.rango_momio` no aparece en el WHERE. Ademas el vocabulario de buckets del
    veto (`<1.40`, `1.40-1.80`, `1.80-2.50`, `2.50-4.00`, `>4.00`) es distinto del
    de `rango_momio()` que guarda las lecciones (`1.01-1.50`, `1.50-1.80`,
    `1.80-2.20`, `2.20-3.00`, `3.00-5.00`): aunque se usara, no cruzaria.
    El filtro de liga tambien es un no-op: `(la.liga IS NULL OR p_liga IS NULL OR
    la.liga = p_liga OR liga_es_de_deporte(la.liga, p_deporte))` — el ultimo
    termino ya es verdadero por el AND anterior.
    **Efecto medido** (`oraculo_picks_tracking`, ai_pro, MLB, ML, 120 dias):
    | rango de momio | n | ROI | IC95 | medido por la regla |
    |---|---|---|---|---|
    | 1.01-1.50 | 8 | -33.1% | [-83.0, +16.8] | SI |
    | 1.50-1.80 | 42 | -41.3% | [-65.4, -17.1] | SI |
    | 1.80-2.20 | 350 | -4.5% | [-15.2, +6.1] | NO |
    | 2.20-3.00 | 504 | **+10.0%** | [-0.9, +20.9] | NO |
    | 3.00-5.00 | 118 | **+35.4%** | [+5.7, +65.2] | NO |
    | 5.00+ | 7 | +40.8% | [-192.4, +274.0] | NO |
    Los 10 picks de MLB que RONGOL bloqueo hoy tienen momios 1.893 a 3.02:
    **3 caen en 1.80-2.20, 6 en 2.20-3.00 y 1 en 3.00-5.00. NINGUNO en un rango
    donde la regla fue medida.** RONGOL esta bloqueando el unico tramo con ROI
    positivo estadisticamente significativo de su propia fuente de datos.

75. **RONGOL walk-forward: 1 de 3 reglas sobrevive.**
    Corte por mediana temporal dentro de cada celda:
    | celda | n train | ROI train | n test | ROI test | WR test |
    |---|---|---|---|---|---|
    | ML 1.50-1.80 | 21 | -37.7% | 21 | **-44.8%** | 33.3% |
    | ML 1.01-1.50 | 4 | -63.8% | 4 | -2.5% | 75.0% |
    | OU 1.01-1.50 | 3 | +23.3% | 3 | -100.0% | 0.0% |
    Solo **ML 1.50-1.80 (n=42)** persiste fuera de muestra. Las otras dos son ruido
    de n=8 y n=6. Y el veto se recalcula sobre una ventana movil de 120 dias con
    la misma fuente que despues bloquea: **es in-sample por construccion**.
    Extra: `extraer_lecciones_de_perdidas` **nunca escribe `bloqueo_total`** — ni
    en el INSERT ni en el DO UPDATE. Las 3 filas con `bloqueo_total=true` fueron
    marcadas a mano y sobreviven cada reconstruccion.
    Clasificacion: **LEGACY_GUARD_NO_VALIDADO** salvo la celda ML 1.50-1.80.

76. **El llenado greedy de produccion es un corte por PREFIJO, no un llenado.**
    `reto_picks_hoy` ordena por `monto_cand desc` y descarta todo lo que cumpla
    `expuesto + acumulado > limite_monto`. Si el candidato mas grande no cabe,
    **mata a todos los que vienen detras**, aunque cupieran.
    Medido con el conjunto real de hoy (9 candidatos con Kelly > 0, presupuesto
    disponible $196.64):
    | orden | picks financiados | monto | EV en pesos |
    |---|---|---|---|
    | **A. monto desc (PRODUCCION)** | **0** | **$0.00** | **$0.00** |
    | B. monto asc | 3 | $187.99 | +$11.06 |
    | C. EV desc | 0 | $0.00 | $0.00 |
    | D. EV asc | 3 | $187.99 | +$11.06 |
    | E. hora de arranque | 1 | $177.59 | **+$32.16** |
    | F. prob que decide desc | 1 | $104.68 | +$8.98 |
    El optimo de mochila con ese presupuesto es **+$35.71** (Washington $169.22).
    La produccion captura **$0.00**. Hoy el defecto esta tapado porque RONGOL
    borra 7 de los 9 candidatos y los 2 que quedan suman $156.01 < $196.64.

77. **Nomenclatura: no es CDaR ni "limite de exposicion". Es `TOPE_EXPOSICION_BRUTA`.**
    Propuesta (sin renombrar produccion todavia):
    - `TOPE_EXPOSICION_BRUTA` = suma de stakes vivos / bankroll **contable**.
      Es lo que hoy hace `exposicion_viva`, con el denominador corregido.
    - `EXPOSICION_POR_EVENTO` = `max_loss_expuesta_por_evento`, sin equivalente hoy.
    - `CDaR` queda **reservado** y sin usar hasta que exista distribucion,
      horizonte y nivel de confianza.

78. **Atribucion S0–S5 del dia (bankroll disponible $6,000, 16 picks candidatos).**
    | escalon | monto | n picks | delta |
    |---|---|---|---|
    | S1 Kelly fraccional 0.25 sobre p_raw | $2,055.51 | 16 | — |
    | S2 + techo 5% + piso $20 | $2,032.15 | 16 | -$23.36 (1.2%) |
    | S3 + recorte V1 (sesgo + Wilson) | $1,161.35 | 9 | **-$870.80 (45.9%)** |
    | S4 + RONGOL | $156.01 | 2 | **-$1,005.34 (52.9%)** |
    | S5 + tope de exposicion (PRODUCCION) | $156.01 | 2 | -$0.00 (0%) |
    Reduccion total **-$1,899.50 (-92.4%)**.
    Correccion sobre mi atribucion anterior (que daba RONGOL 72.4%): ahi el recorte
    V1 quedaba mezclado en el residual. Separado, **el recorte V1 y RONGOL pesan
    casi lo mismo (46% y 53%)** y el tope de exposicion **no aporta nada hoy**.
    **S_parlays = $1,003.36 y NO pasa por ningun escalon de S1–S5.** Es 6.4 veces
    toda la autorizacion de sencillas y su unica puerta fue el 15% por apuesta.

---

79. **#215 REGISTRO DE REALIDAD: un boleto ya pagado afuera no puede ser rechazado.**
    *(5-sep-2026. Necesidad operativa independiente de Fase 2. No es un cambio de
    politica de sizing: ningun techo se aflojo.)*

    **Donde estaba el bloqueo.** Ruta completa del Ticket Scanner:
    `SmartUploadButton.tsx` -> `scan-betslip` (OCR) -> modal de confirmacion
    (`SingleConfirmModal` / `ParlayConfirmModal`) -> `supabase.from("picks"|"parlays")
    .insert()` via PostgREST -> trigger `zzz_autoridad_stake` -> `tg_autoridad_stake()`.
    **El unico bloqueo real estaba ahi, en Postgres.** `revisar_tamano_apuesta`,
    `tamano_apuesta` y `revisar_apuesta` devuelven jsonb y solo informan; el
    `useTamanoApuesta` del modal solo pinta. `reto_picks_hoy` es una funcion de
    LECTURA (SECURITY DEFINER, STABLE) y no escribe nada: el productor real es el
    cliente contra las tablas.
    El mensaje era `STAKE NO AUTORIZADO: $X supera el techo de $Y`, lanzado con
    `errcode = check_violation`, y el cliente lo pintaba como un toast generico
    "Error guardando pick" sin ofrecer salida.

    **Que ya existia y que faltaba.** El escape hatch YA estaba (`stake_sobre_techo_razon`
    >= 15 caracteres) pero el escaner nunca lo usaba, y no habia forma de distinguir
    un boleto escaneado de una captura a mano: `boleto_path` esta en 0 de 32 picks y
    0 de 53 parlays; `parlays.source` vale 'manual' en las 53 filas y ya lo leen
    `capture_parlay_legs_to_ai_learning` y `sync_parlay_legs_to_learning_data`, asi
    que sobrecargarlo habria roto el aprendizaje. `manual_override` tiene CERO
    lectores SQL y ya significa otra cosa ("correccion manual del RESULTADO", 3 filas
    con motivos de calificacion): tampoco se reutiliza.

    **Cambio minimo.**
    - `picks.origen` y `parlays.origen` (columna nueva, `text`, con CHECK sobre el
      vocabulario `ticket_escaneado | app_manual | app_recomendacion`). NULL = filas
      previas, procedencia desconocida.
    - `tg_autoridad_stake()`: una sola rama nueva en el camino "por encima del techo".
      Si `origen = 'ticket_escaneado'` **Y** hay evidencia (`bet_id_casa` o
      `boleto_path`), no se lanza excepcion: se estampa `stake_techo_al_guardar` con
      el cap vigente y se autogenera `stake_sobre_techo_razon` con el prefijo
      `APUESTA_EXTERNA_YA_REALIZADA | fecha UTC | casa y folio | stake real y %% del
      bankroll | techo recomendado`. Todo lo demas del trigger queda intacto.
    - `v_stake_provenance` (vista, `security_invoker = true`, sin acceso anon):
      separa `stake_real` / `cap_recomendado` / `origen` / `override_riesgo`.
    - Frontend (`SmartUploadButton.tsx`): manda `origen: 'ticket_escaneado'` en los
      dos inserts y pinta el aviso + boton "Registrar ticket de todos modos".

    **La bandera NO es suelta.** Exige evidencia del boleto. `origen='ticket_escaneado'`
    sin folio ni imagen sigue rebotando con `STAKE NO AUTORIZADO` (prueba C2).
    Esto no debilita nada respecto de antes: el escape hatch previo (escribir 15
    caracteres) era igual de accesible desde el cliente.

    **Mapeo de campos pedidos vs campos usados** (no se invento ninguno de mas):
    | pedido | campo real |
    |---|---|
    | `origen = 'ticket_escaneado'` | `picks.origen` / `parlays.origen` (NUEVO) |
    | `stake_real` | `apuesta` (ya existia, se guarda el monto REAL sin recortar) |
    | `cap_recomendado` | `stake_techo_al_guardar` (ya existia, lo estampa el trigger) |
    | `override_riesgo = true` | derivado en `v_stake_provenance` |
    | `override_motivo` | `stake_sobre_techo_razon` con prefijo `APUESTA_EXTERNA_YA_REALIZADA` |
    | `override_timestamp` | `created_at` / `updated_at` + la fecha dentro del motivo |
    | `stake_recomendado` | **NO se creo.** Para un boleto de OCR no hay probabilidad del modelo, asi que Kelly no tiene punto estimado que guardar. Crear la columna seria repetir la enfermedad de BTTS (columna que nadie llena). El separador honesto para auditar sizing es `cap_recomendado`, que si es un hecho. |

    **Contabilidad de riesgo (PASO 4): la apuesta externa SI cuenta.** `bankroll_expuesto`
    y `exposicion_viva` filtran por `resultado` y `es_prueba`, nunca por `origen`.
    Medido: al registrar un parlay externo de $1,000 la exposicion pasa de $1,003.36
    (16.7%) a **$2,003.36 (40.1%)**, `parlays_vivos` 2 -> 3.

    **Pruebas A-H (INSERT reales, rollback transaccional, estado final $1,003.36 = inicial):**
    | prueba | resultado |
    |---|---|
    | A) escaneado DENTRO del 5% | ACEPTADO sin marca de override (razon NULL, cap NULL) |
    | B) escaneado $500 SOBRE el 5% | ACEPTADO, cap $300, motivo `APUESTA_EXTERNA_YA_REALIZADA ... stake real $500.00 = 8.3% ... techo recomendado $300.00 (5.0%)` |
    | C) pick del sistema $500 sin `origen` | **SIGUE BLOQUEADO**: `STAKE NO AUTORIZADO: $500.00 supera el techo de $300.00` |
    | C2) `origen` escaneado SIN folio ni boleto | **SIGUE BLOQUEADO** |
    | D) parlay escaneado $1,000 sobre el techo RETO ($900) | ACEPTADO con override `[RETO 13M]` |
    | E) exposicion viva | $1,003.36 (16.7%) -> **$2,003.36 (40.1%)** |
    | F) `v_stake_provenance` | `stake_real=$500.00 | cap_recomendado=$300.00 | origen=ticket_escaneado | override_riesgo=t` |
    | G) `kelly_stake` sin cambios | MLS 761781: $93.25 / EV 10.57% (identico); `reto_picks_hoy` total $156.01 (identico) |
    | H) `EXP_OFF` | `constant numeric := 0.50` intacto |

---

## FASE 2A — HOTFIX P0 (5-sep-2026). LIMITE DE CARTERA CON CANDADO DE ESCRITURA

80. **#216 2A.51 VOCABULARIO CANONICO. Un concepto, un nombre.**
    Medido antes de definir: `get_bankroll_actual` solo suma `ganancia_neta` de
    apuestas **YA RESUELTAS**, y `ganancia_neta` de una pendiente vale `0.00`
    (verificado: los 2 parlays vivos tienen 0.00). **Por tanto el stake de una
    apuesta viva SIGUE DENTRO de esa cifra**: es la equity total con las posiciones
    abiertas valuadas a su costo.
    | nombre canonico | funcion | hoy |
    |---|---|---|
    | `BANKROLL_TOTAL_RIESGO` | `get_bankroll_actual` | $7,003.36 |
    | `EXPOSICION_ABIERTA` | `bankroll_expuesto` | $1,003.36 |
    | `CAPITAL_LIBRE` | `bankroll_disponible` | $6,000.00 |
    Identidad: `CAPITAL_LIBRE = BANKROLL_TOTAL_RIESGO - EXPOSICION_ABIERTA`.

81. **#217 CORRECCION MATEMATICA: el "20%" era 16.667%.**
    La formula vieja era `limite = CAPITAL_LIBRE * pct = (T - E) * pct`. Se cruza en
    `E >= (T - E)*pct  <=>  E*(1+pct) >= T*pct  <=>  E >= T*pct/(1+pct)`.
    Con pct=0.20: `E >= T/6 = 16.667%`. El denominador se encogia solo conforme
    subia la exposicion, asi que el limite perseguia hacia abajo.
    Formula correcta, coherente con lo que `get_bankroll_actual` significa:
    ```
    EXPOSICION_ABIERTA / BANKROLL_TOTAL_RIESGO <= limite_pct
    capacidad_restante = BANKROLL_TOTAL_RIESGO * limite_pct - EXPOSICION_ABIERTA
    ```
    Hoy: limite $1,400.67 (era $1,167.23 efectivo), capacidad **$397.31** (reportaba
    $196.64), ratio **14.33%** (reportaba 16.7%, que era E/CAPITAL_LIBRE).
    **CONSECUENCIA QUE HAY QUE DECIR EN VOZ ALTA: corregir el denominador SUBE la
    capacidad de $196.64 a $397.31.** No es un endurecimiento del numero. El
    endurecimiento viene de #218: antes ese limite no se aplicaba nunca.

82. **#218 2A.52 EL LIMITE DEJA DE SER INFORMATIVO: `tg_limite_exposicion`.**
    Nuevo trigger `zzzz_limite_exposicion` BEFORE INSERT OR UPDATE OF apuesta en
    **picks y parlays**. Evalua el efecto POST-INSERT (`exposicion_actual + delta`),
    no el estado previo. En UPDATE solo cuenta el incremento.
    Orden alfabetico de triggers: `zzz_autoridad_stake` (cap individual) corre
    primero, `zzzz_limite_exposicion` (cap agregado) despues.
    **Concurrencia**: `pg_advisory_xact_lock(hashtext('expo_cartera:'||apodo))`.
    Sin el, dos INSERT simultaneos leen la misma exposicion previa y los dos pasan.

83. **#219 2A.53 RUTA DE LEDGER EXTERNO, ortogonal al candado.**
    `origen='ticket_escaneado'` + evidencia (`bet_id_casa` o `boleto_path`) permite
    superar cap individual Y cap agregado. Sube `EXPOSICION_ABIERTA` de inmediato.
    Medido: un ticket externo de $700 deja la cartera en **24.32%**, `sobre_el_limite
    = true`, `capacidad_restante = $0`, y a partir de ahi **toda apuesta automatica
    queda bloqueada** (probado con $50: rebota).

84. **#220 2A.54 AUTORIDAD ECONOMICA DE PARLAYS.**
    Medido: **CERO funciones SQL leen `ai_prob_combinada` o `ai_ev_pct`**, y cero
    funciones SQL insertan en `parlays`. La unica ruta propuesta -> apostada es el
    cliente. `construir_parlay_del_dia`, `construir_parlay_v2` y `generar_parlay_seguro`
    solo proponen.
    Nueva columna `parlays.autoridad_economica`, estampada por el trigger en cada
    INSERT: `SIN_MODELO_CONJUNTO_VALIDADO` (todo parlay que no sea ledger) o
    `LEDGER_EXTERNO`. `ai_prob_combinada` NO se borra: queda como dato observacional.

85. **#221 2A.55 PADRE/PATAS: `exposicion_viva` DOBLE-CONTABA.**
    `bankroll_expuesto` excluye `es_pata_parlay`; `exposicion_viva` **no lo hacia**.
    Una pata con fila propia se contaba dos veces (en el padre y en la pata).
    Hoy hay **0 filas de pata**, asi que el arreglo no mueve ningun numero, pero la
    puerta estaba abierta. Corregido en `exposicion_viva`.
    Modelo contable declarado: el stake vive UNA vez, en el padre. La pata es
    descriptiva. El padre NUNCA queda exento del candado.
    Probado: padre $300 + pata $300 -> `EXPOSICION_ABIERTA = $1,303.36` (no $1,603.36).

86. **#222 2A.56 LOS CAPS INDIVIDUALES SON INCOMPATIBLES CON EL AGREGADO.**
    Los caps individuales se miden sobre `CAPITAL_LIBRE`; el agregado sobre
    `BANKROLL_TOTAL_RIESGO`. **Dos denominadores distintos.**
    Con E=0 y cap RETO 15%: apuesta 1 = 0.15T (E=0.15T); apuesta 2 = 0.15*0.85T =
    0.1275T -> E=0.2775T > 0.20T, rechazada. **Cabe 1 apuesta RETO completa y un
    resto de 0.05T.**
    Condicion de compatibilidad: para garantizar al menos N posiciones,
    `cap_individual <= limite_agregado / N`. Con 20% agregado: 5% -> N=4 (coherente),
    15% -> N=1.33 (incoherente).
    **NO se cambia ningun numero en este hotfix.** Alternativas y consecuencias en
    DISENO_FASE1_CEREBRO.md.

87. **#223 CORRECCION ACEPTADA: el recorte V1 NO es arquitectura aprobada.**
    Retiro mi clasificacion `A — portar tal cual`. Queda como
    **`LEGACY_GUARD_NO_APROBADO_PARA_V2`**: reescribe la probabilidad via
    Wilson/Beta/P_DECIDE y ya mostro problemas de semantica y monotonicidad.
    Permanece en produccion solo porque quitarlo hoy cambiaria exposicion (vale el
    45.9% del recorte de sizing, medido en 2A.49). No se hereda a V2.

88. **#224 NOTA DE METODO: una fila artificial SI se escribio en produccion.**
    En la prueba de concurrencia H10 el INSERT quedo bloqueado 17.98 s en el
    advisory lock y, al liberarse, **entro y se confirmo** — mi bloque DO no tenia
    rollback en el camino de exito y `execute_sql` hace commit.
    Fila: pick $10.00, `bet_id_casa='H10-A'`, id `5c76bcb3`. **Borrada de inmediato**;
    verificado 0 residuos en picks, parlays y cron. `EXPOSICION_ABIERTA` volvio a
    $1,003.36 exacto.
    El hallazgo del bloqueo es valido y es MEJOR prueba que un timeout: el INSERT
    espero de verdad a que la otra sesion soltara el lock.

---

## FASE 2A — CIERRE DEL P0: LOS TRES PENDIENTES (5-sep-2026)

89. **#225 PENDIENTE 1 CERRADO: un parlay sin modelo conjunto YA NO puede crear riesgo.**
    Mi version anterior marcaba y no bloqueaba, y eso no satisfacia H4. Ahora
    `tg_limite_exposicion` **lanza excepcion** para cualquier INSERT en `parlays`
    con `apuesta > 0` que no declare una ruta de ledger:
    `PARLAY SIN MODELO CONJUNTO VALIDADO: no se autoriza exposicion nueva de $X...`
    - `apuesta = 0` -> se persiste como propuesta observacional, marcada
      `SIN_MODELO_CONJUNTO_VALIDADO`.
    - ruta de ledger (`ticket_escaneado` con evidencia, o `registro_externo_manual`
      con razon escrita) -> se registra con `LEDGER_EXTERNO` / `LEDGER_EXTERNO_MANUAL`.
    - `ai_prob_combinada` y `ai_ev_pct` **se conservan intactos** como dato
      observacional. Verificado: 7.22 / -45.80 sobreviven al INSERT.
    **BLAST RADIUS**: hoy el cliente no manda `origen`, asi que **hasta que Lovable
    despliegue, guardar un parlay desde la app falla**. Mensaje accionable y cambio
    de frontend enviado en el mismo turno.

90. **#226 PENDIENTE 2 CERRADO: NO OVERSUBSCRIPTION con dos escritores reales.**
    E0=$1,003.36, limite=$1,400.67. S1=S2=$250:
    `E0+S1 = $1,253.36 <= limite`, `E0+S2 = $1,253.36 <= limite`,
    `E0+S1+S2 = $1,503.36 > limite`.
    Sesion A (backend aparte via pg_cron, pid 474441) inserta S1 y mantiene la
    transaccion abierta 20 s. Sesion B (pid 474438) intenta S2:
    **espero 20,022 ms, reevaluo la exposicion ya comprometida y fue RECHAZADA**
    con `LIMITE DE CARTERA ... dejaria la exposicion abierta en $1503.36`.
    Estado tras la prueba: **$1,253.36 <= $1,400.67**. Solo entro S1.
    Limpieza: fila S1 borrada, job y funcion auxiliar eliminados, exposicion de
    vuelta en $1,003.36, 0 residuos.

91. **#227 PENDIENTE 3 CERRADO: el bypass exige evidencia server-side.**
    Hallazgo que obligo el diseno: `scan_logs` **ya existia y ya se escribe en cada
    escaneo** (199 filas, la ultima 2 minutos antes de la auditoria), asi que no hizo
    falta redesplegar `scan-betslip`. Pero `authenticated` **si puede insertar en
    `scan_logs`** (2 policies): una fila ahi NO basta por si sola.
    Lo que el cliente NO puede fabricar es un objeto en `storage.objects`: subir el
    archivo crea la fila con `owner_id` y `created_at` puestos por el servidor. Y las
    **tres** rutas de escaneo del frontend llaman `uploadAndGetUrl(file)` antes de
    invocar `scan-betslip`, asi que el artefacto siempre existe.
    `evidencia_scan_valida(scan_id, apodo)` exige las cinco: existe / es del mismo
    usuario / sin error / <= 48 h / el `image_url` apunta a un objeto REAL del bucket
    `screenshots` bajo la carpeta del propio usuario / no consumido.
    `scan_consumos` (PK sobre `scan_id`) es la garantia estructural de un solo uso.
    Nueva RPC `ultimo_scan_utilizable(apodo, minutos)`: el cliente **pregunta** cual
    es su scan valido en vez de elegirlo. No puede mandar uno ajeno ni gastado.
    Ruta manual separada a proposito: `origen='registro_externo_manual'` +
    `stake_sobre_techo_razon` >= 15 caracteres -> `LEDGER_EXTERNO_MANUAL`. **No se
    confunde con un OCR validado.**
    Pruebas: E1 registra y consume · E2 `ticket_escaneado` inventado sin scan_id NO
    obtiene bypass · E2b scan de otro usuario NO obtiene bypass · E3 scan reutilizado
    rechazado citando la apuesta que ya lo gasto · E4 ticket externo deja la cartera
    en 24.32% y se registra · E5 la recomendacion posterior queda bloqueada.

92. **#228 CONTRATO DE BANKROLL (documentado, sin cambios de comportamiento).**
    `BANKROLL_TOTAL_RIESGO` = `get_bankroll_actual` = equity total; el stake vivo
    sigue dentro porque `ganancia_neta` de una pendiente vale 0.00.
    `EXPOSICION_ABIERTA` = `bankroll_expuesto` = stakes pendientes reales.
    `CAPITAL_LIBRE` = TOTAL - EXPOSICION.
    **`kelly_stake` dimensiona sobre `CAPITAL_LIBRE`** (verificado: su campo
    `bankroll` = $6,000.00 = `capital_libre`). **Ese comportamiento NO se toco.**
    El limite de cartera se mide contra `BANKROLL_TOTAL_RIESGO`; los caps
    individuales, contra `CAPITAL_LIBRE`. Esa mezcla de denominadores sigue siendo
    el riesgo residual #2 de 2A.56.

---

## FASE 2A — ATAQUE S1 Y ATTESTACION REAL (5-sep-2026)

93. **#229 ATAQUE S1: mi diseno anterior SI era falsificable. Los cuatro pasos funcionaron.**
    Ejecutado con el rol `authenticated`, en transaccion revertida:
    | paso | resultado |
    |---|---|
    | S1.1 subir archivo a `screenshots/rodelcast/...` | **LOGRADO** |
    | S1.2 INSERT en `scan_logs` sin pasar por el OCR | **LOGRADO** |
    | S1.3 `evidencia_scan_valida` lo acepta | **LOGRADO** (`ok: true, motivo: evidencia verificada`) |
    | S1.4 ledger override de $500 sobre el cap individual | **ACEPTADO** |
    **Causa raiz**: la policy de INSERT de `scan_logs` es `with_check = true` para el rol
    `public`, y `anon`/`authenticated` tenian GRANT INSERT. `owner_id` de storage
    demuestra propiedad de un archivo, **no** que `scan-betslip` lo proceso.
    Mi afirmacion anterior ("attestation server-side") era incorrecta. No la maquillo.

94. **#230 ATTESTACION REAL: `scan_attestations` + edge function `attestar-scan`.**
    - `public.scan_attestations`: RLS activo, `anon` y `authenticated` **sin INSERT /
      UPDATE / DELETE**, solo SELECT. Un trigger estampa `escrito_por := current_user`
      y `creado_at := now()`, asi que el cuerpo de la peticion no puede suplantarlos
      (probado: se mando `escrito_por='INTENTO_DE_SUPLANTAR'` y quedo `service_role`).
    - `attestar-scan` (nueva edge function, `verify_jwt = true`): recibe el mismo body
      que `scan-betslip`, verifica con el service role que el archivo **existe de
      verdad** en el bucket y esta bajo la carpeta del usuario, **invoca `scan-betslip`
      servidor-a-servidor**, y solo entonces sella la attestacion. Devuelve el objeto
      de `scan-betslip` **tal cual** mas `scan_id`. No aumenta el numero de llamadas al
      OCR: sustituye la del cliente.
    - No se toco `scan-betslip` (182 KB): habria sido un round-trip innecesario y
      riesgoso.
    - `evidencia_scan_valida` ya **no mira `scan_logs`**. Exige: attestacion existe /
      mismo usuario / `escrito_por='service_role'` / `ocr_ok` / <= 48 h / el archivo
      sigue en el bucket bajo la carpeta del usuario / no consumida.
    - `scan_consumos` ahora referencia `scan_attestations`.
    - Higiene: `revoke insert, update, delete, truncate on scan_logs from anon, authenticated`.
    **Re-ejecucion del ataque S1**: S1.2 BLOQUEADO (`permission denied for table
    scan_logs`), S1.2b BLOQUEADO (`permission denied for table scan_attestations`),
    S1.3 rechaza (`no existe attestacion del backend`), S1.4 rechaza
    (`Ruta de ledger rechazada: sin scan_id`).
    Subir un archivo sigue siendo posible **y debe serlo**: ya no concede nada.

95. **#231 `REGISTRO_EXTERNO_MANUAL` reclasificado como `LEDGER_OVERRIDE_HUMANO`.**
    - Quien puede invocarlo: **cualquier usuario autenticado dueno de su propia fila**
      (el trigger `asignar_apodo_del_dueno` fija el apodo). No exige rol especial.
    - Requisito: `origen='registro_externo_manual'` + `stake_sobre_techo_razon` de
      15 caracteres o mas, escrita por una persona.
    - Provenance que deja: `origen`, la razon escrita, `stake_techo_al_guardar` con el
      cap vigente, `created_at`, y en parlays `autoridad_economica='LEDGER_EXTERNO_MANUAL'`.
    - **NO es un boleto verificado.** Es un override humano del propietario de la
      cuenta. Es declarativo por diseno: un boleto de ventanilla sin captura tambien
      es realidad economica.
    - **Cuenta integramente para exposicion**, igual que cualquier otra apuesta.

96. **#232 Higiene: `dblink` desinstalado.**
    Se habia instalado solo para investigar la prueba de concurrencia y al final no se
    uso (la prueba se hizo con `pg_cron`). Verificado 0 consumidores y 0 foreign
    servers antes de `drop extension`. Superficie eliminada.

97. **#233 Frontend: tres mensajes a Lovable, el tercero pendiente de publicar.**
    Ya aplicado por Lovable: `origen`, `scan_id` en los inserts, cuadro de texto
    obligatorio cuando no hay escaneo, aviso ambar del techo y traduccion de los tres
    errores nuevos.
    Pendiente en el tercer mensaje: cambiar las tres llamadas de `scan-betslip` a
    `attestar-scan` y tomar `scan_id` de la respuesta en vez del RPC.
    **Mientras eso no se publique**, `scan_attestations` esta vacia y el flujo del
    escaner degrada a `registro_externo_manual` (pide razon escrita). Es seguro pero
    NO es la ruta de boleto verificado, asi que el E2E de la ruta OCR sigue sin
    ejecutarse. **Yo no puedo correr el E2E**: mi proxy bloquea `reto13.lovable.app`.

98. **#234 El fallback manual ya no puede tapar un fallo de integracion del OCR.**
    Riesgo señalado por el auditor: si el escaneo sale bien pero el `scan_id` se
    pierde, la pantalla pedia en silencio "escribe una razon manual", convirtiendo un
    fallo tecnico en lo que parece una decision del usuario.
    Dos capas:
    - **UI** (enviado a Lovable): tres casos separados. Con `scan_id` no pide nada;
      **vino de escaneo pero sin `scan_id`** muestra aviso ROJO diciendo que es una
      falla tecnica y deja el guardado DESHABILITADO hasta que el usuario pulse
      explicitamente "Registrar de todos modos sin comprobante"; captura a mano sin
      escaner se comporta como antes.
    - **Servidor**: `public.salud_ocr_ledger(horas)` detecta la degradacion silenciosa
      cruzando attestaciones selladas, attestaciones consumidas y registros manuales.
      Si se sellaron attestaciones que nadie uso Y entraron registros manuales,
      levanta `sospecha_degradacion_silenciosa`.
    - `public.auditoria_e2e(apodo, n)`: una fila por apuesta con `ruta_real` explicita
      (`TICKET_ESCANEADO_VERIFICADO` / `DECLARADO SIN ATTESTACION` /
      `LEDGER_OVERRIDE_HUMANO` / `AUTORIZACION NORMAL DEL MOTOR` / `PATA`).

99. **#235 UNA fila real quedo mal etiquetada en la ventana de transicion. NO la toco.**
    `salud_ocr_ledger` levanto bandera de inmediato y encontro:
    pick de **"el dos"**, `2b693371`, **$500.00**, 5-sep 14:47 UTC, `origen='ticket_escaneado'`,
    `scan_id = NULL`, `stake_techo_al_guardar = $220.41`.
    Es una apuesta REAL, registrada entre mi primer despliegue de Lovable (que mandaba
    `origen='ticket_escaneado'` con solo `bet_id_casa` como evidencia) y el
    endurecimiento posterior. Obtuvo el bypass con las reglas viejas.
    **Es dinero real de otro usuario: no la borro ni la reetiqueto por mi cuenta.**
    Bajo la taxonomia nueva es un `LEDGER_OVERRIDE_HUMANO`, no un boleto verificado.
    `auditoria_e2e` ya la muestra como `DECLARADO SIN ATTESTACION`. Queda a decision
    del auditor si se reetiqueta a `registro_externo_manual` (seria un cambio de
    procedencia, cero cambio de dinero).

100. **#236 MIGRACION_PROCEDENCIA_PRE_ATTESTATION ejecutada. UNA fila, cero cambio economico.**
     *Autorizada por el auditor el 5-sep-2026.*

     **Enumeracion previa** (sin ventana de tiempo, ambas tablas): **1 sola fila** cumple
     `origen='ticket_escaneado' AND scan_id IS NULL`. No hay mas. `picks` tenia 1 fila con
     `origen` no nulo y `parlays` 0.

     **Fila**: `2b693371-f7bc-4786-8188-a2a76a047b33` · "el dos" · 5-sep 14:47:38 UTC ·
     TSG Hoffenheim - Borussia Dortmund · "Menos de 3.5 Goles" · momio 1.50 ·
     **$500.00** · resultado `perdido` · `ganancia_neta -500.00` · `bet_id_casa 5376349438` ·
     `stake_techo_al_guardar $220.41` · RETO 13M.

     **Seguridad del UPDATE.** Los 8 triggers de `picks` que disparan en UPDATE sin filtro
     de columna se leyeron uno por uno antes de tocar nada. Ninguno actua si no cambia
     `resultado`: `notify_pick_graded` exige `OLD.resultado='pendiente' AND NEW IN
     ('ganado','perdido')` (**no se mando ninguna notificacion**);
     `actualizar_bankroll_post_al_calificar`, `recalc_pick_on_result_change`,
     `capture_pick_to_ai_learning` y `protect_picks_premature_grading` exigen transicion de
     resultado; `protect_pa_picks` exige que NEW difiera de OLD; `proteger_ganancia_cashout`
     exige `cashout_monto` no nulo (aqui es NULL). El unico con efecto es
     `update_picks_updated_at`.
     Ademas el UPDATE corrio dentro de un candado que **aborta la transaccion completa** si
     cambiaba cualquier campo distinto de `origen` y `updated_at`, o si se movia la
     exposicion.

     **Diff real, verificado:**
     | campo | antes | despues |
     |---|---|---|
     | `origen` | `ticket_escaneado` | `registro_externo_manual` |
     | `updated_at` | 15:40:06 | 16:04:46 |

     Todo lo demas identico: `apuesta` $500.00, `resultado` perdido, `ganancia_neta` -500.00,
     `bankroll_post` 3908.19, `bet_id_casa` 5376349438, `created_at` 14:47:38.88888,
     `stake_techo_al_guardar` 220.41, `scan_id` NULL (**no se fabrico**).
     Exposicion abierta de "el dos": **$0.00 antes y $0.00 despues**.
     No aplica `autoridad_economica`: esa columna solo existe en `parlays` y la fila es un pick.

     **Evidencia durable**: fila 4 de `public.evidencia_procedencia`, que ya existia (se uso
     esa en vez de inventar arquitectura nueva). Guarda la afirmacion completa
     (`MIGRACION_PROCEDENCIA_PRE_ATTESTATION`, valor anterior, valor nuevo, `scan_id` original
     NULL, motivo, y la declaracion explicita de cero cambio economico) y el **estado completo
     de la fila antes del cambio** en la columna `sentencia`.

     **Verificacion posterior**: `picks_contaminados = 0`, `parlays_contaminados = 0`.
     `salud_ocr_ledger(24)` y `(168)` ya no levantan `declarados_ticket_sin_attestacion`;
     ahora leen "Registros manuales sin ningun escaneo en la ventana: consistente con captura
     deliberada sin escaner". `auditoria_e2e('el dos')` clasifica la fila como
     **`LEDGER_OVERRIDE_HUMANO`**. La clase `TICKET_ESCANEADO_VERIFICADO` quedo limpia.

     **RESIDUAL QUE NO TOQUE**: `stake_sobre_techo_razon` de esa fila sigue diciendo
     literalmente "boleto escaneado en PlayDoIt folio 5376349438". Lo genero el trigger viejo
     y es el acta original del momento. Reescribirlo seria alterar una declaracion historica,
     asi que se deja como esta; la contradiccion aparente queda explicada en
     `evidencia_procedencia`. Si el auditor prefiere anotarla, es un cambio aparte.

101. **#237 CORRECCION A LO QUE YO AFIRME: las alertas NO las veian todos.**
     Dije "todos la ven" basandome en los GRANTS de tabla (`anon` y `authenticated`
     tenian SELECT). **Estaba mal**: `alertas_sistema` tiene RLS activo y ya traia
     `as_admin_select` y `as_admin_update`, ambas con `has_role(auth.uid(),'admin')`.
     El usuario la veia porque **es** el admin. Leer los grants sin leer las policies
     fue un error de metodo mio.
     Lo que si era real, aunque menor de lo que dije: `anon` y `authenticated` tenian
     tambien INSERT, DELETE y **TRUNCATE**. INSERT y DELETE los frenaba la RLS (no hay
     policy que los permita), pero **TRUNCATE no pasa por RLS**. No es explotable via
     PostgREST (no expone TRUNCATE), asi que era defensa en profundidad, no una puerta
     abierta. Lo cerre igual.

102. **#238 LA CAUSA REAL de "siempre hay una alerta": el conteo iba en el titulo.**
     `auditar_analisis` metia el numero dentro del titulo y el `ON CONFLICT` es sobre
     `(tipo, titulo)`. Titulos historicos medidos para la MISMA condicion:
     "47 analisis...", "52...", "55...", "56...", "57..." — **cinco alertas distintas
     para un solo hallazgo**. Cada corrida (cada 2 h) con distinto conteo creaba una
     fila nueva sin ver. Marcar "Entendido" no servia de nada.
     Corregido: titulo fijo por regla, conteo en el detalle. Ahora el `ON CONFLICT`
     encuentra la fila, actualiza detalle y gravedad, y **preserva `visto`**.

103. **#239 La alerta NO habla de dinero. Medido.**
     `v_pick_canonico` **no lee** `analisis_partidos`, y tampoco lo leen
     `reto_picks_hoy`, `kelly_stake`, `filtro_pick`, `rongol_veto`, `stake_techo` ni
     `exposicion_viva`. La regla `bet_con_datos_malos` mira
     `analisis_partidos.analisis_json->veredicto_final = 'BET'` con `data_quality <= 8`
     de 25: es la pantalla de ANALISIS que lee el usuario, no el motor que dimensiona.
     **La regla NO se apago.** El hallazgo es cierto y es el mismo patron de #107/#108.
     Cambios aplicados: `salud_alertas` ahora ademas filtra por admin dentro de la
     propia vista (`security_invoker`), y se revocaron las escrituras de cliente
     dejando solo `UPDATE (visto)` a `authenticated` para que el boton "Entendido"
     siga funcionando sin poder reescribir titulo, gravedad ni detalle.

104. **#240 P0 REGRESION: Lovable SOBRESCRIBIO `attestar-scan` y la dejo abierta.**
     Lovable reporto "la funcion no existia, ya la cree". **Falso**: existia (v1, mia).
     Desplego una v3 que rompio dos guardas:
     - **`verify_jwt: false`** (la mia era `true`): cualquiera sin sesion podia llamarla.
     - **Cero verificacion**: tomaba `image_url` y `apodo` del cuerpo y sellaba. Con eso
       se podia sellar evidencia a nombre de OTRO usuario.
     Lo unico que aguanto fue el trigger `tg_sellar_attestation`, que sobrescribe
     `escrito_por` con `current_user` e ignoro el `"attestar-scan"` que mandaba Lovable.
     Haber puesto esa guarda en la base y no en la funcion es lo que evito que la
     regresion llegara hasta la evidencia.

105. **#241 ERROR MIO EN LA CORRECCION: la v4 habria roto TODOS los escaneos.**
     Al corregir la v3 puse una guarda que comparaba `uid_de_apodo(apodo)` contra el
     uid de la sesion. **`usuarios.id` NO es el uid de auth**: ninguno de los tres
     existe en `auth.users`. El vinculo real es `usuarios.user_id`.
     Lo detecte antes de que el usuario probara, revisando el cruce. La v4 habria
     devuelto 403 en todos los escaneos.
     **v5** usa dos funciones nuevas SECURITY DEFINER, solo ejecutables por
     `service_role`:
     - `apodo_es_del_uid(apodo, uid)` — via `usuarios.user_id`
     - `archivo_scan_es_del_uid(path, uid)` — via `storage.objects.owner_id`, que lo
       pone el servidor al subir y el cliente no elige
     Probadas las cuatro combinaciones: dueno OK / suplantador rechazado / archivo
     propio OK / archivo ajeno rechazado.

106. **#242 PUSH: el transporte SI funciona. Lo que se perdio fue el LIBRO y el aviso de ARRANQUE.**
     Medido el 5-sep-2026. Tres cosas distintas que se venian contando como una sola:
     - **Transporte OK.** En la ventana viva de `net._http_response` (retencion real
       ~2 h, NO 24 h — eso invalida cualquier conteo mio anterior "en 24 horas")
       hay 6 llamadas a `enviar-notificacion-push`, las 6 con `{"sent":1,"cleaned":0}`.
       `alertas_enviadas` confirma actividad hoy: `inicio` 14:21, `marcador_final`
       15:31, `calificado` 16:26.
     - **El libro murio.** `push_log` no tiene una sola fila desde el **1-sep 21:19**.
       Causa: `enviar-notificacion-push` **v236 ya no escribe `push_log`**. La tabla
       tiene `enviados / suscripciones / silenciado / motivo` — era el rastro — y una
       redeployada la dejo sin escritor. Por eso "no llego el push" no se puede probar
       ni desmentir. Es la reaparicion de #80.
     - **ARRANQUE: hueco estructural, medido.** `alertar_inicio_partidos()` recorre
       **solo `parlays`** (`FROM parlays p, jsonb_array_elements(p.picks_data)`).
       Una sencilla nunca recibe "ARRANCA". Prueba de hoy: los 3 eventos con dinero
       vivo — Lens-Lorient, Inter-Napoli (patas de parlay) y Schalke-Bayern
       (sencilla) — tienen `tuvo_inicio = false`. Segundo filtro: exige
       `live_scores.status='live'` **y** minuto <= 8; si el marcador tarda en marcarse
       live, la ventana se cierra y ya no vuelve a abrirse nunca.
     - **GOLES: sin rastro por diseno.** El push de gol lo manda `check-score-updates`
       con un `fetch` **interno** (no pasa por pg_net), y el trigger
       `trigger_enviar_push_notificacion` **silencia** la fila espejo de
       `notificaciones` (`marcador` con `data->origen='score_notifications'`). Si ese
       fetch falla, el usuario no recibe nada y **no queda registro en ningun lado**.
       Ademas la regla "quieto una vuelta" retrasa el aviso 2-4 min: no es tiempo real.
     - Los **635 HTTP 404 en 2 h** son `{"error":{"message":"No stats found."}}` de la
       API de MLB (linescore/enrich). Ruido, no push.

107. **#243 CLIMA FUTBOL: el cron pide SIEMPRE los mismos 20 estadios.**
     Medido: 159 estadios con partido en 6 dias. 58 (36%) **no estan** en
     `futbol_estadios` -> nunca son elegibles. 2 sin coordenadas. 99 elegibles, pero
     **solo 37 tienen clima**. Cobertura de la vista `v_futbol_clima_partido` en la
     ventana -12h/+4d: 37 con clima, 106 con sede y sin clima, 31 sin sede.
     Causa: `futbol_clima_pedir(20)` hace `select distinct ... limit 20` **sin
     ORDER BY y sin filtro de frescura**; lo unico que excluye es lo que esta en
     `futbol_clima_pendiente`, que `futbol_clima_recoger()` vacia 5 min despues. A las
     3 h vuelve a elegir el mismo primer lote. Nunca avanza mas alla de esos ~20.

108. **#244 FUT PRO: el Moneyline no lo mata RONGOL ni el Skill Score. Lo mata un piso de 52%.**
     La pantalla lee `v_picks_futbol_limpio` = `picks_futbol_cache` = `v_picks_futbol_calc`,
     que **no es** `v_pick_canonico`. Contenido de la cache ahora: **BTTS 5,
     Over/Under 3, Moneyline 0**.
     `v_picks_futbol_calc` filtra `probabilidad BETWEEN 52 AND 80`. En `picks_premium`
     a 48 h: Over/Under n=37 (24 pasan), BTTS n=18 (18 pasan), **Moneyline n=12, 0
     pasan** — su maximo es **49.5%** y su media 42.1%. Es un piso pensado para
     mercados de dos salidas aplicado a un 1X2 de tres, donde el empate se lleva ~25%.
     Mientras tanto `v_pick_canonico` si tiene 44 Moneyline de futbol con 4 `es_pick`
     (Dortmund ML, Lille ML, Real Salt Lake, Empate) y **0** Over/Under `es_pick`:
     las dos pantallas dicen lo contrario porque leen motores distintos (#204).

109. **#245 BARRA DE FAVORITOS: ya consume P_FAIR. Premisa descartada.**
     `PicksProbabilidadFavoritos.tsx` pinta `favorito_pct` de `v_pick_canonico`, y ahi
     `favorito_pct = GREATEST(prob_local_casa_pct, prob_visitante_casa_pct)` con
     `prob_local_casa_pct = 100*(1/home_ml)/(1/home_ml + 1/away_ml + 1/draw_ml)`.
     Eso **es** probabilidad normalizada sin vig (incluye el empate en el 1X2), no el
     EV legacy ni el implicito crudo. Unico matiz: es el favorito **del mercado**, no
     el del modelo; el del modelo es `probabilidad_pct`.

110. **#246 NFL: cero picks canonicos y cero apuestas reales. Pero no es "SIN_MODELO".**
     `v_pick_canonico` para NFL: **0 filas**. Apuestas NFL reales historicas: **0**.
     De facto apagada para dinero, y asi sigue.
     Mapa de datos SI disponible: 572 partidos (272 futuros, hasta ene-2027),
     `nfl_picks_premium` 1,358, `nfl_tablero` 572, 24 crons activos (agenda, lesiones,
     snaps, FPI, clima, momios, ADP, stats, H2H). `nfl_backtest` sigue **vacia**.
     `modelo_confiabilidad` medido el 1-sep sobre n=1,437:
     - **NFL Moneyline**: dice 53.7%, pasa 54.5% (sesgo -0.8 pp), Brier 0.23813 vs
       0.24799 tasa base y 0.25 volado -> "acierta de verdad".
     - **NFL Over/Under**: dice 56.3%, pasa 48.8% (**sesgo +7.5 pp**), Brier 0.25287
       **peor que un volado**, y recalibrar lo empeora -> **no usar**.

111. **#247 RONGOL: el bloqueo IGNORA `rango_momio`. Bug localizado.**
     `rongol_veto()` calcula `v_rango` arriba y lo usa **solo** en el bucle de fugas
     (que unicamente advierte). El bucle que **bloquea** —
     `lecciones_aprendidas WHERE activa AND bloqueo_total` — cruza por
     `mercado_norm` + `liga` y **nunca lee `la.rango_momio`**.
     Ademas hay dos vocabularios de tramo: `rongol_hallazgos.clave` usa el de
     `v_rango` (`<1.40`, `1.40-1.80`, `1.80-2.50`, `2.50-4.00`, `>4.00`) y
     `lecciones_aprendidas.rango_momio` usa otro (`1.01-1.50`, `1.50-1.80`,
     `1.80-2.20`, `2.20-3.00`, `3.00-5.00`, `5.00+`, `TODOS`).
     Las tres lecciones que hoy bloquean:
     | id | mercado | liga | rango | n | W-L | ROI |
     |----|---------|------|-------|---|-----|-----|
     | 11 | OU | MLB | 1.01-1.50 | **6** | 3-3 | -38.3% |
     | 13 | ML | MLB | 1.01-1.50 | **8** | 4-4 | -33.1% |
     | 12 | ML | MLB | 1.50-1.80 | 42 | 15-27 | -41.3% |
     Ninguna se midio arriba de 1.80. Hoy hay **9 picks MLB bloqueados**, todos
     Moneyline, con momios de **1.909 a 3.01** — es decir, ninguno cae en un tramo
     medido. Las celdas n=6 (3-3) y n=8 (4-4) son 50% exacto: Wilson 95%
     [18.8, 81.2] y [21.5, 78.5]. No tienen soporte fuera de muestra.

112. **#248 P0 CERRADO: cerrar una apuesta desde la app era IMPOSIBLE. Era RLS, no la logica de cierre.**
     Sintoma reportado con captura: al cerrar un parlay de 2 patas la app devolvia
     `new row violates row-level security policy for table "notificaciones"`.
     **Causa.** `notificaciones` tiene RLS con politicas de `SELECT` y `UPDATE` para
     `authenticated` y **ninguna de `INSERT`**. Y los dos triggers que escriben ahi al
     calificar corrian como el usuario:
     - `notify_parlay_graded()` (trigger `on_parlay_graded_notify` en `parlays`)
     - `notify_pick_graded()` (trigger `on_pick_graded_notify` en `picks`)
     Las otras cuatro funciones que insertan en `notificaciones`
     (`procesar_notificaciones_marcador`, `alertar_picks_sin_marcador`,
     `dispatch_pa_para_pick`, `dispatch_pa_para_pierna_parlay`) **si** eran
     `SECURITY DEFINER`. Estas dos se quedaron fuera. Por eso el cron calificaba bien
     (corre como `service_role`) y el cierre manual moria siempre — sencillas incluidas.
     **Correccion.** `SECURITY DEFINER` en las dos. Se descarto la alternativa de dar
     una politica de `INSERT` a `authenticated`: la notificacion es un efecto del
     sistema, no una escritura del cliente, y esa politica le permitiria fabricar
     notificaciones arbitrarias por PostgREST. Con DEFINER no puede: la RLS de
     `parlays`/`picks` solo lo deja tocar filas con
     `apodo = apodo_de_la_sesion()`, asi que `NEW.apodo` siempre es el suyo.
     **Prueba adversarial, con rollback.** Con `set local role authenticated` y las
     claims de rodelcast:
     - parlay `0c20f6c6` -> **OK, 1 fila actualizada** (antes: violacion de RLS)
     - pick `6e741cff` -> rechazado por `23514`: *"Todavia no se puede calificar:
       Schalke 04 - Bayern Munich sigue en juego (29')"*. Esa es la guarda de
       calificacion prematura haciendo su trabajo, no el bug.
     Todo revertido: parlay y pick siguen `pendiente`, `updated_at` sin tocar, y
     **0 notificaciones creadas** por la prueba.
     **Residual (no tocado, mismo patron, hoy inofensivo):**
     `auto_close_parlay_when_all_legs_decided` (escribe `parlays`) y
     `marcar_patas_parlay` (escribe `picks`) siguen `SECURITY INVOKER`. No fallan
     porque ambas tablas SI tienen politica `ALL` para el dueno; pero si un dia una
     pata pertenece a otro apodo, no daran error: **no haran nada**.
