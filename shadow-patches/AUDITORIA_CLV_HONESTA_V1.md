# Auditoría CLV honesta — ¿el sistema le gana al mercado? (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. Fecha 2026-10-20. Dinero OFF.

## Hallazgo central

El sistema **NO demuestra edge contra la línea de cierre real.** Está en break-even a
ligeramente negativo. El `clv_dashboard` decía *"EDGE REAL — Sistema encuentra valor
genuino"*; eso era falso y se corrigió.

Datos: `oraculo_picks_tracking`, 1,071 picks con CLV, 2026-07-15 → 2026-09-12.

| Métrica (global) | Valor | Lectura |
|---|---|---|
| CLV promedio | +3.66% | Engañoso: lo inflan outliers |
| **CLV mediano** | **0.00%** | El pick típico no le gana al cierre |
| **% que gana al cierre** | **43.1%** | <50% = el mercado gana |
| Distribución | 43% positivo / 44% negativo / 13% cero | Moneda |
| CLV mediano (solo con movimiento) | −0.47% | Negativo |

### Por mercado (muestra seria)

| Deporte/Mercado | n | CLV medio | CLV mediano | Gana al cierre | Veredicto |
|---|--:|--:|--:|--:|---|
| MLB Over/Under | 242 | −2.32% | 0.00 | **33.9%** | EDGE NEGATIVO |
| MLB Moneyline | 275 | −4.68% | 0.00 | 49.1% | Sin edge (moneda) |
| Soccer Over/Under | 277 | +10.65% | 0.00 | **39.7%** | EDGE NEGATIVO |
| Soccer Moneyline | 161 | +9.13% | 0.00 | 48.4% | Sin edge (moneda) |
| Soccer BTTS | 42 | +21.0% | +13.7 | 61.9% | Prometedor pero muestra insuficiente |

**El +11% de CLV en Soccer es 100% sesgo de outliers** (mediana 0, gana al cierre 39-48%).
Unos pocos "robos" de líneas rancias inflan el promedio; no es edge repetible.

**MLB O/U**: el modelo marca 61% de acierto vs mediana en `reto_modelo_validacion_v1`
pero gana al cierre solo **33.9%**. Es el caso de libro de *acertarle a una mediana
estática ≠ ganarle al mercado*. Está publicándose un mercado que el mercado real gana.

## Qué se cambió (honestidad, aditivo, sin tocar dinero)

1. **`clv_dashboard`** reescrito: el veredicto ahora se basa en **mediana de CLV + % que
   gana al cierre**, no en el promedio global. Mismas 6 columnas. Hoy devuelve
   *"EDGE NEGATIVO — el mercado le gana al sistema"*.
2. **`v_reto_clv_veredicto_sistema_v1`** (nueva): veredicto a nivel sistema por deporte y
   por deporte×mercado, con mediana, beat-rate y `sesgo_outliers` (media − mediana).
3. **`v_reto_realidad_vs_mercado_v1`** (nueva): junta el accuracy-vs-mediana declarado con
   el CLV real por deporte → diagnostico CONSISTENTE / ENGAÑOSO / CONTRADICTORIO / SIN
   MEDICION.

## Recomendaciones (decisión del dueño, NO ejecutadas)

- **Despublicar lo que pierde al cierre con muestra seria:** MLB O/U (33.9%) y Soccer O/U
  (39.7%). Mismo principio con que se apagó NHL O/U por backtest, pero con la vara real.
- **No ampliar mercados** hasta que el que exista pruebe CLV>0 con beat-rate >~53%.
- **Investigar Soccer BTTS** (único con señal: 61.9% beat, +13.7 mediano) con más muestra
  antes de confiar.
- **Medir CLV de tenis** (hoy `SIN MEDICION`): el tenis O/U publicado esta sesión está
  validado solo contra mediana; su edge de mercado es desconocido.
- **Cambiar la vara de validación** de accuracy-vs-mediana a CLV real en
  `reto_modelo_validacion_v1`.

## La verdad incómoda

Ninguna app de picks que "acierta 60-67%" vale nada si pierde contra el cierre. La métrica
que importa es CLV, y hoy este sistema no la supera. El valor de esta auditoría no es
alegre: es que ahora el dashboard dice la verdad en vez de felicitarse solo.
