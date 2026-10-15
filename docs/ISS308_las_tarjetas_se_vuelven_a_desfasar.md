# ISS308 — Las tarjetas se vuelven a desfasar, y mi arreglo de hace dos días era puntual

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-15**

---

## Lo que pasó

El 13 de octubre (ISS297) dejé `v2.gate_active_soccer_analysis_1x2` en **PASS(0)**
realineando 41 tarjetas con el cerebro autorizado. Hoy vale **FAIL(19)**.

No es un fallo nuevo, y no es que mi arreglo fallara: **mi arreglo era puntual
cuando el defecto era de ciclo.**

`analisis_partidos.zzz_enforce_active_soccer_1x2` es un trigger
`BEFORE INSERT OR UPDATE`. Fuerza la concordancia **cuando alguien escribe la
fila**. Pero `v_futpro_publication_v3` es vivo: el cerebro recalcula P_RETO
continuamente y la tarjeta guardada se queda atrás **sin que nadie la toque**.
Nada la vuelve a alinear.

**Para el usuario esto no es un detalle interno:** la tarjeta y el pick publicado
muestran números distintos para el mismo partido.

## El arreglo

`v2.realinear_tarjetas_soccer(p_limite)` + cron `realinear-tarjetas-soccer`
cada 10 minutos, en el minuto 6 para respetar la escalera de ISS304.

Encuentra las tarjetas activas desfasadas con el **mismo predicado que usa el
guardia** —ni más ni menos—, guarda la imagen previa, y las toca para que el
trigger **autorizado** las reescriba desde la publicación canónica.

### Lo que no hace, y por qué

- **No inventa un número.** Todo sale del cerebro autorizado vía el trigger que
  ya existe y está declarado en `v2.escritor_autorizado` (ISS294).
- **No borra nada.** La imagen previa entra en `v2.analisis_preimagen_iss297`
  **antes** de tocar la fila, y solo si ese contenido exacto no estaba ya
  guardado — así un desfase repetido no infla la tabla con copias idénticas.
- **No toca eventos pasados.** El predicado exige `kickoff > now()`.
- **Tiene límite por corrida**, para no volverse un trabajo largo que pegue en su
  techo de tiempo. Que es justo el defecto que arreglé hoy en otros cuatro crons:
  no tiene sentido arreglar eso y crear uno nuevo.

### Detalle técnico que vale la pena

La imagen previa se lee en el **mismo statement** que el `UPDATE`, con un CTE que
modifica datos. Ambos ven la misma instantánea, así que lo guardado es el estado
de **antes** del cambio. El primer intento usaba una tabla temporal; sobraba.

## Probado

```
v2.realinear_tarjetas_soccer(200)
  -> {"desfasadas_antes": 19,
      "tocadas": 19,
      "imagenes_nuevas": 19,
      "desfasadas_despues": 0,
      "limite": 200}
     3,150 ms
```

De 19 a 0, con las 19 imágenes previas guardadas, en 3.1 segundos.

## Rollback

```sql
select cron.unschedule('realinear-tarjetas-soccer');
drop function if exists v2.realinear_tarjetas_soccer(integer);
-- y, si se quisiera deshacer una realineacion concreta:
update public.analisis_partidos a
   set analisis_json = pi.analisis_json_prev,
       model_version = pi.model_version_prev,
       motor         = pi.motor_prev
  from v2.analisis_preimagen_iss297 pi
 where pi.id = a.id
   and pi.guardado_at = (select max(x.guardado_at)
                           from v2.analisis_preimagen_iss297 x where x.id = a.id);
-- OJO: el trigger la realineara en la siguiente escritura, y el cron en 10 min.
```

No se borró un dato, no se tocó un modelo, no se encendió dinero. Cada contenido
anterior quedó guardado antes de ser sustituido.
