# Mercados derivados de soccer — validación honesta (2026-10-14)

Objetivo: no publicar mercados mal hechos. Cada uno se validó forward (predicción
congelada antes del saque, `temporal_safe`, vs. resultado real de `historico_partidos_espn`).

## Resultados (n≈308–319 partidos jugados)

| Mercado | n | Brier modelo | Baseline | Veredicto |
|---|---|---|---|---|
| **Handicap −1.5 (local)** | 319 | **0.1653** | base 0.1863 | ✅ **le gana, significativo** (Δsup95 −0.0112 < 0) |
| **Marcador correcto** | 319 | — | dice 11.4% / pega 10.0% | ✅ **calibrado** (info honesta) |
| BTTS (Ambos Anotan) | 319 | 0.2437 | base 0.2426 | ❌ empata/peor, poca discriminación, subcalibrado |
| Over/Under | 308 | 0.2593 | base 0.2496 · mercado 0.2445 | ❌ peor que base y mercado |

## Causa raíz de los que fallan
Los mercados de **total de goles** (BTTS, O/U) salen sesgados porque el modelo de
**goles esperados (lambdas) corre bajo**: subestima los partidos de muchos goles
(línea 3.5: dice 36% over, pasa 51% → −14pp). Los mercados de **margen** (handicap)
y el 1X2 no dependen del total, por eso sí funcionan.

## Publicado (backend) — solo los validados
`public.v_reto_soccer_mercados_v1` (read-only, grant anon/authenticated):
- `p_home_handicap_menos15`, `p_away_handicap_menos15` (derivados de `score_dist`, normalizados)
- `marcador_probable`, `marcador_prob_pct`
Acotado a partidos READY con kickoff en los próximos 10 días. Dinero apagado.

## Pendiente (NO publicar hasta arreglar)
- BTTS y O/U: corregir el sesgo del modelo de goles (lambdas bajos / subdispersión
  del Poisson independiente). Ruta: recalibración por línea OOS (train/holdout) y/o
  modelo de goles con correlación entre equipos. Re-validar; publicar solo si supera
  la base de forma significativa fuera de muestra.
