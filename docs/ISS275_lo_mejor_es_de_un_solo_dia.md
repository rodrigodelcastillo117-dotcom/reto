# ISS275 — «Lo que RETO cree que va a pasar» mezclaba dos días

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## Lo que reportó el dueño

Con la función ya cargando (ISS274), la sección mostraba:

```
Cincinnati @ Atlanta    mar 22 de sep    70.1%
NY Giants @ LA Rams     lun 21 de sep    70.0%
```

Su reclamo, textual: *"me das de lunes y martes. solo es de 1 día"*.

Tiene razón, y hay dos defectos, no uno:

1. **Mezcla días.** La vista particiona por `(dia_mx, deporte)`, así que con dos
   días en la ventana devuelve dos días.
2. **El orden es por probabilidad, no por fecha.** Por eso el **martes** aparecía
   **antes** que el lunes. Para quien lo lee, incoherente.

## Arreglo

- Se queda con **un solo día**: el más próximo que tenga contenido (`min(dia_mx)`).
- Se ordena **cronológicamente**.
- Se añade `kickoff > now()` para no listar algo ya empezado como «va a pasar».
- No se toca el piso editorial de 58%, ni el ranking, ni una sola columna del
  contrato.

## Por qué en la base y no en el frontend

Verificado: **ningún otro objeto de la base consume esta vista.** Su único
consumidor es la pantalla. Arreglarlo aquí es una línea de SQL y le ahorra al
dueño gastar créditos de Lovable.

## Resultado, leído como lo lee la app

```
anon ve 1 fila en 1 dia
  [football · 21 Sep 18:15 · Gana Los Angeles Rams · 70.0%]
con_dinero = 0
```

## La tensión que esto deja a la vista, y hay que decirla

**Pasó de 2 picks a 1.** Es menos, y es correcto — pero conviene entender por qué:

El lunes 21 hay **4 partidos** con análisis. Solo uno supera el piso editorial:

| partido | P_RETO | ¿pasa el piso de 58%? |
|---|---|---|
| LA Rams vs NY Giants | **70.0%** | **sí** |
| SF Giants vs Minnesota | 55.4% | no |
| Detroit vs Washington | 54.4% | no |
| Baltimore vs Toronto | 52.4% | no |

Los tres de MLB están entre 52% y 55%: prácticamente volados. El sistema se niega
a presentarlos como «lo mejor».

**Consecuencia que el dueño debe conocer: habrá días de un solo pick, y días de
cero.** El martes, cuando sea el día más próximo, mostrará 5. Esa variabilidad no
es un defecto: es lo que pasa cuando no se rellena el hueco con volados.

**Mi recomendación: dejar el piso en 58%.** Es exactamente la regla que separa una
app confiable de una ruidosa. Bajarlo es decisión del dueño, no mía, y tiene
costo medible en calidad.

## Rollback

```sql
-- quitar el filtro de un solo dia: eliminar el CTE dia_elegido y su condicion,
-- y devolver el ORDER BY a rank_global. La version anterior esta en el historial
-- de migraciones (antes de iss275).
```

Ninguna fila tocada. Solo la forma de la vista.
