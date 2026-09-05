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

1. **Oráculo: `limpieza-nocturna` borra el marcador antes de calificar (#181).**
   MEDIDO: 185 picks sin calificar; 59 ya jugados; **42 sin fila en `live_scores`**
   (borrada) y 6 con marcador final disponible que nadie calificó.
   Causa: `DELETE FROM live_scores WHERE status IN ('post','final') AND updated_at <
   now() - interval '72 hours'` (cron 32, 11:00 UTC). Un pick no calificado en 72h
   pierde su marcador para siempre. Es pérdida de datos irreversible.

2. **404 de ESPN: ni registro ni evasión.**
   MEDIDO: 235 respuestas 404 en 2 horas = **13.5% de todo el tráfico saliente**.
   El 100% cae en minuto ≡ 0 mod 10 → cron `futbol-jugadores-pedir` (`*/10`,
   `futbol_jugador_pedir(60)`): 35-45 de cada 60 peticiones son 404. Nada registra
   qué id murió, así que se reintenta el mismo id para siempre (~6,500 llamadas
   desperdiciadas al día).

3. **RETO 13M: 5 de los 7 motivos de bloqueo no tienen insignia.**
   `bloqueado_por` devuelve `abstencion | sin_datos | rongol | kelly | ev_negativo |
   bajo_minimo | exposicion`. La UI solo pinta insignia para `rongol` y `exposicion`.
   Hoy 14 de 16 picks caen en "descartado" y el usuario ve un muro sin taxonomía.
   (Hueco que yo mismo dejé al desplegar A8/A9 — entra por la Regla 360°.)

---

## C. ABIERTAS — SIGUIENTES (por prioridad, con su número histórico)

4.  **#193** MLB Over/Under: el 0.55 hardcodeado le gana al motor Poisson. Extirpar el
    fallback en `analizar-partido` (239,475 chars; requiere reenvío del archivo completo
    y hay riesgo de que `deploy_edge_function` voltee `verify_jwt`). El veto de mercado
    ya cubre el riesgo de dinero.
5.  **#191** El skill negativo es falta de información, no de calibración. Platt no sirve
    (0.66 sigmas). Pendiente: decidir si Moneyline se apaga como Over/Under.
6.  **#202** El torniquete de #201 cubre 1 de 7 puertas: `v_analisis_fut_completo` sigue
    mostrando picks con muestra insuficiente. `[SIN MEDIR HOY]`
7.  **#176** `calibracion_isotonica`: techo aplastado en 45-51%, alimenta 3 funciones vivas.
8.  **#182** RETO 13M: piso de muestra en el origen + el reloj que valía Infinity.
9.  **#158** El chip GANA de MLB enseñaba la probabilidad previa con el partido en vivo.
10. **#159** Causa raíz de la cartelera de MLB: tres filtros en `v_radar_mlb`.
11. **#120** Tenis: 112 de 163 partidos de ATP con marcador imposible.
12. **#205** Partidos fantasma: nadie relee la fecha cuando ESPN reprograma.
13. **#206** Los dos motores de fútbol discrepan 17.6 pp y nada mide cuál acierta.
14. **#175** El bucle nocturno ya existe: 14 crons de aprendizaje sin coordinar.
15. **#200** Residuales de #179/#180: pisos de muestra y el veto blando de Uruguay.
16. **#169** Calibración sobre picks publicados: primero descartar el confundidor.
17. **#174** MLB: Poisson sobredisperso 2.36x (mercado vetado). Fútbol limpio (1.025).
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

## D. HALLAZGOS NUEVOS (se anotan aquí sin desviarse)
