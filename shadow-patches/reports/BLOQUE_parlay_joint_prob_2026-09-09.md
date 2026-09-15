# PARLAY JOINT PROBABILITY — §25 fail-closed (STAGED)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
estado: `READ_ONLY_VERIFIED` + `iss038 STAGED`.

## Hallazgo (§25)
- `public.parlays.ai_prob_combinada` (numeric): poblado en **38/65** parlays, **0 escritores
  SQL** → proviene de LLM/edge (prefijo `ai_`). Es una probabilidad CONJUNTA de parlay de
  proveniencia no validada.
- `iss022` calcula `prob_parlay_pct = Π(P_RETO de patas)` (asume independencia) — usado como
  gate interno de filtrado, con nota de que no es certeza conjunta calibrada.

§25 es estricto: no presentar P_joint = Π(P_legs) ni una prob conjunta de LLM como
autoridad. Sin modelo conjunto validado → `joint_probability = NULL`,
`joint_reason='NO_VALIDATED_JOINT_MODEL'`. No convertir correlación desconocida en
independencia (crítico en same-game parlays).

## Fix staged (iss038)
`v2.v_parlay_canonical_contract`:
- expone las patas con su **P_RETO individual** (el frontend agrega, no recalcula);
- `joint_probability` **SIEMPRE NULL** + `joint_reason='NO_VALIDATED_JOINT_MODEL'`;
- `ai_prob_combinada` se conserva sólo como `..._context_only` con
  `ai_prob_combinada_status='LLM_ORIGIN_NOT_AUTHORITY'` — nunca alimenta joint_probability.

## Invariante / gate
`PARLAY_JOINT_PROB_GATE = STAGED_ONLY`: en el contrato canónico, 100% de filas con
`joint_probability IS NULL`. `ai_prob_combinada` (LLM) NUNCA es autoridad. En cutover,
la P_RETO por pata se resuelve contra la superficie canónica del evento.

## Nota para ChatGPT (frontend)
El frontend NO debe mostrar `ai_prob_combinada` como la probabilidad del parlay ni el
producto de patas como certeza. Parlay = ensamblador de patas canónicas; prob conjunta
= NULL con razón, hasta que exista un modelo conjunto validado.
