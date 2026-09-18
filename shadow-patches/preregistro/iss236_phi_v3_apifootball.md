# ISS236 — PREREGISTRO: `league_strength_hierarchical_v3`

P1-a: API-Football como fuente doméstica. Challenger nuevo, `model_version`
nuevo. **No modifica phi_v2 ni reutiliza su holdout, que ya se gastó.**

Escrito y comiteado ANTES de ajustar o medir nada del experimento.
Fecha: 2026-09-18.

---

## 0. AUDITORÍA DE PROVEEDOR — hecha antes de modelar, como pediste

### 0.1 Concordancia donde los dos proveedores se solapan
Cruce por `(team_espn_id, domestic_league_id, fecha)` entre
`v2.soccer_domestic_observation` (API-Football) y `public.historico_partidos_espn`
(ESPN). Tabla: `v2.iss235_proveedor`.

| | filas equipo-partido |
|---|---|
| en ambos proveedores | **5,705** |
| marcador idéntico | **5,702** |
| marcador distinto | **3** |
| sólo API-Football | 19,249 |
| sólo ESPN | 88,435 |

**Concordancia de marcador: 99.95%.** No hay discrepancia sistemática. Los 3
casos divergentes se listan y se excluyen del entrenamiento; no se "arreglan".

### 0.2 SESGO DE SELECCIÓN — la amenaza principal, y es total

Fracción de equipos cubiertos por API-Football que son participantes de
competencia continental, en las ligas antes bloqueadas:

| liga | lid | equipos cubiertos | continentales | % |
|---|---|---|---|---|
| Brasil Serie A | 71 | 15 | 15 | **100** |
| Argentina | 128 | 18 | 18 | **100** |
| Colombia Primera A | 239 | 11 | 11 | **100** |
| Ecuador Liga Pro | 242 | 12 | 12 | **100** |
| Perú | 281 | 11 | 11 | **100** |
| Uruguay | 268 | 9 | 9 | **100** |
| Japón J1 | 98 | 5 | 5 | **100** |
| Corea K1 | 292 | 3 | 3 | **100** |
| Arabia Pro League | 301 | 3 | 3 | **100** |

**Cero equipos no continentales en las nueve.** La muestra no es una muestra de
la liga: es su élite. Japón trae 5 de ~20 equipos; Corea 3 de ~12.

Consecuencia esperada y declarada **antes** de medir: θ de esas ligas saldrá
**sobreestimado**, porque la forma doméstica promedio de sus clubes de élite es
mejor que la de la liga. Ignorar esto produciría probabilidades sesgadas a favor
de los equipos sudamericanos y asiáticos en cruces continentales.

### 0.3 Cómo se cuantifica ese sesgo, no se supone
Experimento de calibración **sobre las 22 ligas ya servibles**, donde sí existe
cobertura completa:
1. estimar θ con TODOS sus equipos;
2. reestimar θ usando SÓLO sus participantes continentales;
3. medir `Δθ_sesgo = θ_solo_elite − θ_completo` por liga;
4. regresar `Δθ_sesgo` sobre la **fracción de liga cubierta**.

Esa regresión da la corrección a aplicar a las ligas con cobertura parcial. Si
`Δθ_sesgo` no resulta significativo (IC95 cruza cero), **no se aplica ninguna
corrección y las ligas con cobertura <60% quedan NO SERVIBLES**, motivo
`PHI_SELECTION_BIAS`. No se inventa una corrección que los datos no sostengan.

---

## 1. DATASET

- **Forma doméstica:** `v2.soccer_domestic_observation`, ventana 540 días, piso
  15 partidos, filtrada a la división punto-en-el-tiempo del equipo.
- **Puentes:** `public.historico_partidos_espn` para competencias multi-división
  (continentales y copas domésticas), con los mismos filtros de ISS224:
  sin amistosos, sin femenil, sin juvenil, **sin Sudamericana**.
- **Membresía:** `v2.phi2_membresia` extendida con la división observada en
  API-Football (`domestic_league_id` por temporada), misma regla de
  desambiguación: gana la división con más partidos; empate → menor tier.

### 1.1 Identidad, sin doble conteo
`canonical_event_id` = `espn_event_id` cuando existe; si un partido llega por
los dos proveedores, **ESPN manda** para el resultado y API-Football sólo aporta
forma. Clave de deduplicación: `(canonical_event_id)`. Un equipo-fecha-liga no
puede contribuir dos veces. Se registra `provider` y `provider_event_id` en cada
fila del dataset.

### 1.2 Puentes esperados (ya medidos, no proyectados)

| familia | puentes | pares | ligas |
|---|---|---|---|
| **LIBERTADORES** | **156** | 15 | 12 |
| UEFA | 57 | 34 | 29 |
| **AFC** | **32** | 10 | 16 |
| copa doméstica / otro | 17 | 9 | 18 |

Contra phi_v2: Libertadores 0, AFC 0.

---

## 2. CORTE TEMPORAL Y HOLDOUT NUEVO

- Desarrollo: fecha ≤ **2026-03-31**
- **Holdout sellado NUEVO:** fecha > **2026-03-31**

Corte distinto al de phi_v2 (2026-01-31) a propósito: el holdout de v2 ya se
abrió y no puede reutilizarse ni parcialmente. Se sella el hash antes de
ajustar. **Una sola apertura.**

`dataset_hash` = md5 del conjunto ordenado `(canonical_event_id, marcador)`.
`code_hash` = hash del commit de este preregistro más el de la función de ajuste.
Los dos se registran antes de la primera corrida.

---

## 3. MODELO

Igual forma funcional que v1/v2, con `a0, batt, bdef, home_adv, rho` congelados
del registro sellado. Jerarquía:

```
θ_L = μ_país(L) + δ_tier(L) + u_L      u_L ~ N(0, τ²)
```

Candidatos preregistrados, todos medidos en validación walk-forward, nunca en
el holdout:
- **v3a** — jerarquía con forma de API-Football (primaria)
- **v3b** — v3a + puente por ascenso/descenso (93 equipos que cambiaron división)
- **v3c** — v3a + corrección de sesgo de selección de §0.3

Regla de selección: gana la variante que baje el log loss de validación en
≥0.005 sobre v3a; empate → v3a por parsimonia.

**El sesgo de empate de Dixon-Coles NO entra aquí.** Es un experimento separado,
con su propio preregistro, su propia hipótesis y su propio holdout, como pediste.

## 4. HIPERPARÁMETROS

`τ ∈ {0.10, 0.20, 0.35, 0.50}` · `τ_c ∈ {0.15, 0.30}` · `H ∈ {365, 540, 730, 1095}`
32 combinaciones. Rejilla determinista, fijada aquí.

Se amplía respecto de v2 en los dos extremos **porque v2 ganó en el borde de la
rejilla** (τ=0.35, H=730), no porque haya mirado ningún resultado nuevo.
**No se amplía otra vez después de medir.**

## 5. SERVIBILIDAD

Una liga es servible sólo si cumple **las tres**:
- semiancho del intervalo de perfil 95% ≤ **0.25** en log-goles;
- **≥1 puente directo** en desarrollo (cero puentes ⇒ `PHI_NO_BRIDGE`);
- **cobertura de equipos ≥ 60%** de la liga, o corrección de sesgo validada
  en §0.3 (si no, `PHI_SELECTION_BIAS`).

La tercera es nueva y es la que impide que Corea entre con 3 equipos de 12.

## 6. MÉTRICAS

Brier 1X2, log loss, ECE + fiabilidad por deciles, cobertura, error por liga,
error por tramo de puentes, IC95 por bootstrap pareado (10,000 réplicas,
semilla 236), estabilidad por trimestre, incertidumbre de θ.

**Desglose obligatorio por competencia**: Libertadores · AFC · UEFA · CONCACAF ·
copas domésticas · cruces entre tiers · las 22 ligas ya servibles.
**Y por proveedor**: puentes cuya forma vino de ESPN vs de API-Football.

## 7. CRITERIO DE PROMOCIÓN

Sobre el holdout sellado, todos:
- **PC1** Brier(v3) < Brier(θ=0), IC95 de la diferencia estrictamente < 0.
- **PC2** log loss(v3) < log loss(θ=0).
- **PC3** En las 22 ligas ya servibles: Brier(v3) ≤ Brier(v1) + 0.005.
  *No degradar donde ya funciona.*
- **PC4** ECE(v3) ≤ 0.05.
- **PC5** ligas servibles(v3) > 23.
- **PC6** Libertadores y AFC con n ≥ 30 evaluables cada una **y** ΔBrier < 0
  en ambas por separado. Aumentar cobertura sin mejorar esas dos no cuenta.

**PC5 y PC6 sin PC1–PC4 no promueven.** No se promueve por cobertura.

## 8. CRITERIO DE ABORTO

- falla cualquiera de PC1–PC4;
- el conjunto servible incluye una liga con cero puentes o con cobertura <60%
  sin corrección validada;
- holdout evaluable < 100;
- aparece un `canonical_event_id` duplicado entre proveedores;
- el ajuste no converge en 200 pasadas;
- dos corridas desde git difieren en θ más de 1e-6.

## 9. RUTA

shadow → backtest → prospectivo → canary informativo → autorización del dueño →
integración al cerebro único `soccer_canonical_v2` como **módulo interno**.
Un solo cerebro. Un solo publicador. Sin segunda P_RETO. Sin escritura en
superficie productiva. Almacenamiento shadow aislado, sin `anon` ni
`authenticated`. `RETADOR_DECLARADO` con fecha de evaluación y criterio de retiro.

## 10. HIPÓTESIS PRIMARIA, UNA SOLA

> Usando API-Football como fuente de forma doméstica, la estimación jerárquica
> de fuerza de liga produce probabilidades mejores que el baseline sin
> corrección **en Libertadores y AFC**, sin degradar las 22 ligas que ya se
> sirven, y con el sesgo de selección de la cobertura parcial medido y acotado.

Una corrida. Un holdout. Un veredicto. Sin reinterpretar después de medir.

## 11. LO QUE ESTE EXPERIMENTO NO RESUELVE

P1-b sigue abierto y es otro objetivo: dar picks de un **Brasil-Brasil** o
**Corea-Corea** exige cobertura doméstica completa, que API-Football no tiene.
**Chile no aparece en el censo: ésa sí es ingesta faltante real.**
