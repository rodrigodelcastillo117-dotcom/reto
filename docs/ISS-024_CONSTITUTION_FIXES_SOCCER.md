# ISS-024 — Correcciones de Constitución (audit externo #2) sobre fútbol V2

Respuesta al 2º audit externo (FAIL P0). El fallo clave: MARKET_ANCHORED NUNCA puede ser P_RETO; momios = contexto, no cerebro. Corregido en prod `wpiztubmmmzclhlprgpd`.

## Cambios aplicados
1. **market_anchored ELIMINADO como P_RETO.** El builder ya NO usa momios para construir P_RETO. Barcelona–Feyenoord, PSG–Slovan, Stuttgart–Viking (Champions) → **P_RETO NULL / fail-closed**. Momios quedan solo como CONTEXTO (`odds_*`, etiquetados "no es P_RETO").
2. **Competencia exacta del evento:** el modelo usa `agenda_espn.liga_id` del evento (Champions=2, LaLiga=140, LigaMX=262…) y toma las tasas de goles de esa MISMA competencia — ya NO auto-selecciona la liga con más partidos del equipo.
3. **`v2.model_registry` (candado de publicación):** solo (modelo, versión, liga_id) allowlisted publican P_RETO. Aprobadas: ligas domésticas (LaLiga, LigaMX, MLS, Premier, Serie A, Bundesliga, Ligue 1, Eredivisie, Liga Portugal, Saudi, Süper Lig). **Champions/Europa/AFC/copas NO aprobadas → fail-closed** hasta tener modelo de régimen validado.
4. **Temporal-safe por diseño:** builder solo procesa `kickoff > now()`; odds `snapshot_at <= now()`; no reconstrucción post-kickoff (tabla inmutable/versionada; live/final reusa el último snapshot pregame).
5. **Mejor pick sin momios ≤1.20:** el "mejor pick" se elige entre mercados con prob ≤83.3% (momio justo ≥1.20) y ≥45%. Ej.: Galatasaray −1.5 (73.8%) en vez del ML a 89.7%. Incluye handicap asiático, doble oportunidad, O/U — todo de la misma distribución.
6. **Mercados derivados** de la MISMA distribución: 1X2, marcador (argmax) + distribución, BTTS, O/U (línea real), handicap asiático (−1.5/−1/+1.5), doble oportunidad, portería a cero. Factuales: goles a favor/en contra por juego (local/visita), %BTTS.
7. Vista publica **solo READY_UNVALIDATED** (modelo propio aprobado). Nunca READY_NO_EDGE/mercado.

## Evidencia (prod)
- 162 partidos READY (domésticos aprobados, modelo propio), 59 fail-closed (Champions/cruces/insuficiente).
- Champions: PSG/Stuttgart/Barça–Feyenoord = DATA_INCOMPLETE (P_RETO NULL). ✅
- Domésticos: América 86.1% (LigaMX), Atlanta 55.9% (MLS). ✅
- Mejor pick: 0 con momio <1.20.

## Pendiente (frontend, próximo build) — puntos del auditor
- Quitar `mejor_oportunidad_hoy`, EV/Kelly como recomendación, probabilidades live en cliente, `analizar-partido`/`analisis_partidos` legacy, rutas predictivas legacy; restaurar el MENÚ (popup) en bottom nav; alinear el adapter a los nombres nuevos del contrato; fail-closed en componentes predictivos no migrados.
- Análisis rico: forma W/E/L, H2H, lesiones, alineaciones desde fuentes factuales limpias con provenance.
- Regla ESPN: el pipeline de momios es The Odds API (DraftKings/pinnacle); ESPN no expone momios propios — el momio se muestra como contexto etiquetado con la casa.

MARKET_ANCHORED como P_RETO: **eliminado.** No se avanza a MLB hasta que el auditor apruebe.
