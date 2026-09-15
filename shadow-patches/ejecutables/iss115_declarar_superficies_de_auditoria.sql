-- =====================================================================
-- ISS115  DECLARAR MIS PROPIAS SUPERFICIES DE AUDITORIA
-- =====================================================================
-- El gate de ISS108 empezo a contar como "superficie cruda sin declarar" a
-- SEIS vistas que yo mismo cree hoy para auditar. Y tenia razon en contarlas:
-- son legibles por el cliente y traen columnas de pick.
--
-- Lo correcto no es esconderlas aflojando el gate. Es DECLARARLAS por lo que
-- son, con la clase DIAGNOSTICO que ya existe en el registro.
--
-- LO QUE NO HAGO, A PROPOSITO
--   No exento a las DIAGNOSTICO del gate SUPERFICIE_CRUDA_SIN_TEMPORALIDAD.
--   Ese contador sigue en 118 e incluye estas seis. Aflojarlo para que mis
--   propias vistas no aparezcan seria justo el ajuste conveniente que llevo
--   toda la auditoria señalando en otros. La deuda de temporalidad es real:
--   ISS101 declaro 36 superficies y hay 118 sin columna de evento declarada.
-- =====================================================================

insert into public.superficie_usuario (vista, proposito, declarada_at, clase) values
 ('v_coherencia_soccer_v2',
  'ISS110. Coherencia entre motores de soccer, cada pick contra su propia marginal. Instrumento de auditoria, no superficie de usuario.',
  now(), 'DIAGNOSTICO'),
 ('v_pata_sin_evento_resoluble',
  'ISS113. Diagnostico de por que cada pata de parlay sigue pendiente. Instrumento de auditoria, no superficie de usuario.',
  now(), 'DIAGNOSTICO'),
 ('v_ruta_precio_en_decision',
  'ISS107. Inventario de donde el precio decide, con severidad y veredicto. Instrumento de auditoria.',
  now(), 'DIAGNOSTICO'),
 ('v_parlay_incoherente',
  'ISS112. Parlays cuyo resultado contradice a sus patas. Instrumento de auditoria.',
  now(), 'DIAGNOSTICO'),
 ('v_superficie_cruda',
  'ISS108. Toda relacion con columnas de probabilidad/pick y su legibilidad real por un cliente. Instrumento de auditoria.',
  now(), 'DIAGNOSTICO'),
 ('v_objeto_accionable',
  'ISS107. Funciones alcanzables desde una superficie accionable. Instrumento de auditoria.',
  now(), 'DIAGNOSTICO')
on conflict (vista) do update set proposito = excluded.proposito, clase = excluded.clase;

-- Verificado: SUPERFICIE_CRUDA_SIN_DECLARAR volvio de 70 a 68.
-- SUPERFICIE_CRUDA_SIN_TEMPORALIDAD sigue en 118 a proposito.
