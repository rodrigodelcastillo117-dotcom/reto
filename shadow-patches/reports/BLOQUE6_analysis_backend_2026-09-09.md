# BLOQUE 6 — ANÁLISIS BACKEND V2 (separado del builder) · confirmación + audit (§22/§23)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
artefacto: `shadow-patches/prepared/iss023_soccer_full_data_analysis.sql` (`analisis_futbol_reto_core`)
estado: `STAGED_NOT_EXECUTED` · `READ_ONLY_VERIFIED` (audit del archivo).

## BLOQUE 6 ES SEPARADO de BLOQUE 5
- BLOQUE 5 (builder/contrato): iss033 `build_soccer_prediction_v2_staged` + `v_soccer_canonical`
  — GENERA P_RETO as-of.
- BLOQUE 6 (análisis): iss023 `analisis_futbol_reto_core` — CONSUME P_RETO canónico y arma
  el dossier + narrativa. **No recalcula probabilidad.** Son artefactos distintos.

## Contrato de análisis (§22) — verificado por lectura del código
INPUT: `canonical_event_id` (resuelto por `resolver_evento_canonico`).
READ: `v_prediccion_reto_futbol` (P_RETO canónico) + fuentes de dossier as-of.
RETURN: probabilidades canónicas, score dist, línea real del proveedor, dossier,
narrativa, provenance, missing reasons, metadata de modelo, `coverage_manifest`.

## Audit NO-RECALC / NO-LEGACY (grep + lectura) — VERIFICADO
- **Única probabilidad de evento** = `v_prediccion_reto_futbol` (línea 138). No hay segundo
  cálculo de P (no `fn_score_dist`, no Dixon-Coles recomputado, no `matriz_marcadores`).
- **Cero fuentes legacy en la ruta soccer**: no `v_pick_canonico`, no `pred_futbol_espn`,
  no `predecir_mlb`, no EV/Kelly/no-vig. Las únicas apariciones de esos términos en el
  archivo son comentarios y la nota de contrato.
- `_analysis_contract.legacy_event_probability_sources = 0` (línea 429),
  `probability_contract = 'P_RETO_ONLY'`.
- Features de contexto (xG, descanso, árbitro, clima, odds) etiquetados
  `CONTEXT_ONLY`/`AVAILABLE_NOT_USED` con `model_note: no modifica P_RETO`.
- Narrativa aterrizada en el dossier (§23): cada mención tiene su fila de manifest;
  clima sin `captured_at` se marca "no se inventa as_of" y NO entra a narrativa operativa.

## Wrapper (importante, no es leak)
`analisis_completo(p_event)` enruta: `deporte='soccer'` → `analisis_futbol_reto_core`
(LIMPIO); MLB/NFL → `analisis_completo_core` (legacy, **fuera de alcance P0 soccer**).
Para SOCCER el core legacy **nunca** se invoca. `analisis_completo_cached` versiona el
cache (`SOCCER_FULL_DATA_V1`) para que un payload viejo de soccer jamás cuente como HIT.

## Gates
- `ANALYSIS_NO_RECALC_GATE = PASS` (soccer: no recalcula P; consume P_RETO canónico).
- `ANALYSIS_NO_LEGACY_GATE = PASS` (soccer: 0 fuentes legacy de probabilidad).
- `CANONICAL_CONTRACT_GATE`: análisis alineado a `v_prediccion_reto_futbol`; en cutover
  debe apuntar a la MISMA superficie que el daily/builder (iss033) — item de alineación
  de cutover, no defecto.

## Residual de cutover
Al migrar el feed a iss033 (`soccer_prediction_v2_staged`), repuntar `analisis_futbol_reto_core`
a esa superficie para que builder + análisis + daily lean exactamente la misma fila canónica.
