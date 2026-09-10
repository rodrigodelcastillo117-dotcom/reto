# CROSS-SPORT ANALYSIS PARITY — SOCCER / MLB / NFL

Main cards may remain sport-specific. The modal/drawer opened by `Ver análisis` must share the same information hierarchy:

1. event header: league/sport, exact event identity, teams/logos, kickoff/status
2. RETO hero
3. probability visualization
   - Soccer: Home/Draw/Away canonical 1X2
   - MLB: Home/Away canonical winner P_RETO
   - NFL: Home/Away canonical winner P_RETO only after own-model validation; disabled shell before that
4. expected scoring summary only from canonical backend model outputs
5. accordions in shared order:
   - Qué mueve la predicción
   - Forma y rendimiento
   - Matchup profundo
   - Alineaciones y disponibilidad
   - H2H y tendencias
   - Estadio, clima y viaje
   - Mercados y movimiento de línea
   - Riesgos e incertidumbre
   - Conclusión
   - De dónde salen los números

Every field shown must carry truthful provenance/as-of semantics. Market lines are context. Missing real data is explicit. Same event ID must hydrate the same dossier from every surface.
