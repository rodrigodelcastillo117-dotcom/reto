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
