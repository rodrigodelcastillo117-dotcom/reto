# BLOQUE 4 — Real Provider Total Line · EVIDENCIA (STAGED)

Artefacto: `shadow-patches/prepared/iss032_real_total_line_contract.sql`
(`v2.fn_real_total_line`, `v2.v_real_line_audit`). Fix en iss030 (total_line ahora
lee `v_momios_confiables`, no `momios_mercado`).

## Contrato
O/U expone: `provider_total_line` (over_line), `provider` (bookmaker), `line_asof`
(snapshot_at), `decision_time`, over/under odds. Invariante `line_asof<=decision_time`.
Fuente = `v_momios_confiables` (la MISMA que consume v_futpro_v2). Última captura
confiable `<= decision` (no max sin filtro). Sin línea real → **0 filas → O/U fail-closed**.
Prohibido hardcode 2.5 / nearest / fallback inventado.

## Audit real (eventos READY con O/U, 2026-09-09)
| métrica | valor |
|---|---|
| READY con O/U | 77 |
| con línea real confiable `<= decision` | **77 / 77** |
| línea publicada == línea del proveedor | **77 / 77** |
| sin línea real (debería fail-close) | 0 |
| `line_asof <= decision` | 77 / 77 |
| over_line = 2.5 | 46/77 — **NO hardcode**: coincide 1:1 con la línea real del libro |

Conclusión: la línea O/U de producción YA es la línea real del proveedor, con
`snapshot_at<=decision`, sin fabricación. El "2.5" frecuente es la línea real del
mercado (probado por coincidencia 77/77), no un default.

## Operaciones que requerirán autorización posterior
1. Ejecutar iss032 (contrato + vista de auditoría).
2. BLOQUE 5: over_prob/under_prob sólo si `fn_real_total_line` devuelve fila y la
   línea del modelo == provider_total_line; si no → O/U fail-closed (NULL).
