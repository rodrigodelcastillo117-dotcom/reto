-- =====================================================================
-- ISS124 : EL BLOQUE H2H SE DECLARABA CERTIFICADO Y VENIA VACIO
-- =====================================================================
-- Queja del dueno: "FUT PRO no tiene analisis de los partidos, en teoria ya
-- estaba, si hay analisis, pero no los muestra el frontend".
--
-- LO QUE ENCONTRE, midiendo y no suponiendo:
--
-- public.futpro_terminal_v2_certified_core arma el bloque h2h asi:
--
--   'factor_key','h2h','label','Enfrentamientos directos',
--   'status', case when coalesce(a.h2h_n,0)>0 and v_context_temporal_safe
--                  then 'CERTIFIED' else 'INSUFFICIENT_OR_UNCERTIFIED' end,
--   'role','FACTUAL_CONTEXT','used_in_p_reto',false,
--   'source','mv_futpro_analysis_v4',
--   'sample_n', a.h2h_n, 'payload', j#>'{match_context,h2h}'
--                                   ^^^^^^^^^^^^^^^^^^^^^^^^
-- El bloque DECLARA que su fuente es mv_futpro_analysis_v4 y toma su
-- sample_n de ahi (a.h2h_n), pero leia el payload de OTRA fuente: j, que es
-- public.futpro_terminal_v2_core(). Y ahi match_context.h2h vale JSON null.
--
-- Resultado medido sobre el evento 401914282 (Everton vs Wolverhampton):
--   mv_futpro_analysis_v4.h2h_n        = 5
--   mv_futpro_analysis_v4.h2h_recent   = array de 5 partidos reales con
--                                        marcador (Everton-Wolves 1-1 el
--                                        2026-01-07, etc.)
--   j #> '{match_context,h2h}'         = null
--   => el contrato publicaba status=CERTIFIED, sample_n=5, payload=null
--
-- Un bloque que se declara CERTIFICADO, dice que tiene 5 partidos de muestra
-- y entrega el payload vacio es exactamente lo que hace que un frontend
-- cuidadoso lo esconda. La informacion existia y no llegaba.
--
-- EL ARREGLO: alinear el payload con la fuente que el propio bloque ya
-- declara. Una sola expresion.
--
--   'payload', j#>'{match_context,h2h}'   ->   'payload', a.h2h_recent
--
-- NO cambia ninguna probabilidad, ni P_RETO, ni la seleccion, ni el orden,
-- ni el estado de ningun mercado. Solo deja de tirar un dato que ya estaba
-- calculado. Es aditivo: null -> datos reales.
--
-- md5(prosrc) antes:   db4fc1361a3d52405f0d98bbd360dc96
-- md5(prosrc) despues: 3f549ac196c24904ff9d42cdef64f3c7
-- El rastro queda en public.parche_contrato_futpro con su motivo.
-- =====================================================================

-- El parche se aplico sobre la definicion viva, sustituyendo UNA expresion.
-- Se exigio que apareciera exactamente una vez; si no, no se tocaba nada:
--
-- do $p$
-- declare
--   v_oid oid; v_def text; v_nuevo text;
--   k_viejo constant text := '''sample_n'',a.h2h_n,''payload'',j#>''{match_context,h2h}''';
--   k_nuevo constant text := '''sample_n'',a.h2h_n,''payload'',a.h2h_recent';
-- begin
--   select p.oid into v_oid from pg_proc p
--     join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
--    where p.proname='futpro_terminal_v2_certified_core';
--   v_def := pg_get_functiondef(v_oid);
--   if position(k_viejo in v_def) = 0 then
--     raise exception 'NO ENCONTRE LA EXPRESION EXACTA. No toco nada.';
--   end if;
--   if (length(v_def) - length(replace(v_def, k_viejo, ''))) / length(k_viejo) <> 1 then
--     raise exception 'LA EXPRESION APARECE MAS DE UNA VEZ. No toco nada.';
--   end if;
--   execute replace(v_def, k_viejo, k_nuevo);
-- end $p$;

create table if not exists public.parche_contrato_futpro (
  funcion text primary key,
  aplicado_at timestamptz not null default now(),
  md5_antes text not null,
  md5_despues text,
  cambio text not null,
  motivo text not null,
  revertido_at timestamptz
);
revoke all on public.parche_contrato_futpro from anon, authenticated;

-- =====================================================================
-- VERIFICACION (2026-09-16)
-- =====================================================================
-- ANTES, evento 401914282:
--   status=CERTIFIED  sample_n=5  payload=null
-- DESPUES, mismo evento:
--   status=CERTIFIED  sample_n=5  payload=array de 5 partidos, con marcador
--   source=mv_futpro_analysis_v4  (ahora coincide con de donde sale de verdad)
--
-- CASO SIN MUESTRA, evento 401876455 (h2h_n=0), para comprobar que no se
-- rompio el lado contrario:
--   status=INSUFFICIENT_OR_UNCERTIFIED  sample_n=0  payload=null
--
-- El invariante que ahora se cumple en los dos sentidos:
--   status=CERTIFIED  <=>  payload trae datos
--
-- ALCANCE, contado sobre mv_futpro_analysis_v4:
--   128 eventos en la vista materializada
--    81 pasan de "certificado con payload vacio" a "certificado con datos"
--   320 partidos de H2H que antes se calculaban y no llegaban al contrato
--    47 declaran correctamente que no tienen muestra
--
-- =====================================================================
-- LO QUE ESTE PARCHE **NO** ARREGLA, y hay que decirlo
-- =====================================================================
-- El resto de la queja de FUT PRO es FRONTEND, no base. Medido:
--
--   futpro_terminal_v2('401914282') devuelve hoy, sin P_RETO oficial:
--     ok = true
--     status = 'NO_OFFICIAL_PICK'
--     factual_analysis.display_message =
--         "Analisis disponible. Aun sin P_RETO oficial para esta competicion."
--     factual_analysis.current_season = local 1PJ (4.00 GF/pj, 0.00 GC/pj,
--         3.00 PPG) / visita 2PJ (2.50 GF/pj, 0.00 GC/pj, 3.00 PPG)
--     factual_analysis.last5 = local 2G-3E-0P (1.80 GF, 0.60 GC, 1.80 PPG) /
--         visita 3G-1E-1P (2.20 GF, 1.40 GC, 2.00 PPG)
--     factual_analysis.h2h / venue / lineups / estimated_xg
--
-- O sea: la temporada actual, los ultimos 5, los goles metidos y recibidos
-- por partido YA salen del contrato. La pantalla que dice "Datos del evento
-- insuficientes. RETO no publica probabilidad" esta leyendo el model_status
-- de la lista en vez del factual_analysis del terminal.
--
-- Y sobre los goles esperados: el contrato ya publica goal_expectation con
-- home_expected_goals, away_expected_goals, total_expected_goals,
-- expected_score_rounded y top_score_scenarios con sus porcentajes.
-- Ejemplo real (Puebla-Toluca): 1.12 - 1.50, total 2.62, escenarios
-- 0-1 (11.8%), 1-1 (11.4%), 1-2 (9.2%), 1-0 (9.0%), 0-2 (8.2%).
-- =====================================================================
