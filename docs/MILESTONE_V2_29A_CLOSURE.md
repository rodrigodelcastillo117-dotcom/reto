# MILESTONE — V2_VERTICAL_SLICE_29A closure (respuesta a auditoría FAIL)

Auditor marcó `V2_VERTICAL_SLICE_29A = FAIL` (no por falta de trabajo, sino por
"no sincronizado, determinista, reproducible y auditable"). Aquí el cierre de cada
bloqueador, con evidencia medida en prod `wpiztubmmmzclhlprgpd`.

## Bloqueadores del auditor → estado

### 1) P0 — `v_analisis_v2` con duplicados (639 filas / 254 eventos = 385 dups; Stuttgart–Viking ×9)
**CAUSA RAÍZ:** el join de forma usaba `team_id` a secas, pero `v_fuerza_equipo`
tiene 1 fila por (team_id, **liga_id**) — hasta 5 por equipo (1781 equipos con >1).
El join se abría en producto cartesiano.
**FIX:** CTE `fuerza` = `DISTINCT ON (team_id)` ordenado por `pj DESC` (competencia
más jugada, desempate por liga_id) → 1 fila por equipo, determinista.
**EVIDENCIA:** `v_analisis_v2` ahora **254 filas / 254 eventos / máx 1 por evento**.
Stuttgart–Viking aparece **1 vez** (antes 9). ONE ANALYSIS restaurado.
Migración: `v_analisis_v2_fix_dedup_fuerza_one_row_per_event`.

### 2) Gobernanza — `competition_catalog.model_supported` contradecía `model_registry`
`model_supported=true` en 23 competencias (Champions, Europa, Conference, CONCACAF,
Libertadores, Danish, etc.) sin aprobación real en `model_registry`; además
`provider_competition_id` estaba NULL (catálogo sin enlace al registry).
**FIX:** `model_registry.approved` es la única fuente de verdad. `model_supported`
se puso en `true` SOLO para las 11 ligas aprobadas + se pobló `provider_competition_id`
con su ESPN liga_id.
**EVIDENCIA:** catálogo = **11 model_supported / 24 total**, y **0 filas
model_supported sin backing de registry**. Migración:
`competition_catalog_align_model_supported_to_registry`.

### 3) Backend V2 en prod sin versionar en Git (no reproducible)
**FIX:** `docs/backend_v2/` versiona los objetos: `v2_objects_snapshot.sql`
(fn_dist_from_lambda, fn_score_dist, build_soccer_prediction_v2 + registry approved
+ gobernanza), `v2_read_contracts.sql` (v_futpro_v2, v_reto13m_daily), y
`README.md` (manifest de tablas/funciones/vistas/cron + query de re-dump +
migraciones aplicadas). Ahora el backend es reproducible desde Git.

### 4) Logos faltantes (gate visual)
**MEDIDO:** 40/221 eventos con ≥1 escudo faltante (23 home, 24 away, 7 ambos).
NO hay escudos equivocados; son faltantes. Cadena de fallback:
`escudos_evento` → `v2.team_logo` → **monograma** (frontend). El contrato entrega
`null` cuando ninguna fuente tiene el escudo; el frontend DEBE renderizar monograma
(nunca imagen rota, nunca escudo de otro club). Enviado build a Lovable para
garantizar el monograma en `null`. La carga de los escudos faltantes es ingesta de
datos (futuro), no bloquea el gate una vez garantizado el monograma.

### 5) GitHub atrasado vs Lovable / sincronía
No existe rama `claude/v2-strangler` en el repo `reto` (solo
`claude/reto-13m-espn-matches-3uknie`, la designada). Todo el trabajo backend V2 +
docs se versiona en la rama designada. El frontend vive en Lovable `d243f279`
(último commit Lovable de referencia: ver `latest_commit_sha` de get_project).

## Invariantes verdes (re-medido)
- `v_futpro_v2`: 221 eventos, 221 IDs únicos (0 duplicados), 116 READY con P_RETO.
- 0 P_RETO en filas temporalmente inseguras; 0 P_RETO en estados no-READY.
- 1X2 suma y O/U: 0 errores. Líneas reales 1.5/2.5/3.5/4.5 (sin hardcode a 2.5).
- Barcelona–Feyenoord y Stuttgart–Viking: fail-closed, P_RETO=NULL (correcto).
- `mejor_pick` sin 'Doble oportunidad' (0). RETO 13M solo ML/BTTS/Over2.5 (116/116, 0 fuera).
- `v_analisis_v2`: 1 fila/evento. Bloques factuales fail-closed (forma/xG/H2H/tendencias/clima/alineaciones).

## Siguiente (29B, autónomo)
Cargar escudos faltantes; ampliar cobertura xG/H2H a MLS/LigaMX (ingesta per-match);
converger a la matriz canónica del auditor cuando quede fail-closed con vocabulario
'UNVALIDATED'; NO tocar MLB hasta PASS de fútbol.
