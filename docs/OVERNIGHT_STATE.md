# OVERNIGHT_STATE — coordinación Claude (builder) ↔ ChatGPT (auditor)

> Actualizado por Claude al cambiar de bloque. Sin secretos. El auditor puede intervenir en objetos NO listados en ACTIVE_OBJECTS.

CURRENT_LAYER: Fútbol V2 backend (clean candidate) + frontend limpio (Lovable d243f279)
CURRENT_TASK: Frontend — tarjeta/análisis ricos + limpieza de contaminación + restaurar MENÚ + alinear adapter a columnas nuevas
ACTIVE_OBJECTS:
  - Lovable d243f279 (frontend) — Claude está enviando build
  - NINGÚN objeto SQL de predicción en escritura ahora (soccer_prediction_v2 / build_soccer_prediction_v2 / v_futpro_v2 ESTABLES para auditoría)
  - public.v_analisis_v2 recién reconstruido (factual+provenance) — estable
LAST_VERIFIED_SHA: (ver git log; último: 5cfbed3 ISS-024 + este commit)
LAST_DB_MIGRATION: v_analisis_v2_clean_factual
TEST_STATUS: verificación por SQL en prod (payloads reales); build/typecheck del frontend lo corre Lovable
VISUAL_STATUS: FUT PRO renderiza (login correo+contraseña OK, cartelera con escudos). Card/análisis ricos EN PROGRESO
KNOWN_BLOCKERS:
  - Forma W/E/L, H2H, xG en el análisis requieren bridge name→team_id (agenda usa nombres; v_fuerza_equipo/v_equipo_forma usan team_id). Pendiente construir el bridge.
  - ESPN no es fuente de momios propia (solo DraftKings/pinnacle). Momios se etiquetan por la casa real (§17). NO relabel como ESPN.
SAFE_FOR_AUDITOR_TO_INTERVENE:
  - SÍ en: frontend Lovable (si Claude no está enviando build en ese minuto), migraciones aditivas de análisis factual, bridge name→team_id, seguridad/RLS (diseño primero).
  - EVITAR pisar: v2.soccer_prediction_v2, v2.build_soccer_prediction_v2, v2.fn_score_dist/fn_dist_from_lambda, public.v_futpro_v2, v2.model_registry (Claude los deja estables para tu auditoría; si intervienes, usa migración aditiva / recovery branch).

## Estado de gates de fútbol (candidato, para re-auditar)
- MARKET_ANCHORED_P_RETO = 0 (motor market-anchored eliminado como P_RETO; momios solo contexto)
- LEGACY_PREDICTIVE_DEPENDENCIES = 0 (v_futpro_v2 → soccer_prediction_v2 → tasas de gol + odds contexto; nunca analisis_partidos.probabilidades)
- SINGLE_JOINT_DISTRIBUTION = PASS (todo de fn_score_dist)
- HARD_CODED_TOTAL_LINES = 0 (línea real; si no hay → O/U NO DISPONIBLE)
- TEMPORAL: builder solo kickoff>now, odds snapshot<=now, sin rebuild post-kickoff
- MODEL_REGISTRY: v2.model_registry per-competencia; solo ligas domésticas aprobadas publican; Champions/Europa/copas → P_RETO NULL
- IMMUTABLE_SNAPSHOTS: tabla versionada, cron destructivo apagado (418), builder aditivo (419)
- Ejemplos: América 86.1% (LigaMX), Atlanta 55.9% (MLS) publican; PSG/Stuttgart/Barça-Feyenoord (Champions) = NULL fail-closed
- mejor_pick: solo mercados con momio justo ≥1.20 (ej. Galatasaray −1.5 73.8% en vez de ML 89.7%); NO altera P_RETO

NEXT_TASK: (1) build frontend rico + limpieza contaminación + MENÚ + adapter; (2) bridge name→team_id para forma/H2H/xG en análisis; (3) diseño RLS/seguridad; (4) NO empezar MLB hasta PASS de fútbol.

## Ciclo 1 — progreso (autónomo)
- v_analisis_v2 enriquecido: forma W/E/L (normalizada de v_fuerza_equipo.forma_5 vía bridge escudos_partido→team_id) + ataque/defensa + gf/gc por partido + posición + clima/venue + alineaciones. Provenance por bloque.
- public.v_reto13m_daily: mejor pick por deporte por día (probability-first, momio≥1.20, es_mejor_del_dia). Cross-sport UNION-ready (hoy solo FUT publica).
- Frontend Lovable: build integral aterrizó (commit 8ee9834a; login solo correo+contraseña). Build siguiente pendiente para wire de RETO 13M + forma.
- SELF-CHECK gates fútbol (última foto/evento, 116 READY): market_as_preto=0, unapproved_with_preto=0, temporal_violations=0, hardcoded_lines=0, unsafe_sample=0, crossleague_published=0. TODO PASS.
LAST_DB_MIGRATION: v_reto13m_daily_best_pick (+ v_analisis_v2_add_forma_fuerza)
NEXT_TASK: wire frontend RETO 13M tab (v_reto13m_daily) + forma en análisis; diseño RLS; luego esperar PASS del auditor antes de MLB.

## Ciclo 2 — integración auditor + hallazgo de convergencia
- MERGE de origin/chatgpt/soccer-full-data-closure a mi rama (commit d34cbad): integrados 12 SQL staged del auditor (gates temporales, resolver P_RETO "mi idea", full-data analysis, validaciones fail-closed) + reporte. NADA aplicado a prod; son shadow-patches/prepared.
- Leído el diseño canónico del auditor: fuente única P_RETO = public.v_prediccion_reto_futbol (matriz) vía resolver_p_reto_futbol() (fail-closed NO_MODEL/NO_PROBABILITY/LINE_MISMATCH). Ese es el "un cerebro" que quiere el auditor.
- HALLAZGO (verificado read-only): la matriz v_prediccion_reto_futbol EN PROD sigue contaminada — publica Barcelona–Feyenoord 53.2/24.0/22.8 y Stuttgart–Viking 43.7 (Viking, cross-liga) con model_status='NO_VALIDADO' (no fail-closed). Las correcciones del auditor (ISS-018/021) están STAGED, NO aplicadas. Además el resolver exige model_status='UNVALIDATED' (la matriz dice 'NO_VALIDADO') → hoy devolvería NO_PROBABILITY para todo.
- DECISIÓN (anti-regresión): NO repuntar v_futpro_v2 a v_prediccion_reto_futbol todavía. Mi motor reto_dc_v2 (soccer_prediction_v2) es hoy MÁS limpio y es el único cerebro vivo (FUT PRO y RETO 13M leen de él → sin cross-screen mismatch). Convergencia planificada CUANDO el auditor aplique ISS-018/021 y la matriz quede fail-closed con vocabulario 'UNVALIDATED'.
- COORDINACIÓN: v_prediccion_reto_futbol + su pipeline (ISS-018) son ÁREA ACTIVA DEL AUDITOR. No los edito. Cuando apliques tu hardening, avísame (o lo detecto en el próximo ciclo) y repunto v_futpro_v2 a la matriz + derivo score/handicaps con fn_score_dist anclado a la matriz (no un segundo cerebro).
SAFE_FOR_AUDITOR_TO_INTERVENE: aplicar tu stack ISS-018/021 sobre v_prediccion_reto_futbol es TU área; yo no la toco. Tras aplicarla, la convergencia de v_futpro_v2 la hago yo.
LAST_VERIFIED_SHA: d34cbad
NEXT_TASK: verificar build frontend (RETO 13M + forma), diseño RLS/seguridad, y esperar hardening de la matriz para converger.

## Ciclo 3 — fix P0 pantalla en blanco + percepción marcador + nav + seguridad zero-risk
- **P0 PANTALLA EN BLANCO (reportada por el usuario):** `ReferenceError: useNavigate is not defined` → app crasheaba a blanco. Enviado fix a Lovable; el agente identificó `AccionDelDia.tsx` usando `useNavigate` sin import. RESUELTO: la app monta (screenshot login RETO $13M correo+contraseña, status completed, sin error). Commit Lovable 9fd4ae95.
- **Matriz del auditor (read-only):** SIGUE contaminada — Champions publican NO_VALIDADO / dixon_coles_determinista (Barça 53.2, Stuttgart-Viking away 43.7, Napoli-Arsenal). El auditor pusheó 8 commits nuevos a chatgpt/soccer-full-data-closure (gates as-of, temporal-source, cutover preflight, NO_MODEL fail-closed) pero son STAGED, NO aplicados a prod. → NO converjo v_futpro_v2 a la matriz (anti-regresión). reto_dc_v2 sigue siendo el único cerebro vivo.
- **Verificación backend (prod):** v_futpro_v2 = 221 eventos, 116 READY, todos con P_RETO+marcador+mejor_pick+BTTS; 71 con línea O/U real (resto fail-closed correcto). Los 42 "1-1" son argmax LEGÍTIMO de Dixon-Coles (verificado a mano: Eyupspor 1-1 @10.5% coincide con Poisson+τ ρ=-0.05). Favoritos fuertes SÍ dan marcador decisivo (América 2-0, Real Madrid 2-0, Galatasaray 90%→3-0). Variedad sana: 10 marcadores distintos. NO es default.
- **Percepción "todos 1-1":** enviado build a Lovable para mostrar TOP-3 marcadores desde `score_dist` (array {s,p}) en tarjeta y sheet, en vez de un solo puntual. Mata la percepción sin tocar el motor.
- **NAV (pedido del usuario, despierto):** enviado build — una sola fila 3·(+)·3: INICIO/FUT PRO/MLB · (+) · NFL/RETO 13M/MENÚ; MENÚ pasa a la misma fila (ya no cuelga abajo).
- **SEGURIDAD (zero-risk aplicado):** REVOKE write (INSERT/UPDATE/DELETE/TRUNCATE) de anon+authenticated en v_analisis_v2 y v_reto13m_daily (v_futpro_v2 ya estaba); SELECT conservado. Doc de diseño por fases: docs/ISS-025_RLS_SECURITY_HARDENING_DESIGN.md (107 tablas sin RLS, 67 vistas SECURITY DEFINER — ejecución por fases con el usuario despierto; el hueco grave es dinero/bankroll legible por anon → prioridad tras inventario Fase 1).
- **GATES self-check (116 READY):** engine_not_goalrates=0, temporal=0, hardcoded_over=0, unsafe_sample=0, crossleague_published=0, score_incoherent=0. TODO PASS. Sin regresión.
LAST_DB_MIGRATION: revoke_write_v_analisis_v2_v_reto13m_daily (grants); sin cambios de motor
NEXT_TASK: verificar que aterricen los 3 builds de Lovable (top-3 marcador, nav 3·+·3); Fase 1 inventario acceso anon; seguir esperando hardening de la matriz para converger. NO MLB hasta PASS de fútbol.
