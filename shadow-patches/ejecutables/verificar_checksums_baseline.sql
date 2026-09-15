-- =====================================================================
-- verificar_checksums_baseline.sql
--   Prueba que los volcados de baseline/ son IDENTICOS a produccion.
--   Un volcado transcrito a mano puede traer un typo silencioso; un typo en
--   una definicion de vista no rompe nada hasta el dia que alguien reconstruye
--   el sistema desde Git y obtiene una vista distinta sin darse cuenta.
--   Por eso esto se verifica con md5, no a ojo.
--
--   md5 tomados del cuerpo del archivo (lo que sigue a "create or replace
--   view public.X as") comparado contra md5(pg_get_viewdef(X, true)).
--   Verificado el 2026-09-12: 10 de 10 IDENTICO.
-- =====================================================================
with archivo(nombre, md5_archivo) as (values
 ('calibracion_mercado',        '76ed074dde8cdb065332a172cd2d66ac'),
 ('picks_recomendados_hoy',     '71a1345a1221f9391e92b939822987f4'),
 ('picks_recomendados_hoy_raw', '0a7d43ac01ada0a0d115f5eacb419eb7'),
 ('v_evento_hora',              '9c3bde5c0065242ff26bb39a49fc253e'),
 ('v_momios_confiables',        'd5a78c6c6ed8f1ac0eb1fe0e9da21c6e'),
 ('v_pick_momio_libro',         'ee5b8300f92b49d845679234e4ddee0a'),
 ('v_picks_futbol_calibrado',   '14b22e39096a659b3f55939fe16e7c63'),
 ('v_picks_mlb_modelo',         '2b953ad407633d869f589d6d55efe21a'),
 ('v_radar_odds_fase',          '8c9b4f4f4606d3fc03942af9ab3f14b2'),
 ('v_super_pick',               'cacc5aa254b7c1d523b0c1602f5f95f0')
)
select a.nombre,
       md5(pg_get_viewdef(('public.'||a.nombre)::regclass, true)) as md5_produccion,
       a.md5_archivo,
       case when md5(pg_get_viewdef(('public.'||a.nombre)::regclass, true)) = a.md5_archivo
            then 'IDENTICO' else 'DIVERGE' end as veredicto
from archivo a order by 4 desc, 1;

-- Si algo sale DIVERGE la regla es la misma de siempre: se ejecuta el ARCHIVO
-- hacia produccion, nunca al reves. Un volcado que ya no coincide significa
-- que produccion cambio sin pasar por Git, y eso es la deuda que estamos
-- cerrando, no una excusa para re-volcar.
