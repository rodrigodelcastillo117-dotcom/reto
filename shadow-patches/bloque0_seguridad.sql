-- =====================================================================
-- BLOQUE 0 — SEGURIDAD (ISS-001, ISS-002, ISS-008)   ** NO APLICADO **
-- PATCH SHADOW para revisión. NO ejecutar sin GO explícito.
-- Preparado a partir de AUDIT_360 (AUDIT_AS_OF 2026-09-07T03:41:49Z).
-- Proyecto: wpiztubmmmzclhlprgpd
--
-- INVARIANTES (lo que este patch NO toca):
--   * NO modelos, probabilidades, EV, Kelly ni gates.
--   * NO semántica económica legítima (tipos, validaciones, montos, ajustes_cuenta).
--   * Solo AÑADE binding de identidad server-side y RECORTA grants.
--   * Identidad económica deriva de auth.uid() vía funciones #262 ya en prod
--     (apodo_scope / resolver_identidad_economica). p_apodo se mantiene por
--     compatibilidad de firma pero se valida/deriva server-side.
--   * Ruta INTERNAL (service_role/jobs) preservada por resolver_identidad_economica
--     (clase INTERNAL con p_apodo explícito y auditable).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- ISS-001 — ESCRITURAS DE DINERO: bindear identidad (rechazo duro de ajeno)
-- Patrón: resolver_identidad_economica() -> {ok, apodo, motivo}.
--   authenticated propio -> ok, apodo=propio ; ajeno -> IDENTIDAD_AJENA_RECHAZADA (aborta)
--   INTERNAL/service_role -> ok con p_apodo explícito (jobs siguen) ; anon -> rechazado.
-- Cambio mínimo: resolver al inicio y reasignar p_apodo; el resto del cuerpo INTACTO.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_ajuste_manual(p_apodo text, p_monto numeric, p_tipo text, p_descripcion text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_ident jsonb;                          -- [ISS-001] binding de identidad
  v_user_id_internal UUID;
  v_ajuste_id UUID;
  v_bankroll_nuevo NUMERIC;
BEGIN
  -- [ISS-001] Identidad server-side: rechaza p_apodo ajeno; deriva de auth.uid().
  v_ident := public.resolver_identidad_economica(p_apodo);
  IF NOT COALESCE((v_ident->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'IDENTIDAD_RECHAZADA: %', COALESCE(v_ident->>'motivo','CONTEXTO_NO_RECONOCIDO');
  END IF;
  p_apodo := v_ident->>'apodo';

  -- Validar tipo
  IF p_tipo NOT IN ('bono', 'maquinita', 'deposito', 'retiro', 'otro', 'sincronizacion') THEN
    RAISE EXCEPTION 'Tipo inválido: %. Usa bono/maquinita/deposito/retiro/otro', p_tipo;
  END IF;

  -- Validar monto no cero
  IF p_monto = 0 THEN
    RAISE EXCEPTION 'El monto no puede ser cero';
  END IF;

  -- Buscar el id interno del usuario
  SELECT id INTO v_user_id_internal
  FROM usuarios WHERE apodo = p_apodo;

  IF v_user_id_internal IS NULL THEN
    RAISE EXCEPTION 'Usuario % no encontrado', p_apodo;
  END IF;

  -- Insertar
  INSERT INTO ajustes_cuenta (user_id, apodo, fecha, tipo, monto, descripcion)
  VALUES (
    v_user_id_internal,
    p_apodo,
    CURRENT_DATE,
    p_tipo,
    p_monto,
    p_descripcion
  )
  RETURNING id INTO v_ajuste_id;

  v_bankroll_nuevo := get_bankroll_disponible(p_apodo);

  RETURN jsonb_build_object(
    'ajuste_id', v_ajuste_id,
    'monto', p_monto,
    'tipo', p_tipo,
    'bankroll_nuevo', v_bankroll_nuevo,
    'mensaje', 'Ajuste registrado'
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.registrar_movimiento_cuenta(p_apodo text, p_monto numeric, p_tipo text, p_descripcion text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ident jsonb; v_uid uuid; v_antes numeric; v_despues numeric;   -- [ISS-001] v_ident
begin
  -- [ISS-001] Identidad server-side: rechaza p_apodo ajeno (estilo jsonb-error de esta función).
  v_ident := public.resolver_identidad_economica(p_apodo);
  if not coalesce((v_ident->>'ok')::boolean, false) then
    return jsonb_build_object('error','Identidad no autorizada','motivo', v_ident->>'motivo');
  end if;
  p_apodo := v_ident->>'apodo';

  if p_tipo not in ('bono','freebet','cashback','deposito','retiro','correccion') then
    return jsonb_build_object('error',
      'Tipo no valido. Usa: bono, freebet, cashback, deposito, retiro o correccion.');
  end if;
  if p_monto is null or p_monto = 0 then
    return jsonb_build_object('error','El monto no puede ser cero.');
  end if;
  if p_tipo in ('bono','freebet','cashback','deposito') and p_monto < 0 then
    return jsonb_build_object('error', format('Un %s suma, no resta. Usa monto positivo.', p_tipo));
  end if;
  if p_tipo = 'retiro' and p_monto > 0 then
    return jsonb_build_object('error','Un retiro resta. Usa monto negativo.');
  end if;

  select id into v_uid from usuarios where apodo = p_apodo;
  if v_uid is null then return jsonb_build_object('error','No encuentro ese usuario.'); end if;

  v_antes := public.get_bankroll_real(p_apodo);

  insert into ajustes_cuenta (user_id, apodo, fecha, tipo, monto, descripcion)
  values (v_uid, p_apodo, current_date, p_tipo, p_monto,
          coalesce(p_descripcion, initcap(p_tipo)||' registrado desde la app'));

  v_despues := public.get_bankroll_real(p_apodo);

  return jsonb_build_object(
    'ok', true, 'tipo', p_tipo, 'monto', p_monto,
    'banca_antes', v_antes, 'banca_despues', v_despues,
    'nota', case when p_tipo in ('bono','freebet','cashback')
      then 'Suma a tu banca pero NO cuenta como apuesta ganada: tu ROI y tu porcentaje de aciertos no se mueven. Es dinero regalado, no habilidad.'
      else 'Movimiento de cuenta. No cuenta como apuesta.' end);
end;
$function$;

-- ---------------------------------------------------------------------
-- ISS-002 — LECTURAS FINANCIERAS: auto-scope al apodo del JWT (apodo_scope),
-- mismo patrón ya en prod de calcular_bankroll_actual. Ignora p_apodo ajeno
-- (devuelve los datos del propio usuario). service_role sin JWT -> pasa p_apodo (interno).
-- Cambio mínimo: una línea al inicio; resto del cuerpo INTACTO.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_dashboard_stats(p_apodo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bankroll_inicial NUMERIC;
  v_bankroll_disponible NUMERIC;
  v_bankroll_total NUMERIC;
  v_picks_pend_cnt INT;
  v_picks_pend_total NUMERIC;
  v_parlays_pend_cnt INT;
  v_parlays_pend_total NUMERIC;
  v_stats_7d JSONB;
  v_stats_30d JSONB;
  v_curva JSONB;
BEGIN
  p_apodo := public.apodo_scope(p_apodo);   -- [ISS-002] auto-scope al apodo del JWT

  SELECT bankroll_inicial INTO v_bankroll_inicial FROM usuarios WHERE apodo = p_apodo;
  v_bankroll_disponible := get_bankroll_disponible(p_apodo);
  v_bankroll_total := get_bankroll_patrimonio(p_apodo);

  SELECT COUNT(*), COALESCE(SUM(apuesta),0) INTO v_picks_pend_cnt, v_picks_pend_total
  FROM picks WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado='pendiente';
  SELECT COUNT(*), COALESCE(SUM(apuesta),0) INTO v_parlays_pend_cnt, v_parlays_pend_total
  FROM parlays WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado='pendiente';

  WITH eventos_7d AS (
    SELECT apuesta, resultado, ganancia_neta FROM picks
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
        AND fecha >= CURRENT_DATE - INTERVAL '7 days'
    UNION ALL
    SELECT apuesta, resultado, ganancia_neta FROM parlays
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
        AND fecha >= CURRENT_DATE - INTERVAL '7 days'
  )
  SELECT jsonb_build_object(
    'eventos', COUNT(*),
    'wins', COUNT(*) FILTER (WHERE resultado='ganado'),
    'losses', COUNT(*) FILTER (WHERE resultado='perdido'),
    'pushes', COUNT(*) FILTER (WHERE resultado IN ('nulo','push')),
    'wr_pct', CASE WHEN COUNT(*) FILTER (WHERE resultado IN ('ganado','perdido')) > 0
                   THEN ROUND(100.0 * COUNT(*) FILTER (WHERE resultado='ganado')
                              / COUNT(*) FILTER (WHERE resultado IN ('ganado','perdido')), 1)
                   ELSE NULL END,
    'profit', ROUND(COALESCE(SUM(ganancia_neta), 0), 2),
    'apostado', ROUND(COALESCE(SUM(apuesta), 0), 2),
    'roi_pct', CASE WHEN COALESCE(SUM(apuesta),0) > 0
                    THEN ROUND(100.0 * SUM(ganancia_neta) / SUM(apuesta), 1)
                    ELSE NULL END
  ) INTO v_stats_7d
  FROM eventos_7d;

  WITH eventos_30d AS (
    SELECT apuesta, resultado, ganancia_neta FROM picks
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
        AND fecha >= CURRENT_DATE - INTERVAL '30 days'
    UNION ALL
    SELECT apuesta, resultado, ganancia_neta FROM parlays
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
        AND fecha >= CURRENT_DATE - INTERVAL '30 days'
  )
  SELECT jsonb_build_object(
    'eventos', COUNT(*),
    'wins', COUNT(*) FILTER (WHERE resultado='ganado'),
    'losses', COUNT(*) FILTER (WHERE resultado='perdido'),
    'pushes', COUNT(*) FILTER (WHERE resultado IN ('nulo','push')),
    'wr_pct', CASE WHEN COUNT(*) FILTER (WHERE resultado IN ('ganado','perdido')) > 0
                   THEN ROUND(100.0 * COUNT(*) FILTER (WHERE resultado='ganado')
                              / COUNT(*) FILTER (WHERE resultado IN ('ganado','perdido')), 1)
                   ELSE NULL END,
    'profit', ROUND(COALESCE(SUM(ganancia_neta), 0), 2),
    'apostado', ROUND(COALESCE(SUM(apuesta), 0), 2),
    'roi_pct', CASE WHEN COALESCE(SUM(apuesta),0) > 0
                    THEN ROUND(100.0 * SUM(ganancia_neta) / SUM(apuesta), 1)
                    ELSE NULL END
  ) INTO v_stats_30d
  FROM eventos_30d;

  WITH dias AS (
    SELECT generate_series(
      CURRENT_DATE - INTERVAL '30 days',
      CURRENT_DATE,
      '1 day'::interval
    )::date AS fecha
  ),
  movimientos AS (
    SELECT fecha, ganancia_neta::numeric AS delta FROM picks
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
    UNION ALL
    SELECT fecha, ganancia_neta::numeric AS delta FROM parlays
      WHERE apodo=p_apodo AND created_at >= public.reto_desde(p_apodo) AND resultado IN ('ganado','perdido','nulo','push')
    UNION ALL
    SELECT fecha, monto::numeric AS delta FROM ajustes_cuenta
      WHERE apodo=p_apodo
  ),
  acumulado AS (
    SELECT d.fecha,
           v_bankroll_inicial + COALESCE(SUM(m.delta), 0) AS bankroll
    FROM dias d
    LEFT JOIN movimientos m ON m.fecha <= d.fecha
    GROUP BY d.fecha
    ORDER BY d.fecha
  )
  SELECT jsonb_agg(
    jsonb_build_object('fecha', fecha, 'bankroll', ROUND(bankroll, 2))
    ORDER BY fecha
  ) INTO v_curva
  FROM acumulado;

  RETURN jsonb_build_object(
    'bankroll', jsonb_build_object(
      'disponible', v_bankroll_disponible,
      'total', v_bankroll_total,
      'inicial', v_bankroll_inicial,
      'en_juego', v_bankroll_total - v_bankroll_disponible
    ),
    'pendientes', jsonb_build_object(
      'picks_cantidad', v_picks_pend_cnt,
      'picks_total', v_picks_pend_total,
      'parlays_cantidad', v_parlays_pend_cnt,
      'parlays_total', v_parlays_pend_total,
      'total_en_juego', v_picks_pend_total + v_parlays_pend_total
    ),
    'stats_7d', v_stats_7d,
    'stats_30d', v_stats_30d,
    'curva_bankroll_30d', v_curva,
    'calculado_en', NOW()
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.get_historial_reciente(p_apodo text, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_result JSONB;
BEGIN
  p_apodo := public.apodo_scope(p_apodo);   -- [ISS-002] auto-scope al apodo del JWT

  WITH unificado AS (
    SELECT
      'pick' AS tipo, id, fecha, partido AS descripcion, pick_desc, liga,
      apuesta, momio, resultado, ganancia_neta, created_at
    FROM picks WHERE apodo=p_apodo
    UNION ALL
    SELECT
      'parlay', id, fecha,
      FORMAT('Parlay de %s legs', jsonb_array_length(picks_data)),
      NULL, 'Multi-liga', apuesta, momio_total, resultado, ganancia_total, created_at
    FROM parlays WHERE apodo=p_apodo
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'tipo', tipo, 'id', id, 'fecha', fecha, 'descripcion', descripcion,
      'pick_desc', pick_desc, 'liga', liga, 'apuesta', apuesta, 'momio', momio,
      'resultado', resultado, 'ganancia_neta', ganancia_neta,
      'emoji', CASE
        WHEN resultado='ganado' THEN '✅'
        WHEN resultado='perdido' THEN '❌'
        WHEN resultado='pendiente' THEN '⏳'
        WHEN resultado IN ('nulo','push') THEN '➖'
        ELSE '❓'
      END
    )
    ORDER BY created_at DESC
  ) INTO v_result
  FROM (
    SELECT * FROM unificado ORDER BY created_at DESC LIMIT p_limit
  ) t;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

-- ---------------------------------------------------------------------
-- ISS-008 — DOS capas: (a) binding de identidad en los cuerpos (cierra el IDOR
-- entre usuarios AUTENTICADOS), (b) REVOKE anon/PUBLIC (cierra el ataque anónimo).
-- Identidad autoritativa = usuario_economico_actual() (deriva de auth.uid()); se
-- IGNORA el apodo/uid enviado por cliente; fail-closed si no hay identidad.
-- Sin ruta service_role para estas features de usuario (0 crons/edge las llaman).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.agregar_favorito(p_apodo text, p_deporte text, p_espn_team_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_yo text; v_uid uuid; v_c record;
begin
  v_yo := public.usuario_economico_actual();                                   -- [ISS-008]
  if v_yo is null then return jsonb_build_object('ok',false,'error','IDENTIDAD_REQUERIDA'); end if;
  p_apodo := v_yo;                                                             -- ignora apodo del cliente
  v_uid := uid_de_apodo(p_apodo);
  if v_uid is null then return jsonb_build_object('ok',false,'error','usuario no encontrado'); end if;
  select * into v_c from mv_catalogo_equipos where deporte=p_deporte and espn_team_id=p_espn_team_id;
  if not found then
    return jsonb_build_object('ok',false,'error','ese equipo no esta en las ligas principales que seguimos');
  end if;
  insert into equipos_favoritos(user_id, deporte, espn_team_id, nombre, pais, liga_casa)
  values (v_uid, p_deporte, p_espn_team_id, v_c.nombre, v_c.pais, v_c.liga_casa)
  on conflict (user_id, deporte, espn_team_id) do nothing;
  return jsonb_build_object('ok',true,'equipo',v_c.nombre,'pais',v_c.pais,'liga',v_c.liga_nombre);
end $function$;

CREATE OR REPLACE FUNCTION public.quitar_favorito(p_apodo text, p_deporte text, p_espn_team_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_yo text; v_uid uuid; v_n int;
begin
  v_yo := public.usuario_economico_actual();                                   -- [ISS-008]
  if v_yo is null then return jsonb_build_object('ok',false,'error','IDENTIDAD_REQUERIDA'); end if;
  p_apodo := v_yo;
  v_uid := uid_de_apodo(p_apodo);
  delete from equipos_favoritos
   where user_id = v_uid and deporte = p_deporte and espn_team_id = p_espn_team_id;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;

CREATE OR REPLACE FUNCTION public.aceptar_batalla(p_batalla_id uuid, p_apodo text, p_pick_b_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_yo text; v_bat record; v_pick_apodo text; v_pick_resultado text; v_ev_a record; v_ev_b record;
BEGIN
  v_yo := public.usuario_economico_actual();                                   -- [ISS-008]
  IF v_yo IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'IDENTIDAD_REQUERIDA'); END IF;
  p_apodo := v_yo;                                                             -- identidad autoritativa
  SELECT * INTO v_bat FROM batallas WHERE id = p_batalla_id;
  IF v_bat.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Batalla no encontrada'); END IF;
  IF v_bat.reto_contra <> p_apodo THEN RETURN jsonb_build_object('ok', false, 'error', 'Esta batalla no es para ti'); END IF;
  IF v_bat.estado <> 'esperando' THEN RETURN jsonb_build_object('ok', false, 'error', 'Esta batalla ya no acepta picks'); END IF;
  SELECT apodo, resultado INTO v_pick_apodo, v_pick_resultado FROM picks WHERE id = p_pick_b_id;
  IF v_pick_apodo IS NULL OR v_pick_apodo <> p_apodo THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ese pick no es tuyo');
  END IF;
  IF v_pick_resultado <> 'pendiente' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ese pick ya se calificó, elige uno pendiente');
  END IF;
  IF p_pick_b_id = v_bat.pick_a_id THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No puedes aceptar con el mismo pick del retador');
  END IF;
  SELECT * INTO v_ev_a FROM public.batalla_evento_de_pick(v_bat.pick_a_id);
  SELECT * INTO v_ev_b FROM public.batalla_evento_de_pick(p_pick_b_id);
  IF v_ev_b.evento_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ese pick no tiene partido identificado');
  END IF;
  IF v_ev_a.evento_id IS DISTINCT FROM v_ev_b.evento_id THEN
    RETURN jsonb_build_object('ok', false,
      'error', 'La batalla es del MISMO PARTIDO: necesitas un pick de ' || coalesce(v_ev_a.partido, 'ese partido'),
      'partido_requerido', v_ev_a.partido, 'partido_de_tu_pick', v_ev_b.partido);
  END IF;
  UPDATE batallas SET pick_b_id = p_pick_b_id, estado = 'activa' WHERE id = p_batalla_id;
  BEGIN
    PERFORM public.enviar_alerta(
      v_bat.reto_por, 'batalla_aceptada', p_batalla_id::text,
      '⚔️ ' || p_apodo || ' aceptó tu batalla',
      coalesce(v_ev_a.partido, 'El partido') || ' — se resuelve solo al calificar ambos picks.', '/batallas');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'aceptar_batalla: push falló para % : %', v_bat.reto_por, SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true, 'partido', v_ev_a.partido, 'evento_id', v_ev_a.evento_id);
END; $function$;

CREATE OR REPLACE FUNCTION public.cancelar_batalla(p_batalla_id uuid, p_apodo text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_yo text; v_bat record;
BEGIN
  v_yo := public.usuario_economico_actual();                                   -- [ISS-008]
  IF v_yo IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'IDENTIDAD_REQUERIDA'); END IF;
  p_apodo := v_yo;
  SELECT * INTO v_bat FROM batallas WHERE id = p_batalla_id;
  IF v_bat.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Batalla no encontrada'); END IF;
  IF v_bat.reto_por <> p_apodo AND v_bat.reto_contra <> p_apodo THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No puedes cancelar una batalla que no es tuya');
  END IF;
  IF v_bat.estado <> 'esperando' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ya no se puede cancelar');
  END IF;
  UPDATE batallas SET estado = 'cancelada' WHERE id = p_batalla_id;
  RETURN jsonb_build_object('ok', true);
END; $function$;

CREATE OR REPLACE FUNCTION public.generar_codigo_amigo(p_apodo text)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_yo text; v_codigo text;
BEGIN
  v_yo := public.usuario_economico_actual();                                   -- [ISS-008]
  IF v_yo IS NULL THEN RAISE EXCEPTION 'IDENTIDAD_REQUERIDA'; END IF;
  p_apodo := v_yo;
  SELECT codigo_amigo INTO v_codigo FROM usuarios WHERE apodo = p_apodo;
  IF v_codigo IS NOT NULL THEN RETURN v_codigo; END IF;
  LOOP
    v_codigo := upper(regexp_replace(substr(p_apodo,1,5), '[^a-zA-Z0-9]', '', 'g')) || '-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM usuarios WHERE codigo_amigo = v_codigo);
  END LOOP;
  UPDATE usuarios SET codigo_amigo = v_codigo WHERE apodo = p_apodo;
  RETURN v_codigo;
END; $function$;

-- (b) REVOKE anon/PUBLIC (defensa en profundidad; el binding ya protege authenticated).
REVOKE EXECUTE ON FUNCTION public.aceptar_batalla(uuid,text,uuid)   FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cancelar_batalla(uuid,text)       FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.agregar_favorito(text,text,text)  FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.quitar_favorito(text,text,text)   FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.generar_codigo_amigo(text)        FROM anon, PUBLIC;

-- Pipeline de marcadores: no tiene identidad de usuario -> fuera del cliente por completo.
REVOKE EXECUTE ON FUNCTION public.upsert_live_scores_guarded(jsonb) FROM anon, authenticated, PUBLIC;

COMMIT;

-- =====================================================================
-- FUERA DE BLOQUE 0 (ISS separados, su propio GO):
--   * IDOR de LECTURA anon NO-financiero (mis_favoritos, calificaciones_mis_equipos,
--     mis_batallas, ...) — P2, revisar caso por caso (dato no sensible vs cerrar).
--   * Resto de familia p_apodo de lectura: get_top_nichos_usuario, historial_por_equipo,
--     get_weekly_snapshots -> aplicar apodo_scope igual que ISS-002 (mismo patrón).
-- =====================================================================
