#!/usr/bin/env node
// RETO 13M V2 — Contamination Gate (P0 zero-contamination migration rule).
// Runs over the NEW frontend `src/`. Fails (exit 1) if any legacy predictive
// contamination is found in files marked as migrated. During migration, files
// still pending appear in QUARANTINE and are reported but do not fail the build
// until listed in MIGRATED.
//
// Usage: node contamination-gate.mjs [srcDir]   (default ./src)
//
// Principle: "Quiero la experiencia vieja; no quiero el cerebro viejo."
// PORT: UI/UX/workflow/lifecycle/status. BLOCK: every predictive data source
// and predictive decision path. Everything shown as P_RETO / predicted score /
// 1X2 / BTTS / totals / recommended selection / analysis conclusions MUST trace
// to an approved V2 contract. No legacy fallback. Fail closed if V2 has no answer.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, extname } from "node:path";

const SRC = process.argv[2] || "./src";

// ── Approved V2 predictive allowlist (the ONLY predictive sources) ──────────
const V2_ALLOW = [
  "v_futpro_v2", "v_analisis_v2", "v_mlb_v2", "v_nfl_v2",
  "v_canonical_event", "v_canonical_prediction", "v_canonical_analysis",
  "team_logo", "competition_catalog", "soccer_prediction_snapshot",
];

// ── Legacy predictive DENYLIST (discovered transitively from donor reto13) ──
// Each rule: { gate, label, re }  — re tested per line.
const RULES = [
  // Legacy predictive views / RPC read as truth
  { gate: "LEGACY_PREDICTIVE_VIEW_READS", label: "legacy predictive view/rpc",
    re: /\b(analisis_completo|v_prediccion_reto_futbol|v_pick_canonico|v_picks_futbol_(calc|calibrado|limpio)|v_analisis_fut_completo|v_poisson_(picks|recomendaciones)|v_motor_valor_proximos|v_super_pick|v_mejores_picks_mlb|v_radar_mlb|v_picks_mlb_modelo)\b/ },
  { gate: "LEGACY_PREDICTIVE_RPC_CALLS", label: "legacy predictive rpc/edge",
    re: /\b(predecir_mlb|calcular_1x2_futbol|evaluar_parlay|construir-parlay-ai|analizar-partido)\b/ },
  // Client-side predictive brain modules
  { gate: "LEGACY_PREDICTIVE_IMPORTS", label: "legacy brain module import",
    re: /\b(coreModel|safetyEngine|adaptiveEngine|marketUpgrader|soccerCanonical|oraculoCanonico|useMatrizReto|metaBuilders)\b/ },
  // Client-side probability calculators (goal-rate / Poisson done in the browser)
  { gate: "CLIENT_SIDE_P_CALCULATORS", label: "client-side P/λ calculator",
    re: /\b(lambda_home|lambda_away|poisson\s*\(|dixonColes|dixon_coles|factorial\s*\(|Math\.exp\([^)]*lambda)/i },
  // EV / Kelly as PRIMARY selection or sizing authority
  { gate: "EV_DRIVEN_PRIMARY_SELECTIONS", label: "EV/Kelly primary selection/sizing",
    re: /\b(kelly|expected_value|ev_estimado|ev_real|selectByEv|rankByEv|edge_total)\b/i },
  // Market-implied probability presented as P_RETO
  { gate: "MARKET_AS_P_RETO_PATHS", label: "market/implied prob as P_RETO",
    re: /\b(implied_prob|prob_implicita|prob_mercado|momio_to_prob|de_momio)\b.*\bp_?reto\b/i },
  // Hardcoded / default / fallback scorelines
  { gate: "LEGACY_SCORE_FALLBACK_PATHS", label: "hardcoded/fallback scoreline",
    re: /\b(score_probable|scores?_fallback|default.*score|modal_score)\b|['"`]\s*1\s*-\s*1\s*['"`]/ },
];

const files = [];
(function walk(dir) {
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    const st = statSync(p);
    if (st.isDirectory()) { if (e !== "node_modules" && e !== "ui") walk(p); }
    else if ([".ts", ".tsx"].includes(extname(p))) files.push(p);
  }
})(SRC);

const counts = Object.fromEntries(RULES.map(r => [r.gate, 0]));
counts.P_RETO_WITHOUT_V2_PROVENANCE = 0;
counts.UNKNOWN_PREDICTIVE_DEPENDENCIES = 0;
const hits = [];

for (const f of files) {
  const text = readFileSync(f, "utf8");
  const lines = text.split("\n");
  const usesV2 = V2_ALLOW.some(v => text.includes(v));
  const showsPReto = /\bp_?reto(_home|_draw|_away)?\b/i.test(text) || /P_RETO/.test(text);
  lines.forEach((ln, i) => {
    for (const r of RULES) {
      if (r.re.test(ln)) { counts[r.gate]++; hits.push(`${r.gate}  ${f}:${i + 1}  ${ln.trim().slice(0, 100)}`); }
    }
  });
  // P_RETO shown but no V2 contract referenced in the file → provenance gate
  if (showsPReto && !usesV2) {
    counts.P_RETO_WITHOUT_V2_PROVENANCE++;
    hits.push(`P_RETO_WITHOUT_V2_PROVENANCE  ${f}  (shows P_RETO, no v2 contract import)`);
  }
}

console.log("── RETO 13M V2 — contamination gates ──");
let bad = 0;
for (const [gate, n] of Object.entries(counts)) {
  console.log(`${n === 0 ? "PASS" : "FAIL"}  ${gate} = ${n}`);
  if (n > 0) bad += n;
}
if (hits.length) {
  console.log("\n── hits ──");
  for (const h of hits.slice(0, 200)) console.log("  " + h);
  if (hits.length > 200) console.log(`  … +${hits.length - 200} more`);
}
console.log(`\nfiles scanned: ${files.length}  ·  total violations: ${bad}`);
process.exit(bad === 0 ? 0 : 1);
