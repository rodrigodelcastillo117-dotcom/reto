# BLOQUE 1 — Champions / Cross-League Model · EVIDENCIA (STAGED, sin deploy)

Rama `claude/reto-13m-espn-matches-3uknie`. Proyecto Supabase `wpiztubmmmzclhlprgpd`.
Sólo lectura contra prod. Artefacto staged: `shadow-patches/prepared/iss027_champions_crossleague_model.sql`.
Código+evidencia: `lab/champions_crossleague_v1/`.

## Qué se construyó
Modelo de fuerza entre ligas (Dixon-Coles Poisson) para competencias cruzadas
(Champions, Europa, Conference, Libertadores, Concacaf, AFC), **identificable y
temporalmente seguro**:
- Fuerza de EQUIPO: tasas de gol domésticas en ventana móvil 540d **estrictamente
  anterior** al kickoff (data_asof < decision_time por construcción).
- Fuerza de LIGA φ_L: efecto fijo por liga identificado SÓLO por partidos cruzados;
  ref Premier=0; regularización ridge.
- Ventaja de local γ explícita. Corrección Dixon-Coles ρ para marcadores bajos.
- NO usa odds/mercado. Sudamericana entrena φ pero jamás emite pick (veto).

## Datos reales
- `historico_partidos_espn`: 42,538 juegos con marcador (2020–2026).
- Cruzados continentales: 3,155. **Usables (ambos equipos ≥5 juegos domésticos en
  ventana): 826.** El resto **fail-cierra** por falta de historia doméstica (correcto).

## Validación OUT-OF-SAMPLE (split temporal, nunca aleatorio)
Train `< 2025-02-01` (375) → Test `>= 2025-02-01` (451):

| Modelo | Brier | LogLoss | Acc |
|---|---|---|---|
| **Cross-league (φ)** | **0.5989** | **1.0013** | 0.503 |
| Doméstico naïve (φ=0) | 0.6157 | 1.0243 | 0.508 |
| Prior tasas base | 0.6152 | 1.0223 | 0.508 |

- **Bootstrap (2000): Brier gain +0.0168, 95% CI [+0.0008, +0.0333]** → mejora
  **estadísticamente significativa** (límite inferior > 0).
- Mejora la calibración probabilística (Brier/LogLoss), NO la accuracy (empatada) —
  correcto para un modelo de probabilidad.

Calibración (test cross-league): bucket 0.4–0.6 conf 0.491 → acc 0.485; bucket
0.6–0.8 conf 0.67 → acc 0.712. Bien calibrado.

Walk-forward (folds temporales, ventana 6m): Δ Brier (dom−cross) por fold =
−0.0083 / +0.0145 / +0.0354; **media +0.0138 a favor de cross-league** (el primer
fold, con menos datos, favorece ligeramente al doméstico → el señal se estabiliza
con más muestra).

Ridge sweep (validación interna, sin tocar test): logloss mejora con más
regularización → **el señal de liga es real pero débil; requiere shrinkage**. Se
fijó ridge=10 (balance walk-forward / jerarquía interpretable).

Estabilidad por temporada de test: Brier 2025=0.593, 2026=0.609 (consistente).

## φ liga (ridge=10, ref Premier=0) — jerarquía coherente
Premier 0.00 · LaLiga −0.08 · Bundesliga −0.11 · Ligue1 −0.11 · Serie A −0.12 ·
Liga MX −0.05 · Dinamarca −0.23 · Primeira −0.25 · Noruega −0.29 · Bélgica −0.30 ·
MLS −0.32 · Turquía −0.36 · Eredivisie −0.38 · Grecia −0.39 · Escocia −0.43.
Cobertura: 15/16 ligas con ≥20 juegos cruzados = **SERVIBLES**; Saudi (n=3) y
liga 188 (n=0) **fail-close**.

## Prueba explícita de los 3 partidos del usuario
| Partido | Local | Empate | Visita | Marcador | O2.5 | BTTS |
|---|---|---|---|---|---|---|
| Barcelona–Feyenoord (UCL) | 78.3% | 12.4% | 9.3% | 2-0 | 74.8% | 57.7% |
| Liverpool–Atlético (UCL) | 52.8% | 21.8% | 25.5% | 1-1 | 57.8% | 57.6% |
| Stuttgart–Viking (UEL) | 59.1% | 19.0% | 21.9% | 2-1 | 68.2% | 64.1% |

Los 3 se sirven (todas las ligas SERVIBLES + muestra doméstica suficiente).
Nota de campo (usuario, en vivo HT): Barça 2-0 (marcador modal exacto del modelo),
Stuttgart 3-1 (modelo 2-1, favorito correcto). Una observación en vivo NO altera φ:
la autoridad es la validación OOS, no un partido (guarda anti-overfit #106/#108/#109).

## VERDICTO: APPROVABLE con guardas (fail-closed-until-approved)
El modelo cross-league es **defendible fuera de muestra**: mejora Brier y LogLoss
vs baseline doméstico y prior, con significancia bootstrap y estabilidad temporal.
Guardas obligatorias (ya en el SQL): liga servible (≥20 cruzados), muestra doméstica
≥5 por equipo, data_asof ≤ decision_time, ridge, Sudamericana sin pick.
**NO se enciende** hasta que un humano ejecute iss027 y apruebe en `v2.model_registry`
(bajo freeze: NO aplicar). Reproducible: `python3 fit_crossleague.py`.

## Operaciones que requerirán autorización de deploy posterior
1. Ejecutar `iss027_champions_crossleague_model.sql` (crea `v2.liga_fuerza`,
   `v2.crossleague_params`, `v2.fn_crossleague_features`, `v2.fn_crossleague_p_reto`).
2. Integrar la rama cross-league en `v2.build_soccer_prediction_v2` (llamar
   `fn_crossleague_p_reto` cuando la competencia sea cruzada).
3. INSERT de approval en `v2.model_registry` (UCL/UEL/Conference/Libertadores/
   Concacaf/AFC; NUNCA Sudamericana).
