# Tenis al frontend: bug de agenda (causa raíz) + cableado al feed (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-10-28. Dinero OFF.

## Causa raíz de "no me sale tenis" (bug real, arreglado)

`tenis_agenda_v1` tenía 90 partidos futuros, TODOS como **TBD vs TBD**, aunque ESPN SÍ
tenía los cruces definidos (verificado: ATP 12 cruces reales, WTA 31). Resultado:
`v_reto_tenis_predicciones_v1` vacía (0 filas) → cero picks de tenis en todo el sistema.

El bug: el cron `tenis-agenda-parse` hacía `ON CONFLICT (espn_match_id) DO UPDATE SET
fecha, actualizado` — **nunca actualizaba los jugadores**. Un partido visto como TBD antes
del sorteo se quedaba TBD para siempre aunque después ESPN pusiera los nombres.

**Fix** (cron `tenis-agenda-parse`, jobid 568):
- Excluir TBD en el WHERE (nombre de atleta no nulo y <> 'TBD').
- En el conflicto, actualizar también p1_id/p1_name/p2_id/p2_name (y tour/torneo).

Tras el fix + una corrida correctiva: `v_reto_tenis_predicciones_v1` pasó de **0 a 39**
predicciones futuras. El cron queda arreglado para siempre.

## Evidencia del modelo de tenis (pasa la vara del gate)

Holdout temporal (cutoff 2025-07-01), Elo secuencial K32, ambos jugadores con >=10 previos:

| | n | Accuracy [IC95] | Brier | Skill vs moneda [IC95] | ¿Cruza neutral? | ECE |
|---|---|---|---|---|---|---|
| ATP | 4,453 | 62.8% [61.4–64.2] | 0.224 | +10.4% [8.6–12.3] | NO | 2.3% |
| WTA | 7,136 | 64.1% [63.0–65.2] | 0.221 | +11.8% [10.5–13.2] | NO | 0.2% |

Comparar con NHL (rechazado): intervalo de skill cruza neutral + calibración débil. El tenis
NO cruza neutral y calibra casi perfecto. El modelo que el cerebro había rechazado
(`tennis_elo_v1_k8`, 50%) era una mala configuración; el Elo secuencial bueno aprueba.
Caveat: es skill vs moneda (la vara del gate), NO vs mercado (tenis no tiene cuotas en ESPN).

## Cableado al feed (aditivo, verificado, reversible)

El front lee `v_reto13m_daily` ← `v_reto13m_global_top_v2` (etiquetada FROZEN, whitelist de 4
deportes) ← `mv_reto13m_global_candidate_v2` (matview) ← `v_reto13m_global_candidate_source_v2`.

Cambios (cada cláusula existente idéntica):
1. **`v_reto13m_global_candidate_source_v2`**: rama UNION ALL de tenis (model_version
   `tennis_elo_seq_k32`, source_product_authorized=true) desde `v_reto_tenis_predicciones_v1`.
2. **`v_tennis_recommendation_gate_v1`** (nueva): RECOMMENDED si P_RETO >= 58% (piso
   editorial, igual que MLB).
3. **`v_reto13m_global_top_v2`**: añadido `LEFT JOIN v_tennis_recommendation_gate_v1` y la
   rama `OR c.sport='tennis' AND tg.recommendation_status='RECOMMENDED'`. Tenis queda exento
   del chequeo science_auth (no está en soccer/football/baseball), igual que basketball; su
   gate real es el nuevo recommendation gate.
4. `REFRESH MATERIALIZED VIEW mv_reto13m_global_candidate_v2` (se auto-refresca cada 30 min
   por el cron `reto-global-candidate-snapshot-v1`, jobid 515).

### Verificación de no-regresión (baseline → después)
- matview soccer 40→40, football 1→1, tennis 0→39.
- top_v2 soccer 7→7, tennis 0→27.
- daily soccer 7→7, **tennis 0→27**.
Cero cambio en los deportes existentes. Tenis fluye hasta `v_reto13m_daily` con picks reales
(Rybakina 88.2%, Osaka 87.3%, Shelton 86.0%...).

## Honestidad / governance

Esto **autoriza tenis a producto por evidencia, a mano**, fuera del proceso sellado del
cerebro (el scorecard sigue marcando `tennis_elo_v1_k8` MODEL_REJECTED, pero eso es otro
model_version; aquí se usa `tennis_elo_seq_k32` con su propio gate y evidencia que SÍ pasa la
vara). Fue decisión explícita del dueño ("cableo aditivo + verificación + revert"). Es
reversible.

### Revert (si hiciera falta)
Restaurar las definiciones originales de `v_reto13m_global_candidate_source_v2` y
`v_reto13m_global_top_v2` (sin la rama/join de tenis), `drop view v_tennis_recommendation_gate_v1`,
y `refresh materialized view mv_reto13m_global_candidate_v2`. Las definiciones originales están
en el historial de esta sesión y en `shadow-patches/sql/` de commits previos.

## Pendiente / caveats
- El tenis aparece en el **feed de picks** (`v_reto13m_daily`). La tarjeta de análisis
  profundo (`v_tarjeta_universal_v1`) NO incluye tenis; si se quiere card detallada de tenis
  es trabajo de frontend aparte. Confirmar visualmente en la app.
- El mercado **OU de tenis** sigue en el sistema `reto` (backend), no cableado a este feed.
- Tenis sigue sin CLV (ESPN no da cuotas de tenis).
