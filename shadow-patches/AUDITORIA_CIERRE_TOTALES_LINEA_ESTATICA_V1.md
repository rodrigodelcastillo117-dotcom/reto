# Auditoría de cierre: barrido de picks que solo le ganan a una línea estática

Fecha: 2026-11-03. Gatillo: el usuario pidió "sigue con la auditoría de cierre, empieza
por tenis O/U, y todo lo necesario". Principio rector (del usuario): nada publicado como
pick con % de confianza puede estar validado solo contra una línea estática/mediana —
esa es la MISMA falla que ya se corrigió en los totales de NBA (el "228.5"). Dinero OFF
en todo. No se inventan datos. Backups antes de borrar.

## La falla (misma que NBA 228.5)
Un mercado O/U que predice "P(más de X)" contra una **línea fija del modelo o la mediana
histórica** no enfrenta la línea real de una casa. La casa mueve la línea a ~50/50; una
línea mediana/propia es un blanco fácil, así que el % de acierto sale inflado y engaña.
No es una ventaja real. Si no hay línea real de casa para validar, ese mercado NO puede
publicarse como pick de confianza: a lo sumo es **informativo**.

## Lo que se encontró y midió (prod wpiztubmmmzclhlprgpd)
- **Tenis O/U** (`v_reto_tenis_totales_v1`): `pick_prob_pct` de confianza contra línea
  **mediana histórica** (ATP bo3=22, bo5=30, WTA=20; el config lo dice: "linea mediana").
  No lo lee el frontend (no está en `BACKEND_SURFACE_USADA.md`), pero el snapshot sí lo
  calificaba: 20 capturas (15 ATP + 5 WTA), solo 14 calificadas (n ridículo), contra la
  línea mediana. Contaminaba el `acierto_historico_pct` que se muestra junto a cada pick.
- **NBA O/U** (`reto_pick_snapshot_v1`, mercado OU): 37 capturas **de la era 228.5**,
  0 calificadas, mercado ya vuelto informativo pero las capturas viejas seguían en el
  ledger (basura: "cosas mal creadas").
- **Soccer OU25**: mercado **RETIRADO el 17-sep** (concluyentemente peor que un volado,
  Brier 0.544 vs 0.50). Se habían borrado las capturas futuras pero quedaban **169
  pasadas** (164 calificadas, 59.8% — engañoso: % de dirección, no skill vs baseline),
  contaminando los tramos de acierto mostrados.
- **MLB O/U** (`v_reto_mlb_totales_v1`): `pick_prob_pct` = max(over,under) a la línea
  **del modelo** (derivada de `total_esperado`), no línea de casa. Solo existen **5**
  líneas reales de MLB ingeridas → imposible validar contra línea real. Seguía en
  "mejores picks" y en el snapshot (prob≥60). 0 capturas reales (fuera de temporada),
  pero habría disparado picks de línea-propia en primavera.

## Arreglo (backend, todo CREATE OR REPLACE / DELETE con backup)
1. **Vistas informativas** (mismo patrón que NBA totales): `pick_prob_pct = NULL`,
   `informativo=true`, etiqueta honesta de la fuente de línea. Hecho en:
   - `v_reto_tenis_totales_v1` → `linea_fuente='MEDIANA_HISTÓRICA'`.
   - `v_reto_mlb_totales_v1` → `linea_fuente='MODELO'`.
   (NBA ya estaba informativa, `linea_fuente='ESPN'` con línea real cuando existe.)
2. **`reto_snapshot_capturar_v1()`**: quitadas las ramas de **tenis OU** y **MLB OU**.
   El ledger ya no captura ningún mercado O/U de línea estática/propia.
3. **`v_reto_mejores_picks_v1`**: quitada la rama **MLB OU**. "Mejores picks" ahora solo
   publica: Soccer (Ganador/Ambos anotan, desde v3), NBA/NHL/NFL/Tenis (Ganador).
4. **Récord limpiado** (con backup): borradas del `reto_pick_snapshot_v1`:
   - tenis OU (20) → backup `public._bk_tenis_ou_snapshot_20261103`.
   - nba OU (37) + soccer OU25 (169) → backup `public._bk_record_mercados_retirados_20261103`.

## Resultado (verificado)
- Ledger final = **solo mercados con skill validado**: soccer/ML, soccer/BTTS,
  nba/GANADOR, nhl/GANADOR, nfl/GANADOR, tenis_atp/GANADOR, tenis_wta/GANADOR.
- Las 3 vistas de totales: **0 filas con `pick_prob_pct`** (100% informativas).
- "Mejores picks": mercados = BTTS, Ganador, ML (ningún O/U).
- `acierto_historico_pct` mostrado ahora refleja solo mercados publicados:
  NFL Ganador 56.1% · Soccer BTTS 58.5% · Soccer ML 60.6% · Tenis ATP 56.1% · Tenis WTA 59.0%.
- Los mercados Ganador y BTTS NO tienen la falla de línea estática (son resultados
  binarios reales, no "contra un número"). El barrido queda completo.

## Nota honesta
Los totales (puntos/juegos/carreras) siguen en la app como **contexto informativo**
(lo que el modelo espera), nunca como pick con %. Para volver a publicarlos como pick
haría falta ingerir líneas reales de casa y validarlos OOS contra esas líneas. Dinero OFF.
Nada de esto toca el modelo de soccer (P0) ni el track del auditor de dinero MLB.
