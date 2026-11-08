# Tres mejoras pedidas: line shopping, valor NFL, alertas de bajas (+ fix de contaminación)

Fecha: 2026-11-08. Gatillo del dueño: "haz las 3 que propones" (line shopping, alertas de info, especializar NFL).
También: "apaga la vigilancia diaria MLB" → hecho (trigger `trig_0124mKEihJSziYzEfGavoZ7x` deshabilitado, no borrado; conserva historial, reactivable la próxima temporada).

## Feature 1 — Line shopping: BLOQUEADO sin API de pago (reportado, NO inventado)
Auditoría de fuentes de momios vivas (solo lectura):
- `reto_odds_espn_v1` (ESPN) — VIVA, pero **una sola casa** (proveedor ESPN). Imposible comparar precios.
- `radar_odds_snapshots` — VIVA (483k filas) pero **solo DraftKings** (1 casa) y solo totales/spreads, no moneyline.
- `odds_pro_snapshots` (multi-casa 1X2, Pinnacle + mejor casa) — **MUERTA** desde jul–sep 2026 (la alimentaba la API de pago que dejamos).
- `momios_mercado`, `nfl_prop_line_snapshots` — muertas/vacías.
Conclusión honesta: **line shopping real (comparar varias casas) requiere un feed de pago** (OddsAPI, ~$30–100+/mes). No se finge un comparador con una sola casa. Decisión del dueño pendiente.

## Feature 3 — Valor NFL: `v_reto_nfl_valor_v1` (construida)
NFL es el único mercado que le gana al cierre de forma comprobada (Brier modelo < mercado, mejor CLV).
La vista cruza `v_nfl_publication_v1` (prob del modelo, READY/OOS) con el devig de mercado
(`reto_odds_espn_v1` ml decimal; fallback DraftKings de la publicación) y calcula la **ventaja en puntos
de probabilidad** (modelo − mercado). DINERO OFF (brecha de probabilidad, no EV/Kelly).
**Guardas de honestidad (clave):**
- `edad_linea_h` por fila; una línea > 36 h se marca `LÍNEA VIEJA` (no confiable).
- Brecha ≥ 10 pp → `REVISAR` (línea rancia/blanda o error, no "valor"): evita falsos "+34pp".
- 3–10 pp → `VALOR`; −2..3 → `JUSTO`; < −2 → `SIN VALOR`.
Resultado real: con líneas frescas casi todo sale JUSTO/SIN VALOR (el modelo coincide con el mercado,
como esperábamos); los valores reales son chicos y escasos. Eso es lo honesto.

## Feature 2 — Alertas de bajas: fix de raíz + `v_reto_alertas_bajas_v1`
**Bug encontrado (grave):** `v_reto_lesiones_partido_v1` mezclaba jugadores entre deportes. Causa raíz en
`lesiones_v1`: ESPN reutiliza `team_espn_id` entre deportes (p.ej. id 8 = Detroit Pistons NBA **y**
Milwaukee Brewers MLB) y la ingesta etiquetó a algunos equipos con el `espn_endpoint` equivocado. El join
de la vista solo usaba `espn_endpoint + team_espn_id`, insuficiente. Efecto: el email diario mostraba
conteos de bajas **inflados y con jugadores de otro deporte** (béisbol en juegos NBA, NFL en juegos NHL).
**Fix:** `v_reto_lesiones_partido_v1` ahora también matchea por `team_nombre` (que sí viene correcto), y
excluye status `Active` de la lista. Verificado: Pistons 5→2 bajas (solo reales), Winnipeg sin jugadores NFL.
Esto **corrige automáticamente** `titulares_fuera`/`alerta_lesion` en `v_reto_mejores_picks_v1` y en el email.
**Nueva vista `v_reto_alertas_bajas_v1`:** por juego próximo (48 h) y por equipo, cuenta y lista las ausencias
**confirmadas** (Out / Injured Reserve) con nombre y posición. Sin "score de impacto" inventado.

## Email diario (`mejores-picks-diario` v2)
Se añadieron dos secciones money-free al correo de rodelcast:
- 🏈 **Valor NFL** (próx. 4 días, solo `VALOR` con línea fresca ≤ 36 h). Si no hay señal, no se muestra (honesto).
- ⚠️ **Bajas confirmadas** (top 6 de los juegos del día, datos ya limpios).
Prueba: HTTP 200, Resend 200, 7 picks, 6 bajas, 0 valor NFL (correcto hoy). Cron 7am sin cambios.

## Pendiente de decisión del dueño
- Line shopping real → requiere feed de pago. ¿Lo autorizas o lo dejamos sin comparador?
