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

113. **#249 Cash out: el dinero no era un bug del cash out. Era el boton que se eligio.**
     **CORRECCION A LO QUE YO MISMO DIJE HACE UN MOMENTO.** Vi `cashout_monto` en NULL
     en los 54 parlays y conclui "la app nunca manda ese campo". **Falso.** La ruta
     existe y esta bien hecha:
     `CorregirApuesta.tsx` (la hoja "¿COMO QUEDO?") llama al RPC
     `editar_resultado_parlay(p_id, p_resultado, p_cashout_monto, p_nota)`, y ese RPC
     escribe `cashout_monto` **solo cuando `p_resultado = 'retirado'`**:
     ```sql
     cashout_monto = CASE WHEN p_resultado = 'retirado' THEN p_cashout_monto ELSE NULL END
     ```
     El usuario eligio **❌ PERDIDO** (se ve marcado en ambar en su captura), no
     **💰 LO CERRE ANTES (CASH OUT)**. Con `perdido` el campo de monto ni siquiera
     aparece en pantalla, y el RPC pone `cashout_monto` en NULL a proposito.
     La razon real de que ningun parlay tuviera cash out: nadie habia elegido nunca
     "retirado", y hasta #248 la RLS mataba cualquier cierre manual de todas formas.
     **Correccion aplicada al parlay `0c20f6c6`** ($300, Lens + Inter):
     `cashout_monto = 75.00` -> el trigger `proteger_ganancia_cashout()` recalculo
     `ganancia_neta = 75 - 300 = -225.00`. Bankroll $4,247.45 -> **$4,322.45**.
     No se toco apuesta, momio, bono ni fecha.
     **NO se cambio `resultado` a 'retirado', y es deliberado.** Medido: **107**
     funciones y vistas mencionan `'ganado'`/`'perdido'` y **nunca** `'retirado'`,
     entre ellas `get_bankroll_evolution`, `get_dashboard_stats`,
     `get_performance_breakdown`, `get_historial_reciente`, `get_parlays_evolution`,
     `recalc_user_stats_for_user` y `get_leaderboard`. Marcarlo 'retirado' lo haria
     **desaparecer** del historial, las stats y la curva, aunque
     `get_bankroll_actual` si lo cuenta. Ninguna fila de la base usa hoy ese valor.
     Se verifico que las seis lecturas de dinero leen `ganancia_neta` y **ninguna**
     recalcula desde `apuesta`: con `perdido` + `ganancia_neta = -225` todas pintan
     el numero correcto.
     **Pendiente de producto (NO es bug de datos):** "cerre antes Y iba perdiendo" es
     el caso natural del usuario y hoy obliga a elegir entre dos botones que se
     sienten excluyentes. O el estado 'retirado' se ensena en las 107 lecturas, o el
     campo de cash out se ofrece tambien bajo PERDIDO/GANADO. Decision del usuario.

114. **#250 El cash out deja de estar preso de `resultado='retirado'`.**
     Decision del usuario (opcion 2 de #249): en vez de ensenar el estado 'retirado'
     en las 107 lecturas que no lo conocen, se abre el campo de monto bajo GANADO y
     PERDIDO. El caso real es "lo cerre antes Y iba perdiendo".
     **Backend (desplegado):**
     - `editar_resultado_parlay` y `editar_resultado_pick`: `cashout_monto` y
       `cashout_fecha` ahora se escriben con `resultado IN ('retirado','ganado','perdido')`.
       Con 'nulo' o 'pendiente' se rechaza con mensaje propio en vez de borrar el monto
       en silencio. 'retirado' sigue exigiendo monto.
     - `proteger_ganancia_cashout()`: **rama nueva de deshacer**. El diff de arriba abre
       un hueco: antes, quitar un cash out obligaba a cambiar `resultado` (solo existia
       con 'retirado') y eso disparaba `recalc_*_on_result_change`. Ahora se puede
       guardar 'perdido' CON monto y volver a guardar 'perdido' SIN monto: el resultado
       no cambia, recalc no dispara, y `ganancia_neta` se quedaria con el numero viejo.
       La rama nueva reconstruye la ganancia por la regla normal, con
       `TG_TABLE_NAME` para distinguir parlays (`ganancia_parlay_ganado`) de picks
       (`apuesta * (momio - 1)`).
     **Prueba adversarial como `authenticated`, con rollback, sobre el parlay real:**
     | # | entrada | `ganancia_neta` | `cashout_monto` |
     |---|---------|-----------------|-----------------|
     | 1 | perdido + 75 | **-225.00** | 75 |
     | 2 | perdido sin monto (deshacer) | **-300.00** | NULL |
     | 3 | ganado + 500 | **+200.00** | 500 |
     | 4 | nulo + 75 | **RECHAZADO** | — |
     | 5 | pendiente | NULL | NULL |
     Fila intacta despues de la prueba (`updated_at` 17:12:07, bankroll $4,322.45).
     **Frontend:** enviado a Lovable un cambio acotado a
     `src/components/reto/CorregirApuesta.tsx`: el input aparece con
     `ACEPTA_CIERRE = ['retirado','ganado','perdido']`, obligatorio solo en 'retirado',
     se limpia al elegir 'nulo'/'pendiente', y manda
     `p_cashout_monto: aceptaCierre && hayMonto ? monto : null`. Pendiente de verificar
     publicacion.
     **Residual conocido (no tocado):** `bankroll_post` se calcula en un trigger que
     corre ANTES de `zz_proteger_ganancia_cashout`, asi que en un boleto con cash out
     queda desfasado por el delta (se vio $4,547.45 donde tocaba $4,322.45). Es la
     columna basura de #95 y NO alimenta `get_bankroll_actual`; las seis lecturas de
     dinero usan `ganancia_neta`.

115. **#251 E2E del escaner: NO lo declaro cerrado. Una anomalia sin explicar en el candado de cartera.**
     **Lo que SI quedo probado hoy, con datos reales:**
     - 5 attestaciones selladas, las 5 por `service_role`, las 5 consumidas, 0 sin usar,
       0 `declarados_ticket_sin_attestacion`. `salud_ocr_ledger(12h)`: sin degradacion.
     - 3 boletos POR ENCIMA del cap entraron por ledger: $3,847.67 vs cap $577.12,
       $250 vs $195.41, $75 vs $11.22. E2E de "arriba del cap" **PASA**.
     - Parlay de **16 patas**: `filas_pata_creadas = 0`, y `es_pata_parlay` en toda la
       tabla `picks` sigue en **0**. Sin doble conteo ni a 16 patas.
     - Rutas ejercidas en produccion: `TICKET_ESCANEADO_VERIFICADO` (5),
       `LEDGER_OVERRIDE_HUMANO` (1), `AUTORIZACION NORMAL DEL MOTOR` (muchas),
       `PATA (no suma exposicion)`. `DECLARADO SIN ATTESTACION`: 0, que es la senal
       buena (el OCR no ha fallado).
     - **Guardas verificadas en aislamiento**, como `authenticated` y con rollback:
       | caso | `ruta_ledger` | resultado |
       |------|---------------|-----------|
       | attestacion YA consumida | NULL | rechazado por LIMITE DE CARTERA |
       | `scan_id` inventado | NULL | rechazado |
       | `ticket_escaneado` sin `scan_id` | NULL | rechazado |
       | attestacion de OTRO apodo | NULL | rechazado |
       | attestacion sellada por `postgres` | NULL, motivo *"no la sello el backend (escrito_por=postgres)"* | rechazado |
       | attestacion fresca sellada por `service_role` | LEDGER_EXTERNO | **pasa** (correcto) |
       Nota: yo mismo, como `postgres` desde el MCP, **no pude** fabricar evidencia
       valida. La guarda de autoria funciono contra mi.
     **LA ANOMALIA (abierta, P0-adyacente):** en UNA MISMA transaccion, si primero
     entra un insert con ruta de ledger VALIDA y despues otro con la attestacion YA
     CONSUMIDA, el segundo **PASA**. Medido justo antes de ese segundo insert:
     `exposicion_abierta = 6322.67`, `limite_monto = 864.49`, `ruta_ledger = NULL`.
     Con esos tres valores `tg_limite_exposicion` **debia** disparar y no disparo.
     Aislado (sin el primer insert) el mismo caso SI se rechaza.
     Descartado: no es `ruta_ledger` (se verifico con la fila completa,
     `to_jsonb(NEW)`, y da NULL igual); no es `es_prueba` ni `es_pata_parlay`
     (misma fila origen que en el caso aislado). Hipotesis abiertas: reentrada del
     `pg_advisory_xact_lock`, o el snapshot de las funciones STABLE
     (`exposicion_viva` / `get_bankroll_actual`) dentro de la misma transaccion.
     **Alcance real hoy:** por PostgREST cada apuesta llega en su propia transaccion,
     asi que la secuencia no es alcanzable desde la app. **No es excusa para cerrar.**

116. **#252 `push` como LIQUIDACION (no el push del celular): bug latente confirmado.**
     El usuario pidio demostrar `push -> stake devuelto, ganancia_neta = 0`. Hoy
     **no se cumple**. Medido:
     - `recalc_pick_on_result_change` maneja `'push'`: **NO**
     - `recalc_parlay_on_result_change` maneja `'push'`: **NO**
     - `get_bankroll_actual` cuenta `'push'`: **SI**
     - `editar_resultado_pick` acepta `'push'` en VALIDOS: **SI**
     Es decir: se puede marcar un pick como `push` y `ganancia_neta` se queda con el
     valor anterior. Si venia de `ganado (+X)`, el bankroll conserva esa ganancia.
     Lo mismo con `'retirado'`, que tampoco esta en ninguno de los dos recalc (ahi lo
     tapa el trigger de cashout, que exige monto).
     **Filas afectadas hoy: 0** (`push` = 0 en picks y parlays; `retirado` = 0).
     Latente, no activo. Diff propuesto, NO desplegado: agregar a los dos recalc
     `ELSIF NEW.resultado IN ('push') THEN NEW.ganancia_neta := 0;`

117. **#253 FUT PRO: el piso de 52% queda NO APROBADO por el usuario. Con razon.**
     Un umbral fijo de probabilidad no tiene significado economico sin el momio:
     breakeven a 1.50 es 66.67%, a 1.91 es 52.36%, a 2.50 es 40.00%.
     `P=49% @ 2.50` da EV **+22.5%**; `P=53% @ 1.80` da EV **-4.6%**. El piso acepta
     el segundo y rechaza el primero.
     Decision: **no se toca el piso ni se baja**; la elegibilidad debe salir de
     P_FAIR + momio -> EV, y cualquier piso nuevo exige evidencia OOS especifica para
     esa funcion. Queda como rediseno, no como ajuste de numero.

118. **#251 RESUELTO — NO ERA UN BYPASS. Era mi prueba. `tg_limite_exposicion` no se toco.**
     **Causa raiz exacta:** `trg_prevenir_pick_duplicado` -> `prevenir_pick_duplicado()`
     es un trigger BEFORE INSERT que, al encontrar un pick identico
     (`apodo` + `partido` + `pick_desc` + `casa`) creado en los ultimos 120 segundos,
     hace **`RETURN NULL`**. Eso descarta la fila **en silencio, sin error**, y
     **aborta la cadena de triggers antes** de `zzz_autoridad_stake` y
     `zzzz_limite_exposicion`. Mi fila B era identica a la A salvo por `scan_id`,
     asi que nunca llego al candado. La prueba dio "PASO" porque el INSERT no
     lanzo excepcion; la fila **no existia**. Se comprobo con
     `B{no existe}` leyendo por id despues del insert.
     **La hipotesis de snapshot/volatilidad quedo DESCARTADA con medicion.**
     Inventario: `exposicion_viva`, `get_bankroll_actual`, `ruta_ledger`,
     `evidencia_scan_valida`, `bankroll_expuesto` son todas **STABLE SECURITY DEFINER**,
     llamadas desde `tg_limite_exposicion` que es **VOLATILE**. Prueba T0/T1/T2 en una
     sola transaccion, tras insertar $2,000 con ledger valido:
     | eslabon | T0 | T2 |
     |---|---|---|
     | tabla base `picks` | 4,247.67 | **6,247.67** |
     | `bankroll_expuesto` | 4,322.67 | **6,322.67** |
     | `exposicion_viva` | 4,322.67 | **6,322.67** |
     Ningun eslabon lee estado viejo. **No se cambio la volatilidad de ninguna funcion.**
     **REGRESIONES (todas como `authenticated`, con rollback):**
     - **X1** A ledger valido $2,000 (expuesto 6,322.67) -> B $1,500 sin ledger:
       **RECHAZADA** por LIMITE DE CARTERA. PASS
     - **X2** reusar dentro de la misma transaccion el scan que A acaba de consumir,
       fila distinta: **RECHAZADA**. PASS
     - **X3** statements separados: 250 -> 400 -> 550 -> 700 y la 4a ($150, dejaria 850
       sobre un limite de 781.64) **RECHAZADA**. PASS
     - **X4** **multi-row: 4 filas x $150 en UN SOLO statement -> statement RECHAZADO
       COMPLETO.** Exposicion final 250.00, `sobre_el_limite=false`. Politica correcta:
       rechazo de statement entero, sin insercion parcial. PASS
     - **X5** NO se re-ejecuto la prueba de dos sesiones. `tg_limite_exposicion` **no se
       modifico** (no hizo falta arreglo) y conserva su `pg_advisory_xact_lock`
       (verificado); la evidencia previa de H10 sigue vigente sin cambios.
     - **X6** tras el ledger legitimo, apuesta automatica de $900 en la misma
       transaccion: **RECHAZADA**. PASS
     **Residual real que si vale anotar:** un trigger BEFORE que devuelve NULL descarta
     un INSERT **sin error**. Desde PostgREST, insertar un pick duplicado dentro de
     120 s devuelve exito con cero filas. Es preexistente e intencional, pero es un
     modo de fallo silencioso.

119. **#252 CORRECCION A MI PROPIO REPORTE: `push` NO EXISTE en el esquema.**
     Dije que "se puede marcar un pick como push y la ganancia se queda con el valor
     anterior". **Falso.** El CHECK de las DOS tablas es identico:
     `('pendiente','ganado','perdido','nulo','retirado')`. `push` nunca fue escribible.
     El defecto real era otro: `editar_resultado_pick` ofrecia `'push'` en su lista de
     validos, lo aceptaba y despues reventaba con un error crudo de constraint.
     **Corregido:** `'push'` fuera de VALIDOS; ahora responde
     *"Resultado no valido: push. Usa uno de: pendiente, ganado, perdido, nulo, retirado"*.
     **NO se agrego `push` al CHECK a proposito**: seria un valor nuevo que 107
     funciones y vistas no conocen, la misma trampa de `'retirado'` (#249).
     En este esquema el estado "me devolvieron la apuesta" es **`nulo`**.
     Se dejaron ramas defensivas para `push` en los tres recalculadores por si algun
     dia entra al CHECK.

120. **#252b LA PRUEBA P8 CAZO UN BUG REAL Y ALCANZABLE: `nulo` con cash out.**
     Corriendo P1-P8 sobre `nulo` (el equivalente alcanzable de `push`):
     `proteger_ganancia_cashout` tenia `'nulo'` en la lista donde el cash out manda,
     asi que el parlay de $300 con `cashout_monto=75` marcado `nulo` se quedaba en
     **-225 en vez de 0**, y el bankroll no se movia.
     **Corregido:** `nulo`/`push` pasan a ser rama de AUTORIDAD MAXIMA y van primero:
     `ganancia_neta := 0` y se limpian `cashout_monto` y `cashout_fecha` de forma
     explicita. Un cash out es incompatible con una devolucion integra.
     **P1-P8 despues del arreglo, con rollback:**
     | prueba | resultado |
     |---|---|
     | P1 pick ganado +100 -> nulo | 0.00 · bankroll delta -100.00 (= esperado) |
     | P2 pick perdido -250 -> nulo | 0.00 · delta +250.00 |
     | P3 nulo -> ganado | +100.00 |
     | P4 nulo -> perdido | -250.00 |
     | P5 nulo -> nulo | 0.00 idempotente |
     | P6a rpc `nulo` + cashout 999 | RECHAZADO con mensaje propio |
     | P6b rpc `push` | RECHAZADO con mensaje propio |
     | P8 parlay -225/cash75 -> nulo | **0.00**, cashout NULL, delta **+225.00** |
     | P8b nulo -> ganado | +586.38 (con el `momio_efectivo` de la fila) |
     | P8d nulo -> perdido | -300.00 |
     | P8e nulo -> nulo | 0.00, cashout NULL |
     | REG perdido + cash 75 | -225.00 (el cash out legitimo intacto) |
     | REG quitar el cash out | -300.00 (rama de deshacer de #250 intacta) |
     Censo previo: `push` 0 en picks y parlays, `retirado` 0 en ambas. **Cero filas
     historicas tocadas.**
     **Estado final:** parlay `0c20f6c6` intacto (perdido / cashout 75 / -225).
     bankroll rodelcast $4,322.45, el dos $3,908.19. **residuos de prueba: 0.**
     attestaciones 5, consumos 5. `EXP_OFF = 0.50`. `kelly_stake` sin tocar.
     `pg_advisory_xact_lock` presente. RONGOL sin tocar (las 3 lecciones con
     `bloqueo_total` siguen identicas).

121. **#251 CLOSED / PASS — X5 re-ejecutada con DOS SESIONES REALES sobre el estado actual.**
     `dblink` exige contrasena para no-superusuario; **no se manejo ninguna credencial**.
     Se uso **pg_cron**, que lanza cada job en un background worker distinto:
     concurrencia real, sin secretos. La extension dblink se elimino.
     **Escenario** (apodo "el dos", sin ruta de ledger para que gobierne el candado;
     el techo individual se salva con `stake_sobre_techo_razon` >= 15 caracteres, que
     NO concede ruta de ledger):
     `E0 = 250.00` · `limite = 781.64` · `S1 = S2 = 400`
     `250+400 = 650 <= 781.64` cada una · `250+800 = 1050 > 781.64` juntas.
     **Evidencia capturada:**
     - `pg_locks` x5 muestras (17:48:10 -> 17:48:22), mismo `objid = 1552519797`:
       | pid | job | granted | wait_event |
       |-----|-----|---------|------------|
       | 8139 | `x5_a` | **t** | Timeout/PgSleep |
       | 8138 | `x5_b` | **f** | **Lock/advisory** |
     - B espero **19,112 ms** (17:48:06.430 -> 17:48:25.542).
     - A confirmo (job 411 `succeeded`), B adquirio el lock.
     - **B RELEYO la exposicion nueva: `expuesto_visto = 650.00`** (era 250 antes de A).
       Esa relectura es la propiedad que se queria demostrar.
     - Error exacto de B:
       `LIMITE DE CARTERA: esta apuesta de $400.00 dejaria la exposicion abierta en`
       `$1050.00 sobre un bankroll total de $3908.19. El techo de cartera es del 20.0`
       `por ciento ($781.64) y la capacidad restante es $131.64.`
     - Exposicion final tras el rechazo: 650.00 <= 781.64, `sobre_el_limite = false`.
       **Nunca supero el limite.**
     **Limpieza:** se borro la fila artificial de A (`bet_id_casa = X5-SESION-A-BORRAR`),
     se eliminaron `x5_a()`, `x5_b()`, `x5_resultado`, los dos cron jobs y sus
     `job_run_details`, y `dblink`.
     **Estado inicial = estado final** para "el dos": expuesto 250.00, capacidad 531.64,
     bankroll 3,908.19.
     **Residuos: 0** (picks X5 0, picks de prueba 0, funciones x5 0, tabla 0, jobs 0,
     dblink 0).
     **Invariantes:** `EXP_OFF = 0.50` · `kelly_stake` md5 `f8f6f398...` sin cambio ·
     `pg_advisory_xact_lock` presente · RONGOL intacto (lecciones 11/12/13 con
     `bloqueo_total`, sin tocar) · attestaciones 5 / consumos 5 · `push` fuera del
     CHECK y 0 filas.
     **#251 CLOSED / PASS sin asterisco**: same transaction, same statement/multi-row,
     sesiones concurrentes, ledger override legitimo y scan single-use, todo a la vez.

122. **#247b CONTRAFACTUAL DE RONGOL — MEDIDO, SIN DESPLEGAR NADA.**
     Regla simulada: alcance por deporte + mercado + liga + `rango_momio`;
     `bloqueo_total` solo para la leccion **12** (MLB / Moneyline / 1.50-1.80 / n=42,
     OOS train -37.7% -> test -44.8%); las **11** y **13** quedan activas como
     advertencia; **cero bloqueos nuevos** para 1.80-2.20 ni otros tramos.
     **Universo:** `v_pick_canonico` 277 filas, **15 con `es_pick`**.
     **Agregado:**
     | metrica | valor |
     |---|---|
     | filas bloqueadas hoy | 164 |
     | de esas, `es_pick` | **13** |
     | seguirian bloqueadas (filas) | 16 |
     | de esas, `es_pick` | **0** |
     | `es_pick` que se desbloquean | **13** |
     | bloqueadas hoy sin momio (grupo C) | 64 (0 `es_pick`) |
     Nota: el 5-sep a las 16:5x conte 9; ahora son 13. La cartelera se refresco
     (nuevos juegos y precios). El numero vigente es 13.
     **GRUPO A — SIGUEN BLOQUEADOS: 0 picks.** Las 16 filas que conservan el bloqueo
     son MLB / Moneyline / 1.50-1.80, y **ninguna** es `es_pick` hoy.
     **GRUPO B — SE DESBLOQUEAN: 13, todos MLB Moneyline.** Todos bloqueados hoy por
     `13:ML/MLB/1.01-1.50 n=8 + 12:ML/MLB/1.50-1.80 n=42`, ninguna de las dos medida
     en su tramo:
     | momio | tramo | pick | P_V1 | EV mostrado | edge |
     |---|---|---|---|---|---|
     | 1.877 | 1.80-2.20 | ML Atlanta Braves | 54.9% | +3.1% | 1.6 |
     | 1.909 | 1.80-2.20 | ML Kansas City Royals | 54.3% | +3.7% | 1.9 |
     | 2.040 | 1.80-2.20 | ML Miami Marlins | 50.5% | +3.0% | 1.5 |
     | 2.090 | 1.80-2.20 | ML New York Yankees | 54.7% | +14.3% | 6.9 |
     | 2.130 | 1.80-2.20 | ML Baltimore Orioles | 48.4% | +3.1% | 1.5 |
     | 2.340 | 2.20-3.00 | ML Detroit Tigers | 47.7% | +11.6% | 5.0 |
     | 2.350 | 2.20-3.00 | ML Atlanta Braves | 52.2% | +22.7% | 9.6 |
     | 2.380 | 2.20-3.00 | ML Detroit Tigers | 47.3% (P_RAW 38.5) | +12.6% | 5.3 |
     | 2.380 | 2.20-3.00 | ML San Francisco Giants | 46.1% | +9.7% | 4.1 |
     | 2.550 | 2.20-3.00 | ML Athletics | 48.7% | +24.2% | 9.5 |
     | 2.570 | 2.20-3.00 | ML Los Angeles Angels | 41.7% | +7.2% | 2.8 |
     | 2.830 | 2.20-3.00 | ML Washington Nationals | 41.4% (P_RAW 39.4) | +17.2% | 6.1 |
     | 3.010 | 3.00-5.00 | ML Athletics | 45.2% | +36.1% | 12.0 |
     **P_RAW solo existe en 2 de 13**: `picks_recomendados_hoy.probabilidad_real` viene
     NULL en 11. Donde si existe, la brecha P_RAW -> P_V1 es grande
     (38.5 -> 47.3 y 39.4 -> 41.4): es la recalibracion de MLB. **No lo fuerzo a B**,
     queda anotado como dato incompleto.
     **GRUPO C — AMBIGUOS: 64 filas bloqueadas sin momio** (32 ML + 32 OU de MLB),
     `rango_momio` indeterminable. **Ninguna es `es_pick`**, asi que no hay dinero en
     juego, pero con la regla corregida un `rango_lec` NULL **no** casa con
     `1.50-1.80` y quedarian permitidas. Es una decision de diseno pendiente: sin
     precio no se puede ubicar el tramo.
     **IMPACTO ECONOMICO: $0. Y la razon importa.**
     `stake_techo('rodelcast')` devuelve `ok:false, techo_monto:0` y `kelly_stake`
     devuelve `"Usuario sin bankroll configurado"`, **porque `capital_libre = 0`**: la
     cartera ya esta al 100% ($4,322.67 sobre un limite de $864.49).
     | metrica | valor |
     |---|---|
     | stake autorizado hoy (13 picks) | **$0.00** |
     | stake pre-RONGOL (Kelly) | **$0.00** (Kelly se niega) |
     | stake contrafactual tras corregir | **$0.00** |
     | **incremento de autorizacion** | **$0.00** |
     **Corregir RONGOL hoy no autoriza un solo peso.** El cap agregado del 20% muerde
     antes que RONGOL.
     **Escenario de exposicion** (contrafactual puro, cartera vacia, techo individual
     5% del capital libre que se encoge en cada apuesta):
     | # | stake max | exposicion acumulada | cabe en el 20% ($864.49) |
     |---|---|---|---|
     | 1 | 216.12 | 216.12 | si |
     | 2 | 205.32 | 421.44 | si |
     | 3 | 195.05 | 616.49 | si |
     | 4 | 185.30 | 801.79 | si |
     | 5 | 176.03 | 977.82 | **NO** |
     **Solo 4 de los 13 caben**; del 5º en adelante choca con el cap agregado.
     **PRUEBAS DE AISLAMIENTO (predicado corregido, casos sinteticos):**
     | caso | hoy | corregido |
     |---|---|---|
     | soccer ML 1.65 | ok | permitido |
     | control MLB ML 1.65 | bloqueado (13+12) | **BLOQUEADO por 12** |
     | MLB **O/U** 1.65 | bloqueado (11) | **permitido** — ML no bloquea O/U |
     | MLB ML **1.95** | bloqueado (13+12) | **permitido** — 1.50-1.80 no bloquea 1.80-2.20 |
     | MLB ML 1.55 | bloqueado | **BLOQUEADO por 12** — la 12 no se toca |
     | MLB ML 1.30 (tramo de la 13) | bloqueado | permitido |
     | MLB O/U 1.30 (tramo de la 11) | bloqueado | permitido |
     Ojo con las dos ultimas: degradar 11 y 13 a advertencia **tambien abre el tramo
     1.01-1.50**. Hoy son 2 filas, 0 `es_pick`, pero es consecuencia de la decision.
     **NO se modifico nada:** `rongol_veto`, `lecciones_aprendidas`, Kelly, caps, V2,
     `EXP_OFF` y produccion intactos. Solo medicion.

123. **#247 CERRADO — RONGOL corregido y desplegado. Solo veta donde tiene evidencia OOS.**
     **Condicionante previo, demostrado:** existe un guard de autoridad economica
     SEPARADO de `rongol_veto` que impide que un pick sin precio autorice dinero, en
     dos capas independientes:
     - `v_pick_canonico.es_pick` arranca con `c.momio_mercado IS NOT NULL`. Medido:
       **0 de 15** `es_pick` tienen momio NULL.
     - `kelly_stake` responde `{"ok":false,"error":"Momio invalido"}` con momio
       NULL / 0 / 1, y `"Probabilidad invalida"` con prob NULL.
     Ademas `es_senal` es explicitamente la rama sin precio (`momio_mercado IS NULL`).
     Ninguna de las dos vive dentro de `rongol_veto`.
     **Diff aplicado a `rongol_veto`:**
     - `v_rango_lec`: tramos de `lecciones_aprendidas` (`1.01-1.50 / 1.50-1.80 /
       1.80-2.20 / 2.20-3.00 / 3.00-5.00 / 5.00+`), distintos de los de
       `rongol_hallazgos` (`<1.40 / 1.40-1.80 / 1.80-2.50 / ...`). Mezclarlos era el bug.
     - El bucle que BLOQUEA ahora exige coincidencia real de deporte + mercado + liga
       + tramo. Con momio NULL el tramo no casa y **no veta**.
     - Bucle nuevo de OBSERVACION: lecciones activas sin `bloqueo_total` **con liga
       propia** y coincidencia estricta -> `advertencia`, no veto.
       **Las lecciones globales (liga NULL) quedan FUERA a proposito:** medido, un loop
       generico ponia **15 de 15 `es_pick` en advertencia** (148 de 277 filas) y el
       aviso se volvia ruido. Acotado a liga propia: 2 filas, 0 `es_pick`.
     - `RANGO_NO_EVALUABLE` cuando no hay momio: alerta + `advertencia`, nunca veto.
     - La respuesta ahora expone `rango_momio` y `rango_evaluable`.
     **Lecciones 11 y 13 -> `bloqueo_total = false`, siguen `activa`.** No se creo
     ningun veto sustituto. Unica regla con veto duro: **12 (MLB / ML / 1.50-1.80 /
     n=42 / OOS train -37.7% -> test -44.8%)**.
     **PRUEBAS A-J, todas PASS:**
     | | caso | nivel | alertas |
     |---|---|---|---|
     | A | MLB ML 1.65 | **bloqueado** | bloqueo [MLB/1.50-1.80] |
     | B | MLB ML 1.95 | permitido | solo fuga preexistente |
     | C | MLB ML 2.40 | permitido | solo fuga preexistente |
     | D | MLB ML 1.30 | permitido | **observacion** [MLB/1.01-1.50] (leccion 13) |
     | E | MLB O/U 1.30 | permitido | **observacion** [MLB/1.01-1.50] (leccion 11) |
     | F | soccer ML 1.65 | **ok** | ninguna |
     | G | momio NULL | permitido | **rango_no_evaluable** |
     | H | los `es_pick` de hoy | **0 bloqueados** (eran 13) | — |
     | I | leccion 12 | intacta, `bloqueo_total=true` | bloquea solo su poblacion |
     | J | EXP_OFF 0.50 · kelly md5 `f8f6f398` · candado advisory presente | sin cambios | — |
     **REPARTO:**
     | | veto duro | warning | libres | total |
     |---|---|---|---|---|
     | universo `v_pick_canonico` | **16** | 143 | 118 | 277 |
     | `es_pick` | **0** | 13 | 2 | 15 |
     **MATIZ IMPORTANTE: los 13 pasaron de `bloqueado` a `advertencia`, no a `ok`.**
     El warning viene del bucle de FUGAS que ya existia (`baseball · Moneyline`,
     n=25, 40%, -6.38 unidades), no de nada que yo agregara. `requiere_confirmacion`
     sigue en true para ellos: la app pedira confirmar. Ya no se les quita el dinero,
     pero quedan marcados.
     **Sin residuos.** La exposicion de "el dos" bajo de 250.00 a 0.00 por una
     calificacion legitima del cron: pick `7975e41c` (Volos NFC - Olympiacos, Menos de
     2.5) marcado **ganado +$190** a las 18:07 con `AUTO_DET:live_scores`. Bankroll
     3,908.19 -> 4,098.19. Nada que ver con las pruebas: `residuos_prueba = 0`.
     **No se optimizo ninguna regla ni se creo bloqueo alguno desde ROI in-sample.**

---

## 253. ALLOCATOR: el prefijo monotono descartaba a TODOS los que venian detras del primero que no cabia

**Estado: CERRADO / DESPLEGADO** — 5-sep-2026

**Diagnostico (2A.59-2A.67, aceptado por el auditor).** `reto_picks_hoy` no tenia
bucle greedy ni `break`: la admision era una suma corrida de ventana
`sum(monto_cand) over (order by monto_cand desc, ...)`. Ese `acumulado` es
monotono creciente por construccion, asi que en cuanto cruzaba el techo NINGUN
candidato posterior podia entrar aunque cupiera. Efecto medido sobre snapshot:
meseta de cero de $175 de ancho (C=$5 a C=$180) y hasta $19.80 de profit
diagnostico perdido.

**Matiz que corrige la premisa del reporte inicial:** un candidato bloqueado
(rongol / ev_negativo / abstencion / ...) ya consumia CERO en el codigo viejo,
porque `cand` le pone `monto_cand = 0`. El envenenamiento venia EXCLUSIVAMENTE
de candidatos elegibles que no cabian enteros.

**CONTRATO declarado: `ALLOCATOR_V1 = 0/1`.** Stake completo (Kelly + caps) o
cero. Sin recorte parcial. Documentado en `COMMENT ON FUNCTION`.

**Cambio.** Se sustituyo la ventana por una recurrencia `WITH RECURSIVE` que
recorre los candidatos en el MISMO orden congelado y solo baja la capacidad
cuando un candidato es EFECTIVAMENTE ADMITIDO. La funcion sigue siendo
`LANGUAGE sql STABLE SECURITY DEFINER` (no se convirtio a PL/pgSQL).
`exp`, `lim` y `ord` van `MATERIALIZED` para que `exposicion_viva`,
`kelly_stake` y `rongol_veto` se evaluen UNA vez y no por paso de recursion.

Nuevo motivo `no_cabe_entero` (antes todo caia en `exposicion`), con texto que
dice el monto pedido y la capacidad restante.

- md5 antes `6d7c30017252289cea521f1878a9b2fa` -> despues `eae5486a0429f65ac48bfc5c3e55b969`
- Orden CONGELADO: `monto_cand DESC, arranca_en NULLS LAST, espn_event_id, pick_desc`
- Sin tocar: Kelly (`f8f6f398...`), RONGOL (`35b327df...`), caps 5/15/20, EXP_OFF 0.50, V2, confidence

**Comparacion sombra (snapshot 8 candidatos, sigma $841.74, stakes
181.56/157.55/102.03/96.49/92.06/78.37/77.46/56.22):**

| C | viejo stake / n | nuevo stake / n | residual viejo | residual nuevo |
|---|---|---|---|---|
| 35.71 | 0 / 0 | 0 / 0 | 35.71 | 35.71 |
| 56.22 | 0 / 0 | 56.22 / 1 | 56.22 | 0.00 |
| 100 | 0 / 0 | 96.49 / 1 | 100.00 | 3.51 |
| 150 | 0 / 0 | 102.03 / 1 | 150.00 | 47.97 |
| 181.56 | 181.56 / 1 | 181.56 / 1 | 0.00 | 0.00 |
| 250 | 181.56 / 1 | 237.78 / 2 | 68.44 | 12.22 |
| 300 | 181.56 / 1 | 283.59 / 2 | 118.44 | 16.41 |
| 400 | 339.11 / 2 | 395.33 / 3 | 60.89 | 4.67 |
| 500 | 441.14 / 3 | 497.36 / 4 | 58.86 | 2.64 |
| 569.64 | 537.63 / 4 | 537.63 / 4 | 32.01 | 32.01 |
| 700 | 629.69 / 5 | 685.91 / 6 | 70.31 | 14.09 |
| 841.74 | 841.74 / 8 | 841.74 / 8 | 0.00 | 0.00 |

R1-R7 **PASS** (R1 = 0 a C=35.71 demuestra que NO se introdujo stake fraccional).

**Candidatos bloqueados consumen 0** — probado en dos escenarios, incluido uno
ADVERSARIAL donde a los bloqueados se les puso `monto_cand > 0` a proposito
(invariante roto a mano): la recurrencia igual los deja en 0 porque el predicado
exige `motivo_bloqueo is null`. Doble candado.

**Determinismo PASS**: 12/12 md5 identicos con el orden fisico de filas barajado.

**Congruencia con `tg_limite_exposicion` PASS**: el conjunto admitido entra
secuencialmente (431.56 -> 589.11 -> 691.14 -> 787.63, techo 819.64). Mismos
denominadores (`exposicion_viva`), sin cambiar porcentajes.

**Impacto real en produccion al desplegar:**
- `el dos`: SIN cambio de dinero ($537.63, 4 picks). Solo cambia el motivo de 4
  rechazados: `exposicion` -> `no_cabe_entero`.
- `rodelcast`: **$1,437.43 (6) -> $1,551.56 (7)**. El candidato de $157.25 no
  cabia (1437.43+157.25 > 1562.42) y antes descartaba a los 3 siguientes; ahora
  entra el de $114.13. Capacidad ociosa $124.99 -> $10.86.

**PENDIENTE, NO tocado:** el ORDER BY sigue siendo por tamano, no economico.
Sobre este snapshot cuesta $3.14 a C=$700 (EV%-desc alcanzaria 162.10 vs 158.97).
Eso es politica de orden y va aparte. Tampoco se toco knapsack ni el 5/15/20.

**Cero residuos**: tablas de prueba 0, funciones de prueba 0 (`mlb_shadow_generar`
es preexistente y ajena), jobs 0, dblink 0, sobrecargas de `reto_picks_hoy` = 1.

---

## 254. Animacion de victoria de Zeus: dos variantes segun pick sencillo o parlay

**Estado: DESPLEGADO en Lovable** — 5-sep-2026. SOLO presentacion.

**Lo que ya existia (y por que estaba desaprovechado).** `useWinCelebration`
detectaba ganadas pero colapsaba todo en un texto generico ("¡GANASTE!") que
iba a `CelebrationModal`: sin monto, sin patas y **sin distinguir pick de
parlay**. Al mismo tiempo `ResultadoOverlay` ya tenia un modo `victoria`
completo (confeti en canvas, monto, patas) que **nadie usaba**: la unica ruta
viva de ese componente era el WASTED de derrota (#122).

**Lo que se hizo.** Tres archivos, ni uno mas:

1. **NUEVO `src/components/reto/ZeusWinOverlay.tsx`** — reutiliza el patron de
   `ResultadoOverlay` (ModalPortal + `useRegisterOverlay` + framer-motion +
   `prefers-reduced-motion` + confeti en canvas + auto-cierre) sin tocarlo.
   Dos variantes:
   - `zeus_pick_win` (MODERADA): 1 rayo, 2 ramas, 40 confeti, sin sacudida,
     sin "VICTORY!", 2,600 ms, acento dorado `#D4A152`.
   - `zeus_parlay_win` (EPICA): tormenta continua de 5 rayos con 5 ramas,
     3 destellos blancos, sacudida de 9 px, onda de choque, 160 confeti,
     **"VICTORY!"**, 4,800 ms, acento electrico `#7FD4FF`.
2. **`src/hooks/useWinCelebration.ts`** — nuevo estado `victoria` con
   `variante / titulo / monto / patas / legs / extras`. `CelebrationModal`
   queda SOLO para la meta semanal (`variant: "goal"`).
3. **`src/pages/Reto.tsx`** — monta `<ZeusWinOverlay>`; el WASTED pasa a
   `open={derrota.open && !victoria.open}` para que nunca se encimen.

**Regla de variante (medida en `legs`, no en el nombre de la tabla).**
`legs` = `picks_data.length`. Un pick sencillo es `legs = 1`. Si entre las
ganadas nuevas hay ALGUN parlay de `legs >= 2`, gana la epica (la de mayor
ganancia); si no, la moderada. Un "parlay" con menos de 2 patas cae en la
moderada a proposito: dato sucio no debe disparar la animacion grande.

**Voz "Victory!": APAGADA por defecto**, en `VOZ_VICTORY.activa = false`.
El texto en pantalla cumple el requisito. iOS bloquea audio que no nace de un
gesto del usuario y este overlay aparece solo, asi que dejarla prendida daria
un comportamiento distinto por navegador. Se prende cambiando una constante.

**Como se ajusta despues.** TODO lo tunable vive en un solo bloque,
`ZEUS_PRESETS`, arriba del archivo: duracion, numero de rayos y ramas,
destellos, confeti, sacudida, brillo, grosor, onda, "VICTORY!" y acento.
No hay constantes de animacion repartidas por el componente.

**Lo que NO se toco:** grading, bankroll, `useAutoGrader`, servicios, RPC,
`ResultadoOverlay`, `CelebrationModal` y cualquier otra pantalla. El overlay
solo se monta en `src/pages/Reto.tsx`.

**Disparo:** `resultado === "ganado"` EXACTO. No se dispara con `perdido`,
`nulo`, `pendiente` ni `retirado`. Se conserva el guard `primed.current` que
indexa el historico en la primera pasada sin celebrar nada.

**Movil:** DPR tope 2, un solo `requestAnimationFrame` por canvas con
`cancelAnimationFrame` al desmontar, `pointerEvents: none` en los canvas,
sin librerias nuevas. Con `prefers-reduced-motion` no se monta ningun canvas
ni la sacudida: solo texto y monto.

**PENDIENTE:** prueba de humo en navegador. No puedo abrir `reto13.lovable.app`
desde aqui (el proxy de salida lo bloquea con 403), asi que las dos variantes
estan verificadas por codigo, no por vista.

### 254-QA. Harness de prueba visual (andamio, se borra al cerrar #254)

Frontend-only, para poder ver las variantes de Zeus sin tocar dinero.

**Acceso:** `https://reto13.lovable.app/?qa=zeus` — en la RAIZ, no en `/reto`
(`App.tsx` monta `Reto` en `<Route path="/">`; `/reto` cae en NotFound).
Ademas exige `apodo === 'rodelcast'`. Sin el parametro, o con otro usuario,
el panel ni se monta.

**Archivos:**
- NUEVO `src/components/reto/ZeusQaPanel.tsx` (171 lineas)
- `src/components/reto/ZeusWinOverlay.tsx`: UNA prop opcional
  `forzarReducedMotion?: boolean`. `undefined` = comportamiento normal.
- `src/pages/Reto.tsx`: `useSearchParams`, `const qaZeus = ...`, y
  `{qaZeus && <ZeusQaPanel />}`.

**Candados verificados leyendo el diff aplicado:**
- `ZeusQaPanel.tsx` importa SOLO `useState`, `ZeusWinOverlay` y
  `ResultadoOverlay`. Cero imports de `supabase`, servicios o hooks de datos.
- La cadena `localStorage` no aparece ni una vez en el archivo. No toca
  `celebration_seen_win_ids_v1` ni `celebration_seen_loss_ids_v1`.
- Todos los datos vienen de dos constantes literales (`FIX`, `DERROTA_FIX`)
  y de tres `useState`. Nada sale de la base.
- Reutiliza los componentes reales; no duplica ninguna animacion ni preset.
- `useWinCelebration` NO se modifico.
- Panel en z-index 1100, por debajo de los overlays (1200 y 1300).
- `App.tsx` no se toco: no se creo ninguna ruta nueva.

**MATIZ del boton 7:** el panel pasa `forzarReducedMotion={reducido}`, un
booleano siempre definido. Casilla marcada = modo reducido FORZADO; casilla
sin marcar = movimiento completo FORZADO, aunque el sistema del usuario tenga
`prefers-reduced-motion` activado. Es lo util para QA (se prueban los dos
lados a voluntad) pero NO es "leer el ajuste del sistema".

**Lo que el harness NO puede probar** (es logica del hook, no visual):
no repetir tras refresh, no repetir al reentrar, y que `nulo`/`retirado`/
`perdido` jamas disparen Zeus. Eso necesita datos reales o una prueba
unitaria de `useWinCelebration`.

**Para borrarlo:** borrar `ZeusQaPanel.tsx`; quitar de `Reto.tsx` el import,
`useSearchParams`, la linea `qaZeus` y el bloque `{qaZeus && ...}`; y quitar
la prop `forzarReducedMotion` de `ZeusWinOverlay.tsx`.

**OBSERVACION aparte (no tocada):** `ScoreNotifBridge` en `App.tsx` ya lanza
un toast de sonner `"¡GANASTE $X!"` por realtime cuando la base marca un
parlay como ganado. En una ganada REAL veras ESE toast **y** el overlay de
Zeus. El harness no reproduce el toast, asi que esa duplicacion no se ve en QA.

### 254-B. Faltaba lo principal: no habia Zeus, habia un rayo

**Reportado por el usuario al abrir el QA:** *"no sale ZEUS, sale puro rayo"*.
Tenia razon. La primera entrega dibujaba un bolt SVG + tormenta en canvas y lo
llamaba "Zeus", pero no habia ninguna figura del dios en pantalla. En
`src/assets/` solo existian `fyb_logo.png`, `logo.png` y `reto13m_icon.png`:
nunca hubo imagen de Zeus, y en vez de decirlo se entrego el rayo como si
cumpliera. Error de reporte, no solo de implementacion.

**Corregido:** dos ilustraciones originales generadas por Lovable, PNG con
alpha, en `src/assets/`:
- `zeus-sereno.png` — Zeus de pie, rayo en la mano baja, sereno. Variante
  MODERADA (`zeus_pick_win`), altura `clamp(130px, 30vw, 180px)`.
- `zeus-furioso.png` — mismo personaje, brazo alzado lanzando el rayo, capa
  al viento. Variante EPICA (`zeus_parlay_win`), altura
  `clamp(190px, 44vw, 280px)`.

Estilo pedido: semi-silueta con luz de borde dorada/electrica para que se lea
sobre el overlay negro. Obra original, sin copiar God of War, Hades ni Marvel.

**Cableado:** `Preset` gana dos campos, `imagen` y `alturaZeus`, dentro del
mismo bloque `ZEUS_PRESETS`. El tamano se ajusta ahi, igual que todo lo demas.
La tormenta y el confeti siguen corriendo detras de la figura, sin cambios.

**Fallback:** `imagenFallo` con `onError` en el `<img>`. Si la imagen no carga,
vuelve el rayo SVG de antes. Vale mas un simbolo pobre que un hueco.

**Sin verificar visualmente.** No puedo abrir el navegador ni leer los PNG
binarios: no he visto como quedaron las ilustraciones. Lo tiene que mirar el
usuario en `/?qa=zeus`. Puntos concretos a revisar: que la figura se lea sobre
negro y no se pierda; que el fondo transparente sea real y no un recuadro
blanco; y que en la epica el conjunto Zeus + VICTORY + monto + patas + boton
CERRAR quepa en movil sin tapar el boton.

---

## 255. Celebraciones tematicas: ZEUS gana, HADES pierde. Un solo componente, tres variantes

**Estado: DESPLEGADO en Lovable** — 5-sep-2026. SOLO capa visual.

**Por que se unificaron.** Antes las dos celebraciones vivian en archivos
distintos: Zeus en `ZeusWinOverlay.tsx` y el WASTED en `ResultadoOverlay.tsx`,
cada uno con su propia estetica y sus propias constantes. "Ajustar intensidad"
significaba tocar dos archivos que no compartian nada. Ahora hay UN componente,
`CelebracionOverlay.tsx`, con UN bloque `PRESETS` de tres variantes.

| variante | cuando | duracion | atmosfera |
|---|---|---|---|
| `zeus_pick_win` | pick sencillo ganado (legs = 1) | **1,800 ms** | 1 rayo, 40 confeti, sin sacudida, eyebrow "VICTORY" |
| `zeus_parlay_win` | parlay ganado (legs >= 2) | **3,500 ms** | 5 rayos continuos, 3 destellos, 160 confeti, sacudida 9px, onda de choque, "VICTORY!" grande |
| `hades_loss` | apuesta perdida | **2,600 ms** | sin rayos, 90 BRASAS ascendentes, velo rojo, vinetado, fondo en gris, entrada lenta sin rebote, "WASTED" en serif rojo |

Duraciones dentro de los rangos que pidio el auditor (1.5-2s / 3-4s / 2-3s).

**Motor de particulas con dos modos** en el mismo canvas: `confeti` cae desde
arriba y rota; `brasas` suben desde abajo, brillan con `shadowBlur` y se
desvanecen con la altura. Un solo `requestAnimationFrame`, DPR tope 2.

**Assets:** `zeus-sereno.png`, `zeus-furioso.png` y `hades.png`, los tres en el
mismo estilo splash art pintado.

**Lo que NO se toco:** `useWinCelebration.ts` quedo intacto. El disparo ya
distinguia `resultado === 'ganado'` de `=== 'perdido'` exactos, ya priorizaba
parlay sobre sencilla, y ya traia el guard `primed` contra repeticiones. Lo
unico que cambio es a que componente va cada estado: `victoria.variante` elige
entre las dos de Zeus, y `derrota` entra fija como `hades_loss`.

Tampoco se toco grading, bankroll, Kelly, RONGOL, el allocator ni ninguna RPC.

**Secuencia ganada+perdida:** se conserva `derrota.open && !victoria.open`.
Zeus corre primero y Hades entra cuando Zeus se cierra solo. Nunca se encinan.
Total del peor caso: 3,500 + 2,600 = 6.1 s (antes eran 8.3 s).

**Archivos:** NUEVO `CelebracionOverlay.tsx`; BORRADO `ZeusWinOverlay.tsx`;
editados `Reto.tsx` y `ZeusQaPanel.tsx`. `ResultadoOverlay.tsx` se CONSERVA en
el repo aunque ya nadie lo importe.

**QA:** el panel de `?qa=zeus` gana un boton `7 · HADES (LOSS)`; la casilla de
reduced motion pasa a `8`.

**SIN VERIFICACION VISUAL.** No puedo abrir el navegador ni leer los PNG. Ni
las tres ilustraciones ni las tres animaciones han sido vistas por nadie
todavia. Lo tiene que mirar el usuario en `/?qa=zeus`.

**PENDIENTES que siguen abiertos y NO se tocaron aqui:**
- A. tipo real de entidad: hoy un parlay con `picks_data` corrupto se rotula
  "PICK GANADO". 0 casos vivos medidos.
- B. tope de 200 ids en `SEEN_WINS_KEY`: al pasar de 200 ganadas el FIFO expulsa
  ids viejos y las celebraciones se repiten solas. Hoy van 14 ganadas.
- C. `ScoreNotifBridge` en `App.tsx` lanza un toast "¡GANASTE $X!" por realtime
  ademas del overlay. Duplicacion en la ganada real; el QA no la reproduce.

### 255-B. PUBLICADO. Y la causa real de "no me sale nada"

**Causa raiz, verificada descargando el bundle publicado** (no supuesta):
`reto13.lovable.app` llevaba congelado desde el PRIMER deploy de Zeus. El
bundle servido (`index-_pOzIyqz.js`, 926 KB) contenia `zeus_parlay_win` y el
`WASTED` viejo, pero **NO** contenia `QA ZEUS` ni el candado de `?qa=zeus` ni
`hades_loss`. El parametro no hacia nada porque el codigo que lo lee no estaba
ahi. Todo lo posterior vivia solo en el preview de Lovable, que responde **401**
a quien no tenga sesion de Lovable.

**Metodo:** el proxy de salida de mi entorno bloquea lovable.app, asi que la
inspeccion se hizo con `net.http_get` desde Postgres y `position()` sobre el
contenido, sin traerme el bundle al contexto.

**Error propio:** habia recomendado abrir el preview en incognito. En incognito
no hay sesion de Lovable y el preview devuelve 401 — mi consejo garantizaba que
no funcionara.

**Publicado** con autorizacion explicita del usuario (deployment
`21c9a4cb-1944-4049-9ac6-25e4a7654616`). Bundle nuevo `index-VWvNJXMf.js`,
933 KB. Verificado en el bundle publicado:

| marcador | |
|---|---|
| `QA ZEUS` (panel) | SI |
| `zeus_pick_win` / `zeus_parlay_win` / `hades_loss` | SI las tres |
| candado `rodelcast` | SI |
| boton `HADES (LOSS)` | SI |
| assets `zeus-sereno` / `zeus-furioso` / `hades` | SI los tres |

(`qa=zeus` como cadena literal da NO, y es un falso negativo de mi grep: el
codigo minificado compara `.get("qa")==="zeus"`, nunca escribe la cadena junta.)

**DEUDA NUEVA:** el harness de QA quedo en el sitio PUBLICO. Esta cerrado con
`?qa=zeus` + `apodo === 'rodelcast'`, pero el codigo viaja. Hay que borrarlo al
aprobar visualmente las tres variantes; los pasos exactos estan en el comentario
de cabecera de `ZeusQaPanel.tsx`.

### 255-C. Las figuras dejan de ser calcomanias: movimiento continuo, cero assets nuevos

Zeus y Hades entraban y se quedaban quietos. Se les anade vida SIN un solo
byte de assets nuevos, todo con framer-motion y el canvas que ya existia.

Cinco campos nuevos en `Preset`, dentro del MISMO bloque `PRESETS`:

| campo | pick | parlay | hades |
|---|---|---|---|
| `respiracionPct` | 2 | 2.5 | 1.5 |
| `destelloFigura` | si | si | no |
| `haloPulsante` | si | si | si |
| `parallaxPx` | 0 | 5 | 0 |
| `particulasFrente` | 0 | 0 | **30** |

- **Destello**: la figura sube a `brightness(1.55)` en el momento del rayo, con
  `times` desiguales para que el pulso no se sienta metronomo.
- **Respiracion**: latido infinito de 2.6 s, `scale` uniforme (no deforma).
- **Halo**: radial-gradient del color del acento, detras de la figura
  (`zIndex 0` contra `zIndex 1`), pulsando escala y opacidad.
- **Parallax**: en el parlay la figura se mueve al REVES que la sacudida.
- **Brasas de frente**: segunda instancia del MISMO componente `Particulas`
  con `cantidad` y `encima`, solo en Hades. Ahora Hades corre dos canvas.

**Anidacion deliberada en 4 capas** (entrada / parallax / respiracion /
destello). Entrada y respiracion animan las dos `scale`, y el destello y el
`drop-shadow` animan los dos `filter`: colapsarlas en un solo `motion.div` hace
que se pisen. Queda documentado en el codigo.

Con `prefers-reduced-motion` no se monta ninguna de las cinco.

**Publicado** (deployment `30ce754b-526d-4613-9040-927c2ae47071`).
Bundle `index-CDA5pj1n.js`, 934,732 bytes. Verificado dentro del bundle
publicado: `brightness(1.55)` presente, respiracion presente, `hades_loss`,
`QA ZEUS`, boton `HADES (LOSS)`, y las tres figuras
(`zeus-sereno`, `zeus-furioso`, `hades`).

Sigue **sin verificacion visual**: nadie ha visto todavia como se ve.

---

## 256. AUDITORIA DEL HAIRCUT — PASO 1 (PROCEDENCIA). BLOQUEANTE

**Solo medicion. Cero parametros cambiados. NFL sin tocar.**

### Correcciones aceptadas del auditor
1. `medido=true` significa "hay datos observados", NO "evidencia valida ni
   transferible". Mi reporte anterior lo dio por bueno; queda corregido.
2. `media_beta - 1.2816*sd_beta` NO es el percentil 10 exacto de una Beta. Es
   una **aproximacion normal del limite inferior del posterior**. Se renombra a
   **`BETA_LOWER_NORMAL_APPROX`**. Verificado: en `kelly_stake` NO existe
   ninguna inversa de la CDF Beta; la unica formula es esa resta.
3. Marco del auditor adoptado: la MISMA celda historica hace TRES trabajos —
   corrige el centro de P, castiga por incertidumbre, y vuelve a castigar por
   la misma incertidumbre.

### PROCEDENCIA — la cadena completa

```
modelo_backtest  --(recalcular_zonas_confiables)-->  zonas_confiables  -->  kelly_stake
```

`recalcular_zonas_confiables` hace `DELETE FROM zonas_confiables` y reconstruye
todo con:
```sql
FROM modelo_backtest WHERE muestra_min >= 8
GROUP BY mercado, width_bucket(prob_modelo,0,1,10)
HAVING count(*) >= 100
```
Agregacion **in-sample completa**. Sin train/test. Sin walk-forward.

### HALLAZGO 1 — LA POBLACION ES 100% FUTBOL

`modelo_backtest`: 30,876 filas (24,618 con `muestra_min>=8`), **sin columna
`deporte`**, solo `liga_id`. Cruzando contra `ligas_master.api_sports_id`:

| deporte | ligas | 
|---|---|
| **soccer** | **20** |

**UN SOLO deporte. Cero filas de cualquier otro. Cero sin cruce.**
(El conteo de filas del cruce sale inflado por duplicados de `api_sports_id` en
`ligas_master`; lo que importa es que hay UN valor distinto de `deporte` y
ningun bucket sin cruzar.)

Cobertura: partidos del **10-mar-2026 al 26-ago-2026**. Mercados: Over/Under,
Moneyline, Total Equipo, Corners, Doble Oportunidad, Tarjetas, BTTS.

**Consecuencia directa:** `kelly_stake` cruza `zonas_confiables` SOLO por
`mercado`. Los **50 picks de MLB Moneyline** de hoy reciben:
- `v_sesgo` = una correccion de calibracion **aprendida en futbol**;
- Beta y Wilson calculados sobre **n y prob_real de futbol**.

MLB esta siendo corregido y castigado por el error de calibracion de un modelo
de futbol. No es transferencia justificada: es la unica celda que hay.

### HALLAZGO 2 — NO HAY VERSIONADO TEMPORAL

`zonas_confiables` tiene 9 columnas y **ninguna fecha de corte**. `actualizado`
tiene **UN SOLO valor distinto** en las 44 filas: `2026-09-05 13:40:00`. Es un
snapshot unico, reescrito de golpe. No existe tabla de historico de zonas.

**No se puede saber que valor de `n/prob_real/prob_dicha` existia antes de
ningun partido historico.**

### VEREDICTO DEL CANDADO ANTI-LEAKAGE

Aplicar la `zonas_confiables` de hoy a picks historicos usaria celdas
construidas con partidos POSTERIORES a esos picks. Es leakage puro.

Por la regla del auditor, el backtest historico directo queda declarado:
**`NO_IDENTIFICABLE_SIN_RECONSTRUCCION_WALK_FORWARD`**

### QUE SE PUEDE Y QUE NO SE PUEDE RECONSTRUIR

- **FUTBOL: SI.** `modelo_backtest` tiene `fecha` por observacion, asi que las
  celdas se pueden reconstruir walk-forward usando solo partidos anteriores a
  cada fecha. La ablacion A-H es ejecutable para futbol.
- **MLB: NO.** No existe poblacion de MLB en `modelo_backtest`. Su haircut es
  **estructuralmente inmedible** con esta fuente: no se puede reconstruir lo que
  nunca se midio. Clasificacion preliminar para MLB:
  **`HEURISTICA_SIN_DATOS`** (ruta `medido=true` pero con celda ajena) —
  pendiente de confirmar contra una fuente propia de MLB como `bt_mlb_ml`.

### ESTADO
Kelly sin cambios (md5 `f8f6f398221cddd5bca929cd6644d353`). RONGOL sin cambios.
Allocator sin cambios. Caps sin cambios. EXP_OFF = 0.50. NFL sigue `SIN_MODELO`.
V2 sin consumidores. Cero residuos: la auditoria fue de solo lectura.

### PARALELO: HARNESS DE ZEUS RETIRADO Y VERIFICADO
Bundle publico `index-BTsRc0Fq.js` (931,509 bytes), verificado con
`net.http_get` + `position()`:

| marcador | |
|---|---|
| `QA ZEUS` | **NO** (retirado) |
| `HADES (LOSS)` | **NO** (retirado) |
| candado `rodelcast` | **NO** (retirado) |
| `zeus_parlay_win` | SI (intacto) |
| `hades_loss` | SI (intacto) |
| `brightness(1.55)` (animacion) | SI (intacta) |
| `PARLAY GANADO` (correccion A) | **SI** (desplegada) |

Correccion A incluida: el tipo de apuesta ya sale del ORIGEN, no de
`picks_data.length`. Un parlay con patas corruptas ya NO se rotula
"PICK GANADO". Mismo arreglo en derrotas ("PARLAY PERDIDO" en vez de
"PARLAY X0 PERDIDO"). `legs >= 2` sigue decidiendo SOLO la intensidad.

---

## 257. BLOQUE A (FUTBOL WALK-FORWARD) + BLOQUE C. RESULTADO: LOS DOS HAIRCUTS DANAN OOS

**Solo medicion. Cero cambios. Kelly, RONGOL, allocator, caps y NFL intactos.**

### Metodo
Reconstruccion walk-forward ESTRICTA desde `modelo_backtest`, sin usar el
snapshot actual de `zonas_confiables`. Ventana:
`PARTITION BY mercado, tramo ORDER BY fecha RANGE BETWEEN UNBOUNDED PRECEDING
AND CURRENT ROW EXCLUDE GROUP`. El `EXCLUDE GROUP` saca la fila actual **y todas
las empatadas en fecha**, asi que ningun partido se ve a si mismo ni a otro del
mismo instante. Regla de produccion respetada: `medido = (n_previo >= 100)`;
si no, `n=30, k=round(p*30)`. n = 24,612 observaciones de futbol.

### BLOQUE A — ABLACION A-H (Brier, menor es mejor)

| variante | Brier | delta vs P0 | log loss | bias (real-pred) |
|---|---|---|---|---|
| **B_sesgo** | **0.22151** | **-0.00193** | **0.63699** | -0.0037 |
| A_P0 | 0.22343 | 0 | 0.64335 | -0.0021 |
| G_sesgo_wilson | 0.22406 | +0.00063 | 0.64343 | +0.0420 |
| F_sesgo_beta | 0.22430 | +0.00086 | 0.64584 | +0.0416 |
| D_wilson | 0.22562 | +0.00219 | 0.64850 | +0.0435 |
| C_beta | 0.22632 | +0.00289 | 0.65338 | +0.0432 |
| **H_PRODUCCION** | **0.23051** | **+0.00707** | 0.66242 | **+0.0806** |
| E_beta_wilson | 0.23213 | +0.00869 | 0.66918 | +0.0821 |

**La configuracion de produccion es la 7a de 8.** Solo le gana en maldad la
que quita el sesgo y deja los dos recortes.

### PRUEBAS PAREADAS (n=24,612). LAS SIETE SIGNIFICATIVAS

| comparacion | delta Brier | t | IC95 | veredicto |
|---|---|---|---|---|
| sesgo aporta (B vs A) | **-0.001926** | **-5.51** | [-0.00261, -0.00124] | **MEJORA** |
| solo Beta (C vs A) | +0.002885 | +8.61 | [+0.00223, +0.00354] | EMPEORA |
| solo Wilson (D vs A) | +0.002364 | +6.94 | [+0.00170, +0.00303] | EMPEORA |
| PRODUCCION vs cruda (H vs A) | +0.007157 | +10.25 | [+0.00579, +0.00853] | EMPEORA |
| **marginal Wilson tras Beta (H vs F)** | **+0.006295** | **+22.39** | [+0.00574, +0.00685] | EMPEORA |
| **marginal Beta tras Wilson (H vs G)** | **+0.006353** | **+23.12** | [+0.00581, +0.00689] | EMPEORA |
| PRODUCCION vs solo sesgo (H vs B) | +0.009084 | +14.85 | [+0.00789, +0.01028] | EMPEORA |

**Respuesta a la pregunta de redundancia:** el segundo bound no solo no aporta
senal — DANA, y son los dos resultados con MAYOR certeza estadistica de toda la
tabla (t = 22.4 y 23.1). Cobrar la incertidumbre dos veces es peor que cobrarla
una, y cobrarla una es peor que no cobrarla.

**El sesgo va en direccion contraria:** es el UNICO componente que mejora, y de
forma significativa. P0 ya llega casi insesgada (-0.21 pp); produccion la deja
en **+8.06 pp de subestimacion sistematica** (predice 43.84%, la realidad es
51.91%).

### BLOQUE C — RUTA `medido=false` (n=30, k=round(p*30))

Monotonica: **0 violaciones** en la rejilla fina 0.30-0.99.

| p inicial | Beta pp | factor | p final | caida abs | caida rel |
|---|---|---|---|---|---|
| 35% | 10.94 | 0.706 | **16.98%** | 18.02 pp | **51.5%** |
| 50% | 11.33 | 0.769 | **29.74%** | 20.26 pp | 40.5% |
| 65% | 10.72 | 0.830 | **45.04%** | 19.96 pp | 30.7% |
| 80% | 9.22 | 0.874 | **61.84%** | 18.16 pp | 22.7% |

**P inicial minima para conservar EV > 0:**

| cuota | breakeven | P minima requerida | sobrecosto |
|---|---|---|---|
| 1.50 | 66.67% | **84%** | +17.3 pp |
| 1.80 | 55.56% | **75%** | +19.4 pp |
| 2.00 | 50.00% | **70%** | +20.0 pp |
| 2.50 | 40.00% | **61%** | +21.0 pp |
| 3.00 | 33.33% | **54%** | +20.7 pp |

**Un mercado sin medir necesita ~20 pp por encima del breakeven para que el
sistema autorice un solo peso.** Esto no es un filtro: es un apagado de facto.

**Implicacion para NFL (informativa, NO es propuesta):** NFL no existe en
`modelo_backtest`. Si se levantara `sin_modelo_independiente`, TODO pick de NFL
caeria en la ruta `medido=false` y necesitaria ~70% declarado a cuota 2.00.
La segunda puerta lo apagaria igual que la primera.

### CLASIFICACION PRELIMINAR (solo futbol; MLB pendiente de Bloque B)

| componente | futbol |
|---|---|
| `v_sesgo` (calibracion) | **SOPORTADA_OOS** |
| `BETA_LOWER_NORMAL_APPROX` | **DANINA_OOS** |
| Wilson (`v_factor_n`) | **DANINA_OOS** |
| Beta + Wilson juntos | **DANINA_OOS** (peor que cualquiera solo) |
| ruta `medido=false` | **HEURISTICA_SIN_DATOS** |
| regla de produccion para MLB | **HEURISTICA_CROSS_DOMAIN_SIN_VALIDACION_MLB** |

**NO SE RETIRA NADA.** Falta la parte economica del Bloque A, el Bloque B
completo (MLB: transferencia soccer->MLB y MLB-native), y la decision de
arquitectura, que es del auditor.

---

## #258 MLB "SIN PRECIO": la cartelera cae al respaldo porque la vista corre el modelo 25 veces

**Estado:** DIAGNOSTICADO Y MEDIDO. No se despliega nada (la orden vigente es
"solo medicion").

**Sintoma reportado (captura del 5-sep):** tarjeta Philadelphia Phillies vs
Atlanta Braves, HOY 04:05 P.M. Chip **SIN PRECIO**, los dos momios en `—`,
`— casa`, y abajo **"Margen de la casa: —"**. Al mismo tiempo, el bloque de
analisis de esa misma tarjeta dice: *"El modelo y el mercado no se parecen:
11.9 puntos de diferencia"*. La tarjeta niega tener precio mientras el aviso
de abajo esta usando ese precio.

### El precio SI existe y esta fresco

| dato | valor |
|---|---|
| `espn_event_id` | 401816813 |
| inicio | 2026-09-05 22:05 UTC (16:05 CDMX) |
| filas en `v_momios_confiables` | 117 |
| ultimo snapshot | 2026-09-05 21:15:03 UTC |
| `home_ml` / `away_ml` | 1.602 / 2.370 (DraftKings) |
| `devig_1x2` | local 59.7% / visita 40.3%, margen 4.62% |
| modelo (`predecir_mlb`) | PHI 47.8% |
| brecha | \|47.8 - 59.7\| = **11.9** — exactamente el numero del aviso |

`v_radar_mlb` tambien lo tiene: 25 filas, **0 sin `dec_home`**, y para este
partido `dec_home=1.602`, `dec_away=2.370`, `total_linea=8`,
`overround_ml=1.0462`.

### Los dos lectores de la tarjeta NO leen lo mismo

- **El aviso del modelo** lo pinta `PronosticoMlbModelo.tsx` con el RPC
  `predecir_mlb`, que lee `v_momios_confiables`.
- **El precio, el chip y el margen** los pinta `MLB.tsx` -> `desdeMlb()` ->
  `GameCard` / `buildMlbMeta` con la fila de **`v_radar_mlb`**.

`GameCard` imprime literalmente `"Margen de la casa: —"` cuando
`margenCasa(match.odds)` es null, o sea cuando `dec_home`/`dec_away` vienen
nulos. `ChipSinPrecio` sale cuando `hayMomio = (r.dec_home != null || r.mkt_home != null)`
es false.

### CAUSA RAIZ: `v_radar_mlb` invoca `predecir_mlb` dentro de la vista

Fragmento real de `pg_get_viewdef('public.v_radar_mlb')`:

```sql
LEFT JOIN LATERAL (
  SELECT (predecir_mlb(calc.espn_event_id) #>> '{prediccion,total_esperado}'::text[])::numeric
         AS total_modelo
) m2 ON true
```

Consecuencias medidas:

1. **Permisos.** `predecir_mlb(text)` tiene
   `postgres=X | service_role=X | authenticated=X`. **`anon` NO tiene EXECUTE.**
   Los privilegios de EXECUTE de una funcion se checan contra el rol que
   consulta, no contra el dueno de la vista, asi que la vista no lo blinda.

   - `set role anon; select count(*) from v_radar_mlb;` -> **25** (no evalua el LATERAL)
   - `set role anon; select count(carreras_esp) from v_radar_mlb;` -> **ERROR 42501: permission denied for function predecir_mlb**
   - `GET /rest/v1/v_radar_mlb?select=*` con llave publicable **y** con la anon legacy
     -> **HTTP 401**, cuerpo `{"code":"42501","message":"permission denied for function predecir_mlb"}`
   - `GET /rest/v1/v_radar_mlb?select=espn_event_id,dec_home,...` (columnas sueltas)
     -> **HTTP 200** con los precios correctos
   - `set role authenticated; select count(dec_home), count(carreras_esp) ...` -> 25 / 25

   La app llama `.select("*")`. Esa es exactamente la forma que falla.

2. **Costo.** La lista corre el modelo de MLB **una vez por partido**: 25
   llamadas a `predecir_mlb` en una sola consulta de cartelera. Medido en
   caliente: **3.057 s**. `statement_timeout` es **3 s para `anon`** y **8 s
   para `authenticated`**. Es decir: para `anon` ya esta por encima del techo
   aunque tuviera permiso, y para `authenticated` va a 3 s de 8 en el mejor caso.

### EL AMPLIFICADOR: `MLB.tsx` tira el error al piso

```ts
const { data } = await (supabase as any).from("v_radar_mlb").select("*");
let rows = (data ?? []) as RadarMlb[];
if (rows.length === 0) { /* respaldo desde live_scores */ }
```

`error` **no se lee**. Un 401 o un timeout es indistinguible de "hoy no hay
partidos": `data` llega null, `rows.length === 0`, y entra el respaldo que
arma la cartelera desde `live_scores` con **todos los precios en null**:

```ts
casa: null, dec_home: null, dec_away: null, total_linea: null,
dec_over: null, dec_under: null, mkt_home: null, mkt_away: null, ...
```

Verificado: `live_scores` SI tiene el 401816813 (`Philadelphia Phillies` /
`Atlanta Braves`, 22:05 UTC, `scheduled`) y **`anon` SI puede leerla**. Por eso
el partido aparece — sin precio, sin linea y sin margen.

**Huella que confirma que la tarjeta venia del respaldo:** la captura dice
"Carreras esperadas: 8.99" **sin** el "vs linea 8". Ese sufijo solo se pinta si
`lineaTotal != null`, y `total_linea` es 8 en `v_radar_mlb` y null en el
respaldo. La tarjeta se dibujo con la fila del respaldo.

El aviso del modelo sigue saliendo bien porque `PronosticoMlbModelo` monta al
expandir la tarjeta y va por el RPC, no por la vista.

**No esta probado cual de los dos disparos ocurrio en el navegador del
usuario** — la peticion salio como `anon` (sesion aun no restaurada al montar
el `useEffect`) o salio como `authenticated` y se paso de los 8 s. Los dos
caminos son consecuencia del mismo defecto estructural y los dos quedan
invisibles por el `error` descartado. Distinguirlos requiere el navegador, que
yo no puedo correr.

### La columna que rompe la pantalla no la usa la pantalla

- Consumidores de `v_radar_mlb` en la base: **cero** vistas y **cero**
  funciones.
- En el front, `carreras_esp` esta en la interfaz `RadarMlb` y en la firma de
  `buildMlbMeta`, pero **no se pinta en ningun lado**. `diff_total` se asigna a
  una variable `diff` en `buildMlbMeta` que nunca se usa. `SenalBadge` y
  `Pitcher` estan definidos en `MLB.tsx` y **no se renderizan**.
- Las "Carreras esperadas" que ve el usuario salen del RPC, con un comentario
  explicito en `desdeMlb`: *"Las carreras esperadas y la senal de total salen
  del modelo (`predecir_mlb`), no de la suma cruda"*.

**El LATERAL que tumba toda la cartelera de MLB alimenta una columna muerta.**

### ARREGLO MINIMO PROPUESTO (NO DESPLEGADO — requiere visto bueno)

1. **Sacar `predecir_mlb` de `v_radar_mlb`** (quitar el `LEFT JOIN LATERAL m2`
   y las columnas derivadas). La cartelera vuelve a ser dato puro: sin permiso
   de funcion, sin 25 corridas del modelo, sin techo de 3/8 s. La prediccion
   sigue viniendo del RPC por tarjeta, que es donde ya vive.
2. **`MLB.tsx`: dejar de descartar `error`.** Si la consulta falla, pintar
   estado de error, no una cartelera fabricada. El respaldo de `live_scores`
   debe entrar solo cuando de verdad no hay filas, nunca cuando hubo error.

**NO se propone** `grant execute ... to anon`: dejaria a un anonimo disparar 25
corridas del modelo por peticion y no arregla el costo.

**Riesgo de no arreglarlo:** la app ensena "SIN PRECIO" y "Margen de la casa: —"
sobre partidos que **si tienen precio**, en la misma tarjeta donde el aviso cita
ese precio. Es la app mintiendo sobre el mercado, no una falta de dato.

---

## #258-B HOTFIX MLB: primera puerta cerrada, SEGUNDA PUERTA descubierta

**Hecho (autorizado y aplicado):** `v_radar_mlb` ya no llama `predecir_mlb`
directamente. Se retiro el `LEFT JOIN LATERAL m2`.

**Contrato: IDENTICO.** 26 columnas, mismos nombres, mismos tipos, mismo orden.
`position('predecir_mlb' in pg_get_viewdef(...))` = **0**.

Se eligio la **opcion A** del auditor para `carreras_esp` y `diff_total`:
quedan como `NULL::numeric` deprecadas. Se descarto sustituirlas por la formula
L5 que ya vivia en el `COALESCE` porque **cambiaba las 25 filas**, con
diferencia media absoluta de **1.657 carreras** y maxima de **4.35**. Eso habria
sido meter un numero distinto bajo el mismo nombre: exactamente el defecto que
este hotfix corrige. Ninguna de las dos columnas tiene consumidor en base ni se
pinta en el front. Queda `COMMENT ON VIEW` con la prohibicion de reintroducirlo.

**NO se concedio `EXECUTE ... TO anon` sobre `predecir_mlb`.** Verificado:
`proacl = postgres=X | service_role=X | authenticated=X`. Sin cambios.

### SEGUNDA PUERTA (hallazgo nuevo, NO tocada)

Tras el arreglo, `select=*` como `anon` **sigue devolviendo 401 / 42501
permission denied for function predecir_mlb**. Cadena medida:

```
v_radar_mlb
  -> LEFT JOIN LATERAL m  (columnas mod_home / mod_away / mod_over)
      -> v_pick_canonico
          -> v_picks_mlb_modelo
              -> predecir_mlb()
```

Comprobacion aislada como `anon`:
- `select count(dec_home), count(overround_ml) from v_radar_mlb` -> **25 / 25 OK**
- `select count(mod_home) from v_radar_mlb` -> **ERROR 42501**

O sea: **el precio ya viaja; lo que rompe es la probabilidad del modelo.**

**Costo real, peor de lo reportado antes.** `EXPLAIN ANALYZE select * from
v_radar_mlb`: **4,279 ms** (planning 35 ms). El plan muestra que
`v_picks_mlb_modelo` evalua un CTE sobre `agenda_espn` de **61 eventos de
baseball**, no 25: la cartelera dispara ~61 corridas del modelo, no una por
partido mostrado.

`mod_home/mod_away/mod_over` **SI se consumen**: 29 de 29 filas los traen, y
`desdeMlb` los mapea a `model.home/away/over`, que `GameCard` pinta como el
"% modelo" de cada equipo y que `mejorVentaja` usa para el badge
"Ventaja del modelo · +X% EV". Quitarlos NO es neutral: borra numero de
pantalla en una tarjeta de dinero.

**Opciones (ninguna ejecutada, todas cruzan una linea que el auditor trazo):**
- **A.** Quitar `m` de `v_radar_mlb` -> cartelera 100% dato puro y anon-safe,
  pero desaparecen el "% modelo" y el badge de ventaja de cada tarjeta de MLB.
- **B.** Tocar `v_picks_mlb_modelo` / `v_pick_canonico` -> zona prohibida
  (V2 / logica de picks / riesgo conocido de recursion 42P17).
- **C.** Materializar la prediccion MLB en tabla + cron; la vista lee la tabla.
  No pierde pantalla y no edita logica de picks, pero es infraestructura nueva
  y exige politica de frescura.
- **D.** `grant execute to anon` -> **prohibido explicitamente**.

### FIX 2 (frontend) enviado a Lovable

`src/pages/MLB.tsx` pasa de `data ?? []` a tres estados: exito con filas ->
radar; exito con 0 filas -> unico caso que permite el respaldo de `live_scores`;
error -> `ErrorCarga` reintentable y **prohibido** caer al respaldo. Las filas
del respaldo se marcan `source = "live_scores_fallback"`. Esto mata la mentira
"SIN PRECIO" con independencia de cual opcion se elija arriba.

---

## #259 BLOQUE A ECONOMICO: los bounds matan apuestas GANADORAS, y el sesgo solo sirve en Corners

**Reconstruccion verificada.** Se rehizo el walk-forward estricto en la tabla de
laboratorio `public.lab_bloque_a_wf` (24,618 filas). Brier reproducido contra lo
ya aceptado: A 0.22362 (antes 0.22343), B 0.22169 (antes 0.22151), H 0.23067
(antes 0.23051). Delta <= 2e-4; H sigue **7o de 8**. Orden completo:
**B < A < F < E < D < C < H < G**.

### BLOQUEO METODOLOGICO: no existe el momio historico

`modelo_backtest` **no tiene columna de precio**. Cobertura medida de las 1,550
fixtures del walk-forward:

| fuente | fixtures cubiertas |
|---|---|
| `radar_odds_snapshots` (via puente ESPN) | 81 |
| `fut_odds_history` (por `fixture_id`) | 82 |
| `odds_pro_snapshots` (por `fixture_id`) | 36 |
| `futbol_5ligas_2526` (cierre, via puente ESPN) | **0** |

Maximo **5.3%**, y concentrado en el tramo reciente (la ingesta de momios es
nueva): usarlo seria sesgo de seleccion puro. **A-ECO-1/2/6 tal como estan
escritos NO son computables con dato real.** Se sustituyo por un barrido de
6 precios sinteticos, y se reporta lo que ese barrido SI puede decir.

**Ademas, el ROI del barrido no informa nada.** Con precio plano fijo `q`,
`ROI = hit x q - 1`: es una reescala monotona del hit rate. Los ROI de +117%
a cuota 4.00 son artefacto del precio inventado, no economia. Se descartan.

### ESTRUCTURA DE LA MUESTRA (hallazgo que cambia la lectura)

`modelo_backtest` **no es un registro de apuestas: es una rejilla de resultados
enumerados**. Filas por fixture y aciertos por fixture, exactos:

| mercado | filas/fixture | aciertos/fixture |
|---|---|---|
| Moneyline | 3.000 | **1.000** |
| Corners | 8.000 | **4.000** |
| Tarjetas | 6.000 | **3.000** |
| Total Equipo | 3.000 | 1.872 |
| Over/Under | 5.000 | 2.723 |
| Doble Oportunidad | 2.000 | 1.241 |
| BTTS | 1.000 | 0.511 |

Es la poblacion correcta para medir CALIBRACION. No es una poblacion de
apuestas tomadas.

### A-ECO-1 — cuantos mata cada bound (barrido de precio)

Filas con EV>0 sobre 24,618. `pos->neg` respecto de A:

| cuota | A | B | E (=B+Beta) | H (produccion) | mata Beta (B->E) | mata Wilson (E->H) |
|---|---|---|---|---|---|---|
| 1.50 | 7,115 | 6,435 | 4,931 | 3,866 | 1,504 | 1,065 |
| 1.80 | 11,062 | 10,981 | 8,891 | 7,406 | 2,090 | 1,485 |
| 2.00 | 13,208 | 13,593 | 11,407 | 9,392 | 2,186 | 2,015 |
| 2.50 | 17,260 | 17,785 | 15,884 | 13,856 | 1,901 | 2,028 |
| 3.00 | 19,377 | 19,650 | 18,098 | 16,645 | 1,552 | 1,453 |
| 4.00 | 22,435 | 22,739 | 21,023 | 19,509 | 1,716 | 1,514 |

H mata entre **2,569 y 4,186** candidatos respecto de B segun el precio.

### A-ECO-3 — LA PREGUNTA CENTRAL: los que matan, ¿eran peores?

Grupos formados sobre B (mejor variante probabilistica). `gap` = hit real - P
previa de B.

| cuota | grupo | N | P previa B | hit real | gap | Brier previo | breakeven |
|---|---|---|---|---|---|---|---|
| 1.80 | SURVIVE_BETA | 8,891 | 72.34% | 70.24% | -2.11 | 0.20637 | 55.56% |
| 1.80 | **KILLED_BY_BETA** | 2,090 | 58.63% | **57.51%** | -1.12 | 0.24428 | **55.56%** |
| 1.80 | **KILLED_BY_WILSON** | 1,485 | 64.71% | **63.64%** | -1.07 | 0.22973 | **55.56%** |
| 2.00 | SURVIVE_BETA | 11,407 | 69.05% | 67.17% | -1.88 | 0.21494 | 50.00% |
| 2.00 | **KILLED_BY_BETA** | 2,186 | 53.14% | **54.03%** | **+0.89** | 0.24905 | **50.00%** |
| 2.00 | **KILLED_BY_WILSON** | 2,015 | 58.87% | **57.42%** | -1.45 | 0.24377 | **50.00%** |
| 2.50 | SURVIVE_BETA | 15,884 | 63.61% | 62.23% | -1.38 | 0.22447 | 40.00% |
| 2.50 | **KILLED_BY_BETA** | 1,901 | 43.81% | **44.50%** | **+0.70** | 0.24588 | **40.00%** |
| 2.50 | **KILLED_BY_WILSON** | 2,028 | 49.07% | **48.37%** | -0.70 | 0.24735 | **40.00%** |

**En los 6 grupos eliminados, el hit real queda POR ENCIMA del breakeven del
precio al que se eliminaron.** Beta y Wilson no estan cortando apuestas
perdedoras: estan cortando apuestas ganadoras.

Peor: a cuotas 2.00 y 2.50, el grupo que Beta mata tiene gap **POSITIVO**
(+0.89 y +0.70: el modelo los SUBESTIMABA) mientras el grupo que sobrevive
tiene gap negativo (-1.88 y -1.38: los SOBREESTIMABA). **Beta aplica su
correccion a la baja justo donde el modelo ya iba corto, y conserva el segmento
donde va largo.** Va al reves.

Es cierto que el grupo eliminado tiene peor Brier previo (0.249 vs 0.215): son
predicciones de menor calidad. Pero "menor calidad" no es "expectativa
negativa": a los precios probados siguen por encima del breakeven.

### A-ECO-5 — POR MERCADO: el sesgo global es un espejismo de Corners

Delta de Brier x1000, negativo = mejora. t pareado.

| mercado | N | sesgo x1000 | t | Beta x1000 | t | Wilson x1000 | t |
|---|---|---|---|---|---|---|---|
| Over/Under | 6,775 | **+0.495** | +1.68 | +1.944 | +3.91 | +4.790 | +11.12 |
| Moneyline | 4,065 | -0.250 | -0.93 | +2.102 | +3.19 | +4.362 | +8.38 |
| Total Equipo | 4,065 | **+0.361** | +1.14 | +2.288 | +3.05 | +6.336 | +9.58 |
| **Corners** | 3,272 | **-15.810** | **-6.95** | +3.872 | +3.39 | +6.642 | +7.03 |
| Doble Oportunidad | 2,710 | -0.309 | -0.82 | +2.477 | +2.54 | +7.025 | +7.98 |
| Tarjetas | 2,376 | **+1.124** | +1.41 | +4.678 | +3.32 | +8.716 | +7.49 |
| BTTS | 1,355 | -0.975 | -0.52 | +5.172 | +2.52 | +11.183 | +6.68 |
| **TOTAL** | 24,618 | -1.926 | -5.51 | +2.783 | +8.33 | +6.198 | +21.94 |

**Corners aporta -15.810 x 3272/24618 = -2.10 x1000, mas que TODA la mejora
global (-1.926).** Sin Corners, `v_sesgo` no mejora nada; en los tres mercados
de mayor volumen el efecto es de +-0.5 x1000 y en dos de tres va en contra.

**Confundidor a vigilar:** Corners es justo la rejilla simetrica perfecta
(8 filas / 4 aciertos exactos por fixture, prob media 0.5000, bias 0.00). La
ganancia del sesgo ahi puede ser artefacto de la complementariedad determinista
de la rejilla, no habilidad transferible. **NO se declara SOPORTADA_OOS.**

Beta y Wilson: **empeoran en los 7 mercados, sin excepcion**, con t entre
+2.52 y +11.18.

Sesgo de produccion H por mercado: **+6.29 a +11.68 pp** de subestimacion
sistematica. En todos.

### CLASIFICACION POR MERCADO

| mercado | v_sesgo | Beta | Wilson |
|---|---|---|---|
| Over/Under | NO_APORTA_OOS | DANINA_OOS | DANINA_OOS |
| Moneyline | NO_APORTA_OOS | DANINA_OOS | DANINA_OOS |
| Total Equipo | NO_APORTA_OOS | DANINA_OOS | DANINA_OOS |
| Corners | SOPORTADA_OOS_CON_CONFUNDIDOR_DE_REJILLA | DANINA_OOS | DANINA_OOS |
| Doble Oportunidad | INCONCLUSO_MUESTRA | DANINA_OOS | DANINA_OOS |
| Tarjetas | NO_APORTA_OOS | DANINA_OOS | DANINA_OOS |
| BTTS | INCONCLUSO_MUESTRA | DANINA_OOS | DANINA_OOS |

`v_sesgo` global baja de `SOPORTADA_OOS_GLOBAL_SOCCER_PROVISIONAL` a
**`NO_SOPORTADA_FUERA_DE_CORNERS`**.

### RESPUESTA A LAS DOS PREGUNTAS DEL BLOQUE A

1. **¿Beta o Wilson mejoran la seleccion economica OOS aunque empeoren la
   probabilidad?** **NO.** A los 3 precios probados, todo grupo que eliminan
   tiene hit real por encima del breakeven. Empeoran probabilidad Y seleccion.

2. **¿Su efecto parece calibracion o politica de abstencion/riesgo?** **Ninguna
   de las dos.** Como calibracion van al reves del signo del error (corrigen a
   la baja donde el modelo ya subestima). Como abstencion serian defendibles si
   recortaran cola perdedora, y no lo hacen: recortan por encima del breakeven.
   Lo que hacen es **reducir volumen de forma no informativa**.

**Conclusion: caso A del auditor** — empeoran probabilidad y economia. Beta y
Wilson son candidatos fuertes a salir de V2. **NO SE TOCA PRODUCCION.**

### LO QUE FALTA Y POR QUE

- **A-ECO-2 y A-ECO-6 (Kelly) quedan ABIERTOS por falta de precio historico.**
  No se simulan con precio inventado.
- **A-ECO-4** queda cubierto parcialmente (mercado + tramo de probabilidad via
  las celdas + precio via el barrido). Falta estratificar por `n` de celda.
- **Desbloqueo propuesto:** empezar a persistir el momio del mercado junto a
  cada fila de backtest desde hoy, para que dentro de N semanas exista una
  poblacion con precio real. Sin eso, la pregunta economica es estructuralmente
  incontestable, no dificil.
