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
