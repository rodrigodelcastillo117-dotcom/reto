-- =====================================================================
-- ISS114  EL PRECIO ADENTRO DE LA PROBABILIDAD
-- =====================================================================
-- POR QUE HACE FALTA OTRO GATE, SI YA EXISTE ISS107
--   El candado del dueno tiene DOS prohibiciones distintas, y yo habia
--   construido instrumento para una sola:
--
--     (a) el desacuerdo con el mercado "may never select, rank, authorize,
--         suppress, or substitute a P_RETO pick"
--         -> eso lo mide ISS107: el precio ELIGE un pick.
--
--     (b) "Nunca sustituyas P_RETO con implied/no-vig de DraftKings"
--         -> esto NO lo medía nada. El precio puede estar ADENTRO del numero
--            que se publica como probabilidad, sin elegir nada.
--
--   Lo encontre volcando v_super_pick a Git para cerrar el clean bootstrap.
--   El detector de ISS107 no marcaba la linea, y tenia razon en no marcarla:
--   es una asignacion en la lista de SELECT, no una construccion que decide.
--   Simplemente estaba midiendo otra cosa.
--
-- METODO: DOS PASES, Y LA DISTINCION QUE IMPORTA
--   Pase 1  alias_contaminados_por_precio(src)
--           alias cuya expresion de definicion CONVIERTE precio en
--           probabilidad: 1/momio, 100/momio, devig, no-vig.
--           Que una columna solo MUESTRE el momio no contamina nada. Lo que
--           contamina es convertir precio en probabilidad.
--   Pase 2  buscar un objeto que consuma ese alias y lo publique bajo un
--           nombre de probabilidad.
--
--   Tener un alias contaminado NO es violacion. Publicarlo como probabilidad
--   si lo es. Esa distincion es todo el gate.
--
-- MEDIDO EN PRODUCCION EL 2026-09-12
--   57 alias que convierten precio en probabilidad, en 22 objetos.
--   De esos, DOS llegan a una probabilidad publicada:
--
--   1) v_super_pick.prob_pct
--        round(COALESCE(c.prob_observada, c.prob_declarada) * 100, 1)
--      prob_observada viene de calibracion_mercado:
--        (ganados + 40 * avg(1.0 / momio_mercado)) / (n + 40)
--      Es una mezcla bayesiana cuyo PRIOR son 40 observaciones de la
--      probabilidad implicita del precio. Y va PRIMERO en el COALESCE, asi
--      que cuando existe calibracion del segmento la probabilidad que el
--      usuario lee NO es P_RETO.
--      No es un reemplazo directo sino una MEZCLA, y por eso nadie lo vio: el
--      numero sigue llamandose probabilidad.
--
--   2) v_picks_para_parlay.probabilidad_pct
--        vp.prob_estimada_pct AS probabilidad_pct
--      prob_estimada_pct lo define v_picks_premium con aritmetica de
--      probabilidad implicita (senal FORMA_PROB_IMPLICITA).
--      Y v_picks_para_parlay es la FUENTE de get_oportunidades_hoy y de
--      construir_parlay_v2__base: la superficie de parlays decide sobre una
--      probabilidad que trae precio adentro.
--
--   O sea: las DOS rutas de probabilidad publicada del sistema, la del
--   super-pick y la de parlays, tienen precio dentro del numero.
--
--   Dos mas quedan en REVISION_PENDIENTE, sin afirmar nada:
--     nfl_tablero.prob_fuente (se define con devig; no encontre la linea
--       donde se publique como probabilidad en sus consumidores)
--     refrescar_destacados.suma_implicita (es el overround del mercado, no una
--       probabilidad; medir el vig es legitimo)
--   No los cuento como violacion porque no lo probe. Falta de prueba no es
--   prueba.
--
-- NO SE CORRIGE NADA. Cambiar de donde sale una probabilidad publicada es
-- cutover de modelo y esta congelado.
-- =====================================================================

create or replace function public.alias_contaminados_por_precio(p_src text)
returns table(ord int, alias text, senales text[], linea text)
language plpgsql immutable as $fn$
declare
  v_lineas text[]; v_n int; i int; j int;
  v_l text; v_ctx text; v_sen text[]; v_alias text;
begin
  v_lineas := string_to_array(coalesce(p_src,''), E'\n');
  v_n := coalesce(array_length(v_lineas,1),0);
  for i in 1..v_n loop
    v_l := btrim(v_lineas[i]);
    if v_l ~ '^--' or v_l = '' then continue; end if;

    -- solo lineas que TERMINAN definiendo un alias: "... AS nombre," o "... AS nombre"
    v_alias := lower((regexp_match(v_l, '\mas\s+([a-z_][a-z0-9_]*)\s*,?\s*$', 'i'))[1]);
    if v_alias is null then continue; end if;

    -- ventana de 6 lineas hacia atras, por la misma razon que en ISS107:
    -- un CASE parte la expresion y el AS queda lejos del 1/momio
    v_ctx := v_l;
    for j in greatest(1, i-6) .. i-1 loop
      if btrim(v_lineas[j]) !~ '^--' then
        v_ctx := btrim(v_lineas[j]) || ' ' || v_ctx;
      end if;
    end loop;

    v_sen := public.forma_precio_en_linea(v_ctx) || public.token_precio_en_linea(v_ctx);

    -- contaminado = la expresion trae la PROBABILIDAD IMPLICITA del precio o un devig.
    -- Que traiga solo el momio NO basta: una columna que simplemente muestra el
    -- momio no contamina nada. Lo que contamina es convertir precio en probabilidad.
    if v_sen && array['FORMA_PROB_IMPLICITA','FORMA_DEVIG','TOKEN_PROB_IMPLICITA'] then
      ord := i; alias := v_alias; senales := v_sen; linea := v_l;
      return next;
    end if;
  end loop;
end;
$fn$;

comment on function public.alias_contaminados_por_precio(text) is
'ISS114. Devuelve los alias cuya expresion de definicion convierte PRECIO en PROBABILIDAD (1/momio, devig). Un alias aqui no es violacion por si mismo: lo es si despues alimenta una probabilidad publicada. Que una columna solo muestre el momio no contamina nada.';

create table if not exists public.p_reto_contaminado (
  objeto          text not null,
  clase           text not null,
  linea_num       int  not null,
  alias           text not null,
  senales         text[] not null,
  linea           text not null,
  calculado_at    timestamptz not null default now(),
  primary key (objeto, linea_num, alias)
);
comment on table public.p_reto_contaminado is
'ISS114. Snapshot de alias que convierten precio en probabilidad. Es tabla y no vista por el mismo motivo que ruta_precio_inventario: recorrer todo el codigo fuente no cabe en el timeout de un gate.';

create or replace function public.refrescar_p_reto_contaminado()
returns table(objetos bigint, alias_contaminados bigint) language plpgsql as $fn$
begin
  delete from public.p_reto_contaminado;
  insert into public.p_reto_contaminado (objeto, clase, linea_num, alias, senales, linea)
  select c.relname, 'VISTA', d.ord, d.alias, d.senales, d.linea
  from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
  cross join lateral public.alias_contaminados_por_precio(pg_get_viewdef(c.oid, true)) d
  where c.relkind in ('v','m')
  on conflict do nothing;

  insert into public.p_reto_contaminado (objeto, clase, linea_num, alias, senales, linea)
  select p.oid::regprocedure::text, 'FUNCION', d.ord, d.alias, d.senales, d.linea
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
  cross join lateral public.alias_contaminados_por_precio(p.prosrc) d
  where p.prokind='f'
  on conflict do nothing;

  return query select count(distinct objeto), count(*) from public.p_reto_contaminado;
end;
$fn$;

create table if not exists public.p_reto_sustitucion (
  objeto_publica   text not null,
  columna_publicada text not null,
  alias_contaminado text not null,
  objeto_origen    text not null,
  linea_origen     text not null,
  linea_publicacion text not null,
  veredicto        text not null check (veredicto in ('SUSTITUCION_CONFIRMADA','REVISION_PENDIENTE','NO_ES_SUSTITUCION')),
  razon            text not null,
  registrado_at    timestamptz not null default now(),
  primary key (objeto_publica, columna_publicada, alias_contaminado)
);

comment on table public.p_reto_sustitucion is
'ISS114. Lugares donde una probabilidad PUBLICADA se deriva del PRECIO. El candado dice textual "Nunca sustituyas P_RETO con implied/no-vig de DraftKings". Esto NO lo detectaba ISS107: ese gate busca si el precio ELIGE un pick, no si el precio esta ADENTRO de la probabilidad. Son dos prohibiciones distintas.';

create or replace function public.gate_p_reto_sin_precio()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'P_RETO_SUSTITUIDO_POR_PRECIO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(objeto_publica || '.' || columna_publicada
                             || ' <- ' || alias_contaminado || ' (' || objeto_origen || ')', ' | '), 'ninguno')
  from public.p_reto_sustitucion where veredicto = 'SUSTITUCION_CONFIRMADA'
  union all
  select 'P_RETO_SUSTITUCION_SIN_REVISAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(objeto_publica || '.' || columna_publicada, ', '), 'ninguno')
  from public.p_reto_sustitucion where veredicto = 'REVISION_PENDIENTE'
  union all
  select 'ALIAS_QUE_CONVIERTEN_PRECIO_EN_PROBABILIDAD'::text, 'INFO', count(*),
         'alias cuya expresion convierte precio en probabilidad, en ' || count(distinct objeto)
           || ' objetos. Tener el alias no es violacion; publicarlo como probabilidad si.'
  from public.p_reto_contaminado;
$fn$;

comment on function public.gate_p_reto_sin_precio() is
'ISS114. La probabilidad que el producto publica no puede venir del precio. Cubre la prohibicion "Nunca sustituyas P_RETO con implied/no-vig", que ISS107 NO cubria: ese gate mide si el precio ELIGE, este mide si el precio esta ADENTRO del numero.';

grant select on public.p_reto_contaminado  to anon, authenticated, service_role;
grant select on public.p_reto_sustitucion  to anon, authenticated, service_role;
revoke insert, update, delete, truncate on public.p_reto_contaminado from anon, authenticated;
revoke insert, update, delete, truncate on public.p_reto_sustitucion from anon, authenticated;
grant all on public.p_reto_contaminado to service_role;
grant all on public.p_reto_sustitucion to service_role;
grant execute on function public.alias_contaminados_por_precio(text) to anon, authenticated, service_role;
grant execute on function public.gate_p_reto_sin_precio()            to anon, authenticated, service_role;
grant execute on function public.refrescar_p_reto_contaminado()      to service_role;
