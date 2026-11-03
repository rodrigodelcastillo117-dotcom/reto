# Totales: arnés de validación forward contra la LÍNEA REAL de casa

Fecha: 2026-11-03. Gatillo: "déjame la mejor app del mundo". La mejor app honesta no
inventa un mercado; lo gana con evidencia. Los totales (puntos/juegos/carreras) hoy son
informativos porque solo le ganaban a una línea estática/mediana (ver
`AUDITORIA_CIERRE_TOTALES_LINEA_ESTATICA_V1.md`). Para poder publicarlos como pick de
verdad hace falta demostrar, out-of-sample, que el modelo le gana a la **línea real de
casa** (la de cierre, la difícil). Antes de hoy NO había historial de línea real
calificable (solo 5 juegos MLB; 0 NBA/NHL) porque nadie **persistía** la línea pre-partido.

## Lo que se midió primero
- `reto_lineas_totales` solo guarda la línea ACTUAL de juegos próximos (se sobrescribe).
  Al terminar el juego, la línea se pierde → imposible calificar a posteriori.
- IDs de `reto_nba_agenda_v1` y `historico_partidos_espn` (basketball/nba) comparten
  espacio → la calificación por `espn_event_id` funciona a medida que absorbe resultados.
- Bug encontrado y corregido de paso: las etiquetas MÁS/MENOS de `v_reto_nba_totales_v1`
  estaban **invertidas** (modelo esperaba +8.7 sobre la línea y decía "MENOS anotador").
  Corregido: MÁS cuando el modelo espera más que la línea, MENOS cuando menos.

## Lo que se construyó (todo additivo, dinero OFF, no toca modelo ni gate)
1. **`public.reto_totales_forward_v1`** (tabla): congela el snapshot pre-partido por
   `espn_event_id` — `linea_real`, `total_esperado`, `diferencia`, `model_side` (MAS/MENOS),
   `captured_at`; y tras el juego `total_real`, `real_side`, `acierto` (1/0, null=push),
   `graded_at`.
2. **`public.reto_totales_forward_capturar_grade_v1()`** (función):
   - CAPTURA/REFRESCO: upsert de juegos NBA próximos con línea real + total del modelo;
     refresca mientras el juego sigue por jugar (se acerca a la **línea de cierre**),
     nunca toca filas ya calificadas.
   - CALIFICA: llena `total_real`/`real_side`/`acierto` contra el total final de
     `historico_partidos_espn`. Primera corrida: capturados=4, calificados=0 (aún por jugar).
3. **Cron `reto-totales-forward-v1`** (`9,29,49 * * * *`): corre justo después del ingreso
   de líneas (`lineas-totales-ingestar` 7,27,47) para fijar cierre y calificar pronto.
4. **`public.v_reto_totales_forward_resumen_v1`** (vista, solo lectura): n calificados,
   aciertos, acc_pct vs línea real, **límite inferior 95%** (Wald), pendientes, y el
   **gate pre-registrado**:
   - `MUESTRA_INSUFICIENTE` si n_decididos < 100,
   - `LE_GANA_A_LA_LINEA_95` si el IC95 inferior > 50% (tiene ventaja sobre el mercado),
   - `NO_LE_GANA_A_LA_LINEA` en otro caso.

## Regla de la casa (honesta)
No se publica ningún total como pick hasta que el gate diga `LE_GANA_A_LA_LINEA_95` **y**
haya sign-off. Mientras tanto, los totales siguen informativos. Si nunca le gana a la
línea real (lo más probable: por eso existen las casas), se quedan informativos para
siempre — y eso también es la mejor app del mundo: una que no te miente.

## Alcance
- NBA tiene modelo de totales + línea real ESPN → arnés activo.
- NHL: hay línea real ESPN pero no hay modelo de totales (O/U) construido → pendiente de
  modelo antes de sumarlo al arnés.
- MLB: línea real casi inexistente (5) y temporada terminada → no aplica aún.
- Cómo vigilarlo: `select * from public.v_reto_totales_forward_resumen_v1;`
