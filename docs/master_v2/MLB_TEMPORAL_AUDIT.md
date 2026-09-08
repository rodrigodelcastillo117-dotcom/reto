# MLB — AUDITORÍA DE INTEGRIDAD TEMPORAL

**Método:** escaneo de las definiciones vivas (`pg_get_functiondef`/`pg_get_viewdef`) replicadas en laboratorio fiel, buscando `ORDER BY … DESC LIMIT 1`, `MAX(timestamp)` y ausencia de cota `<= as_of`. Sin tocar producción.

**Conclusión en una línea:** el motor MLB **tiene un candado temporal real y bien hecho para las features**, pero **selecciona la fila de caché y la de odds por "más reciente" sin cota**, lo que es correcto hacia delante y **leaky en evaluación retrospectiva**.

---

## 1. Lo que está bien hecho — y conviene decirlo

`predecir_mlb` implementa un candado temporal explícito (comentado en el código como `candado_temporal_fase15`):

```sql
v_as_of := m.game_date;
...
liga_rpg := COALESCE(public.mlb_liga_rpg_hasta(v_as_of), 4.40);
SELECT * INTO ft_h FROM public.mlb_forma_hasta(m.home_team, v_as_of);
SELECT * INTO ft_a FROM public.mlb_forma_hasta(m.away_team, v_as_of);
```

Y la calibración se busca con doble cota:

```sql
where c.effective_from <= v_as_of
  and coalesce(c.data_cutoff_at, c.effective_from) < v_as_of
order by coalesce(c.data_cutoff_at, c.effective_from) desc, c.id desc limit 1
```

Eso es integridad temporal correcta: la forma, el RPG de liga y la calibración se leen **hasta** la fecha del partido, no "lo último que haya". El comentario del propio código dice que antes la fecha de referencia se leía en siete sitios distintos y se unificó. Es trabajo bien hecho.

## 2. Clasificación por feature

| Feature / entrada | Fuente | Cota temporal | Estado |
|---|---|---|---|
| Forma de equipo | `mlb_forma_hasta(team, v_as_of)` | `<= v_as_of` | **SAFE** |
| RPG de liga | `mlb_liga_rpg_hasta(v_as_of)` | `<= v_as_of` | **SAFE** |
| Calibración | `effective_from <= v_as_of` **y** `data_cutoff_at < v_as_of` | doble cota | **SAFE** |
| Fecha de referencia | `v_as_of := m.game_date` | derivada del evento | **SAFE** |
| **Fila de `mlb_stats_cache`** | `ORDER BY cached_at DESC LIMIT 1` | **ninguna** | **CONDITIONAL_LEAK** |
| **Fila de `v_momios_confiables`** | `ORDER BY snapshot_at DESC LIMIT 1` | **ninguna** | **CONDITIONAL_LEAK** |
| Pitcher abridor: timestamp de confirmación | no localizado | — | **UNKNOWN** |
| Lineup timestamp | no localizado | — | **UNKNOWN** |
| Bullpen | no localizado como feature del motor | — | **NOT_USED** |
| Lesiones MLB | no localizado como feature del motor | — | **NOT_USED** |
| Marcador probable (`motor_mlb`) | `order by pr desc limit 1` | n/a | **SAFE** (falso positivo del escaneo: ordena por probabilidad, no por tiempo) |

## 3. Los dos CONDITIONAL_LEAK, explicados con precisión

```sql
-- (1) selección de la fila de estadísticas
SELECT * INTO m FROM mlb_stats_cache
 WHERE espn_event_id = p_espn_event_id AND fetch_success
 ORDER BY cached_at DESC LIMIT 1;

-- (2) selección de la fila de odds
SELECT * INTO v_odds FROM v_momios_confiables o
 WHERE o.espn_event_id = p_espn_event_id
 ORDER BY o.snapshot_at DESC LIMIT 1;
```

**Hacia delante (uso en vivo): correcto.** Al predecir un partido futuro, "lo más reciente" *es* lo disponible en el momento de decidir. No hay leakage.

**Hacia atrás (backtest / medición histórica): leaky.** Al re-evaluar un partido pasado, ambas consultas devolverán la fila más reciente que exista *hoy*, que puede haberse escrito **después del inicio del partido**. En el caso de las odds esto es exactamente lo prohibido: evaluar un pick con una cuota que no existía cuando se emitió.

**Consecuencia práctica:** cualquier métrica histórica calculada llamando a `predecir_mlb` sobre partidos pasados está contaminada por construcción. Eso incluye cualquier intento de demostrar skill MLB re-corriendo el motor sobre el histórico. **No invalida las predicciones en vivo.**

Esta distinción importa: no es "el motor tiene leakage", es "el motor es seguro hacia delante y no es utilizable para backtest sin una variante as-of".

## 4. Corrección propuesta — NO implementada

La corrección correcta **no** es cambiar `predecir_mlb`: eso alteraría el comportamiento en vivo de un motor en producción para arreglar un problema que solo existe en backtest. La corrección es **añadir un parámetro opcional de as-of** que, cuando se pasa, acota ambas consultas:

```sql
-- predecir_mlb(p_espn_event_id text, p_as_of timestamptz DEFAULT NULL)
... WHERE espn_event_id = p_espn_event_id AND fetch_success
      AND (p_as_of IS NULL OR cached_at <= p_as_of)
    ORDER BY cached_at DESC LIMIT 1;
```

Con `p_as_of IS NULL` el comportamiento en vivo queda **byte-idéntico**; con `p_as_of` fijado se obtiene una evaluación honesta. Es aditivo y no rompe firmas existentes… salvo que `CREATE OR REPLACE FUNCTION` con parámetro nuevo con DEFAULT **crea una sobrecarga**, y `analisis_completo` tiene un guard de `overload_count = 1`. Habría que verificar el guard equivalente para `predecir_mlb` antes de aplicarlo.

**No lo implementé** porque: (a) toca un motor en producción y el deploy está prohibido; (b) exige medir antes el impacto, como pide la instrucción ("no cambies modelos para arreglar leakage, primero mide impacto"); (c) el guard de sobrecarga necesita revisión previa.

## 5. Test adversarial diseñado — NOT_RUN

```
Objetivo: demostrar el CONDITIONAL_LEAK de forma reproducible.
Procedimiento:
  1. Elegir un partido pasado P con al menos dos filas en mlb_stats_cache,
     una con cached_at < inicio(P) y otra con cached_at > inicio(P).
  2. Ejecutar predecir_mlb(P) tal cual  -> registrar probabilidad Pr_now.
  3. Ejecutar la variante as-of con p_as_of = inicio(P) -> Pr_asof.
  4. Si Pr_now <> Pr_asof, el leak está demostrado y cuantificado.
  5. Repetir sobre N partidos y reportar la distribución de |Pr_now - Pr_asof|.
Estado: NOT_RUN — coverage_status = BLOCKED.
Bloqueo: el laboratorio se construyó con `pg_dump --schema-only` (sin datos, por
política de no usar datos sensibles de producción), así que no hay filas de
mlb_stats_cache sobre las que ejecutarlo. Ejecutarlo contra producción sería
read-only y viable, pero requiere una ventana de cómputo no trivial y un GO.
```

## 6. Estado

```
MLB_TEMPORAL_INTEGRITY_FORWARD    = SAFE (features con cota as-of verificada)
MLB_TEMPORAL_INTEGRITY_BACKTEST   = CONDITIONAL_LEAK (caché y odds sin cota)
MLB_LEAK_IMPACT_MEASURED          = NO  (test diseñado, NOT_RUN, BLOCKED por datos)
MLB_MODEL_CHANGED                 = NO
```

**Ninguna métrica histórica de MLB debe presentarse como evidencia de skill hasta ejecutar el test de §5 y, si procede, la variante as-of.**
