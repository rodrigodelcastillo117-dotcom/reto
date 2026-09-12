# BARRIDO EDGE — clasificacion (running)
# formato: slug | verify_jwt | auth | identidad objetivo | reads | writes | veredicto

recalibrate-model-weights | false | NINGUNA | n/a (global) | algorithm_feedback_logs | model_weights (UPDATE global) | P1-WRITE: escritura no autenticada a pesos del modelo. Debe exigir service. No user-private.
procesar-venganza | true | getUser (real) | body pick_id/jugador_id SIN check de propiedad | pit_picks,pit_jugadores | pit_jugadores UPDATE | P1-AUTHZ (IDOR write): JWT A + jugador_id de B revive/elimina el PIT de B. Falta ownership.
analizar-partido-ligamx | false | NINGUNA | partido_id (publico) | ligamx_* | ligamx_analisis INSERT | SAFE-ish (analisis publico; write no user-private; unauth trigger de LLM = costo IA)
get-parlay-with-scores | false | NINGUNA | body apodo + uuids | parlays,picks,live | none | P0-READ (gated uuid+apodo). Debe exigir sesion.
crear-parlay-screenshot | true | (por confirmar) | body apodo | - | parlays INSERT | P1-AUTHZ write (trusts body.apodo)
enviar-notificacion-push | false | Bearer presente pero NO validado (solo checa prefijo) | body apodo | push_subscriptions | push a apodo + delete subs expiradas | P1-ABUSE: cualquiera con un Bearer cualquiera manda push a CUALQUIER apodo (phishing). Debe exigir service token real (uso interno).
compartir-analisis | false | NINGUNA | espn_event_id (publico) | analisis_partidos | none | SAFE (contenido publico de analisis)
recalibrate-model-weights,procesar-venganza | (ver arriba) | | | | |
manual-calificar-pick | true | getUser + usuarios.email==user.email | ownership OK | picks,parlays | UPDATE resultado/bankroll | SAFE (propiedad por JWT email)
manual-calificar-parlay | true | getUser + usuarios.email | ownership OK | parlays | UPDATE resultado/cashout | SAFE
detect-user-patterns | false | NINGUNA | body apodo (opt) | picks,parlays | user_patterns UPSERT | P0-READ+WRITE: sin auth devuelve pnl/insights ($ perdido) de cualquier apodo y escribe user_patterns. Debe ser service-only.
confirmar-fecha-pick | false | NINGUNA | body target_id (uuid) SIN ownership | picks/parlays | UPDATE espn_event_id/partido/fecha | P0-WRITE (IDOR): sin auth reescribe a que partido apunta la apuesta de otro -> mis-grade. Debe exigir sesion+propiedad.
reconectar-picks-huerfanos | false | NINGUNA | n/a (global, todos los huerfanos) | picks,parlays | UPDATE espn linkage | P2-INTERNAL: cron sin auth. Abuso = costo API-Football + recomputo. No fuga user-data.
oraculo-premium | false | NINGUNA | n/a (global) | analisis_partidos,market_calibration | oraculo_picks_tracking INSERT | P2-INTERNAL: cron sin auth quema creditos Anthropic. No user-data.
track-record | false | NINGUNA | n/a | agregados globales (ai_track_record_v2) | none | SAFE (agregado publico intencional; sin datos por-usuario)
scan-fantasy-lineup | false | apodoDelLlamante (valida /auth/v1/user; service por token-as-apikey real) | JWT | fantasy_liga_config | none | SAFE (auth correcta; no money)
cashout-contexto | false | autorizado() (valida /auth/v1/user o token-as-apikey) | JWT | ESPN publico | none | SAFE (auth presente; datos publicos)
log-scan-result | false | NINGUNA | body apodo | - | scan_logs INSERT | P2-WRITE: escritura no autenticada de scan_logs con apodo arbitrario (pollution + image_url arbitrario). Telemetria, no dinero.
procesar-venganza | true | getUser | RECLASIFICADO: pit_jugadores/pit_picks NO existen -> DEAD, 404 siempre, IDOR no explotable
crear-parlay-screenshot | true | NINGUNA (no getUser) | body.apodo | - | parlays INSERT | P1-AUTHZ write CONFIRMADO (diff en DIFFS_SEGURIDAD.md)
detect-user-patterns | false | NINGUNA | body.apodo/todos | picks,parlays | user_patterns | P0 cron sin auth (diff: SNIPPET A)
