# Tendencias recientes U5/U10 (contexto descriptivo, NO predictivo)

Fecha: 2026-11-03. El usuario preguntó si con los últimos 5-10 partidos se puede generar
más info. Respuesta honesta en dos partes:

1. PARA PREDECIR (cambiar el pick): NO. El backtest de esta sesión ya probó que la
   recencia (U5/U10) EMPEORA las predicciones vs la temporada completa (fútbol 1X2 y BTTS).
   No se toca el modelo con recencia. (ver SOCCER_FORMA_BACKTEST_Y_H2H_V1.md)
2. PARA CONTEXTO (que el usuario lea): SÍ, gratis, aditivo. Más dimensiones de cómo vienen.

## Construido
`public.v_reto_tendencias_recientes_v1` (contexto, solo lectura, grant anon): por cada
partido de fútbol próximo (v3), por equipo (home/away) y ventana (U5, U10), desde
`historico_partidos_espn` por ID de equipo fijado a su liga doméstica actual
(mismo patrón anti-colisión que la forma): record (G-E-P), goles a favor/juego,
goles en contra/juego, % over 2.5, % ambos anotan, % portería a cero, % no anotó.
Cobertura: 263 partidos, 1034 filas.

Ej. PSV vs Club Brugge (U10): PSV 7-1-2, 3.30 GF, 1.10 GA, 80% over, 80% BTTS, 20% CS,
0% no anotó; Brugge 9-0-1, 2.60 GF, 0.80 GA, 80% over, 50% BTTS, 50% CS, 0% no anotó.

## Honesto
Es contexto para leer, NO alimenta el pick (que sigue validado sin recencia). Dinero OFF.
Falta render en Lovable (cambio chico) para mostrarlo en la tarjeta del partido.
