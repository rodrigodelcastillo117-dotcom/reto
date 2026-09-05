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
12. **#205** Partidos fantasma: nadie relee la fecha cuando ESPN reprograma.
13. **#206** Los dos motores de fútbol discrepan 17.6 pp y nada mide cuál acierta.
14. **#175** El bucle nocturno ya existe: 14 crons de aprendizaje sin coordinar.
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

