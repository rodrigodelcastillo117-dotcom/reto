# Auditoría RETO 13M — informe consolidado
_Fecha: 2026-10-13 · Proyecto Supabase prod `wpiztubmmmzclhlprgpd` · Autor: Claude (backend)_

Alcance: backend, datos, feeds, jobs, modelos/gates y seguridad. **No incluye el frontend (Lovable)**: no puedo verlo ni tocarlo, así que "botones muertos" o fallas de UI quedan fuera de mi alcance — audité el backend/datos que esos botones consumen.

---

## 1. Lo que ARREGLÉ (verificado)

| # | Problema | Causa raíz | Estado |
|---|---|---|---|
| 1 | **FUT PRO caído** (Champions/Europa `MODEL_UNAVAILABLE`) | Snapshot cross-league desincronizado (seal 24 vs 25 ligas) tras extensión de phi | ✅ re-seal + **auto-sanación** (cron 557 `crossleague-reseal-drift`) para que no recurra |
| 2 | **Escudos soccer equivocados** (Atlético con escudo ajeno, etc.) | Cadena de vistas con fallback venenoso (`ligamx_equipos` slug 'madrid'→id erróneo) | ✅ resolución por id nativo de ESPN en `escudos_evento` y `v_futpro_v2`; 245/245 correctos. MLB/NFL/NBA/NHL ya estaban bien. |
| 3 | **MLB "HOME/AWAY"** en vez del nombre del equipo | Literales en `get_mlb_enrichment` | ✅ usa `home_team/away_team` reales |
| 4 | **NFL con datos de hace un mes** (data_asof congelado Sep-15) | ESPN **dejó de aceptar su API de rango** `dates=YYYYMMDD-YYYYMMDD` (→400) ~Sep-15; el encolador de `team_history_event` murió y **no tenía cron** | ✅ encoladores reescritos a formato por-día (200), **backfill** (63 juegos NFL), modelo reconstruido, **crons de durabilidad** (559/560). NFL `data_asof` ahora = hoy, 28 picks READY. También catch-up NBA/NHL. |
| 5 | **Job 366** (motor-cache diario) fallaba a diario por timeout | Llamaba sin límite de lote | ✅ lote de 20 |

---

## 2. Lo que está "vacío" PERO es INTENCIONAL (gates, no bugs)
Las pantallas no-soccer salen vacías/limitadas por los gates inmutables **P0=SOCCER** y **RELEASE_GATE=HOLD**, codificados en el sistema de release-authority (basado en validación científica real):

- **Global / Top y Parlay = solo soccer**: NFL/MLB no alcanzan `display_class='OFFICIAL_P_RETO'`. Gate P0=SOCCER.
- **money / EV / Kelly = apagado en todo**: `money_authorized` está **hard-codeado en false** en todas las vistas de autoridad (postura "probabilidades, no dinero"). Encenderlo es decisión de release del auditor, no un bug.
- **NFL** publica sin money (validado: Brier 0.230 < 0.25, 143 OOS). El modelo fresco ahora tiene datos actuales (fix #4).

---

## 3. MLB money — **NO liberable hoy** (con evidencia)
El modelo MLB (`C0-prod-2026-09`) tiene skill agregado pero **está mal calibrado**:

| Criterio | Umbral | MLB hoy | ¿Pasa? |
|---|---|---|---|
| Muestra OOS | ≥ 120 | 117 | ❌ (por 3) |
| Brier | < 0.25 | 0.239 | ✅ |
| LogLoss | < 0.693 | 0.670 | ✅ |
| Gap calibración | ≤ 5 pp | **10.0 pp** (bucket 0.40: dice 46%, gana 36%) | ❌ |
| Buckets soportados | ≥ 3 | 2 | ❌ |

Encender money = apostar dinero real sobre probabilidades erradas por 10 puntos → los usuarios pierden. **Se mantiene gateado (correcto).** Ruta legítima: **recalibrar** el modelo (no solo acumular juegos) hasta gap ≤5pp en ≥3 buckets.

### Bug encontrado en el propio gate (staged, requiere auditor)
`v_mlb_canonical_release_authority_v1` saca el kickoff con `JOIN agenda_espn`, que **purga juegos pasados** → la muestra calificada (116 capturas) se evapora y reporta `n=0` / "muestra insuficiente", **ocultando la razón real** (mala calibración). Fix preparado en `shadow-patches/prepared/iss_mlb_authority_kickoff_source_fix.sql` (cambia la fuente del kickoff a `historico_partidos_espn`, permanente). **No cambia el resultado** (MLB sigue gateado) ni ningún umbral; solo hace honesto el reporte. **No aplicado**: toca el gate de dinero → revisión del auditor.

---

## 4. Jobs backend — sanos salvo lo anotado
De ~250 jobs, los únicos con fallas: **366** (arreglado), **515** `global-candidate` matview (timeout transitorio ~11%, la vista source es muy pesada → la pantalla Global se estanca a ratos; mitigable subiendo su timeout/optimizando). El resto: ok (fallos aislados por "server restarted", normales).

## 5. Frescura de datos — OK
soccer 18:15 · NFL (post-fix) hoy · MLB 12:30 (normal, postemporada) · motor_cache 19:04 · tarjeta_soccer 19:12 · historico fresco en los 3 deportes.

---

## 6. 🔴 Seguridad (grave, pendiente — plan por fases)
Advisor de Supabase: **219 ERROR**.
- **109 tablas `public` SIN RLS** → abiertas con la key `anon` (lectura, y potencialmente escritura): internals del modelo (`modelo_registry`, `lineas_canonicas`, `feature_pesos`, `predicciones_congeladas`, `calib_*`, `mlb_modelo_snapshot`). **Fuga de datos propietarios.**
- **110 vistas SECURITY DEFINER** y **188 funciones** ejecutables por `anon`.
- **110 tablas con RLS activado pero SIN política** → devuelven 0 filas (si el front lee una directo con anon, sale vacía).

⚠️ Arreglar RLS es delicado: activarlo mal **rompe** las pantallas que hoy leen con anon. Debe ir por fases con pruebas, con sign-off del auditor. **No aplicado** (no romper más bajo freeze).

---

## 7. Pendientes / recomendaciones
1. **Auditor:** revisar y aplicar `iss_mlb_authority_kickoff_source_fix.sql`.
2. **MLB:** recalibrar el modelo (objetivo gap ≤5pp) antes de considerar release/money.
3. **Seguridad RLS:** plan por fases (clasificar las 109 tablas: internas→lock con RLS; leídas por app→política que preserve acceso). Con auditor.
4. **Job 515 Global:** subir statement_timeout del refresh u optimizar `v_reto13m_global_candidate_source_v2` (muy pesada).
5. **Frontend (Lovable):** cualquier "botón muerto" o pantalla rota en el wiring del front queda fuera de mi alcance; reportar cuál para mapearla al endpoint backend.

## 8. Límite honesto
La mayoría de "pantallas vacías" no son bugs: son los gates (P0=SOCCER, RELEASE_GATE=HOLD, money off) funcionando como fueron definidos. "Llenarlas" (NFL/MLB al Global, money on) es una **decisión de release** que requiere validación real por deporte + sign-off del auditor — y para MLB money específicamente, recalibración previa. No lo hice por mi cuenta porque implica publicar apuestas sin validar, que daña a los usuarios.
