-- ISS167: 82 trabajos llevaban una semana persiguiendo partidos ya jugados
--
-- SINTOMA: G34.1 en FAIL, "KV Kortrijk (87 intentos)".
--
-- CAUSA, que resulto ser general y no de un equipo:
--   v2.soccer_coverage_job guarda el next_kickoff que motivo cada trabajo.
--   La cola no retiraba nunca un trabajo cuyo partido ya se habia jugado, asi
--   que seguia reintentando para siempre un dato que ya no sirve para nada.
--
--     Willem II      103 intentos   next_kickoff 2026-09-11 (hacia 6 dias)
--     Ross County    101 intentos   next_kickoff 2026-09-12
--     KV Kortrijk     87 intentos   next_kickoff ya pasado
--
--   Medido: de 159 trabajos activos, 82 apuntaban a un partido ya jugado.
--
-- ARREGLO: estado RETIRADO_PARTIDO_YA_JUGADO, con el motivo escrito en
-- last_error (fecha del kickoff e intentos acumulados). NO se borra ninguna
-- fila: queda el historial de lo que se intento y por que se dejo.
--
-- RESULTADO
--                                antes     despues
--   trabajos activos              159          77
--   peor numero de intentos       103           7
--   G34.1                        FAIL        PASS
--
-- PENDIENTE (no se hace aqui): la cola deberia retirarlos sola. Hoy se limpio
-- a mano. Si no se automatiza, en una semana vuelve a pasar. Va aparte.

update v2.soccer_coverage_job
set status = 'RETIRADO_PARTIDO_YA_JUGADO',
    last_error = coalesce(last_error,'')||' | ISS167: retirado el '||now()::date
                 ||'. El partido que lo motivo (next_kickoff '||next_kickoff::date
                 ||') ya se jugo, asi que este trabajo no puede servir para nada. '
                 ||'Llevaba '||attempts||' intentos. No se borra: queda el historial.',
    updated_at = now()
where status in ('PENDING','RETRY') and next_kickoff < now();
