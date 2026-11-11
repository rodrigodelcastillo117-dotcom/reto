# ⚠️ SUPERSEDED por BLOQUE 2b (2026-09-09)

`domestic_result.json` / `validate_domestic.py` de este directorio son un **fit de
LABORATORIO** (Dixon-Coles ajustado en Python con split train/test), NO el modelo
que iría a producción.

La validación **canónica y vinculante** es BLOQUE 2b, que evalúa la **función de
producción `v2.fn_score_dist`** sobre features AS-OF idénticas al builder staged:

- `shadow-patches/reports/BLOQUE2b_domestic_walkforward_2026-09-09.md`
- `shadow-patches/reports/BLOQUE2b_queries.sql`

## Reversión honesta
El lab-fit daba Bélgica/Dinamarca/Escocia como APPROVABLE. Con el modelo REAL de
producción, sólo **Grecia (197)** vence a la tasa base AS-OF con IC>0. Bélgica es
**peor** que la base. El lab medía un modelo distinto → su conclusión no aplica
(ver §68 del prompt: parity lab→producción).

Decisión final (staged): Grecia APPROVABLE_STAGED; Noruega/Dinamarca/Escocia/Bélgica
NOT_APPROVABLE. Fuente de verdad: iss029 + BLOQUE2b report.
