# Identidad canónica de patas de parlay (agrupado) · EVIDENCIA (STAGED)

Reportado por el usuario (captura 2026-09-09): en un parlay, dos patas del MISMO
partido no se agrupan. Corresponde a BLOQUE 5 (identidad canónica) + BLOQUE 7
(scanner ESPN-first) + gate de event/provider identity.
Artefacto: `shadow-patches/prepared/iss031_parlay_leg_canonical_identity.sql`.

## Causa raíz (verificada en prod, parlay a3135134)
Cada partido tenía 2 patas (ML + Over/BTTS) con **dos identidades distintas**:
una con id ESPN real (401915423) y otra con `af_<fixture>` (API-Football sin
resolver). El frontend no puede agrupar dos ids distintos.
- `canonizar_evento_id('af_1635698')` → `af_1635698` (SIN cambio: sólo usa registro
  de fixtures, vacío para estos partidos de Champions).
- `resolver_evento_canonico('af_1635698')` → `401915423` (FUZZY_UNIQUE por equipos+fecha).
El canonizador de patas usaba el resolver DÉBIL en vez del FUERTE.

## Alcance
63/363 patas (17%) en 16/58 parlays (30 días) con id `af_` sin resolver. Los
partidos que SÍ agrupan (Chelsea-Leeds, Al Nassr-Abha) tienen ambas patas con el
mismo id ESPN.

## Simulación read-only (parlay a3135134) — el resolver fuerte agrupa TODO
| partido | id_actual | id_canónico | método |
|---|---|---|---|
| Napoli vs Arsenal | af_1635698 | 401915423 | FUZZY_UNIQUE |
| SSC Nápoles - Arsenal FC | 401915423 | 401915423 | YA_ESPN |
| Liverpool vs Atletico | af_1635686 | 401915446 | FUZZY_UNIQUE |
| Liverpool FC - Atlético | 401915446 | 401915446 | YA_ESPN |
| Sporting CP vs Galatasaray | af_1635736 | 401915447 | FUZZY_UNIQUE |
| Sporting Lisboa - Galatasaray | 401915447 | 401915447 | YA_ESPN |
| PSG vs Slovan | 401915445 | 401915445 | YA_ESPN |
| PSG - SK Slovan | af_1635705 | 401915445 | FUZZY_UNIQUE |
Cada pareja converge al MISMO canonical_event_id → agrupan. Todas EXACT/FUZZY_UNIQUE;
ninguna ambigua (si lo fuera → needs_review, sin adivinar).

## Fix staged (iss031)
- `v2.fn_leg_canonical_event_id`: passthrough ESPN; para `af_` usa resolver fuerte,
  adopta ESPN sólo si EXACT/FUZZY_UNIQUE; si no → conserva crudo + needs_review.
- `v2.fn_parlay_identidad_propuesta` (dry-run): añade `canonical_event_id` por pata.
- `v2.v_parlay_identity_audit`: auditoría de identidad.
- Backfill staged (UPDATE, no aplicado) para las 63 patas.

## Operaciones que requerirán autorización posterior
1. Ejecutar iss031; correr el backfill (§4) sobre parlays con patas `af_`.
2. Deploy: `canonizar_legs_parlay()` debe usar el resolver fuerte como fallback y
   escribir `canonical_event_id`; el scanner (BLOQUE 7) debe resolver ESPN-first al ingest.
3. Frontend (ChatGPT/Remix): agrupar patas por `canonical_event_id`, no por el
   string `partido`. (Es render — fuera de mi ámbito; entrego la identidad canónica.)
