-- iss062 — El motor decía "APUESTA" sobre datos que él mismo calificaba de basura.
--
-- EL OWNER DIJO: "quiero picks reales basados al 100 en análisis". Esto es lo que medí.
--
-- LO MEDIDO, sobre partidos que todavía no se juegan:
--   veredicto BET .......... 58 partidos
--     con data_quality <= 8/25 ... 53   (91 %)
--     con data_quality 9-15 ......  4
--     con data_quality > 15 ......  1
--   El MÁXIMO de calidad de datos entre TODOS los BET era 16 de 25.
--
-- O sea: 9 de cada 10 recomendaciones de apostar estaban hechas sobre datos que el propio
-- análisis puntuaba por los suelos. Eso no es un pick basado en análisis.
--
-- EL UMBRAL NO ES MÍO. La vista `v_auditoria_analisis` ya traía la regla `bet_con_datos_malos`
-- con gravedad **alta** y el corte en `data_quality <= 8`. Estaba escrita, corría, y sólo
-- REPORTABA. Nadie la hizo bloquear. La alerta decía exactamente "53 caso(s)".
--
-- Y hay un detalle que lo explica todo: el job que levanta esa alerta (`autodiagnostico`,
-- job 227) estaba DESACTIVADO. La app sabía que esto pasaba y tenía apagado al que avisa.
--
-- EL ARREGLO, en dos partes:
--   1. Un trigger que degrada el veredicto en ESCRITURA, así que ningún análisis nuevo puede
--      volver a decir BET con datos malos.
--   2. Backfill de los 53 ya publicados.
-- Ambas conservan el veredicto original en `veredicto_original` y explican el motivo en
-- `veredicto_degradado_por`, así que es auditable y reversible.

create or replace function public.no_decir_bet_con_datos_malos()
returns trigger language plpgsql as $$
declare v_dq int; v_ver text;
begin
  v_ver := new.analisis_json->>'veredicto_final';
  if v_ver is distinct from 'BET' then return new; end if;

  v_dq := nullif(new.analisis_json->'picks_recomendados'->0->'confianza_desglose'->>'data_quality','')::int;

  if v_dq is not null and v_dq <= 8 then
    new.analisis_json := new.analisis_json
      || jsonb_build_object(
           'veredicto_final', 'NO BET',
           'veredicto_original', v_ver,
           'veredicto_degradado_por', format(
             'calidad de datos %s de 25 (umbral 8). Regla bet_con_datos_malos de v_auditoria_analisis.', v_dq),
           'veredicto_degradado_at', now());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_no_bet_con_datos_malos on public.analisis_partidos;
create trigger trg_no_bet_con_datos_malos
  before insert or update on public.analisis_partidos
  for each row execute function public.no_decir_bet_con_datos_malos();

-- MEDIDO DESPUÉS:
--   BET con datos malos restantes ......... 0
--   BET vigentes en partidos por jugar .... 5  (todos con calidad aceptable)
--   Degradados por este trigger ........... 53  (coincide EXACTO con la alerta)
--   Degradados que ya venían de antes ..... 311 (otro mecanismo previo, sin motivo escrito)
--
-- CONSECUENCIA QUE HAY QUE DECIR EN VOZ ALTA: la app pasa de ofrecer 58 "apuesta" a ofrecer 5.
-- No es que se hayan perdido 53 picks buenos: es que 53 nunca debieron presentarse como picks.
-- Menos picks y honestos es el objetivo, no un efecto secundario.
--
-- REVERTIR: `drop trigger trg_no_bet_con_datos_malos on public.analisis_partidos;` y restaurar
-- `veredicto_final` desde `veredicto_original` en las filas que tengan `veredicto_degradado_por`.
