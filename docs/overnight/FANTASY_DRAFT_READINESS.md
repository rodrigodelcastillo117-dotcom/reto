# FANTASY DRAFT — WAR ROOM READINESS

**Semáforo: 🔴 RED — infraestructura presente, cero datos. No utilizable para el draft de mañana.**

---

## 1. Estado

```
DATA_AVAILABLE            = NO   (todas las tablas vacías)
USER_LEAGUE_CONFIG_AVAILABLE = NO
DRAFT_ENGINE_STATUS       = SCHEMA_ONLY
UI_STATUS                 = NO AUDITABLE (frontend fuera de este repo)
```

## 2. Evidencia — las 11 tablas del módulo están a cero

| Tabla | Filas |
|---|---|
| `lab_ff_champion_registry` | 0 |
| `lab_ff_draft_event` | 0 |
| `lab_ff_feat` | 0 |
| `lab_ff_forward` | 0 |
| `lab_ff_ownership` | 0 |
| `lab_ff_playerweek` | 0 |
| `lab_ff_pos_prior` | 0 |
| `lab_ff_raw` | 0 |
| `lab_ff_sync_contract` | 0 |
| `lab_ff_team_week` | 0 |
| `lab_ff_wf` | 0 |

Sin `lab_ff_playerweek` no hay jugadores; sin jugadores no hay ADP, tiers, proyecciones, replacement value ni escasez posicional. **Un War Room sobre cero jugadores no puede recomendar nada.**

## 3. Configuración de liga del usuario

`lab_ff_sync_contract` (columnas `method, descripcion, feeds, estado, notas`) está **vacía**. No consta en ninguna parte del esquema:

- scoring (PPR / half / standard)
- roster slots
- número de equipos
- tipo de draft (snake / auction)
- posición de pick
- reglas de keeper

Conforme a la instrucción explícita, **no invento estos parámetros**. Sin ellos, "best available" y "best fit for my roster" no son computables: replacement value y escasez posicional dependen enteramente del scoring y de los slots.

## 4. Lo que sí está diseñado

`lab_ff_draft_event` tiene un esquema razonable para registrar un draft en vivo:

```
id, draft_id, action, pick_number, ronda, pick_en_ronda, fantasy_team,
is_my_pick, espn_player_id, jugador, posicion, equipo, identity_status,
source, nota, captured_at
```

Y existe `lab_ff_draft_pick(...)` como función de registro. La arquitectura de captura de draft **existe**; lo que falta es el universo de jugadores y la config de liga.

⚠️ `lab_ff_draft_pick` y las otras 5 funciones `lab_ff_*` son `SECURITY DEFINER` **sin `search_path` fijado** — ver hallazgo de seguridad SEC-02 en el reporte maestro.

## 5. Por qué no construí el War Room esta noche

Construir motor de recomendación sin datos ni config habría significado inventar ADP, proyecciones y pesos — exactamente lo prohibido ("no inventar features ni modelos sin disponibilidad/evidencia"). Un War Room que recomienda sobre datos inventados es peor que no tener War Room: da confianza falsa en una decisión irreversible (un pick de draft no se deshace).

## 6. Camino mínimo para que sea usable

En orden, y todo requiere decisión o datos del usuario:

1. **Config de liga** (5 minutos de input humano): scoring, slots, nº equipos, tipo de draft, posición de pick, keepers. Sin esto nada más importa.
2. **Universo de jugadores + ADP**: poblar `lab_ff_playerweek` / `lab_ff_raw` desde la fuente que use la liga.
3. **Proyecciones**: sin ellas se puede operar con ADP + tiers (peor pero honesto); con ellas se puede calcular replacement value.
4. Recién entonces: motor de recomendación (best available / best fit / positional run / value faller).

**HUMAN_DECISION_REQUIRED:** la config de liga. Es el bloqueo raíz y solo el usuario la tiene.

**BLOCKER:** ingesta del universo de jugadores (fuente externa).
