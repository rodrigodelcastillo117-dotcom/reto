# Barrido proactivo de bugs — 11-sep-2026

El owner pidió buscar sin esperar a que los reporte. Esto es lo que salió, con el daño medido
y separando lo que arreglé de lo que **no debo arreglar solo**.

## Método

Partí de las cinco clases de bug que ya habían aparecido esta noche, y busqué más de cada una:

1. El frontend llama a un RPC que no existe → *Prop Board*
2. Una política RLS excluye a `anon` aunque las tablas hermanas sí lo incluyen → *lesiones y depth chart*
3. El que escribe y el que lee usan llaves distintas del mismo JSON → *Fantasy*
4. El calificador no tiene el parámetro que necesitaría → *props en el parlay*
5. Un proceso pisa datos buenos → *live_scores*

---

## ARREGLADO — `clv-capturar` llevaba fallando desde ayer por un punto de más

**Job 196, activo, cada 15 min. 16 fallos. Última corrida buena: 10-sep 23:46.**

```
ERROR: invalid input syntax for type numeric: "50.5."
```

`clv_capturar_cierre` extraía el número de la línea así:

```sql
regexp_replace(f.pick_desc,'[^0-9.]','','g')::numeric
```

Borra todo lo que no sea dígito o punto. Con la pata
**"Menos de 50.5 puntos totales (incl. prórroga)"** el punto de *"incl."* sobrevive y produce
`"50.5."`, que no es un número. La apuesta del propio owner era la que tiraba el job.

Hay **5 patas con `"incl."`** en la base, así que no era un caso aislado.

**Arreglo:** extraer el PRIMER número en vez de borrar letras, en las 4 ocurrencias:

```sql
(regexp_match(f.pick_desc, '(\d+(?:\.\d+)?)'))[1]
```

Aplicado con un `DO` que exige exactamente 4 ocurrencias y aborta si encuentra otra cosa.
Verificado: 0 patrones viejos, 4 nuevos, y las dos funciones corren limpias — capturó 1 apuesta
y clasificó 69 cierres (Moneyline 39, Otro 11, Over/Under 10, Doble Oportunidad 7, Hándicap 2).

> Nota personal: es exactamente el mismo error que yo cometí hoy con `to_char(3.0,'FM9990.9')`
> devolviendo `"3."`. Dos bugs distintos, la misma causa: tratar texto con formato como si fuera
> un número.

---

## NO ARREGLADO A PROPÓSITO — el ciclo de aprendizaje RONGOL lleva 5 días muerto

**Job 182 (`rongol-ciclo`), activo. Última corrida exitosa: 6-sep-2026. 17 fallos desde entonces.**

```
ERROR: invalid transaction termination
CONTEXT: PL/pgSQL function rongol_ciclo_seguro() line 7 at COMMIT
```

El procedimiento hace `COMMIT` entre pasos a propósito (para liberar memoria y conservar el
progreso parcial), y ese `COMMIT` ya no está permitido en el contexto desde el que se llama.
Falla en el **primer** paso, así que **no corre ninguna** de las 14 etapas: `agente_aprender`,
`recalcular_dixon_coles`, `recalcular_calibracion`, `recalcular_zonas_confiables`,
`ajustar_ratings`, `agente_analizar_futuros`, `nfl_predecir`.

**Por qué no lo toco:** es el pipeline de aprendizaje del modelo de fútbol, que está bajo
auditoría externa. Cambiarlo (quitar los COMMIT, o cambiar cómo se invoca) altera cómo se
recalculan Dixon-Coles y la calibración. Eso necesita decisión del owner y del auditor, no
mi criterio a las 4 de la mañana.

**Impacto real:** el modelo de fútbol lleva 5 días sin reaprender ni recalibrar.

---

## NO ARREGLADO — el vigilante está apagado

**Job 227 (`autodiagnostico`), `active = false`.** Es `select public.diagnostico_automatico();`.

Es el proceso que existe justamente para detectar lo que estuvimos encontrando a mano toda la
noche. Está desactivado. También están en cero corridas exitosas
`auditar-coherencia-analisis` (job 370) y `auditar-completitud-analisis` (job 373).

No lo reactivo sin permiso porque no sé por qué lo apagaron — pudo ser por ruido o por costo.
Pero mientras siga apagado, la siguiente tanda de bugs también la vamos a encontrar por queja
del usuario y no por alerta del sistema.

---

## REVISADO Y DESCARTADO — 72 tablas cerradas a `anon`

Busqué más casos como el de `nfl_lesiones_semana`. Hay 72 tablas con RLS cuyas políticas de
SELECT no incluyen a `anon`. **La gran mayoría está bien así**: `user_roles`, `limites_usuario`,
`ajustes_cuenta`, `canasta`, `respaldo_borrado_usuarios` y los backups son datos privados.

Llama la atención un grupo de tablas de referencia de Fantasy (`nfl_adp`, `nfl_snaps`,
`nfl_uso_jugador`, `nfl_pateadores`, `nfl_defensa_fantasy`, …). Parecen el mismo bug, **pero no
las abrí**: las funciones de Fantasy son `SECURITY DEFINER` y `fantasy_ranking` ya devuelve
filas como `anon`, así que el acceso va por RPC. Abrirlas sería ensanchar la superficie por una
corazonada, que es justo lo que no se debe hacer.

---

## Ruido descartado explícitamente

`job startup timeout` y `server restarted` aparecen en ~15 jobs, casi siempre 1 o 2 veces contra
cientos de corridas exitosas. Son hipos de infraestructura, no bugs. Los dos deadlocks
(`completar-metadatos-live-30min`, `limpieza-nocturna`) sí conviene vigilarlos, pero se
recuperan solos.
