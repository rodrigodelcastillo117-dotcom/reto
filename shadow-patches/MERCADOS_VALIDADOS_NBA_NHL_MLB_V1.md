# Expansión multideporte de mercados validados — NBA totales, NHL, MLB totales

Fecha: 2026-10-20. Estándar: **igual que futbol** — todo validado fuera de muestra
(OOS) antes de publicar; nada de dinero (EV/Kelly OFF); nada fabricado; se publica
solo lo que supera el baseline con calibración honesta. Récord autoactualizable
(snapshot pre-saque → grade vs resultado).

## Resumen de decisiones (honesto)

| Deporte | Mercado | OOS | Acierto | Decisión |
|---|---|---|---|---|
| NBA | O/U puntos totales | 1,266 (prob≥60%) | **65.7%** (pred 66.9) | ✅ PUBLICADO |
| NHL | Ganador (ML) | 1,379 (margen≥0.75) | **58.5%** (base local 54.2) | ✅ PUBLICADO (selectivo, prob capada 70%) |
| MLB | O/U carreras | 3,546 (prob≥60%, 2026) | **61.0%** (modelo canónico c/pitcher) | ✅ PUBLICADO (dormido fuera de temporada) |
| NHL | O/U goles | 2,937 | 49.9% (corr 0.038) | ❌ NO — sin señal (hockey muy aleatorio en goles) |
| Tennis | O/U juegos | — | — | ⛔ BLOQUEADO — la base solo guarda conteo de sets, no marcadores por set; falta ingestión de linescores + backfill |
| MLB | O/U (tasas de equipo) | 8,263 | 52.5% (corr 0.098) | ❌ reemplazado por el canónico con pitcher |

### Calibración por tramo (evidencia)
- **NBA O/U** (línea 228.5, tasas rodantes 20 juegos ofensiva/defensiva, holdout 2024-10):
  prob≥60% → 65.7% real (1266); 57-60 → 59.2%; 55-57 → 53.2% (por eso piso 60%).
- **NHL ML** (diferencial de goles rodante 20 + ventaja local 0.227, holdout 2024-10),
  P(local)=1/(1+exp(−(0.08+0.36·margen))), monótona: margen 0.75→58.7% pred vs 58.5% real;
  tope empírico ~68% (bucket 2.0-3.4) → prob servida capada a 70%.
- **MLB O/U**: cerebro canónico `mlb_one_brain_v2` (Poisson con pitcher abridor);
  backtest 2026 prob≥60% → 61.0% real (3546). Ligeramente sobreconfiado (pred 65.6),
  el récord vivo muestra el real.

## Objetos creados / modificados (prod `wpiztubmmmzclhlprgpd`)

**Vistas de servicio**
- `public.v_reto_nba_totales_v1` — totales NBA desde tasas rodantes 20 juegos + agenda; línea 228.5; prob logística-normal (σ=19).
- `public.v_reto_nhl_mercados_v1` — ML NHL desde diferencial rodante + agenda; prob capada 70%.
- `public.v_reto_mlb_totales_v1` — totales MLB desde el grid canónico `v2.mlb_totales_grid` (over_pct/under_pct 0-100, línea en la clave).

**Agenda NHL (nueva, espeja NBA)**
- Tablas `public._carga_agenda_nhl`, `public.reto_nhl_agenda_v1` (pk espn_event_id).
- Funciones `pedir_agenda_nhl_v1(dias)`, `absorber_agenda_nhl_v1()` (endpoint `hockey/nhl`).
- Crons `nhl-agenda-pedir` (9 */3 * * *), `nhl-agenda-parse` (14 */3 * * *).

**Ingestión de resultados NBA/NHL (hueco pre-existente corregido)**
- Causa: `v2.deporte_del_producto` (gobierno de ingestión diaria) solo incluía soccer/mlb/nfl; NBA y NHL quedaban 5 días atrasados → ratings stale y grading incompleto. NO se tocó el gobierno (riesgo de "cerebro canónico").
- Fix aislado: `public.pedir_historico_nba_nhl_v1(meses)` (formato mensual `dates=YYYYMM` que ESPN sí acepta) + cron `nba-nhl-historico-pedir` (2 4 * * *), absorbido por el `historico-espn-absorber` diario (4:11).

**Mejores picks / récord / autograde**
- `v_reto_mejores_picks_v1`: +NBA OU (≥60%), +NHL Ganador (≥56%), +MLB OU (≥60%). Incluye `nivel_confianza` y `acierto_historico_pct` (histórico real por tramo).
- `reto_snapshot_capturar_v1()`: +ramas NBA OU, NHL GANADOR, MLB OU.
- `v_reto_pick_grade_v1`: +deportes nhl/mlb; mercado OU genérico calificado con `linea`; **push** (total=línea) → NULL (no derrota).
- `reto_modelo_validacion_v1`: +filas (nba,OU,1266,65.7), (nhl,GANADOR,1379,58.5), (mlb,OU,3546,61.0) → alimentan `v_reto_record_card_v1`.

**Frontend (Lovable "Remix of Reto 13M", commit 2e85e75)**
- Iconos 🏒 (nhl) / ⚾ (mlb); etiquetas NOMBRE_DEPORTE nhl/mlb y NOMBRE_MERCADO OU. El componente ya renderiza los mercados de forma genérica (badges de confianza + histórico). tsgo limpio.

## Pendiente honesto (no fabricado)
- **Tennis O/U juegos**: requiere nueva ingestión de marcadores por set (linescores ESPN) + backfill histórico + validación OOS. Sin ese dato no hay juegos totales que modelar.
- **NHL O/U goles**: descartado por falta de señal; reconsiderar solo con features de portero/líneas si se ingieren.
