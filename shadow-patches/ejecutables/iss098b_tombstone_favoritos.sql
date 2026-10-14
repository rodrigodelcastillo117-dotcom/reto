-- ISS098b — RETIRO FORMAL DE v_mis_favoritos_analisis.
--
-- El dueno fue explicito (AUDIT_NO_PASS 5644082184): "esa vista debe quedar
-- formalmente retirada/tombstone, despues de demostrar que ya no tiene
-- consumidores, en vez de inventar una definicion nueva solo para apagar un gate."
-- Tenia razon y era mejor que lo que yo iba a hacer.
--
-- CORRECCION A MI PROPIO INFORME DE INCIDENTE: escribi que de esta vista "no
-- existe definicion en ningun sitio". Es FALSO. El texto completo del
-- `create or replace view` quedo grabado en pg_stat_statements (2094 caracteres,
-- reset del contador el 2026-09-11 10:48:44+00) y lo recupere intacto. La
-- definicion queda abajo como evidencia de auditoria. NO SE REDESPLIEGA.
--
-- Y hay una razon de fondo para no redesplegarla, aparte de la orden del dueno:
-- la definicion historica exponia nivel_ventaja, zona, es_pick y favorito_pct
-- directamente en Favoritos. Eso es diagnostico economico y de desacuerdo con el
-- mercado dentro de una superficie de usuario. Reconstruirla tal cual habria
-- reintroducido exactamente lo que estamos sacando.
--
-- PRUEBA DE CERO CONSUMIDORES, cinco frentes, 2026-09-12:
--   1. pg_proc          0 funciones la mencionan en prosrc
--   2. pg_get_viewdef   0 vistas o matviews la referencian
--   3. pg_policy        0 politicas RLS la nombran
--   4. repositorio Git  0 referencias fuera de mi documentacion de incidente
--   5. pg_stat_statements  5 statements la mencionan y TODOS son DDL mio como
--      postgres (create x2, grant, drop) mas un censo de superficies que corri yo
--      como anon. CERO SELECT de app por anon o authenticated.

begin;

insert into public.superficie_retirada
 (vista, motivo, evidencia_cero_consumidores, definicion_historica, fuente_de_la_definicion)
values (
 'v_mis_favoritos_analisis',
 $m$RETIRADA POR DECISION DEL DUENO (AUDIT_NO_PASS 5644082184). Lovable elimino la
dependencia en el commit 58e320c4de6673255f30fa633a0199cdab85ff51; Favoritos ahora se
arma con la arquitectura prevista. El dueno ordeno: "debe quedar formalmente
retirada/tombstone, despues de demostrar que ya no tiene consumidores, en vez de
inventar una definicion nueva solo para apagar un gate."
RAZON DE FONDO, ademas de la del dueno: la definicion historica exponia
nivel_ventaja, zona, es_pick y favorito_pct directamente en Favoritos, es decir campos
de diagnostico economico y de desacuerdo con el mercado en una superficie de usuario.
Reconstruirla tal cual habria reintroducido lo que estamos sacando.$m$,
 $e$Probado el 2026-09-12, cinco frentes:
1. pg_proc: 0 funciones con prosrc que la mencione.
2. pg_class/pg_get_viewdef: 0 vistas o matviews que la referencien.
3. pg_policy: 0 politicas RLS que la nombren.
4. repositorio Git: 0 referencias fuera de mi propia documentacion de incidente
   (shadow-patches/**), ningun codigo.
5. pg_stat_statements (reset 2026-09-11 10:48:44+00): 5 statements la mencionan y
   TODOS son DDL mio como postgres (create x2, grant, drop) mas un censo de
   superficies que yo corri como anon. CERO SELECT de app por anon/authenticated.$e$,
 $d$-- Recuperada de pg_stat_statements el 2026-09-12. NO SE REDESPLIEGA: queda como
-- evidencia de auditoria. Corrige mi informe de incidente, que afirmaba que no
-- existia definicion en ningun sitio.
create or replace view public.v_mis_favoritos_analisis as
select f.deporte,
       f.nombre            as equipo_favorito,
       case when public.norm_equipo_txt(p.home) = public.norm_equipo_txt(f.nombre)
            then 'local' else 'visitante' end as juega_de,
       p.espn_event_id, p.liga, p.home, p.away, p.arranca_en,
       p.mercado, p.pick_nombre, p.pick_desc,
       p.probabilidad_pct, p.momio_justo, p.momio_mercado, p.casa,
       p.favorito, p.favorito_pct,
       p.clasificacion, p.confianza, p.nivel_ventaja, p.zona,
       p.es_pick, p.es_senal, p.rank_en_partido,
       p.razon, p.resumen
from public.equipos_favoritos f
join public.v_pick_canonico p
  on public.norm_equipo_txt(p.home) = public.norm_equipo_txt(f.nombre)
  or public.norm_equipo_txt(p.away) = public.norm_equipo_txt(f.nombre)
where f.user_id in (select u.id from public.usuarios u where u.user_id = auth.uid())$d$,
 'pg_stat_statements (texto completo, 2094 caracteres)'
) on conflict (vista) do nothing;

-- sale del contrato visible. El trigger de iss098 exige que la lapida exista
-- ANTES de este delete, asi que el orden importa.
delete from public.superficie_usuario where vista = 'v_mis_favoritos_analisis';

commit;

-- ASSERTIONS
do $$
declare v jsonb;
begin
  if not exists (select 1 from superficie_retirada where vista='v_mis_favoritos_analisis') then
    raise exception 'ASSERT 1 FALLO: no quedo la lapida';
  end if;
  if exists (select 1 from superficie_usuario where vista='v_mis_favoritos_analisis') then
    raise exception 'ASSERT 2 FALLO: sigue registrada como superficie viva';
  end if;
  if (select definicion_historica is null or length(definicion_historica) < 500
      from superficie_retirada where vista='v_mis_favoritos_analisis') then
    raise exception 'ASSERT 3 FALLO: la lapida no guarda la definicion historica';
  end if;
  v := gate_superficie_destruida();
  if (v->>'SUPERFICIE_REGISTRADA_INEXISTENTE')::int <> 0 then
    raise exception 'ASSERT 4 FALLO: sigue habiendo superficie registrada inexistente: %', v;
  end if;
  v := gate_superficie_resucitada();
  if (v->>'SUPERFICIE_RETIRADA_RESUCITADA')::int <> 0 then
    raise exception 'ASSERT 5 FALLO: superficie retirada resucitada: %', v;
  end if;
  raise notice 'ISS098b OK: 5 assertions pasadas';
end $$;

-- CONTROLES NEGATIVOS (probados el 2026-09-12, todos revertidos):
--   A  delete from superficie_usuario where vista='v_pick_canonico'
--      -> BLOQUEADO: SUPERFICIE_SIN_LAPIDA
--   B  create view public.v_mis_favoritos_analisis as select 1
--      -> gate_superficie_resucitada = 1, detalle "el objeto existe de nuevo en public"
--   C  re-insertar la fila en superficie_usuario
--      -> gate_superficie_resucitada = 1
--   D  deshacer B y C -> gate = 0
