--- G36: fuga temporal en ventanas de tiros (ISS157) ---
select * from public.gate_fuga_temporal_tiros();
--- G37: la tarjeta servida no esta vacia ni rancia (ISS170) ---
select * from public.gate_tarjeta_no_vacia();
--- G38: la via de fuerza estimada, vigilada aparte (ISS174) ---
select * from public.gate_phi_estimado();
--- G39: mlb_one_brain_v2 no publica sin evidencia, y la evidencia sigue entrando (ISS176) ---
select * from public.gate_mlb_one_brain_medible();
--- G40: la tarjeta no se contradice a si misma (ISS177). G40.1 en FAIL a proposito ---
select * from public.gate_tarjeta_no_se_contradice();
--- G41: contrato de tarjeta unica, ninguna tarjeta muda (ISS178) ---
select * from public.gate_tarjeta_universal();
--- G40.3 / G40.4: marcador y margen condicionados al pick (ISS179), dentro del mismo gate ---
--- G42: Fantasy alcanzable desde el front y honesto sobre el peso de la temporada (ISS180) ---
select * from public.gate_fantasy_alcanzable();
--- Fantasy: participacion de la temporada actual (ISS181) ---
select public.fantasy_participacion('Courtland Sutton',2026);
--- G43: un solo modelo manda en fantasy, el resumen es la suma de las tarjetas (ISS192) ---
select * from public.gate_fantasy_un_solo_modelo();
--- G44: el modelo de fantasy ve la temporada en curso, no solo la pasada (ISS193) ---
select * from public.gate_fantasy_ve_la_temporada_en_curso();
--- G30.11 / G32.6 / G33.9: totales de futbol retirado por evidencia (ISS194) ---
select * from v2.mercado_retirado;
--- Patas que nunca se pudieron calificar, declaradas en vez de eternas (ISS195) ---
select * from public.marcar_patas_no_calificables(7, false);
--- Un solo cerebro de futbol: el 1X2 del analisis sale del canonico (ISS196) ---
select coalesce(analisis_json#>>'{probabilidades,_fuente_1x2}','(sin 1X2)') fuente, count(*)
from public.analisis_partidos where analisis_json ? 'probabilidades' group by 1;
--- G30.12: el backend no emite totales de futbol, asi el front no puede pintarlos (ISS198) ---
select * from public.gate_tarjetas_soccer() where gate like 'G30.1%';
