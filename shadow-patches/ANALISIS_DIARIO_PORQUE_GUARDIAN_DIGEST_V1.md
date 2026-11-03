# Análisis diario: "por qué" honesto + guardián de completitud + digest

Fecha: 2026-11-03. El usuario pidió lo mejor para que el análisis diario salga automático
y lo más completo posible. Tres piezas backend, honestas (solo datos reales), additivas,
sin tocar modelos/gates. Dinero OFF.

## 1. "Por qué" honesto por pick — `v_reto_analisis_del_dia_v1`
Por cada juego próximo (48h) de todos los deportes: pick, prob, nivel de confianza,
`publicable` (bool), `razon` (texto armado SOLO de datos reales ya calculados) y
`contexto` (jsonb). Ejemplos reales:
- Soccer: "Ambos anotan · 68% · Forma: PSV 5-1-2, Club Brugge 7-0-1" (+ H2H si hay).
- NBA: "Gana Boston Celtics · 87% · bajas 2 · total modelo 226.3".
- NHL: "Gana Florida Panthers · 67% · bajas 8 · total modelo 6.43".
- Sin pick: "Sin pick — DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF" (honesto, no inventa).
Nada de LLM ni texto inventado: concatena forma, H2H, lesiones, ventaja y % reales.

## 2. Guardián de completitud — `v_reto_slate_completitud_v1` + `reto_slate_guardian_v1()`
- Vista: por deporte en las próximas 36h, cuántos juegos, con pick publicable, soccer con
  forma (x/total), y línea real (x/total aplica NBA/NHL).
- Función `reto_slate_guardian_v1()` (SECURITY DEFINER, revocada de PUBLIC): empuja el
  ingest de líneas (ventana 3 días), corre la captura de picks y el arnés forward, y
  devuelve el readiness en jsonb. Crons: `reto-slate-guardian-am` (07:37 CDMX) y
  `reto-slate-guardian-pm` (13:07 CDMX). Red de seguridad: nada se queda sin llenar.

## 3. Digest del día — `v_reto_digest_dia_v1`
Por deporte (juegos de HOY CDMX): picks publicables, juegos cerrados (volados a evitar),
juegos con bajas altas (≥6), y el mejor pick del deporte (partido, pick, prob, nivel,
razón). Para una tarjeta "resumen del día".

Grants SELECT a anon/authenticated en las 3 vistas (la app las lee). Falta el render en
Lovable (cambio chico) para que el "por qué" y el digest se vean en la app.
