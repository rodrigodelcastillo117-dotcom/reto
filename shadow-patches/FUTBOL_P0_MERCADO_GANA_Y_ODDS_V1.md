# Fútbol P0: el mercado le gana al modelo (validado) → anclar a mercado + line shopping

Fecha: 2026-11-08. Gatillo: "modelo de fútbol P0" + "Todoooo". Autopsia honesta del modelo de fútbol.

## Hallazgo validado (lo más importante)
Diagnóstico por liga sobre `evidencia_modelo_forward` (modelo vs mercado de-vig, OOS):
- El modelo está **bien calibrado** pero el **mercado está mejor** en casi todas las ligas.
- Única liga donde el modelo "gana": Scottish Premiership (+0.0087, n=43) — ruido, no explotable.
- Peores: Grecia −0.060, Saudi −0.040, LaLiga −0.033, Champions −0.032, Premier −0.031.
- Los sesgos por liga son **mixtos** (a veces sobre, a veces bajo) y dentro del ruido → **no hay un bug que arreglar**.

### Blend por liga, VALIDADO OOS (w* cerrado en train, evaluado en test)
- En casi todas las ligas **w*=0** → el blend simplemente usa el mercado; mejora sobre mercado = **0.0000**.
- Donde train sugirió w>0 (Bundesliga 0.76, Danish 0.86), el **test lo castigó** (−0.03, −0.04) = sobreajuste.
- **Veredicto: la probabilidad del MERCADO es la mejor que podemos publicar en fútbol.** Brier mercado
  ~0.20 vs modelo ~0.24 — mejora real y honesta. El modelo no agrega valor sobre el mercado.

Esto redefine "mejorar fútbol P0": no es tocar el modelo (no sirve), es **publicar la prob del mercado**
y sacar el edge del **mejor precio** (line shopping). Cuando no le ganas al mercado, te unes a él.

## Construido
- **Momios de fútbol en vivo** vía The Odds API: el ingester `ingestar-odds-multicasa` ya acepta
  `{sports, regions}`. Prueba (EPL/LaLiga/UCL, region eu): 622 momios, **1 crédito por liga** (barato).
- **Cron `ingestar-odds-soccer-am`** (50 12 * * * = 6:50am CDMX): 8 ligas principales, region eu.
  Costo ~8 créditos/día + 3 de US = ~11/día ≈ 330/mes (cabe en el tier gratis de 500; el mes en curso
  ya iba por 143 restantes, así que puede quedar corto este mes — resetea mensual).
- **Vista `v_reto_soccer_mercado_v1`**: de-vig 3-way (local/empate/visita) + mejor precio por lado.
  NOTA: la reconstrucción que agrega la **casa** del mejor precio **se quedó colgada (timeout)** — hay
  que confirmar su estado y, si quedó a medias, recrearla (la versión sin casa sí quedó).

## Pendiente (siguiente paso, con cuidado)
- **Anclar la prob publicada de fútbol (ML) al mercado** en el email, con emparejado de nombres
  normalizado (acentos/alias OddsAPI vs nuestros) y **fallback seguro** (si no machea con confianza →
  se queda la prob del modelo, nunca peor que hoy). BTTS se queda en modelo (no hay mercado BTTS).
- Añadir fútbol a `v_reto_pick_precio_v1` (mejor precio por pick de fútbol).
- Opcional: medir CLV de fútbol contra el mejor precio de cierre.
