# Mejoras reales y gratis — guarda de muestra chica en acierto histórico

Fecha: 2026-11-03. El usuario pidió "mejoras reales que no cuesten". Primera aplicada.

## Guarda de muestra chica (honestidad, additivo)
`v_reto_mejores_picks_v1.acierto_historico_pct` mostraba un % aunque el tramo tuviera
muy pocos partidos calificados (ej. NFL CONFIABLE 33.3% sobre **9** juegos, puro ruido).
Fix: el % solo se muestra si el tramo tiene **≥20** partidos calificados; si no, NULL.
Se agrega columna `muestra_historica` (n) para transparencia (el front puede mostrar
"(253 partidos)").
Resultado verificado:
- NBA/NHL: NULL (sin historial) — honesto.
- NFL: NULL con n=9/9/11 visible (muy poco para un %).
- Soccer: 82.6% (n=23) / 61.7% (253) / 61.3% (331).
- Tenis: 80.0% (65) / 54.8% (62) / 49.0% (51).

## Hallazgos para seguir (medidos, no inventados)
- Contexto de LESIONES llega a 0/187 partidos de fútbol próximos (la vista tiene 68 filas
  pero de Liga MX/NFL, no empata con los eventos de fútbol próximos). Posible bug de
  empate o cobertura; revisar.
- `narrative` ("por qué") vacío en los 187 READY de fútbol.
- Advisors de seguridad/rendimiento: en análisis (subagente) para sacar índices faltantes
  y lints seguros.
