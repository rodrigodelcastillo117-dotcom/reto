-- =====================================================================
-- ISS123 : EL ORDEN DE LOS PICKS PUBLICADOS SALE DE KELLY, Y POR LO TANTO
--          DEL PRECIO DE LA CASA. TERCERA GENERACION DEL DETECTOR.
-- =====================================================================
-- Mis tres detectores anteriores no veian esto:
--
--   linea  37 : public.kelly_stake(p_apodo, c.probabilidad_pct, c.momio_mercado, ...)
--   linea  45 : coalesce((k.ks->>'stake_recomendado')::numeric, 0) as kelly_monto
--   linea  69 : ... case when r.motivo_bloqueo is null then r.kelly_monto else 0 end as monto_cand
--   linea  76 : order by monto_cand desc, arranca_en nulls last, espn_event_id, pick_desc
--   linea 162 : ORDER BY ... a.monto_cand desc, ...          <- el orden PUBLICADO
--   lineas 88, 89, 93, 94 : and o.monto_cand > 0 / ... <= l.limite_monto
--   linea 112 : when not a.admitido and a.monto_cand > 0 then 'descartado'
--
-- Por que ninguno lo veia:
--   ISS107 busca el PRECIO en la linea que decide. "order by monto_cand desc"
--          no tiene ni un token de precio. Verificado:
--          token_precio_en_linea('order by monto_cand desc') = {} y
--          forma_precio_en_linea(...) = {}.
--   ISS121 busca la LLAMADA a una funcion con precio adentro en la linea que
--          decide. Aqui no hay llamada: hay una columna.
--   alias_contaminados_por_precio (ISS114) devolvio CERO filas sobre
--          reto_picks_hoy__base. Tampoco lo veia.
--
-- El unico hallazgo que ISS107 si reporto de esta cadena, la linea 75, lo
-- atrapo por SUERTE: kelly_monto esta en la linea 69 y el row_number en la 75,
-- o sea justo dentro de la ventana de 6 lineas. La linea 162, que es el ORDER
-- BY realmente publicado, nunca fue reportada por nadie.
--
-- Lo que esto significa, sin adornos: reto_picks_hoy es LA superficie de picks
-- del producto, y tanto su ORDEN como su ELEGIBILIDAD salen de un stake de
-- Kelly calculado con el momio de la casa. El candado del dueno dice
-- "SIN EV. SIN KELLY. SIN EDGE CONTRA EL MERCADO PARA DECIDIR" y
-- "nunca para ... ordenar TOP_ONLY".
--
-- NO LO ARREGLE. Cambiar el orden canonico y la elegibilidad de la superficie
-- principal es cutover de modelo y seleccion, y esta congelado
-- (PROD_MODEL_CUTOVER=FROZEN, regla §11). Queda como FAIL abierto.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. EL DETECTOR: SEGUIR EL DATO, NO EL NOMBRE
-- ---------------------------------------------------------------------
-- Punto fijo sobre los alias. Se siembra un alias como contaminado si su
-- definicion toca el precio (token, forma aritmetica, o llamada a una funcion
-- con precio adentro) y se propaga a todo alias cuya definicion referencia un
-- alias ya contaminado. Despues se reportan las construcciones que DECIDEN
-- usando un alias contaminado.
--
-- DECISION DE DISENO QUE CAMBIE A MITAD: la primera version sembraba con la
-- ventana de 6 lineas de ISS107 y se desbordo. Sobre reto_picks_hoy__base dio
-- 24 hallazgos con es_pick, estado_live, arranca_en, mercado, pick_desc y
-- limite_alcanzado contaminados: cualquier alias que cayera cerca de una
-- mencion de precio quedaba sucio y de ahi se contagiaba el resto. Inservible.
-- La version que queda exige la senal en la MISMA LINEA que define el alias.
-- Resultado: 3 alias y 8 decisiones, todas reales.
--
-- COSTO DECLARADO DE LA REGLA ESTRICTA: se pierde motivo_bloqueo, que se
-- define con un CASE repartido en varias lineas (63 a 67) y cuyo "as
-- motivo_bloqueo" no comparte linea con la senal. Sus consecuencias SI quedan
-- registradas igual, porque ISS107 reporta las lineas 110, 132 y 134. O sea el
-- hueco esta cubierto por el otro detector, no tapado.
create or replace function public.taint_precio(p_src text, p_funcs text[])
returns table(tipo text, ord int, nombre text, ronda int, construccion text, linea text)
language plpgsql immutable as $fn$
declare
  v_l text[]; v_n int; i int; ronda_n int;
  v_sucio text[] := '{}';
  v_nuevos int;
  v_low text; v_con text; m text[]; s text; v_self text;
  k_stop text[] := array['case','then','else','when','select','from','where','order',
                         'null','true','false','with','value','text','numeric','boolean',
                         'jsonb','integer','interval','timestamptz','desc','nulls','last',
                         'coalesce','nullif','round','extract','epoch','lower','upper'];
begin
  v_l := string_to_array(coalesce(p_src,''), E'\n');
  v_n := coalesce(array_length(v_l,1),0);
  if v_n = 0 then return; end if;

  -- SIN VENTANA para sembrar. La senal tiene que estar en la MISMA linea que
  -- define el alias. Con ventana de 6 lineas la contaminacion se desbordaba:
  -- cualquier alias que cayera cerca de una mencion de precio quedaba sucio, y
  -- de ahi se contagiaba todo. Precision sobre cobertura, a proposito, porque
  -- este detector existe para producir hallazgos en los que se pueda confiar.
  for ronda_n in 1..8 loop
    v_nuevos := 0;
    for i in 1..v_n loop
      v_self := btrim(v_l[i]);
      if v_self ~ '^--' or v_self = '' then continue; end if;

      if not (
           coalesce(array_length(public.token_precio_en_linea(v_self),1),0) > 0
        or coalesce(array_length(public.forma_precio_en_linea(v_self),1),0) > 0
        or exists (select 1 from unnest(p_funcs) f where v_self ~* ('\m'||f||'\s*\('))
        or exists (select 1 from unnest(v_sucio) x where v_self ~* ('\m'||x||'\M'))
      ) then continue; end if;

      for m in select regexp_matches(lower(v_self), '\mas\s+([a-z_][a-z0-9_]{3,60})\s*(?:,|$)', 'g') loop
        if m[1] = any(k_stop) or m[1] = any(v_sucio) then continue; end if;
        v_sucio := v_sucio || m[1]; v_nuevos := v_nuevos + 1;
        tipo := 'ALIAS_CONTAMINADO'; ord := i; nombre := m[1];
        ronda := ronda_n; construccion := null; linea := v_self;
        return next;
      end loop;
      for m in select regexp_matches(lower(v_self), '\m([a-z_][a-z0-9_]{3,60})\s*:=', 'g') loop
        if m[1] = any(k_stop) or m[1] = any(v_sucio) then continue; end if;
        v_sucio := v_sucio || m[1]; v_nuevos := v_nuevos + 1;
        tipo := 'ALIAS_CONTAMINADO'; ord := i; nombre := m[1];
        ronda := ronda_n; construccion := null; linea := v_self;
        return next;
      end loop;
    end loop;
    exit when v_nuevos = 0;
  end loop;

  for i in 1..v_n loop
    v_self := btrim(v_l[i]); v_low := lower(v_self);
    if v_self ~ '^--' or v_low = '' then continue; end if;
    -- si el precio se ve en la linea, ya es hallazgo de ISS107: no se duplica
    if coalesce(array_length(public.token_precio_en_linea(v_self),1),0) > 0
       or coalesce(array_length(public.forma_precio_en_linea(v_self),1),0) > 0 then continue; end if;

    v_con := null;
    if v_low ~ 'order\s+by' then v_con := 'ORDEN';
    elsif v_low ~ 'row_number|dense_rank|\mrank\s*\(' then v_con := 'VENTANA_RANKING';
    elsif v_low ~ '^(and|or|where|having)\M' or v_low ~ '\mwhere\M' then v_con := 'FILTRO';
    elsif v_low ~ 'when .*then' and v_low ~* 'descart|bloque|rechaz|suprim|no\s+apostar|\mveta' then v_con := 'RAMA_SUPRESION';
    elsif v_low ~ '\mlimit\M' then v_con := 'LIMITE';
    end if;
    if v_con is null then continue; end if;

    foreach s in array v_sucio loop
      if v_low ~ ('\m'||s||'\M') then
        tipo := 'DECISION_POR_ALIAS'; ord := i; nombre := s;
        ronda := null; construccion := v_con; linea := v_self;
        return next; exit;
      end if;
    end loop;
  end loop;
end
$fn$;

-- ---------------------------------------------------------------------
-- 2. INVENTARIO
-- ---------------------------------------------------------------------
create table if not exists public.ruta_precio_taint (
  objeto text not null,
  tipo text not null,
  linea_num int not null,
  nombre text not null,
  construccion text,
  linea text not null,
  veredicto text,
  razon text,
  primary key (objeto, tipo, linea_num, nombre)
);
revoke all on public.ruta_precio_taint from anon, authenticated;

create table if not exists public.ruta_precio_taint_pendiente (
  objeto text primary key, src text not null, escaneado boolean not null default false
);
revoke all on public.ruta_precio_taint_pendiente from anon, authenticated;

-- Universo del escaneo: los 158 objetos que alcanzan una superficie canonica
-- de decision, segun ruta_decision_alcance (grafo real de pg_depend mas las
-- menciones de catalogo, no adivinanza de nombres). Ahi es donde manda el
-- candado. Se escanea en lotes de 40 por el limite de 60s del MCP.
--
--   with lav as (select array_agg(funcion) as f from public.ruta_precio_lavadora
--                where funcion <> 'forma_precio_en_linea'),
--   lote as (select objeto, src from public.ruta_precio_taint_pendiente
--            where not escaneado order by objeto limit 40),
--   ins as (
--     insert into public.ruta_precio_taint (objeto, tipo, linea_num, nombre, construccion, linea)
--     select l.objeto, t.tipo, t.ord, t.nombre, t.construccion, left(t.linea,300)
--     from lote l cross join lav cross join lateral public.taint_precio(l.src, lav.f) t
--     on conflict do nothing returning 1
--   )
--   update public.ruta_precio_taint_pendiente p set escaneado = true
--   where p.objeto in (select objeto from lote);

-- ---------------------------------------------------------------------
-- 3. COMPUERTA
-- ---------------------------------------------------------------------
create or replace function public.gate_precio_por_alias()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PRECIO_POR_ALIAS_SIN_CLASIFICAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(objeto||':'||linea_num, ', ' order by objeto), 'ninguno')
  from public.ruta_precio_taint where tipo='DECISION_POR_ALIAS' and veredicto is null
  union all
  select 'PRECIO_POR_ALIAS_VIOLACION_ABIERTA'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(distinct objeto||' ('||construccion||' por '||nombre||')', ' | '), 'ninguna')
  from public.ruta_precio_taint where tipo='DECISION_POR_ALIAS' and veredicto='VIOLACION_CANDADO'
  union all
  select 'PRECIO_POR_ALIAS_PENDIENTE_DE_LECTURA'::text,
         case when count(*) = 0 then 'PASS' else 'INFO' end, count(*),
         coalesce(string_agg(distinct objeto, ', '), 'ninguno')
         || '. Marcados REVISION_PENDIENTE a proposito: no los cierro sin comprobar de donde sale el numero.'
  from public.ruta_precio_taint where tipo='DECISION_POR_ALIAS' and veredicto='REVISION_PENDIENTE'
  union all
  -- Medicion VIVA de la cadena concreta, por si alguien borra los hallazgos:
  -- que kelly_stake siga recibiendo el momio y que el orden siga saliendo de ahi.
  select 'ORDEN_CANONICO_SALE_DE_KELLY'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'reto_picks_hoy__base: kelly_stake recibe momio_mercado y el row_number/ORDER BY usa el monto que sale de ahi. '
         || 'Mientras esto sea FAIL, el orden de los picks publicados lo pone el precio.'
  from pg_proc p
  where p.proname = 'reto_picks_hoy__base'
    and p.prosrc ~* 'kelly_stake\s*\([^)]*momio'
    and p.prosrc ~* 'order\s+by\s+monto_cand'
  union all
  select 'TAINT_DETECTOR_TIENE_SEMILLA'::text,
         case when count(*) > 0 then 'PASS' else 'FAIL' end, count(*),
         'alias sembrados como contaminados. Si llega a 0, el detector quedo ciego.'
  from public.ruta_precio_taint where tipo='ALIAS_CONTAMINADO';
$fn$;

comment on function public.gate_precio_por_alias() is
'ISS123. El precio que decide a traves de un alias intermedio: kelly_monto -> monto_cand -> ORDER BY. Ni ISS107 (precio en la linea) ni ISS121 (llamada a funcion con precio) lo ven.';
revoke all on function public.gate_precio_por_alias() from anon, authenticated;

-- =====================================================================
-- 4. RESULTADO (2026-09-12)
-- =====================================================================
-- Escaneados los 158 objetos del camino de decision: 105 alias sembrados,
-- 15 decisiones por alias contaminado, en SOLO 4 objetos:
--
--   reto_picks_hoy__base    8 hallazgos  VIOLACION_CANDADO
--       ORDEN          linea  76  order by monto_cand desc
--       FILTRO         lineas 88, 89, 93, 94
--       RAMA_SUPRESION lineas 112 (monto_cand), 59 y 125 (veto)
--       veto se define en la linea 41 con una llamada que recibe c.momio_mercado
--
--   kelly_stake__base       2 hallazgos  DIMENSIONAMIENTO_ECONOMICO
--   decision_economica_v1   2 hallazgos  DIMENSIONAMIENTO_ECONOMICO
--       usan v_zona (que lleva precio) solo para DIMENSIONAR el stake. El
--       dueno lo autoriza: el precio puede servir para EV/Kelly/payout.
--
--   refrescar_destacados    3 hallazgos  REVISION_PENDIENTE
--       and e.cal_corta*100 > 50 / and e.cal_larga*100 > 50. Son
--       probabilidades CALIBRADAS, no precios. La pregunta sin resolver: la
--       calibracion que las produce se elige por BANDA DE MOMIO, como en
--       v_super_pick linea 117? Si es si, el precio esta adentro de la
--       probabilidad y es asunto de ISS114. No lo cierro sin comprobarlo.
--
-- ESTADO DEL GATE:
--   PRECIO_POR_ALIAS_SIN_CLASIFICAR         PASS  0
--   PRECIO_POR_ALIAS_VIOLACION_ABIERTA      FAIL  8
--   PRECIO_POR_ALIAS_PENDIENTE_DE_LECTURA   INFO  3
--   ORDEN_CANONICO_SALE_DE_KELLY            FAIL  1
--   TAINT_DETECTOR_TIENE_SEMILLA            PASS  105
--
-- Y en ISS107, al adjudicar las 24 lineas P0 de las superficies canonicas:
--   VIOLACION_CANDADO                19 -> 27
--   P0 sin clasificar               279 -> 257
--   Se agrego la categoria PRECIO_DENTRO_DE_LA_PROBABILIDAD al CHECK de
--   ruta_precio_hallazgo, porque v_super_pick linea 117 elige la CALIBRACION
--   por banda de momio y no habia donde clasificar eso.
--   Tres hallazgos quedaron con veredicto NULL A PROPOSITO
--   (v_pick_canonico:329, v_super_pick:150, y el de refrescar_destacados):
--   el gate los sigue contando como abiertos, que es lo correcto.
-- =====================================================================
