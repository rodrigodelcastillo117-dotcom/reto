# Cobertura de fútbol por demanda (odds solo donde hay picks)

Fecha: 2026-11-09. Gatillo: "mejora cobertura — más ligas, dentro de la cuota gratis". DINERO OFF.

## El problema honesto de cuota
OddsAPI (tier gratis 500/mes) marcaba **142 créditos restantes** este mes. El job de fútbol gastaba
11 keys fijas/día (~330/mes) — y agregar ligas a lo bruto nos dejaba sin cuota antes de fin de mes.
Además 1 de esas 11 (`soccer_spl`, Escocia) **no la cubre el motor** → crédito desperdiciado a diario,
y en descanso FIFA se pagaban 11 ligas de clubes que ni juegan.

## La solución: ingestión POR DEMANDA (coverage ↑, cuota ↓)
`ingestar-odds-multicasa` ahora acepta `{"soccer_auto":true,"dias":N}`:
- Lee las ligas de los **picks publicables próximos** (`v_reto_soccer_pick_v1`, próximos N días).
- Las traduce a keys de OddsAPI con un mapa liga→key (22 ligas del motor) + selecciones activas.
- **Solo gasta un crédito por liga que de verdad tiene picks.** Ligas sin momios o sin juego = 0 gasto.
- Si aparece una liga sin mapear, la reporta en `ligas_sin_key` (así se detectan huecos sin romper nada).

Efecto:
- **Descanso FIFA (hoy):** gastó **1 key** (`nations_league`) en vez de 11. Banca créditos.
- **Cuando los clubes vuelven:** se expande solo a las ligas con picks (Premier, LaLiga, Serie A,
  Bundesliga, Ligue 1, Eredivisie, Liga MX, **Portugal, Turquía, Brasil, Argentina, MLS, Bélgica,
  Conference League, Libertadores, Sudamericana, Noruega, Suecia, Saudí…**) — muchas más que antes,
  pero pagando solo lo que se juega.
- El anclaje a mercado del email cubre automáticamente las nuevas ligas (empareja por nombre de equipo).

## Cambios
- `ingestar-odds-multicasa` v4: modo `soccer_auto` + mapa `LIGA_ODDSAPI` (22 ligas) + `regions=eu`.
- Cron `ingestar-odds-soccer-am` (jobid 599) ahora manda `{"soccer_auto":true,"dias":4}` en vez de
  la lista fija de 11. Se eliminó el desperdicio de Escocia y de ligas en descanso.

## Validación
Corrida de prueba en ventana FIFA: eligió `soccer_uefa_nations_league` (1 key, 27 eventos, 381 filas),
detectó `Eliteserien` como liga sin mapear → se agregó al mapa. Mecanismo confirmado.

## Siguiente
Cuando termine el descanso FIFA (medir ~17 nov), revisar qué ligas elige el modo auto y si alguna
liga con picks sigue en `ligas_sin_key` para sumarla al mapa.
