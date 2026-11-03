# Resumen diario de MEJORES PICKS por email (nuevo sender)

Fecha: 2026-11-03. Gatillo del dueño: "nunca me llegó mi resumen de mejores picks".

## Diagnóstico (honesto)
La cuenta del dueño es `rodelcast` (rodrigodelcastillo117@gmail.com) — push activo desde
31-oct, `notif_picks=ON`, `canal_resumen=email`. La plomería de su lado estaba lista.
Pero el resumen nunca llegó porque **la función no existía**:
- `resumen-diario` es un recap de las **apuestas registradas del propio usuario** (dinero/
  bankroll) y solo dispara si registró apuestas ese día (`allToday.length > 0`). No es un
  resumen de los mejores picks del motor.
- Los crons de pick (`notificar-pick-del-dia`, `pick-del-dia-principal/-noche`,
  `pick-en-peligro`) están `active=false`.
- `push_log` no registra **ningún envío desde el 1-sep**: el pipeline de notificaciones
  llevaba ~2 meses dormido, y lo último eran avisos de marcador, nunca picks.

## Construido (dinero OFF, additivo, no toca modelo/gate/récord)
- **Edge function `mejores-picks-diario`**: lee `v_reto_mejores_picks_v1` (ya money-free) para
  la ventana "de ahora al fin del día CDMX", arma Top-5 + secciones por deporte (hasta 4 c/u),
  muestra pick + probabilidad del modelo + nivel de confianza + hora CDMX + alerta de bajas, y
  **manda EMAIL vía Resend** (remitente `Reto 13M <onboarding@resend.dev>`, mismo mecanismo que
  `resumen-diario`). Pie honesto: "probabilidades del modelo, no garantías; sin dinero/EV/stake;
  el modelo solo supera comprobadamente al cierre en NFL". Audiencia por defecto `['rodelcast']`
  (decisión del dueño: solo a mí); configurable vía `body.apodos`. SOLO email (sin push), por
  elección del dueño.
- **Cron `mejores-picks-diario-7am`** (jobid 596, `0 13 * * *` = 7:00 am CDMX, activo): invoca la
  función con `public.sk()` como todos los demás crons.

## Verificado
- Prueba manual de push a `rodelcast`: `enviar-notificacion-push` → `{sent:1}` (primer envío de
  picks que sale del sistema desde septiembre).
- Prueba del email por la misma vía del cron (`net.http_post` + `public.sk()`): HTTP 200,
  Resend `send:200`, 20 picks a rodrigodelcastillo117@gmail.com. Confirmado.

## Alcance / siguiente decisión
- Hoy va **solo al dueño** por email. Abrirlo a todos los usuarios con `notif_picks=ON` (broadcast)
  es otra decisión del dueño; cambiar `body.apodos` o iterar `usuarios` lo habilita.
- Agregar push además del email: trivial (reusar `sendPush` de `resumen-diario`), pero el dueño
  pidió solo email por ahora.
