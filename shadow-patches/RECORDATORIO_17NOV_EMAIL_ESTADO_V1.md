# Recordatorio 17-nov por correo: "estado completo de la app"

Fecha: 2026-11-09. Gatillo: "recordatorio para el 17, que me llegue por correo para ver todo". DINERO OFF.

## Qué
Un correo de resumen que llega SOLO (sin depender de una sesión de Claude) el 17-nov con TODO el estado:
- Récord verificado (global, forma 7/30 días, tier ≥70%), CLV (estado/número).
- Récord por deporte y por mercado (calibración).
- Cobertura: próximos partidos por deporte + selecciones internacionales + ligas con momios.
- Botón a /validacion (el tablero vivo, para "ver todo" a detalle).

## Piezas
- **Función `reto_cobertura_resumen_v1()`** (SECURITY DEFINER, service_role): próximos por deporte + intl.
- **Edge function `resumen-estado-email`**: compone y envía el correo (Resend) a rodelcast. Reusa
  v_reto_tablero_validacion_v1 + la función de cobertura. Solo lectura.
- **Cron `reto-resumen-17nov`** (jobid 607, `10 14 17 11 *` = 17-nov 8:10am CDMX). ONE-SHOT: el propio
  comando se des-programa (`cron.unschedule`) tras disparar, así no se repite el próximo año.

## Validación
Envío de prueba hoy: status 200, enviado=true, a rodrigodelcastillo117@gmail.com. ✅

## Nota
Convive con el recordatorio de análisis profundo del 17 (trigger de sesión que revisa cobertura+CLV).
Este correo es el entregable garantizado por email; aquel hace el análisis/arreglo más fino.
