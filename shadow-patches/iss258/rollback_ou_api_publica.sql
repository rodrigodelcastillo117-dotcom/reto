-- ROLLBACK EXACTO de ISS258.
--
-- OJO — por que este rollback es por POSICION y no un replace simple:
-- el parche convirtio SIETE condiciones distintas en el mismo texto
-- `WHEN false THEN p.p_over` / `... p.p_under`:
--     ocurrencia 1 -> era `WHEN g.rdy THEN ...`            (la columna)
--     ocurrencia 2 -> era `WHEN p.over_line = 2.5 THEN ...`(jsonb markets)
--     ocurrencia 3 -> era `WHEN p.over_line = 3.5 THEN ...`
--     ocurrencia 4 -> era `WHEN p.over_line = 4.5 THEN ...`
-- Un `replace()` plano NO puede distinguirlas: perderia el 2.5/3.5/4.5. Por eso
-- se parte la cadena por el ancla y se rearma poniendo cada original en su sitio.
--
-- PROBADO: se ejecuto dentro de BEGIN...ROLLBACK y devolvio p_over/p_under a 94
-- filas no nulas y markets con O/U a 94, que son los valores de antes del parche.

do $rb258$
declare
  nuevo  text;
  partes text[];
begin
  nuevo := pg_get_viewdef('public.v_futpro_v2'::regclass, true);

  -- ---- p_over: 4 ocurrencias, 5 partes -------------------------------------
  partes := string_to_array(nuevo, 'WHEN false THEN p.p_over');
  if array_length(partes, 1) <> 5 then
    raise exception 'ROLLBACK ISS258 ABORTA: esperaba 4 ocurrencias de p_over, encontre %.',
                    coalesce(array_length(partes, 1), 1) - 1;
  end if;
  nuevo := partes[1] || 'WHEN g.rdy THEN p.p_over'
        || partes[2] || 'WHEN p.over_line = 2.5 THEN p.p_over'
        || partes[3] || 'WHEN p.over_line = 3.5 THEN p.p_over'
        || partes[4] || 'WHEN p.over_line = 4.5 THEN p.p_over'
        || partes[5];

  -- ---- p_under: 4 ocurrencias, 5 partes -------------------------------------
  partes := string_to_array(nuevo, 'WHEN false THEN p.p_under');
  if array_length(partes, 1) <> 5 then
    raise exception 'ROLLBACK ISS258 ABORTA: esperaba 4 ocurrencias de p_under, encontre %.',
                    coalesce(array_length(partes, 1), 1) - 1;
  end if;
  nuevo := partes[1] || 'WHEN g.rdy THEN p.p_under'
        || partes[2] || 'WHEN p.over_line = 2.5 THEN p.p_under'
        || partes[3] || 'WHEN p.over_line = 3.5 THEN p.p_under'
        || partes[4] || 'WHEN p.over_line = 4.5 THEN p.p_under'
        || partes[5];

  -- ---- jsonb markets: over_current / under_current ---------------------------
  nuevo := replace(nuevo,
    '''over_current'', NULL::numeric, ''under_current'', NULL::numeric',
    '''over_current'', p.p_over, ''under_current'', p.p_under');

  -- ---- mejor_pick: vuelven las dos tuplas de O/U al argmax --------------------
  nuevo := replace(nuevo,
    ') m(label, prob)',
    ', ((''Más de ''::text || p.over_line) || '' goles''::text,p.p_over), ((''Menos de ''::text || p.over_line) || '' goles''::text,p.p_under)) m(label, prob)');

  execute 'create or replace view public.v_futpro_v2 as ' || nuevo;
end
$rb258$;

comment on view public.v_futpro_v2 is NULL;
