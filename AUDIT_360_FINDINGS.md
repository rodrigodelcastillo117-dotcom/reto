# AUDIT_360 — Hallazgos registrados manualmente (FASE A, read-only)

> Registrados durante la Operación 20 Agentes. NO desplegar hasta el informe maestro + GO.
> AUDIT_AS_OF = 2026-09-07T03:41:49Z. Proyecto Supabase: wpiztubmmmzclhlprgpd. Frontend Lovable: 00f8f06b-3762-44a6-a397-e41dd7d9b7c5.

---

## NFL-001 — P1 HIGH — GOVERNANCE / FALSE PICK SURFACE

**SEVERITY:** P1 HIGH
**CLASSIFICATION:** BUG (gobernanza / semántica) — no es "0 legítimo": es superficie que presenta recomendaciones donde la política dice que no debe haberlas.

**EXPECTED:** Con `NFL SKILL_FINAL = INSUFFICIENT` y política `$0 / NO_MODEL_SKILL`, la app NO debe renderizar nada que un usuario lea como pick/recomendación/predicción de NFL. `recommended_nfl_picks = 0` SIEMPRE. Puede existir *contexto de mercado*, pero nunca presentado como recomendación.

**ACTUAL:**
1. La sección `⭐ PICKS PREMIUM` (`src/components/nfl/NflPremiumPicks.tsx`, tabla `nfl_picks_premium`, 1358 filas) presenta líneas y probabilidades implícitas del mercado como si fueran picks. Header dice "⭐ PICKS PREMIUM · líneas reales de mercado"; cada fila usa el lenguaje de pick. Aparece JUSTO debajo del aviso de la propia pantalla: "⚠️ Todavía no recomendamos apuestas de NFL… preferimos no inventarla". Contradicción directa de gobernanza en la misma vista.
2. `nfl_tablero` (vista) renderiza `nfl_predicciones.mejor_pick` / `mejor_prob` como **"GANA: <EQUIPO> <N>%"** por partido (ej. "GANA: SAINTS 55%"). Además `prob_local/prob_visitante = round(100*p_home/p_away)` = **probabilidad implícita del momio (mercado), NO de un modelo NFL validado**. Un "GANA: X%" por partido lee como predicción/pick del sistema.

**EVIDENCE:**
- SQL: `SELECT count(*) FROM nfl_picks_premium;` → 1358 filas / 272 partidos.
- `pg_get_viewdef('nfl_tablero')` → `round(100*p_home,1) AS prob_local` (viene de `nfl_partidos`, ingesta de momios) + `LEFT JOIN nfl_predicciones pr` → `pr.mejor_pick, pr.mejor_prob`.
- `SELECT espn_event_id,mejor_pick,mejor_prob FROM nfl_predicciones` → "Gana New Orleans Saints" 55.1, "Gana Kansas City Chiefs" 54.3, etc.
- Capturas del usuario (2026-09-07): tarjetas "MERCADO / probabilidad de la casa (sin modelo propio)" + tablero "análisis disponible / GANA: CHIEFS 56%".

**ROOT_CAUSE:** La app mezcla tres conceptos en la misma superficie con el mismo lenguaje visual: **mercado ≠ análisis ≠ pick**. No hay una regla de gobernanza en la capa de presentación que impida rotular datos market-only con vocabulario de recomendación cuando `SKILL != PASS`.

**REPRODUCTION:** Abrir pantalla NFL en https://reto13.lovable.app → sección "⭐ PICKS PREMIUM" y tablero con "GANA: X%".

**SURFACE_AFFECTED:** `src/pages/NFL.tsx`, `src/components/nfl/NflPremiumPicks.tsx`, vista `nfl_tablero`, tabla `nfl_predicciones`, tabla `nfl_picks_premium`.

**RECOMMENDED_FIX (FASE B, requiere GO):** Regla de gobernanza en presentación: mientras `NFL SKILL != PASS`, `recommended_nfl_picks = 0`. Puede mostrarse contexto de mercado, pero: (a) renombrar `PICKS PREMIUM` → `MERCADO NFL — INFORMATIVO`; (b) prohibir el vocabulario `PICK/PREMIUM/SEÑAL/GANA/RECOMENDACIÓN/APOSTAR` para datos market-only; (c) etiquetar toda probabilidad como *implícita del mercado*, no del modelo; (d) el "GANA: X%" del tablero pasa a "Favorito del mercado: <EQUIPO> (<N>% implícito)".

**RISK_OF_FIX:** Bajo (capa de presentación/labels). No toca modelos, probabilidades, gates ni dinero.

---

## NFL-002 — P2 MEDIUM — PRESENTATION / QUERY

**SEVERITY:** P2
**CLASSIFICATION:** BUG (presentación + consulta)

**EXPECTED:** Una tarjeta por partido (`espn_event_id`), con sus mercados como sub-líneas, del slate vigente, ordenada por kickoff.

**ACTUAL:** `NflPremiumPicks` renderiza **una fila de mercado por tarjeta**:
- duplica el partido (≈5 tarjetas por juego: ML local, ML visitante, Spread, Total Over, Total Under);
- muestra **ambos lados** del Moneyline como picks separados;
- muestra **Over y Under simultáneamente** como "picks";
- Spread con probabilidad NULL se pinta como `0%`;
- consulta `.from("nfl_picks_premium").select("*").limit(60)` **sin filtro week/date y sin order** → mezcla slate/temporada (semanas 1–18 revueltas).

**EVIDENCE:** Código `NflPremiumPicks.tsx` (queryFn con `.limit(60)`, `.map` una tarjeta por fila). SQL: filas por partido en `nfl_picks_premium` = ML(x2)+Spread+Total(x2). Capturas del usuario: SEA@NE y SF@LAR repetidos 4–5 veces; "SEA -3.5 · 0%".

**ROOT_CAUSE:** Modelo de datos fila-por-línea-de-mercado + render fila-por-tarjeta, sin agrupación por evento ni filtro temporal.

**SURFACE_AFFECTED:** `src/components/nfl/NflPremiumPicks.tsx`, tabla `nfl_picks_premium`.

**RECOMMENDED_FIX (FASE B, requiere GO):** NO elegir arbitrariamente "un lado" por mercado. Una tarjeta por `espn_event_id`; ML muestra ambos precios; Spread muestra línea + precio real, y si falta precio → `Momio no disponible` (NUNCA `0%`); Total muestra Over + Under con sus precios; probabilidades etiquetadas como implícitas del mercado; filtrar por semana/slate vigente y ordenar por kickoff. Patch SHADOW preparado en `shadow-patches/NflPremiumPicks.proposed.tsx` (NO desplegado).

**RISK_OF_FIX:** Bajo (UI/consulta). No toca probabilidades ni gates.

---

## REGRESIÓN DE GOBERNANZA (obligatoria, transversal)

Si `NFL SKILL != PASS` ⇒ `recommended_nfl_picks = 0` SIEMPRE. Puede existir *market context*, pero jamás renderizarse como recomendación. Esta regla debe verificarse superficie por superficie.

## ADDENDUM SOLICITADO PARA AGENTE 20 — BARRIDO GLOBAL DE STRINGS
Búsqueda global en el frontend por: `PICK`, `PREMIUM`, `SEÑAL`, `GANA`, `RECOMENDACIÓN`, `APOSTAR` (y equivalentes). Para cada aparición: identificar la superficie y **de dónde viene el número** que se muestra al lado (mercado implícito / análisis / modelo validado / LLM). Marcar todo caso donde un dato market-only se rotule como pick/recomendación. (El run del Agente 20 en curso tiene prompt fijo; este barrido se corre como pase dedicado y se integra al informe maestro.)
