-- Checksums de ISS099. Capturados el 2026-09-12.
--
-- Anclado al CUERPO DEL ARCHIVO (md5(prosrc)), igual que iss098: eso prueba que
-- produccion corre literalmente lo que dice el parche. Esta vez salio 6 de 6 a la
-- primera; en iss098 fallaron 7 de 9 y tuve que ejecutar el archivo para alinearlo.
--
-- OJO con identidad_valida: hay DOS, y se distinguen por pronargs.
--   8 argumentos = la vigente (evento, deporte, LIGA, mercado, pick, home, away, fuente)
--   7 argumentos = la obsoleta, que devuelve 'FIRMA_OBSOLETA_SIN_LIGA' a proposito
with esperado(objeto, nargs, md5_cuerpo, md5_def) as (values
 ('deporte_canonico',              1,'d53c3cf9559b74b862a6b3d2905a4d78','d3c259159807ace74f4788f95eb648bb'),
 ('identidad_valida',              8,'df5b7c99deeb44322a165c1ea1f31105','1191acdbf37b86793497d4add63b161a'),
 ('identidad_valida',              7,'453987544393642a8c0638fc4b1a6bcf','5a863c45ef3d49161ff3893e60553f5f'),
 ('aplicar_calibrador_autorizado', 5,'38fa15908c3f0132d99f7a87cfeaf2dd','5e05d65e4d39b44e69fab91200aae736'),
 ('gate_identidad_exacta',         0,'22cdf5c217ecfafc121af5b73d78ead7','5665d58eea353323963267f1cf6a4931'),
 ('gate_calibrador_reproducible',  0,'3000764ce091786ffbe0a3d4bc4ee6ca','ec0eca30826975b43896af2e7cbf41d2'),
 -- runner de 13 gates, definido en gates_selector.sql
 ('pruebas_selector_limpio',       0, null,                             '86a3f635584837465964c3f635e52a2d')
)
select e.objeto||'/'||e.nargs as objeto,
       case when p.oid is null then 'NO EXISTE'
            when e.md5_cuerpo is not null and md5(p.prosrc) <> e.md5_cuerpo
                 then 'CUERPO DISTINTO AL ARCHIVO: '||md5(p.prosrc)
            when md5(pg_get_functiondef(p.oid)) <> e.md5_def
                 then 'DEFINICION CAMBIADA: '||md5(pg_get_functiondef(p.oid))
            else 'IGUAL' end as estado
from esperado e
left join pg_proc p on p.proname=e.objeto and p.pronamespace='public'::regnamespace
     and p.pronargs = e.nargs
order by 1;

-- Estructura e invariantes de ISS099.
select 'indice ux_calibrador_autoridad_unica' obj,
       (select count(*) from pg_indexes where schemaname='public'
         and indexname='ux_calibrador_autoridad_unica') as valor,
       'debe ser 1' as esperado
union all
select 'v_pick_canonico pasa la liga',
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relname='v_pick_canonico'
           and pg_get_viewdef(c.oid) like '%identidad_valida(c.espn_event_id, c.deporte, c.liga,%'),
       'debe ser 1'
union all
select 'autoridades de calibrador vivas',
       (select count(*) from calibradores where elegido and apto_para_lock and not invalidado),
       'hoy 0: nada autorizado a mover P_RETO'
union all
select 'filas canonicas rechazadas por identidad',
       (select count(*) from v_pick_canonico p
         where identidad_valida(p.espn_event_id,p.deporte,p.liga,p.mercado,p.pick_desc,
                                p.home,p.away,p.fuente)
               in ('DEPORTE_NO_COINCIDE_CON_AGENDA','LIGA_NO_COINCIDE_CON_AGENDA',
                   'HOME_NO_COINCIDE_CON_AGENDA','AWAY_NO_COINCIDE_CON_AGENDA',
                   'SIN_DEPORTE','SIN_LIGA','FIRMA_OBSOLETA_SIN_LIGA')),
       'debe ser 0';
