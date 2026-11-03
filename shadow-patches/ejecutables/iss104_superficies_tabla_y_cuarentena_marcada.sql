-- ISS104 — P0-3: re-inventario de Under 3.5 desde el HEAD real.
--
-- PUNTO CIEGO ENCONTRADO: TODOS mis gates de superficie recorrian solamente
-- `relkind in ('v','m')`. Una TABLA con picks publicados era invisible para el
-- registro y para la cuarentena. Cuatro superficies estaban fuera de radar:
--   pick_del_dia               32 filas, col pick_desc   (Pick del Dia)
--   pick_del_dia_temporada_1   57 filas
--   oraculo_picks_tracking   3737 filas, col pick_desc   (Oraculo)
--   oraculo_prob_picks          0 filas
--
-- CONTAMINACION REAL QUE OCULTABA: 24 picks Under 3.5 sobre eventos FUTUROS en
-- oraculo_picks_tracking. La vista v_oraculo_picks_activos ya estaba filtrada,
-- asi que la superficie de usuario salia limpia mientras la tabla que la
-- alimenta seguia sucia: cualquier consumidor que leyera la tabla directo veia
-- los 24.
--
-- COMO SE NEUTRALIZA, SIN BORRAR: marca `cuarentena_at` / `cuarentena_motivo`.
-- Borrar filas de una tabla de seguimiento de lo que se PUBLICO seria falsificar
-- el registro. La fila se conserva, deja de ser accionable, y el gate descuenta
-- solo lo ya marcado.
begin;

insert into superficie_usuario(vista, proposito, declarada_at, clase) values
 ('pick_del_dia','Pick del Dia publicado. TABLA, no vista: el registro de superficie solo miraba vistas.', now(), 'USUARIO'),
 ('oraculo_picks_tracking','Picks del Oraculo con seguimiento. TABLA.', now(), 'USUARIO'),
 ('oraculo_prob_picks','Picks probabilisticos del Oraculo. TABLA.', now(), 'USUARIO'),
 ('pick_del_dia_temporada_1','Pick del Dia, temporada 1. TABLA historica.', now(), 'USUARIO')
on conflict (vista) do nothing;

insert into superficie_temporalidad(vista, columna_evento, tipo, motivo) values
 ('pick_del_dia','match_date','EVENTO','fecha del partido; fecha es el dia de publicacion'),
 ('oraculo_picks_tracking','match_date','EVENTO','fecha del partido'),
 ('oraculo_prob_picks','match_date','EVENTO','fecha del partido'),
 ('pick_del_dia_temporada_1','match_date','EVENTO','fecha del partido')
on conflict (vista) do update set columna_evento=excluded.columna_evento,
  tipo=excluded.tipo, motivo=excluded.motivo;

alter table public.oraculo_picks_tracking
  add column if not exists cuarentena_at timestamptz,
  add column if not exists cuarentena_motivo text;

comment on column public.oraculo_picks_tracking.cuarentena_at is
 'Marca de cuarentena. La fila NO se borra: borrar registro de lo que se publico seria falsificarlo. Marcada = excluida de toda superficie accionable.';

update public.oraculo_picks_tracking
   set cuarentena_at = now(),
       cuarentena_motivo = 'mercado_cuarentena: Under/Menos 3.5 en futbol, evento futuro'
 where pick_en_cuarentena('soccer','Over/Under', pick_desc)
   and match_date > now()
   and cuarentena_at is null;

commit;

-- gate_mercado_en_cuarentena() se reescribe para (a) recorrer tambien relkind 'r'
-- y (b) descontar las filas ya marcadas. Cuerpo completo en produccion; su md5 se
-- verifica en verificar_checksums_iss104.sql.
--
-- ESTADO 2026-09-12 tras ISS104:
--   MERCADO_EN_CUARENTENA_CANDIDATO               = 0
--   MERCADO_EN_CUARENTENA_SIN_CLASIFICAR          = 0
--   SUPERFICIE_CON_PICK_SIN_DECLARAR_TEMPORALIDAD = 0
--   filas_marcadas_en_cuarentena_preservadas      = 24
--   en_cuarentena_historico_por_fecha             = 295  (subio de 201: ahora se
--     ven las tablas que antes no se contaban)
--   en_cuarentena_historico_por_liquidacion       = 8
--   en_cuarentena_pendiente_sin_liquidar          = 24   ABIERTO
--
-- ADVERTENCIA PARA EL SIGUIENTE CICLO: `SUPERFICIE_SIN_CLASIFICAR` dentro de
-- pruebas_selector_limpio() TODAVIA recorre solo v/m. Tiene el mismo punto ciego
-- y hay que cerrarlo igual.
