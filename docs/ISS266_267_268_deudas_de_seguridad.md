# ISS266/267/268 — Deudas de seguridad: tres eran falsas, dos eran reales

Base: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

> **Este documento empieza corrigiendome.** Reporte cinco deudas de seguridad
> varias veces, incluida la nota del release de hace una hora. **Tres no
> existian.** Las habia deducido de los GRANTS sin probar el comportamiento real.

---

## PARTE 1 — Las tres que NO existian

Reporte que `pa_audit_log` (302,168 filas) era escribible por `authenticated`, y
que `respaldo_borrado_usuarios` y `usuarios_archivados` eran legibles por `anon`.

**Lo deduje de `has_table_privilege`. Nunca lo probe.** Las tres tablas tienen RLS
activa con **una sola politica, restringida a `service_role`**.

Medido de verdad:

| prueba | resultado |
|---|---|
| `SELECT` como `anon` en las tres | **0 filas** |
| `INSERT` como `authenticated` en las tres | **42501** |
| `INSERT` como `anon` en `pa_audit_log` | **42501** |

Los GRANT existen pero son residuo cosmetico: **la puerta real es RLS y esta
cerrada.** No habia nada que arreglar. La leccion es la misma que vengo aplicando
todo el dia y que aqui me salte: **medir el comportamiento, no leer la teoria.**

---

## PARTE 2 — ISS266: el bankroll del alta no se validaba

`registrar_perfil(p_apodo, p_bankroll)` es SECURITY DEFINER, ejecutable por `anon`
y `authenticated`. Validaba el apodo a conciencia —longitud, caracteres,
unicidad normalizada, apodo legacy, historial reservado— y metia `p_bankroll`
directo con `COALESCE(p_bankroll, 1500)`. **Sin ningun limite.**

**Antes de decidir el arreglo se midio** si el parametro se usa: 6 usuarios, 3
valores distintos, rango real 1500–5000. Se usa de verdad, asi que fijarlo a 1500
habria roto una funcion legitima del alta. Se valida el rango en su lugar.

---

## PARTE 3 — ISS267: el agujero de verdad

La politica de UPDATE de `usuarios` era:

```
"Users update own profile"   USING (user_id = auth.uid())   WITH CHECK = NULL
```

**Una politica UPDATE con USING y sin WITH CHECK deja cambiar la propia fila sin
ninguna restriccion sobre los valores nuevos.** Probado en produccion dentro de
BEGIN/ROLLBACK, como `authenticated` con JWT simulado:

```
filas_afectadas=1 | antes=1500 | despues=999000000
```

Cualquier usuario podia ponerse **999 millones** de bankroll inicial con un UPDATE
directo al API, saltandose por completo `registrar_perfil`.

### Por que importa

`bankroll_inicial` es el denominador del ROI, del progreso hacia la meta y del
leaderboard. No "roba" dinero, pero **corrompe el track record de todos**, y el
dia que se encienda el dinero, tambien el tamano de apuesta.

### Por que NO se bloqueo la edicion

El frontend tiene una funcion legitima, `src/components/reto/EditBankrollSettings.tsx`,
que ya valida **100 a 1,000,000 con 2 decimales**… **pero solo en el cliente.**
Es el caso clasico: validacion de pantalla no es seguridad.

Bloquear el UPDATE habria roto una funcion real. Lo correcto era **hacer cumplir
en la base la regla que la app ya declara**. El limite no es inventado: es el que
la propia pantalla muestra al usuario.

### El arreglo

1. La politica de UPDATE gana `WITH CHECK (user_id = auth.uid())`: ya no se puede
   reasignar la fila a otro usuario.
2. Trigger `trg_validar_bankroll_inicial` en INSERT y UPDATE, **para cualquier
   escritor**: 100 ≤ x ≤ 1,000,000, maximo 2 decimales. Un valor corrupto es
   corrupto lo escriba quien lo escriba; mejor que falle ruidosamente a que
   envenene el leaderboard en silencio.

### Probado antes y despues

| caso | antes | despues |
|---|---|---|
| UPDATE a 999,000,000 | **paso, 1 fila** | **bloqueado (23514)** |
| UPDATE a 0 | pasaba | **bloqueado (23514)** |
| UPDATE a 2500.50 (la pantalla real) | pasaba | **OK-FUNCIONA** |
| `registrar_perfil` con 999,000,000 | pasaba | **rechazado** |
| `registrar_perfil` con 5000 | pasaba | **creado** |

Ninguno de los 6 usuarios actuales queda fuera de rango (1500–5000).

---

## PARTE 4 — ISS268: la politica de INSERT rota

`usuarios_auth_insert` tenia en su WITH CHECK una subconsulta a `usuarios` desde
una politica sobre `usuarios`. Comprobado:

```
42P17 :: infinite recursion detected in policy for relation "usuarios"
```

**No era una fuga** —falla cerrado, nadie puede insertar— **pero era una trampa**:
quien intentara "arreglar la recursion" quitando la subconsulta abriria una via de
alta directa que se salta TODAS las validaciones de `registrar_perfil`.

Se retira la politica. El alta tiene **una sola puerta**: `registrar_perfil()`,
que es SECURITY DEFINER y no la necesita.

| caso | antes | despues |
|---|---|---|
| INSERT directo como `authenticated` | 42P17 recursion | **42501, denegacion limpia** |
| `registrar_perfil` | funcionaba | **funcionaba (creado)** |

---

## Rollback

```sql
-- ISS268
create policy "usuarios_auth_insert" on public.usuarios for insert to authenticated
  with check ((user_id = auth.uid()) AND (apodo IS NOT NULL)
    AND (length(btrim(apodo)) >= 2) AND (length(btrim(apodo)) <= 30)
    AND (NOT EXISTS (SELECT 1 FROM usuarios u WHERE lower(u.apodo) = lower(usuarios.apodo))));
-- (vuelve a fallar con 42P17: era su estado original)

-- ISS267
drop trigger if exists trg_validar_bankroll_inicial on public.usuarios;
drop function if exists public.tg_validar_bankroll_inicial();
drop policy if exists "Users update own profile" on public.usuarios;
create policy "Users update own profile" on public.usuarios for update to authenticated
  using (user_id = (select auth.uid()));   -- sin WITH CHECK: reabre el agujero

-- ISS266: restaurar el COALESCE(p_bankroll,1500) sin validacion en registrar_perfil
```

No se borro ningun dato.

---

## Lo que queda de la lista original

- **4 fugas de lectura con `USING(true)`**: revisadas. La mayoria son catalogos y
  datos de referencia legitimamente publicos (agenda, alineaciones, mapas de
  equipos). **`amigos` y `ai_memory` merecen una revision aparte** y quedan
  anotadas, no arregladas.
- **`generar_parlay_seguro`, rama latente de BTTS**: sigue sin tocarse. Es una
  funcion de dinero y el gate G47.3 ya la marca INFO como inalcanzable.
