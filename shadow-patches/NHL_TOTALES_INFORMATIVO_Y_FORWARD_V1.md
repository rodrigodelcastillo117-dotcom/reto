# NHL totales (goles): vista informativa + arnés forward vs línea real

Fecha: 2026-11-03. Palanca "nuevos mercados bien ganados". NHL no tenía modelo de totales
vivo (la vista de mercados NHL solo trae Ganador). Se construye el mercado de la forma
HONESTA: informativo primero, y solo pasará a pick si le gana a la línea real OOS.

## Construido
- **`public.v_reto_nhl_totales_v1`** (INFORMATIVA, espejo de NBA): goles esperados por
  promedio rodante de goles a favor/en contra (últimos 20 juegos por `espn_id`, mín 10,
  endpoint `hockey/nhl`, 5,967 juegos de historia). Expuesto: `total_esperado`, `linea`
  (real ESPN de `reto_lineas_totales` cuando existe), `lado` (MÁS/MENOS/EN LÍNEA con
  umbral ±0.75 gol), `pick_titulo` honesto, `diferencia_vs_linea`, `linea_fuente='ESPN'`,
  `informativo=true`, y **`pick_prob_pct = NULL`** (nunca pick de confianza).
  57 partidos próximos; 0 con prob; línea real llega conforme se acercan los juegos.
- **Arnés forward** extendido a NHL: `reto_totales_forward_capturar_grade_v1()` ahora
  captura/refresca NBA **y** NHL (congela línea de cierre + lean del modelo) y califica
  contra el total final (NBA=basketball/nba, NHL=hockey/nhl). El cron
  `reto-totales-forward-v1` (9,29,49) ya lo corre.
- **`v_reto_totales_forward_resumen_v1`** ya reporta ambos deportes con el gate
  pre-registrado (n≥100 decididos y IC95 inferior > 50% para "le gana a la línea real").
  Hoy: nba y nhl en MUESTRA_INSUFICIENTE, acumulando.

## Honesto
Igual que NBA/MLB: el total NHL es contexto informativo hasta que el arnés demuestre,
OOS contra la línea real de casa, que el modelo le gana — y entonces, con sign-off.
Si nunca le gana, se queda informativo. No se publica como pick, no entra al récord,
dinero OFF. No toca modelo/gate de otros deportes.
