# NFL — aplicado a PRODUCCIÓN (`wpiztubmmmzclhlprgpd`)

Autorizado explícitamente por el owner el 2026-09-11 ("aplica a prod todo").
Esto levanta `PROD_FREEZE` **sólo** para lo listado aquí. No hubo deploy de frontend.

## Qué se aplicó — todo ADITIVO

| Objeto | Tipo | Efecto |
|---|---|---|
| `v2.nfl_model_config` | tabla nueva | 1 fila: `nfl-2026.09.2`, inmutable por trigger |
| `v2.nfl_points_shape` | tabla nueva | 44 filas, 544 team-games reales de 2025 |
| `v2.nfl_team_rating` | tabla nueva | ratings sellados as-of, append-only |
| `v2.nfl_decision_snapshot` | tabla nueva | 11 constraints, inmutable por trigger |
| `v2.fn_norm_pdf` / `fn_nfl_points_pmf` / `fn_nfl_markets_from_pmf` | funciones nuevas | el motor |
| `v2.fn_nfl_fit_ratings` / `fn_nfl_dk_line_asof` / `build_nfl_decision_snapshot` | funciones nuevas | ajuste y construcción |
| `v2.fn_nfl_reto_predice` | función nueva | el bloque que consume el frontend |
| `public.nfl_dossier` | **función existente MODIFICADA** | ver abajo |
| `public.mlb_bateador_temporada` | RLS | activado + 2 políticas |
| `public.mlb_pitcher_temporada` | RLS | activado + 2 políticas |

## El único objeto existente que se tocó: `nfl_dossier`

Dos cambios, ambos mínimos y verificados:

1. **El campo `metodo` mentía.** Decía literalmente *"Base anclada al mercado (DraftKings sin
   comisión)"* — es decir, presentaba el no-vig de la casa como si fuera la base del análisis,
   exactamente lo que el contrato prohíbe. Ahora dice que P_RETO es propio y que DraftKings es
   contexto.
2. **Se añadió la llave `reto_predice`** usando el MISMO patrón protegido
   (`BEGIN ... EXCEPTION WHEN others THEN NULL; END;`) que la función ya usaba para
   `opinion_modelo`. Si ese bloque fallara por cualquier razón, el dossier devuelve exactamente
   lo que devolvía antes.

Verificación ejecutada dentro de la misma transacción del parche: se contaron las llaves del
dossier antes (15) y después (16), con `raise exception` si hubiera perdido alguna. No perdió
ninguna. `opinion_modelo` (FPI), `linea`, `lesiones`, `h2h`, `clima`, `estadio` y `lecturas`
siguen intactos.

## Estado medido después de aplicar

- **15 de 15** juegos de Week 1 con `reto_predice.disponible = true`. Cero sin bloque.
- 31 snapshots en total (15 de Week 1 + 16 de Week 2).
- SF @ LAR (`401872657`): **Rams 65.2 % / 49ers 34.8 %**, proyección 25.87–22.24,
  spread DK −3.5 → cubre 50.1 / 49.9, total DK 47.5 → over 52.0 / under 48.0.
  El mercado (63.7 %) sigue expuesto aparte en `linea.prob_local`.

## Lo que NO se aplicó

- **Nada de SOCCER.** El auditor lo tiene como P0 con blocker abierto (`crossleague_v1` vs
  `crossleague_v1_1`, comentario 5625875054). No se tocó.
- **Nada del contrato MLB iss052.** Sigue sólo en la rama desechable.
- **Nada de frontend.** Lovable trabaja en paralelo.
- **Nada de NFL Fantasy ni prop board.** Sigue pendiente.

## Honestidad sobre el número que ahora se muestra

`calibration_status = BACKTESTED_2025_NO_EDGE_VS_MARKET`, y está en el payload.

Backtest walk-forward de 208 juegos de 2025:
- Brier del modelo **0.22702** vs **0.25000** del volado → skill real **+9.19 %**
- Brier del mercado **0.21822** → **el mercado sigue siendo mejor**

El número que ve el usuario es nuestro y tiene habilidad real, pero **no le gana a DraftKings**,
y el payload lo dice en el campo `advertencia`. No se presenta como ventaja.

## Rollback

```sql
-- quitar sólo el bloque nuevo del dossier (deja el resto igual):
--   re-aplicar la definición anterior de public.nfl_dossier desde el historial.
drop function if exists v2.fn_nfl_reto_predice(text);
-- el resto es aditivo en el esquema v2 y puede quedarse sin afectar nada:
-- drop schema v2 cascade;  -- SOLO si no hay otros objetos v2 en uso
```
