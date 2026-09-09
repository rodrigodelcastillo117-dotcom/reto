# BLOQUE 2 — Ligas domésticas no aprobadas · EVIDENCIA (STAGED)

Rama `claude/reto-13m-espn-matches-3uknie`. Motor Dixon-Coles INTRA-LIGA (sin φ),
temporalmente seguro (forma 540d < kickoff). Baseline = base-rate del train.
Código: `lab/domestic_leagues_v1/`. Artefacto: `shadow-patches/prepared/iss029_*.sql`.

## Método (por liga)
temporal split ~70/30 · sample floor (5/8/10/15 elegido por validación) · Brier ·
LogLoss · calibración ECE (4 buckets) · estabilidad por temporada · coverage ·
leakage audit (0 filas hoy/live) · identidad competencia/proveedor (liga_id ESPN único).

## Resultados OOS
| Liga | liga_id | n | n_test | Brier | base | ΔBrier | ΔLogLoss | ECE | floor* | Decisión |
|---|---|---|---|---|---|---|---|---|---|---|
| Bélgica/Jupiler | 144 | 913 | 275 | 0.622 | 0.660 | +0.038 | +0.053 | **0.011** | 15 | **APPROVABLE** |
| Dinamarca/Superliga | 119 | 571 | 175 | 0.638 | 0.656 | +0.019 | +0.024 | 0.05 | 15 | **APPROVABLE** |
| Escocia/Premiership | 179 | 425 | 128 | 0.567 | 0.631 | +0.064 | +0.087 | 0.06 | 15 | **APPROVABLE** |
| Noruega/Eliteserien | 103 | 714 | 217 | 0.561 | 0.615 | +0.054 | +0.072 | **0.12** | 15 | NOT_APPROVABLE |
| Grecia/SuperLeague | 197 | 530 | 160 | 0.611 | 0.675 | +0.064 | +0.097 | **0.097** | 15 | NOT_APPROVABLE |

Leakage audit: **0 filas fechadas hoy/live** en el fit de las 5 ligas.
Gate de aprobación: mejora OOS en Brier Y LogLoss + **ECE ≤ 0.08** + n_test ≥ 60.

## Verdicto
- **APPROVABLE (3):** Bélgica, Dinamarca, Escocia — mejoran OOS y bien calibradas.
- **NOT_APPROVABLE (2):** Noruega y Grecia — **discriminan** (buen ΔBrier) pero
  **mal calibradas** (ECE 0.12 / 0.097 = sobreconfiadas). No se aprueban a ciegas:
  requieren capa de calibración por liga (isotónica/Platt) validada OOS. Fail-close.

## Operaciones que requerirán autorización posterior
1. Ejecutar approvals de iss029 SÓLO para 144/119/179 en `v2.model_registry`.
2. Para 103/197: construir + validar calibración por liga, luego re-evaluar.
