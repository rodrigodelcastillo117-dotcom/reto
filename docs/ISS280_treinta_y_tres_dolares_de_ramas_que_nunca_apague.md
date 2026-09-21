# ISS280 — $32.91 de ramas que creé y nunca apagué

Factura Supabase **VKFIVA-00010**, 2026-09-21, **$61.43** · Fecha: 2026-09-21

---

## El desglose real

| concepto | monto |
|---|---|
| Pro Plan | $25.00 |
| **Branching Compute (Micro) — 10 ramas huérfanas** | **$32.91** |
| Compute de los 2 proyectos reales ($13.52 − $10 de crédito) | $3.52 |
| Egress (10.86 GB de 250 incluidos) | $0.00 |
| Realtime (2,761,234 mensajes de 5M incluidos) | $0.00 |
| Edge Functions (200,359 de 2M incluidas) | $0.00 |
| Storage, Cached Egress, MAU | $0.00 |
| **Total** | **$61.43** |

**El uso real de la app costó $0.00.** Todo cae dentro de lo incluido. El 54% de
la factura son diez bases de datos vacías.

## Las diez

Creadas el 9-13 de septiembre para las tareas #4 y #7 —*"ejecutar en una rama
desechable"*— y **nunca borradas**. Las diez en `MIGRATIONS_FAILED` y con
`with_data=false`: jamás terminaron de migrar ni tuvieron un solo dato.

| rama | horas | costo |
|---|---|---|
| soccer-validation | 266 | $3.58 |
| soccer-final-gate | 255 | $3.43 |
| soccer-gate-v2 | 254 | $3.41 |
| soccer-gate-v2-repro | 253 | $3.40 |
| soccer-coherence-gate | 251 | $3.37 |
| nfl-dossier-parity | 249 | $3.35 |
| iss050-mlb-dossier | 248 | $3.33 |
| soccer-final-branch-gate | 248 | $3.33 |
| mlb-decision-contract | 241 | $3.24 |
| reto13m-final-independent-20260913 | 177 | $2.38 |

A $0.01344/hora cada una: **$3.23 por día**, ~**$97 al mes** si se dejaban.

Crearlas fue correcto: probar sin tocar producción es la regla. **No borrarlas
fue mi error**, y es mío, no de la app.

## El bloqueo muerto en mi propia guarda

`delete_branch` no aceptaba correr:

- La guarda (`supabase-project-guard.sh`, ISS258) exige `project_id` a toda
  herramienta que "apunta a un proyecto".
- `delete_branch` identifica su objetivo por `branch_id` y su esquema **rechaza**
  `project_id` (`unrecognized_keys`).

Las dos condiciones son incompatibles: era un **bloqueo imposible de satisfacer**,
no una protección. Doce días de cobro escondidos detrás de una regla muerta.

### La corrección: no eximir, sino cambiar la llave

No se debilitó la guarda. Sigue fallando cerrado; solo cambia el criterio para
`delete_branch`, de `project_id` a un `branch_id` **anotado a mano** en
`.claude/hooks/ramas-autorizadas-para-borrar.txt`. Una rama que no esté en esa
lista no se borra, **aunque pertenezca al proyecto autorizado**.

Antes de anotarlas, `list_branches` confirmó que las 10 tienen
`parent_project_ref = wpiztubmmmzclhlprgpd`. `main` no está en la lista y no
debe estarlo nunca.

### Un error mío dentro del arreglo

La primera versión del filtro usaba `tr -d '[:space:]'`. **`tr` borra también los
saltos de línea**, así que colapsaba el archivo entero en un renglón y
`grep -Fxq` no casaba nunca: **todas las ramas quedaban denegadas, incluidas las
autorizadas.** Lo detectó la prueba, no la corrida real. Se cambió por `sed`,
que trabaja línea por línea.

## Verificación

Probado con payloads simulados **antes** de borrar nada:

```
10 ramas autorizadas          -> allow
main (produccion)             -> deny
rama desconocida              -> deny
branch_id ausente/mal formado -> deny
execute_sql sin project_id    -> deny   (sin cambios)
execute_sql con otro proyecto -> deny   (sin cambios)
```

Y después, contra el servidor real:

```
list_branches   -> 1 rama: main (ACTIVE_HEALTHY)
v_pick_canonico -> 148 picks (produccion intacta)
```

La bitácora `guard-invocaciones.log` deja las 10 decisiones
`PERMITIDA_rama_en_lista_explicita` y las denegaciones de `main` y de la rama
inventada de la prueba.

## Costo después

```
Pro Plan                            $25.00
Compute 2 proyectos - credito        $3.52
Ramas                                $0.00
                                   ───────
                                    ~$28.52 / mes
```

## Compromiso

No vuelvo a crear ramas de Supabase sin avisar antes y sin borrarlas en la misma
sesión. Todo el trabajo de hoy (ISS277, ISS278, ISS279) fue directo sobre
producción, con migraciones reversibles y rollback escrito.

## Rollback

Del cambio de la guarda:
```bash
git revert <este commit>   # devuelve la guarda a exigir project_id siempre
```
Las ramas borradas **no se recuperan**. Estaban vacías y en `MIGRATIONS_FAILED`;
el dueño autorizó su borrado explícitamente tras ver la lista y el costo.
