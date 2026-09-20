# ISS270 — La evidencia no se cosechaba, y el dinero podia encenderse solo

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

---

## Contexto: audite el trabajo de otro agente

El dueño me dijo *"se lo pedi a chatgpt y creo que ya quedo todo menos el frontend"*.
No lo di por bueno. Un agente tocando produccion es justo el caso donde hay que
medir el servidor, no leer el reporte.

### Lo que encontre al medir

**El trabajo de ChatGPT es real y esta bien hecho.** Una migracion,
`20260920193551 mlb_closing_reference_sidecar_temporal`, que conecta el precio de
cierre de mercado con la evidencia de MLB. La revise linea por linea y las cosas
que podian envenenarla estan cubiertas:

| riesgo | como lo cubre |
|---|---|
| volteo local/visitante | une por **nombre** (`m.home_team=s.home_team`) y ademas exige `s.p_home/100=o.p1`, o sea confirma que `p1` es local antes de asignar `ref1=p_home` |
| fuga temporal | `CHECK (captured_at<market_kickoff)` **en la tabla**, no solo en el WHERE; y exige `capturado_at>=o.snapshot_at` (el precio no puede ser anterior a nuestra prediccion) |
| partido equivocado | `abs(saque-kickoff)<=600` segundos |
| momio corrupto | re-deriva el no-vig desde los momios y verifica que cuadre a 0.001 |
| empate de candidatos | `having count(*)=1` — si dos precios casan con una observacion, la **descarta**. Falla cerrado. |
| sobrescribir evidencia | `coalesce(o.ref1, r.p_home)` — solo llena NULLs |
| aflojar el dinero | **los umbrales del gate estan intactos**: 400 eventos, mcov>=75, dr95<0, gap<=7.5 |

Tambien verifique que mis arreglos siguieran en pie: las 4 politicas de ISS269
siguen **CERRADAS**, el `WITH CHECK` de ISS267 sigue puesto, el trigger de
bankroll existe, y `money_authorized` sigue en **0 de 231**.

### Y la primera medicion de mercado que existe

Con el sidecar, MLB quedo con **97.44% de cobertura de mercado** (38 de 39):

| | valor |
|---|---|
| Brier nuestro | **0.416799** |
| Brier DraftKings (cierre, sin vig) | **0.430759** |
| diferencia | **−0.015940** (vamos mejor) |
| **upper95** | **+0.029793** |

**Nuestro cerebro de MLB le gana al precio de cierre en la estimacion puntual.**
Es el primer deporte donde el signo va a nuestro favor — en futbol va en contra
en los cuatro mercados. Pero con 38 observaciones el intervalo incluye el cero:
**no esta demostrado.** Es una señal, no un veredicto. Y 38 esta lejisimos de los
400 que exige el gate.

## El hallazgo propio: la cosecha no corria

Busque el cron que recalcula los gates. **No existe ninguno.**

```
select ... from cron.job where command ~* 'refresh_model_learning|model_learning_gate' ;
-> 0 filas
```

Y `v2.model_learning_gate` la consumen **cinco vistas de producto**:

| vista | que hace |
|---|---|
| `public.v_evidencia_mercado_soccer` | **la insignia de evidencia que ve el usuario** |
| `public.v_favorito_mlb` | favorito de MLB |
| `public.v_reto_brain_release_authority_v1` | autoridad de release |
| `public.v_reto_research_pick_v1` | pick de investigacion |
| `v2.v_model_learning_health` | salud del aprendizaje |

O sea: **cada partido jugado y cada precio de cierre capturado era invisible para
las etiquetas de honestidad de la app** hasta que alguien llamara la funcion a
mano. La app podia estar afirmando cosas calculadas con evidencia congelada.

Es exactamente el patron de ISS262: el laboratorio tiene cron (471, diario 08:35),
la cosecha no. Tercera vez que aparece la misma enfermedad en este sistema.

## Por que poner el cron, solo, era peligroso

`money_authorized` es una **columna calculada**. Un cron nocturno que recalcula el
gate puede cruzar el umbral y **encender dinero sin que nadie lo decida**. La regla
del dueño es explicita: *"No promociones ningun modelo ni enciendas dinero."*

Hasta hoy esa regla se cumplia por accidente: nada calificaba. Eso no es una
garantia, es suerte.

## Lo que hice

Tres piezas, ninguna toca un umbral del gate:

1. **`v2.money_release_approval`** — una fila por (deporte, mercado, modelo) al que
   el dueño autorizo dinero explicitamente. **Nace vacia.** RLS encendida, todo
   revocado a `public`, `anon`, `authenticated`.

2. **`public.gate_dinero_sin_aprobacion()` (G50.4)** — salta si el gate calcula
   `money_authorized` para algo que no tiene fila de aprobacion. El dinero ya no
   puede encenderse en silencio: ahora esta **impuesto y auditable**, en vez de
   depender de que nada califique.

3. **Cron `cosechar-model-learning-gates`**, diario 09:20 UTC (despues del
   laboratorio de las 08:35). Recalcula **la medicion**. No promueve ningun modelo.

## Verificacion

Probado contra el servidor, y el guardia probado **fallando**, no solo pasando:

```
cron_creado=1 | schedule=20 9 * * * | activo=true
G50.4_hoy                  = PASS (n=0)
G50.4_con_fallo_simulado   = FAIL (n=1)
   detalle: DINERO ENCENDIDO SIN APROBACION: baseball/Moneyline/mlb_one_brain_v2
G50.4_con_aprobacion       = PASS
```

Todo el simulacro se revirtio. Residuo confirmado en cero:
`dinero_encendido=0 | aprobaciones_registradas=0 | G50.4=PASS | cron_activo=1`.

## Dos fragilidades del sidecar que dejo declaradas, no arregladas

1. **`m.casa='DraftKings'` esta escrito a mano.** Si esa casa cambia de nombre o
   deja de estar disponible, la cobertura cae a cero **en silencio**. Es la misma
   clase de candado que encontre en ISS263 (`liga in ('NBA','WNBA','NHL')`).
2. **`s.p_home/100=o.p1` es igualdad numerica exacta.** Falla cerrado, pero
   significa que la cobertura la limita un accidente de redondeo, no la
   disponibilidad del dato. Sospecho que ahi se van buena parte de las 143
   observaciones candidatas que acabaron siendo 38. **No lo comprobe**, asi que lo
   dejo como sospecha, no como hallazgo.
3. **El sidecar es solo de MLB.** `momios_cierre_espn` ya tiene NFL (30) y WNBA (9).
   NBA y NHL no tienen ni un precio pre-saque capturado.

## Rollback

```sql
select cron.unschedule('cosechar-model-learning-gates');
drop function if exists public.gate_dinero_sin_aprobacion();
drop table if exists v2.money_release_approval;
```

No borra datos historicos ni toca el gate.
