# NFL — WEDNESDAY READINESS

**Semáforo: 🔴 RED como superficie de picks · 🟡 YELLOW como información de mercado etiquetada**

---

## 1. Hallazgo principal, probado aritméticamente

**`nfl_partidos.p_home` es la probabilidad implícita sin vig del moneyline de la casa. No contiene ningún componente de modelo.**

Demostración con una fila real de producción:

```
Minnesota Vikings vs Chicago Bears
  ml_home = -122   →  implícita = 122/222 = 0.549550
  ml_away = +102   →  implícita = 100/202 = 0.495050
  suma              = 1.044600
  vig registrado    = 0.0446          ← coincide exactamente
  no-vig p_home     = 0.549550/1.0446 = 0.526095
  p_home almacenado = 0.52609         ← coincide exactamente
```

Comprobación agregada: de 563 filas con probabilidad, **563 cumplen `p_home + p_away = 1`** (±0.001). Y `corr(p_home, -spread) = 0.9900` sobre n=562 — consistente con que ambas magnitudes salgan del mismo libro.

## 2. Cómo se propaga el error

`nfl_mejor_pick()` hace literalmente:

```sql
p_ml := g.p_home;
...
'El moneyline implica '||round(100*p_ml,1)||'% para '||g.home_team
```

La función **sabe** que es probabilidad de mercado — lo dice en su propio texto. Pero `nfl_picks_premium` la proyecta como:

```sql
round(100::numeric * b.ph, 1) AS prob
```

en una vista llamada **`nfl_picks_premium`**. Una columna llamada `prob` en una vista llamada "picks premium" se lee inevitablemente como predicción de la app.

## 3. Ambos lados del mismo Moneyline como picks separados

La vista construye dos ramas:

- rama home: `WHERE b.ph IS NOT NULL`
- rama away: `WHERE b.pa IS NOT NULL`

Como `p_home` y `p_away` siempre son ambos no nulos y suman 1, **cada partido genera dos filas "premium"**, una por lado. Confirma exactamente lo que el usuario describió. `PARTIDO ≠ PICK`, `MERCADO ≠ PICK`, `LADO ≠ PICK`.

## 4. Qué es realmente la "señal"

`nfl_mejor_pick` **no es un modelo**: es un **detector de incoherencia de línea**. Compara la probabilidad implícita del moneyline contra la implícita del spread (vía `normal_cdf(-spread/sd)`, con `sd_margen`≈12 y `umbral_brecha`≈3 desde `nfl_parametros`) y señala cuando difieren.

Eso es un señal de arbitraje interno del mercado, **legítima como concepto** pero:
- no es predicción propia,
- su umbral (3 pts) y su `sd` (12) son **constantes de configuración sin validación out-of-sample documentada**,
- no tiene medición de accuracy, Brier, ROI ni CLV.

## 5. Exposición

`nfl_picks_premium` (32 columnas) es **legible por `anon`** y corre como **OWNER** (sin `security_invoker`), por lo que no aplica RLS. No referencia `economic_eligibility_v1`, `v_pick_canonico`, `es_pick` ni `decision_pick_v1`: **está completamente fuera de la cadena de autoridad económica**.

## 6. Cobertura para el miércoles

| Métrica | Valor |
|---|---|
| Eventos `football` en agenda 72 h | 2 (2026-09-10 00:20Z, 2026-09-11 00:35Z) |
| Eventos `football` históricos en agenda | 272 (hasta 2027-01-10) |
| Filas `nfl_partidos` con probabilidad | 563 |
| Modelo propio NFL | **no existe** |

## 7. Estado declarado

```
NFL_MODEL_SKILL       = INSUFFICIENT (no hay modelo que evaluar)
NFL_ECONOMIC_AUTHORITY= FALSE
NFL_STAKE             = 0
NFL_P_PROVENANCE      = HOUSE_NO_VIG_IMPLIED  ← debe etiquetarse así
```

No construí un candidato NFL en shadow: hacerlo bien exige el trabajo de features + integridad temporal + holdout que no cabe sin comprometer las fases previas, y hacerlo mal es peor que no hacerlo.

## 8. Acción recomendada — prioridad alta antes del miércoles

1. **Renombrar/etiquetar**: la columna `prob` de `nfl_picks_premium` debe exponerse como `house_implied_prob_no_vig` o equivalente, con `LABEL = MARKET_INFORMATION_ONLY`. *(Cambio de contrato de vista: requiere el mismo cuidado ordinal que ISS-003/009 — columnas nuevas al final.)*
2. **Una card por partido**, con mercados internos. No una "pick card" por lado.
3. **Retirar la palabra "premium"** de una superficie que no pasa ningún gate económico.
4. A medio plazo: si se quiere señal propia NFL, empezar por medir el detector de incoherencia de línea (accuracy, ROI, CLV contra closing) antes de construir un modelo nuevo.

**No autorizar NFL económicamente.** No hay evidencia; no hay siquiera un modelo del que medir skill.
