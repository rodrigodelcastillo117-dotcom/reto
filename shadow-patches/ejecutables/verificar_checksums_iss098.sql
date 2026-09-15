-- Checksums de ISS098 / ISS098b. Capturados el 2026-09-12.
--
-- DOS NIVELES, y el primero es el que importa:
--
-- A) md5(prosrc) == md5 del CUERPO TAL COMO ESTA EN EL ARCHIVO .sql de este repo.
--    Esto prueba que lo que corre en produccion es literalmente lo que dice el
--    parche, no una variante que escribi en una consola y luego documente
--    parecido. Lo verifique a la inversa: extraje los cuerpos del archivo, saque
--    su md5 local, y encontre que 7 de 9 DIFERIAN de produccion porque al
--    redactar el archivo habia movido comentarios fuera del cuerpo. Ejecute el
--    archivo para que produccion quedara igual al archivo, no al contrario.
--
-- B) md5(pg_get_functiondef) — huella completa con cabecera, para detectar
--    cambios de firma, volatilidad o search_path.
with esperado(objeto, md5_cuerpo, md5_def) as (values
 ('identidad_valida',                   '60e79abea8db865df2d21951aaadb5fc','f42d02c178b92ac3626df54e3e6c6817'),
 ('estado_respaldo',                    'b8412016c0b449dd710902265d1f5f6e','a2cb956500c5eb7df46dc91517702940'),
 ('aplicar_calibrador_autorizado',      '87581348811798654ed6f29e9f7215b6','200b38a13b106ade8cdafe688b96e357'),
 ('tolerancia_desplazamiento_pp',       '2674cf6045f87435608ef7673b4301a8','f963db645a9cea58dc30e005519e2c69'),
 ('gate_p_reto_sin_desplazar',          '7bef5ed767c5e71e59e59b34593d238d','a60e34e24661a9bdb695180f0951e517'),
 ('gate_identidad_exacta',              '728aabf54b5e10aae513ecbbcb8b9570','98fe6b3f2783d6fed60c19079117daca'),
 ('gate_calibrador_reproducible',       'c47f5c8970db9d320d915f9f879ea863','ea96c3d97a7ef5b087946f152047ef26'),
 ('gate_superficie_resucitada',         '54d171339362823b80c0ae56e0d63a08','28d530c044a220412be0b96831a9f6b2'),
 ('tg_superficie_solo_sale_con_lapida', 'b164439fb03b17815f3aa707100b5b04','679102dfb7079f98c1aefb27bb96ce92'),
 -- no los toca ISS098 pero el runner y el gate de superficie destruida dependen de el
 ('pruebas_selector_limpio',            null,                              'e45128279b86e19cca7950d15fd18b69'),
 ('gate_superficie_destruida',          null,                              'e677ddbcca055321399c7311ae0ff660')
)
select e.objeto,
       case when p.oid is null then 'NO EXISTE'
            when e.md5_cuerpo is not null and md5(p.prosrc) <> e.md5_cuerpo
                 then 'CUERPO DISTINTO AL ARCHIVO: '||md5(p.prosrc)
            when md5(pg_get_functiondef(p.oid)) <> e.md5_def
                 then 'DEFINICION CAMBIADA: '||md5(pg_get_functiondef(p.oid))
            else 'IGUAL' end as estado
from esperado e
left join pg_proc p on p.proname = e.objeto and p.pronamespace = 'public'::regnamespace
order by 1;

-- Estructura que crea ISS098. Falta cualquiera = el parche no se aplico completo.
select 'identidad_equipo_alias' obj,
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relname='identidad_equipo_alias') existe,
       (select count(*) from identidad_equipo_alias) filas
union all
select 'superficie_retirada',
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relname='superficie_retirada'),
       (select count(*) from superficie_retirada)
union all
select 'ajustes_a_p_reto.magnitud_max_pp',
       (select count(*) from pg_attribute
         where attrelid='public.ajustes_a_p_reto'::regclass and attname='magnitud_max_pp'
           and not attisdropped), 0
union all
select 'trigger tg_superficie_solo_sale_con_lapida',
       (select count(*) from pg_trigger
         where tgrelid='public.superficie_usuario'::regclass
           and tgname='tg_superficie_solo_sale_con_lapida' and not tgisinternal), 0;
