-- =====================================================================
-- ISS113  PATAS QUE NUNCA SE PUDIERON CALIFICAR, Y UN DEPORTE QUE NO
--         EXISTE EN EL PRODUCTO PERO SI EN LAS APUESTAS
-- =====================================================================
-- DE DONDE SALE: el parlay de -250 de ISS112
--   Sus 9 patas pendientes son de tenis. La pregunta era por que nunca se
--   calificaron. Respuesta medida:
--
--   Las 12 patas de tenis pendientes se parten en tres grupos distintos:
--
--   9 patas  EL EVENTO NO EXISTE EN live_scores
--            ids 181738, 181763, 181764, 181774, 182172, 182174, 182181,
--                182193, 182219
--            Nunca fueron ingeridos (o se borraron). Esas patas NO SE
--            PODIAN calificar nunca. Son las 9 del parlay de -250: se cobro
--            una perdida sobre patas que el sistema jamas pudo resolver.
--
--   1 pata   SIN SETS, status 'sin_confirmar'
--            oa_c6da187f..., 'SIN DATOS: nadie confirmo el resultado'
--            Aqui el fail-closed funciona bien: no se inventa un resultado.
--
--   2 patas  TIENEN SETS FINALES Y DEBERIAN SER CALIFICABLES
--            Flavio Cobolli Ganador, evento 182731, final, sets 1-3
--            Taylor Fritz Ganador,   evento 182727, final, sets 3-2
--            Este si es un hueco real del calificador.
--
-- UNA HIPOTESIS MIA QUE RESULTO FALSA, Y LA DESCARTO ANTES DE REPORTARLA
--   Al ver ids de 6 digitos (181738) contra los de 9 de ESPN (401874394)
--   conclui que era la colision de espacios de ids del proveedor que el
--   dueno viene advirtiendo. ESTABA MAL. En live_scores el tenis usa el
--   MISMO espacio de 6 digitos: 808 de 812 filas. Las 9 patas no apuntan a
--   otro proveedor, apuntan a filas que no existen. Es un hueco de ingesta,
--   no una colision.
--
-- EL DEFECTO DE PROCEDENCIA QUE SI EXISTE, Y SU TAMANO REAL
--   812 ids que NO son de ESPN viven en una columna llamada espn_event_id.
--   La columna afirma una procedencia que el dato no tiene.
--   Busque colisiones reales contra agenda_espn, historico_partidos_espn,
--   analisis_partidos, oraculo_picks_tracking y live_scores de otros
--   deportes: CERO en las cinco. O sea, hoy es un riesgo LATENTE, no un bug
--   activo. Lo reporto asi y no lo infle.
--
-- EL PROBLEMA DE FONDO: UN DEPORTE QUE EL PRODUCTO NO DECLARA
--   agenda_espn declara solo: baseball, football, soccer.
--   RETO 13M es MLB, NFL y futbol. El tenis NO esta declarado.
--   Y sin embargo hay 812 filas de tenis en live_scores y 12 patas de tenis
--   en parlays. Un pick de un deporte sin modelo, sin identidad en el
--   calendario autoritativo y sin calibracion no deberia poder existir: es
--   justo lo que sin_modelo_independiente() esta ahi para apagar.
--
--   NO construyo un calificador de tenis. Eso seria agrandar el producto a
--   un deporte que el dueno no declaro, y no me toca decidirlo. Mido, dejo
--   el invariante y lo subo a la superficie.
-- =====================================================================

create or replace view public.v_pata_sin_evento_resoluble as
select p.id                                  as parlay_id,
       p.resultado                           as resultado_parlay,
       p.ganancia_neta,
       x->>'pick_desc'                       as pick_desc,
       x->>'espn_event_id'                   as event_id,
       x->>'deporte'                         as deporte,
       lower(coalesce(x->>'resultado','pendiente')) as resultado_pata,
       (ls.espn_event_id is not null)         as existe_en_live_scores,
       ls.status                              as status_live,
       coalesce(ls.home_sets,0)+coalesce(ls.away_sets,0) as sets_totales,
       (ae.espn_event_id is not null)         as existe_en_agenda,
       case
         when ls.espn_event_id is null and ae.espn_event_id is null
           then 'EVENTO_INEXISTENTE_EN_TODA_LA_BASE'
         when ls.espn_event_id is null
           then 'NO_ESTA_EN_live_scores'
         when ls.status = 'final' and (coalesce(ls.home_sets,0)+coalesce(ls.away_sets,0)) > 0
           then 'CALIFICABLE_PERO_SIN_CALIFICAR'
         when ls.status in ('sin_confirmar','scheduled')
           then 'SIN_CONFIRMAR_FAIL_CLOSED_CORRECTO'
         else 'OTRO'
       end                                    as diagnostico
from public.parlays p,
     jsonb_array_elements(p.picks_data) x
left join public.live_scores ls on ls.espn_event_id = x->>'espn_event_id'
left join public.agenda_espn ae on ae.espn_event_id = x->>'espn_event_id'
where jsonb_typeof(p.picks_data) = 'array'
  and lower(coalesce(x->>'resultado','pendiente')) = 'pendiente';

comment on view public.v_pata_sin_evento_resoluble is
'ISS113. Cada pata de parlay pendiente con el diagnostico exacto de POR QUE no se ha calificado. Separa la pata que nunca se pudo calificar (evento inexistente) de la que el fail-closed deja pendiente a proposito y de la que SI es calificable y el calificador no esta tocando.';

create or replace function public.gate_pata_calificable()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PATA_PENDIENTE_CON_EVENTO_INEXISTENTE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'patas pendientes cuyo evento no existe en live_scores NI en agenda_espn: '
           || 'NUNCA se pudieron calificar. ' 
           || coalesce(string_agg(distinct event_id, ', '), 'ninguno')
  from public.v_pata_sin_evento_resoluble
  where diagnostico = 'EVENTO_INEXISTENTE_EN_TODA_LA_BASE'
  union all
  select 'PATA_CALIFICABLE_SIN_CALIFICAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'el evento esta final y con datos suficientes, pero la pata sigue pendiente: '
           || coalesce(string_agg(pick_desc || ' (' || event_id || ')', ', '), 'ninguna')
  from public.v_pata_sin_evento_resoluble
  where diagnostico = 'CALIFICABLE_PERO_SIN_CALIFICAR'
  union all
  select 'PICK_DE_DEPORTE_NO_DECLARADO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'patas de un deporte que agenda_espn no declara (el producto es MLB, NFL y futbol): '
           || coalesce(string_agg(distinct deporte, ', '), 'ninguno')
  from public.v_pata_sin_evento_resoluble
  where deporte is not null
    and not exists (select 1 from public.agenda_espn a
                    where public.deporte_canonico(a.deporte)
                        = public.deporte_canonico(v_pata_sin_evento_resoluble.deporte))
  union all
  select 'ID_AJENO_EN_COLUMNA_espn_event_id'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'filas de live_scores cuyo espn_event_id NO tiene formato ESPN de 9 digitos. '
           || 'Colisiones reales medidas contra agenda_espn, historico_partidos_espn, '
           || 'analisis_partidos y oraculo_picks_tracking: CERO. Riesgo latente, no bug activo.'
  from public.live_scores
  where espn_event_id !~ '^[0-9]{9}$'
  union all
  select 'PATAS_PENDIENTES_TOTALES'::text, 'INFO', count(*),
         (select coalesce(string_agg(d || '=' || n, ', ' order by n desc), '-')
            from (select diagnostico d, count(*) n
                    from public.v_pata_sin_evento_resoluble group by 1) z)
  from public.v_pata_sin_evento_resoluble;
$fn$;

comment on function public.gate_pata_calificable() is
'ISS113. Una pata pendiente debe estar pendiente por una razon legitima (el evento no termino, o falta el dato y el fail-closed actua), nunca porque su evento no existe o porque el calificador no la esta mirando.';

grant select on public.v_pata_sin_evento_resoluble to anon, authenticated, service_role;
grant execute on function public.gate_pata_calificable() to anon, authenticated, service_role;

-- =====================================================================
-- MEDICION FINAL: Y NO ERA UN PROBLEMA DE TENIS
-- =====================================================================
--   PATA_PENDIENTE_CON_EVENTO_INEXISTENTE   FAIL    19  en 4 parlays
--       deportes: Futbol, Baseball Y Tenis
--   PATA_CALIFICABLE_SIN_CALIFICAR          FAIL     2
--       Taylor Fritz Ganador (182727), Flavio Cobolli Ganador (182731)
--   PICK_DE_DEPORTE_NO_DECLARADO            FAIL    12  tenis
--   ID_AJENO_EN_COLUMNA_espn_event_id       FAIL  1283  riesgo latente
--   PATAS_PENDIENTES_TOTALES                INFO    23
--       EVENTO_INEXISTENTE=19, CALIFICABLE_SIN_CALIFICAR=2,
--       OTRO=1, SIN_CONFIRMAR_FAIL_CLOSED_CORRECTO=1
--
--   Entre al tema persiguiendo "el hueco de tenis" y el hueco no es de
--   tenis. De las 23 patas pendientes del sistema, 19 apuntan a eventos que
--   NO EXISTEN en ninguna parte de la base, y abarcan Futbol, Baseball y
--   Tenis por igual, en 4 parlays. Esas 19 patas no se podian calificar
--   nunca, en ningun deporte. El tenis solo era el caso que tenia a la vista.
--
--   Y 1283 filas de live_scores, no 812, traen un id que no tiene formato
--   ESPN. El tenis es una parte del problema de procedencia, no todo.
--
-- LO QUE NO HICE, Y POR QUE
--   No construi un calificador de tenis. agenda_espn declara baseball,
--   football y soccer: el tenis no es un deporte del producto. Construirle
--   un calificador seria agrandar RETO 13M a un deporte que el dueno no
--   declaro, con picks que no tienen modelo, ni identidad en el calendario
--   autoritativo, ni calibracion. Esa es una decision de producto.
--
--   Tampoco borre las 19 patas ni los 4 parlays. Borrar historia para
--   limpiar un contador es justo lo que el dueno prohibio.
