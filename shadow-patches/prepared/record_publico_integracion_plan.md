# Récord Público — plan de integración (Lovable)

_Fecha: 2026-10-14 · Prototipo: `record-verificado.html` (artifact) · Vistas: `record_publico_views_v1.sql` (staged)_

## Estado
- ✅ **Prototipo vivo** con datos reales (artifact publicado).
- ✅ **4 vistas read-only** escritas y **validadas** (los números coinciden con el prototipo).
- ⏳ **Pendiente de tu OK** (PROD_FREEZE + LOVABLE_FREEZE): aplicar vistas y construir en Lovable.

## Paso A — aplicar las vistas (prod, requiere levantar PROD_FREEZE para este cambio)
Aplicar `record_publico_views_v1.sql`. Son aditivas y read-only (riesgo mínimo). Crea:
| Vista | Qué entrega | Consumo en la pantalla |
|---|---|---|
| `v_reto_track_record_v1` | agregado por deporte (picks, acierto%, ROI, Brier modelo vs mercado) | tarjetas de marcador |
| `v_reto_calibration_curve_v1` | banda de prob → acierto real, por deporte | diagrama de fiabilidad |
| `v_reto_clv_v1` | CLV soccer (cierre válido, % CLV+, drift) | panel CLV |
| `v_reto_recent_picks_v1` | historial pick por pick | tabla filtrable |

Datos actuales (al 13-oct): soccer 325 picks / 51.4% / ROI +2.9% / Brier 0.239 vs 0.231 ·
NFL 64 / 67.2% / ROI +11.8% / Brier 0.219 vs 0.234 (le gana) · CLV soccer 146 cierres, 53.5% CLV+.

## Paso B — construir en Lovable (requiere levantar LOVABLE_FREEZE)
Nueva ruta `/record` (o sección "Transparencia" en el menú). Mensaje a Lovable:
1. Crear pantalla "Récord" que lea las 4 vistas vía Supabase (cliente ya configurado).
2. Replicar el layout del prototipo `record-verificado.html`: hero honesto → tarjetas por
   deporte (métrica estrella = Brier vs mercado) → diagrama de calibración → panel CLV
   (etiqueta "en construcción") → tabla pick por pick filtrable (aciertos Y fallos).
3. Respetar el sistema visual actual de la app (no imponer el del prototipo si choca).
4. MLB se muestra como "en validación / sin picks de dinero" (no leer vista; es estado fijo).

**Reglas que NO se negocian en la integración:**
- No inventar métricas ni ocultar los picks perdidos.
- No encender money/EV/Kelly (sigue gateado).
- Marcar muestras chicas (NFL n=64) y CLV como "en construcción".

## Paso C — frescura
Las vistas son en vivo (leen el registro forward, que se llena solo con los crons existentes).
La pantalla se actualiza sola conforme se califican nuevos picks. Sin jobs nuevos.

## Qué falta decidir contigo
1. ¿Levanto PROD_FREEZE solo para aplicar estas 4 vistas read-only? (o las deja el auditor)
2. ¿Levanto LOVABLE_FREEZE para construir `/record`?
3. ¿Ruta dedicada `/record` o sección dentro de una pantalla existente?
