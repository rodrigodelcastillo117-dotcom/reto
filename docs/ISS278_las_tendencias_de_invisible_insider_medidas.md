# ISS278 — Las tendencias de @invisiblestats, medidas en vez de discutidas

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

El dueño mandó el hilo y dijo: *"HAY QUE PENSAR COMO EL, VER DE DONDE SACA LA
INFO, DE DONDE SACA TODO."* No lo discutí. Lo medí.

---

## 1. Primero, lo que hay que decir aunque no convenga

**Sus dos jugadas del domingo por la noche ganaron las dos.**

| jugada | resultado |
|---|---|
| Colts +6.5 (-120) | Colts 30, Chiefs 33. Perdieron por 3. **Cubrió.** |
| Over 46 (-110) | 33 + 30 = **63**. **Acertó.** |

**2-0.** Con nuestra línea de cierre (-6) también cubría. Dos jugadas no
demuestran nada — un volado da 2-0 una de cada cuatro veces — pero se reporta
igual, y primero.

Y otra a su favor: **en semana 2 de 2026, la única semana verdaderamente fuera de
su muestra, sus road dogs +3/+7.5 fueron 3-3.** No 63%. Tampoco un desastre.

---

## 2. La aritmética de cada afirmación

`z` mide a cuántas desviaciones típicas está el récord de un volado.

| afirmación | récord | n | z |
|---|---|---|---|
| Misma casilla en semana 2 | 7-0 | 7 | **2.65** |
| Road dogs +3/+7.5 semana 2 | 15-4 | 19 | **2.52** |
| Team totals visitante 0-1 | 16-6 | 22 | **2.13** |
| Visitante perdió S1 → S2 over | 19-9 | 28 | **1.89** |
| Home favs 5.5-7.5 semana 2 | 1-6 | 7 | −1.89 |
| Perdió por 14+ → over | 7-2 | 9 | 1.67 |
| Local viene de ganar por 14+ → overs | 77-58 | 135 | 1.64 |
| Totales entre 45.5 y 47.5 | 107-87 | 194 | 1.44 |
| **Road dogs +3/+7.5 tras perder por 7+** | **54-42** | **96** | **1.23** |

**El más alto es 2.65.** Ninguno llega a 3.

### Por qué 2.65 no basta

El espacio de filtros es: 18 semanas × local/visitante × favorito/perdedor ×
~6 rangos de línea × viene-de-ganar/perder × ~4 umbrales de margen × ~6 mercados
≈ **31,000 combinaciones**.

Con ese espacio, el umbral de Bonferroni al 5% es **z = 4.809**
(`v2.fn_z_critico_bonferroni(31000)`, implementado y probado). Con 31,000
pruebas al 5%, el azar puro regala **~1,550 "tendencias significativas"**.

**Ninguna de las nueve se acerca a 4.809.**

---

## 3. El hallazgo: la ventaja se desvanece cuando crece la muestra

Si un efecto es real, **z crece con √n**. Aquí pasa lo contrario:

| filtro | fuente | récord | n | % | z |
|---|---|---|---|---|---|
| Misma casilla, semana 2 | él | 7-0 | 7 | 100.0 | **2.65** |
| Road dogs +3/+7.5 semana 2 | él | 15-4 | 19 | 78.9 | **2.52** |
| Road dogs +3/+7.5 tras perder 7+ | él | 54-42 | 96 | 56.3 | **1.23** |
| Road dogs +3/+7.5, todas las semanas | nosotros | 56-47 | 103 | 54.4 | **0.89** |
| Todos los road dogs, cualquier línea | nosotros | 94-88 | 182 | 51.6 | **0.45** |

**Monótono. A más partidos, menos ventaja y menos z.** Es la firma de libro de
un patrón seleccionado sobre ruido: el filtro estrecho se ve espectacular porque
se eligió *después* de ver los resultados, y se derrite al ampliarlo.

### Y la resta que lo remata

Medimos su mejor filtro (road dogs +3/+7.5 tras perder por 7+) en nuestra base:

```
2025 solo:  20-6  (76.9%)  n=26
2026 solo:   1-0            n=1
```

Él afirma **54-42 sobre 2022-25**, o sea ~24 partidos por temporada — consistente
con nuestros 26 de 2025. Restando:

> **2022-2024 ≈ 34-36. Un 48.6%. POR DEBAJO DE VOLADO.**

**Toda la ventaja de cuatro años la carga una sola temporada.** Y lo único
verdaderamente fuera de su muestra —2026— tiene **n=1**.

*(La resta es aproximada: nuestro spread viene de ESPN y el suyo puede diferir,
y nuestra regla de "partido anterior" no cruza temporadas. No la presento como
exacta, sino como orden de magnitud.)*

---

## 4. De dónde saca la información

1. **Un archivo histórico de líneas** (spreads, totales, 1H, team totals). Se
   compra o se raspa. No es exótico ni privilegiado.
2. **Su propia app.** Lo dice él: *"if you want to find trends like this for
   yourself, checkout the Betting Insider app"*.

Ahí está todo. **Su producto ES un minero de tendencias**: corta el histórico por
filtros hasta que aparece un porcentaje alto. No es una fuente de datos: es
precisamente la máquina que fabrica los falsos positivos de la sección 2,
vendida como herramienta.

Un detalle que lo cierra: esos posts tienen **8,700 a 83,700 visualizaciones**.
Cualquier ventaja real contra la línea muere al publicarse a esa escala.

---

## 5. Qué podemos y qué NO podemos verificar

Medido, no supuesto:

| afirmación | ¿verificable en RETO? |
|---|---|
| Road dogs / home favs ATS | **SÍ** — `nfl_partidos` tiene spread, marcador, semana |
| Totales de partido completo | **SÍ, datos presentes** — falta escribir el evaluador |
| **Overs de primera mitad** | **NO. No existe marcador de 1H en ninguna tabla.** |
| **Team totals** | **NO. No existe línea de team total en ninguna tabla.** |

Las dos últimas quedan registradas como **INVERIFICABLES**, con el motivo
escrito. No se rellenan para que la tabla se vea completa.

### Y un límite mayor

`nfl_partidos` solo tiene **2025 y 2026**. No hay líneas de 2022-2024.
**No podemos reproducir un "desde 2022".** Lo que sí verifiqué es que el spread
post-hoc de 2025 es fiable: contra las capturas pre-saque de 2026, **24 de 30
idénticos, diferencia media 0.183, máxima 1.0**. Es la línea de cierre, no un
invento posterior.

---

## 6. Lo que se construyó

En vez de discutir el hilo, se convirtió en algo falsable.

| objeto | qué hace |
|---|---|
| `v2.hipotesis_externa` | registra la afirmación, su autor, su récord, y el filtro en **parámetros declarativos** (no SQL guardado: sin superficie de inyección) |
| `v2.hipotesis_externa_evaluacion` | calificaciones append-only |
| `v2.fn_evaluar_hipotesis_nfl_ats` | evaluador fijo y auditable |
| `v2.fn_z_critico_bonferroni` | el umbral corregido, **calculado**, no comentado |

La columna que importa es **`ventana`**, con tres valores:

- `PERIODO_AFIRMADO` — el periodo que él citó. **Contaminado por su propia
  minería. No es evidencia.**
- `TODO_LO_QUE_TENEMOS` — contexto.
- **`DESDE_REGISTRO`** — partidos posteriores a que lo registráramos.
  **La única ventana que constituye evidencia.** Hoy vale **cero**, y así debe
  verse: la evidencia limpia empieza hoy.

Las 8 afirmaciones quedaron registradas (4 evaluables, 4 con su motivo de no
serlo). Cada semana se recalifican solas. Si algo es real, sobrevive. Si es
ruido minado, revierte a 50% y queda escrito que revirtió.

**Esta superficie no alimenta ningún pick.** Todo revocado a `anon`,
`authenticated` y `public`. Es un marcador de afirmaciones ajenas, no una señal.

---

## 7. El veredicto honesto

No es un estafador: publica jugadas con hora, y las dos de anoche ganaron.

Pero lo que vende como ventaja demostrada son **filtros elegidos después de ver
el resultado**, en un espacio de ~31,000 combinaciones, con z máxima de 2.65
cuando el umbral honesto es 4.81, y con una ventaja que **se desvanece
monótonamente conforme crece la muestra** — incluida la resta de sus propios
números, que deja 2022-2024 por debajo de volado.

**No hay nada aquí que copiarle al modelo.** Lo que sí vale la pena es la
disciplina inversa: registrar lo que afirma y dejar que se califique solo.

## Rollback

```sql
drop function if exists v2.fn_evaluar_hipotesis_nfl_ats(bigint);
drop function if exists v2.fn_z_critico_bonferroni(integer,numeric);
drop table if exists v2.hipotesis_externa_evaluacion;
drop table if exists v2.hipotesis_externa;
```

No toca datos, ni modelos, ni el gate, ni un solo pick.
