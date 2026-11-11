# Mercado contrarian: el sistema manda el lado opuesto si un mercado se rompe

Fecha: 2026-11-11. Gatillo: "si en algún mercado acertamos 20-30%, que el sistema lo mande al contrario". DINERO OFF.

## Qué
Detector + inversión automática. Si un (deporte,mercado) acierta de forma consistente POR DEBAJO de 50%
fuera de muestra, el email publica el LADO OPUESTO (y marca "🔄 contrarian").

## Gate de integridad (clave)
Solo invierte si: hit_test < 45% AND hit_train < 48% AND n_test >= 30. Nunca por ruido ni por un mal día.
Invertir un segmento que en realidad es ~50% sería "cosas mal creadas".

## Estado HOY
Ningún mercado califica. El más bajo es BTTS 57% (test 52%), todos por arriba de 50%. El mecanismo
queda dormido y se activa solo si algún mercado se rompe de verdad.

## Piezas
- Vista v_reto_polaridad_mercado_v1 (split 70/30 por fecha, flag `invertir`).
- Email mejores-picks-diario v11: lee la vista; para los segmentos con invertir=true voltea el pick
  (BTTS Sí↔No; mercados de equipo: el rival del "A vs B") y pone prob=100-prob. Fallback seguro si no
  puede determinar el opuesto. Como hoy no hay flags, no cambia nada.
