-- ISS101 — inventario temporal EXPLICITO de la cuarentena Under 3.5.
-- issue #4: "terminar el inventario temporal explícito de Under-3.5
-- (match_date, fecha_utc, etc.)".
--
-- POR QUE HACIA FALTA: el gate de ISS100 buscaba la fecha por NOMBRE entre 6
-- candidatos (arranca_en, kickoff, fecha_evento, comienza_en, fecha_partido,
-- fecha) y se perdio match_date, fecha_utc, fecha_seleccion e
-- intended_game_date. Por eso reporto 328 filas "sin columna de fecha" cuando en
-- realidad las 10 vistas SI tenian columna temporal. Adivinar por nombre fue el
-- error; esta tabla lo reemplaza por una declaracion.
--
-- DISTINCION QUE HACE EL TRABAJO: fecha del EVENTO vs sello de REGISTRO.
-- created_at, updated_at, calculado_at, congelado_at, momio_leido_en,
-- momio_capturado_at, clv_registrado_at y occurred_at dicen cuando se ESCRIBIO la
-- fila, no cuando se juega. Usar cualquiera de esos para decidir si una prediccion
-- apunta al futuro es incorrecto: un pick creado ayer puede ser de un partido de
-- manana.

begin;

create table if not exists public.superficie_temporalidad (
  vista              text primary key,
  columna_evento     text,
  tipo               text not null check (tipo in ('EVENTO','SIN_FECHA_EVENTO')),
  motivo             text not null,
  declarada_at       timestamptz not null default now(),
  columna_resultado  text,
  valores_pendientes text[]
);

comment on table public.superficie_temporalidad is
 'Inventario temporal EXPLICITO por superficie. columna_evento es la fecha DEL EVENTO, nunca la del registro. columna_resultado es la segunda via de prueba: una fila LIQUIDADA demuestra que el evento ocurrio aunque no haya fecha. Sin ninguna de las dos, la fila no se puede clasificar y el gate falla cerrado.';

insert into public.superficie_temporalidad (vista, columna_evento, tipo, motivo) values
 ('ai_picks_historial','match_date','EVENTO','fecha del partido'),
 ('nfl_picks_premium','fecha','EVENTO','fecha del partido'),
 ('picks_premium','fecha','EVENTO','fecha del partido'),
 ('picks_reales','fecha','EVENTO','fecha del partido; intended_game_date es la intencion, no el evento'),
 ('picks_recomendados_hoy','arranca_en','EVENTO','kickoff'),
 ('track_record_historial','match_date','EVENTO','fecha del partido'),
 ('v_analisis_fut_completo','fecha','EVENTO','fecha del partido'),
 ('v_apuestas_equipo','fecha','EVENTO','fecha del partido'),
 ('v_btts_candidatos_activos','match_date','EVENTO','fecha del partido'),
 ('v_mejor_pick_por_partido','arranca_en','EVENTO','kickoff'),
 ('v_mejores_picks_mlb','arranca_en','EVENTO','first pitch'),
 ('v_motor_valor_proximos','fecha_utc','EVENTO','kickoff en UTC'),
 ('v_oraculo_canonico','arranca_en','EVENTO','kickoff'),
 ('v_oraculo_picks_activos','match_date','EVENTO','fecha del partido'),
 ('v_pick_canonico','arranca_en','EVENTO','kickoff'),
 ('v_picks_con_valor','arranca_en','EVENTO','kickoff'),
 ('v_picks_futbol_calc','fecha','EVENTO','fecha del partido'),
 ('v_picks_futbol_calibrado','arranca_en','EVENTO','kickoff'),
 ('v_picks_futbol_limpio','fecha','EVENTO','fecha del partido; calculado_at es sello de escritura'),
 ('v_picks_medibles','match_date','EVENTO','fecha del partido'),
 ('v_picks_mlb_modelo','arranca_en','EVENTO','first pitch'),
 ('v_picks_para_parlay','match_date','EVENTO','fecha del partido'),
 ('v_picks_premium','match_date','EVENTO','fecha del partido'),
 ('v_reto13m_analisis_experimental','arranca_en','EVENTO','kickoff'),
 ('v_reto13m_lo_mejor','arranca_en','EVENTO','kickoff'),
 ('v_reto13m_mejores','arranca_en','EVENTO','kickoff'),
 ('v_super_pick','match_date','EVENTO','fecha del partido; momio_leido_en es sello de lectura de momio'),
 ('pa_activados_recientes',null,'SIN_FECHA_EVENTO','solo occurred_at, que es cuando se activo la alerta, no cuando se juega'),
 ('pa_rechazos_recientes',null,'SIN_FECHA_EVENTO','solo occurred_at, sello de escritura'),
 ('track_record_detalle',null,'SIN_FECHA_EVENTO','fecha_seleccion es cuando se eligio y congelado_at cuando se congelo; ninguna es la fecha del partido'),
 ('v_pick_momio_libro',null,'SIN_FECHA_EVENTO','solo momio_leido_en, que es cuando se leyo el momio'),
 ('v_tr_base',null,'SIN_FECHA_EVENTO','solo created_at, sello de escritura')
on conflict (vista) do update set columna_evento=excluded.columna_evento,
  tipo=excluded.tipo, motivo=excluded.motivo;

-- segunda via de prueba para las que no tienen fecha de evento
update public.superficie_temporalidad
   set columna_resultado='resultado', valores_pendientes=array['pendiente']
 where vista in ('track_record_detalle','track_record_historial','v_tr_base');

commit;

-- =====================================================================
-- FILTRO A NIVEL DE FILA en las vistas que mezclan historia y futuro
-- =====================================================================
-- ERROR MIO EN ISS100, CORREGIDO AQUI: filtre 4 vistas ENTERAS
-- (v_analisis_fut_completo, picks_premium, v_picks_futbol_limpio,
-- picks_recomendados_hoy) en vez de por fila. En las dos que si tenian filas
-- pasadas eso borro registro historico. picks_premium y picks_recomendados_hoy
-- resultaron ser 100% prospectivas (0 filas pasadas), asi que ahi no hubo dano.
do $$
declare v record; v_def text;
begin
  for v in
    select t.vista, t.columna_evento,
           (select a.attname from pg_attribute a where a.attrelid=('public.'||t.vista)::regclass
             and a.attnum>0 and not a.attisdropped and a.attname in ('pick_desc','pick')
             order by case a.attname when 'pick_desc' then 1 else 2 end limit 1) col_pick
    from superficie_temporalidad t
    where t.vista in ('ai_picks_historial','v_motor_valor_proximos','v_oraculo_picks_activos',
                      'v_picks_medibles','v_picks_para_parlay')
  loop
    v_def := pg_get_viewdef(('public.'||v.vista)::regclass);
    if v_def ~ 'pick_en_cuarentena' then continue; end if;
    execute format(
      'create or replace view public.%I as select * from (%s) _pool where not (public.pick_en_cuarentena(%L,%L,_pool.%I) and _pool.%I > now())',
      v.vista, rtrim(rtrim(v_def),';'), 'soccer','Over/Under', v.col_pick, v.columna_evento);
  end loop;
end $$;

-- =====================================================================
-- ASSERTIONS
-- =====================================================================
do $$
declare g jsonb;
begin
  -- toda superficie con columna de pick tiene que estar declarada
  if exists (
    select 1 from superficie_usuario s
    join pg_class c on c.relname=s.vista and c.relnamespace='public'::regnamespace
    where s.clase='USUARIO' and c.relkind in ('v','m')
      and exists (select 1 from pg_attribute a where a.attrelid=c.oid and a.attnum>0
                   and not a.attisdropped and a.attname in ('pick_desc','pick'))
      and not exists (select 1 from superficie_temporalidad t where t.vista=s.vista))
  then raise exception 'ASSERT 1 FALLO: hay superficies con pick sin declarar temporalidad'; end if;

  -- ninguna columna de evento puede ser un sello de escritura
  if exists (select 1 from superficie_temporalidad
              where columna_evento ~* '^(created_at|updated_at|calculado_at|congelado_at|momio_leido_en|momio_capturado_at|clv_registrado_at|occurred_at)$')
  then raise exception 'ASSERT 2 FALLO: una columna_evento es en realidad un sello de registro'; end if;

  g := gate_mercado_en_cuarentena();
  if (g->>'MERCADO_EN_CUARENTENA_CANDIDATO')::int <> 0 then
    raise exception 'ASSERT 3 FALLO: % predicciones en cuarentena sobre eventos futuros', g->>'MERCADO_EN_CUARENTENA_CANDIDATO'; end if;
  if (g->>'MERCADO_EN_CUARENTENA_SIN_CLASIFICAR')::int <> 0 then
    raise exception 'ASSERT 4 FALLO: % filas sin clasificar', g->>'MERCADO_EN_CUARENTENA_SIN_CLASIFICAR'; end if;
  if (g->>'SUPERFICIE_CON_PICK_SIN_DECLARAR_TEMPORALIDAD')::int <> 0 then
    raise exception 'ASSERT 5 FALLO: superficie sin declarar'; end if;
  -- la historia NO se borro
  if (g->>'en_cuarentena_historico_por_fecha')::int = 0 then
    raise exception 'ASSERT 6 FALLO: no queda historia Under 3.5; se falsifico el registro'; end if;

  raise notice 'ISS101 OK: 6 assertions pasadas';
end $$;

-- ESTADO AL CERRAR ISS101 (2026-09-12):
--   MERCADO_EN_CUARENTENA_CANDIDATO                = 0     (bloqueante, limpio)
--   MERCADO_EN_CUARENTENA_SIN_CLASIFICAR           = 0     (bloqueante, limpio)
--   SUPERFICIE_CON_PICK_SIN_DECLARAR_TEMPORALIDAD  = 0     (bloqueante, limpio)
--   en_cuarentena_historico_por_fecha              = 201   preservado
--   en_cuarentena_historico_por_liquidacion        = 8     preservado
--   en_cuarentena_pendiente_sin_liquidar           = 24    ABIERTO
--
-- Las 24 pendientes estan en track_record_detalle con resultado='pendiente' y
-- fecha_seleccion entre 2026-08-19 y 2026-09-11. Son selecciones viejas que nunca
-- se liquidaron. No las filtro porque eso cambiaria el denominador del track
-- record, y no las declaro historicas porque 'pendiente' no prueba nada.
-- Necesitan liquidarse o anularse; es una decision de producto, no mia.
