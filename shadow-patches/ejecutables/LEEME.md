# shadow-patches/ejecutables/

SQL **ejecutable**, no prosa.

## Por qué existe esta carpeta

El auditor levantó un NO-PASS (comentario `5639091011`) con este blocker, y
tenía razón:

> el commit `aae30a79...` contiene un archivo `iss084` que es sólo
> documentación/comentarios, no el SQL ejecutable que modificó producción. Eso
> significa que ahora mismo la calibración viva no es reproducible desde Git.

`shadow-patches/prepared/iss082`, `iss083` e `iss084` son prosa. Documentan lo
que se hizo pero **no lo reconstruyen**. Los cambios se aplicaron con comandos
sueltos por MCP.

De aquí en adelante: todo cambio a producción se escribe primero en un archivo
de esta carpeta y se ejecuta **desde** el archivo, para que Git y la base
coincidan por construcción.

## Deuda pendiente

Falta volver a capturar como SQL ejecutable lo que ya está vivo en la base y
sólo existe como prosa en `prepared/`:

- `iss082` — auditoría del candado del dueño (24 objetos: `v_pick_canonico`,
  `v_mejor_pick_por_partido`, `picks_premium`, `parlay_del_dia_v3`,
  `refrescar_destacados`, `rongol_seleccionar_dia`, `tg_filtrar_pick_del_dia`,
  `favoritos_bien_pagados`, `generar_parlay_seguro`, etc.)
- `iss083` — `zonas_confiables.deporte`, `zona_realidad/3`
- `iss084` — `modelo_backtest.deporte`, backtests de MLB/NFL,
  `dispersion_totales`, `prob_total_sobre`, `normal_cdf`, parche a `motor_mlb`

Hasta que eso exista, **una pérdida de la base no se puede reconstruir**.
