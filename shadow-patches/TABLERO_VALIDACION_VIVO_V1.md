# Tablero de validación VIVO (página /validacion en la app)

Fecha: 2026-11-09. Gatillo: "déjalo vivo" (dashboard de validación que lea la base en tiempo real). DINERO OFF.

## Qué es
Una página dentro de la app (RETO 13M, Lovable `00f8f06b`) en `/validacion` que muestra, en vivo,
qué tan bien acierta el modelo: récord por deporte, calibración (lo que decimos vs lo que ganamos),
el tier ≥70%, tendencia semanal, y qué está validado vs lo que probé y NO se gana el lugar.

## Backend (controlado 100%, en vivo)
- **Vista `v_reto_tablero_validacion_v1`** (`supabase/sql/v_reto_tablero_validacion_v1.sql`): 1 fila,
  1 columna `data` (jsonb) con todo calculado al momento desde `v_reto_pick_grade_v1`. `grant select`
  a `anon` y `authenticated`. Se actualiza sola conforme se gradean picks.
- Forma del JSON: `{ generado_at, totales{n,hit,dice,n_alta,hit_alta,desde,hasta},
  por_deporte[{d,n,hit,dice,brier,n_alta,hit_alta}], buckets[{b,n,dice,real}], semanas[{w,n,hit}] }`.

## Frontend
- Página React `/validacion` construida por la IA de Lovable leyendo la vista con el cliente supabase
  (`select('data').single()`). Diseño: tema oscuro, verde = lo que ganamos, azul = lo que el modelo dice.
- Referencia de diseño estática: `supabase/dashboards/tablero-validacion.html` (la versión que se validó
  primero como artifact, misma estructura y copys).

## Números al 9 nov 2026 (snapshot)
1,730 picks verificados · 59.6% acierto global · tier ≥70% = 193 picks, 79.3% real.
NBA 65% (mejor), fútbol 59%, NHL 63%, WTA 60%, NFL 59%, ATP 57%.
Calibración: 70%+ es oro (~79% real); 65-70% miente (dice 67%, gana 60%); 50-55% pierde (49%).

## Honestidad
El tablero mide acierto y calibración, NO rentabilidad. La métrica real de rentabilidad es el CLV
(se mide aparte, madura en ~2-3 semanas). Nada de dinero/EV/stake en la página.
