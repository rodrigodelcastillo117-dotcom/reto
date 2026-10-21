# Fantasy NFL: diagnóstico honesto + récord de precisión real

Fecha: 2026-10-20. Gatillo: el usuario preguntó "¿cómo mejoramos Fantasy NFL?" y
pidió "haz todo lo necesario". Conclusión honesta tras auditar el sistema: el modelo
ya está rigurosamente validado y las palancas obvias YA se probaron y rechazaron. La
mejora real y segura es **transparencia** (mostrar la precisión real), no tocar el modelo.

## Cómo funciona hoy (medido, no supuesto)
- Modelo servido `public.lab_ff_project_v1` (etiqueta `FF_CHAMP_V1_B1`): proyección =
  **promedio de puntos reales previos del jugador** (2025 sellado + semanas calificadas
  de 2026, solo filas con `graded_at <= momento de decisión` → OOS real). Piso/techo =
  percentiles 20/80 propios del jugador (banda nominal 60%); cold-start → bloqueado.
- Existe un modelo v2 gobernado (`v2.fantasy_model_config_v2`) con 3 versiones
  autorizadas; la activa es **`fantasy-b2-rival-2026.09.2`** (escalera L0→L2:
  oportunidad-sin-suerte-de-TD + factor de rival). Tablas de config y calibración son
  **inmutables** (trigger `fn_fantasy_authority_v2_immutable`: "crea una versión nueva").
- Guards vivos: `gate_fantasy_un_solo_modelo` (un solo modelo, resumen = suma de
  titulares), `gate_fantasy_ve_la_temporada_en_curso`, `gate_fantasy_alcanzable`.

## Qué YA se probó y rechazó (evidencia en `fantasy_model_config_v2.evidence`)
- **Peso reciente / EWMA**: preregistrado y RECHAZADO (ISS182/ISS183: H=4 cruza cero,
  H=2 peor). Mi backtest walk-forward 2026 lo CONFIRMA: half-life da solo ~1–3% menos
  error y el modelo ya le gana en WR/RB/TE.
- **Factor de rival (L2)** y **oportunidad sin suerte de TD (L1)**: probados y
  ADOPTADOS, con honestidad explícita ("+0.057 pts/decisión, nadie gana una liga con
  esto; su valor está en los casos donde cambia la decisión").
- **Cambio de equipo (L3)**: rechazado (IC cruza cero).
- **Momios de Vegas**: excluidos a propósito (el precio es dato informativo, no decide).

## Mi backtest (preregistrado, walk-forward 2026, por posición)
Error medio (MAE) del modelo v2 servido, semanas 1–6 OOS calificadas:
QB 6.57 · RB 5.00 · WR 5.01 · TE 4.30 (correlaciones 0.41–0.61). Mis métodos simples
(recencia/volumen) NO le ganan salvo QB (~5%), y QB es la posición más ruidosa.
Conclusión: el techo real es el ruido del fantasy semanal; no hay mejora de modelo
honesta y grande disponible. Tocar el número sería sobrevender.

## Lo que SÍ se hizo (seguro, additivo)
- `public.v_reto_fantasy_precision_v1`: récord de precisión REAL por posición + GLOBAL
  (n, error_medio_pts, correlacion, cobertura_rango_pct, semanas), leyendo
  `v_lab_ff_official_snapshot` (proyección sellada antes del kickoff vs puntos reales).
- Frontend: sección "¿Qué tan preciso es el modelo?" en /nfl/fantasy con texto honesto
  (error ~5 pts es normal en la industria; úsalo como guía) y etiqueta "QB menos
  confiable" (QB error 6.57, cobertura 46%).

## Recomendaciones futuras (NO modelo, sí datos/decisión)
- Refrescar depth charts (hoy del 2026-08-31, ~7 semanas viejos): afecta la detección
  de rol más que la matemática. Requiere fuente/sync verificado.
- Surtir mejor las DECISIONES (donde el owner dice que está el valor): resaltar cuándo
  el modelo discrepa del número del sitio o del instinto, y por qué.
- Interval honesto: la banda servida (p20/p80, nominal 60%) cubre 54% global y 46% en
  QB; se podría ensanchar QB — pero es cambio de modelo y va por preregistro/versión.
