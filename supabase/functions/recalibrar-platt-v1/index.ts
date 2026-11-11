// recalibrar-platt-v1
// Calibracion Platt (regresion logistica) por deporte sobre el historial de picks graderos.
// p_cal = sigmoid(a*logit(p_raw)+b). Se ajusta en el 70% mas antiguo (train) por fecha y se
// valida en el 30% mas reciente (test). Solo se marca validado=true si MEJORA el Brier OOS
// (gate de integridad: nunca empeorar lo publicado). DINERO OFF: esto solo corrige probabilidades.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const clamp = (p: number) => Math.min(0.999, Math.max(0.001, p));
const logit = (p: number) => Math.log(clamp(p) / (1 - clamp(p)));
const sigmoid = (z: number) => 1 / (1 + Math.exp(-z));

// IRLS (Newton-Raphson) para regresion logistica de y sobre x=logit(p): P(y)=sigmoid(a*x+b)
function fitPlatt(xs: number[], ys: number[]) {
  let a = 1, b = 0;
  for (let it = 0; it < 60; it++) {
    let g0 = 0, g1 = 0, h00 = 0, h01 = 0, h11 = 0;
    for (let i = 0; i < xs.length; i++) {
      const z = a * xs[i] + b, p = sigmoid(z), w = p * (1 - p), e = p - ys[i];
      g0 += e * xs[i]; g1 += e;
      h00 += w * xs[i] * xs[i]; h01 += w * xs[i]; h11 += w;
    }
    h00 += 1e-6; h11 += 1e-6; // regularizacion minima para estabilidad
    const det = h00 * h11 - h01 * h01;
    if (Math.abs(det) < 1e-12) break;
    const da = (h11 * g0 - h01 * g1) / det;
    const db = (-h01 * g0 + h00 * g1) / det;
    a -= da; b -= db;
    if (Math.abs(da) + Math.abs(db) < 1e-9) break;
  }
  return { a, b };
}

const brier = (ps: number[], ys: number[]) =>
  ps.reduce((s, p, i) => s + (p - ys[i]) ** 2, 0) / ps.length;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");

    // Trae TODOS los picks graderos con resultado, paginando (PostgREST limita a 1000 por pagina).
    const data: any[] = [];
    for (let from = 0; ; from += 1000) {
      const { data: page, error } = await sb
        .from("v_reto_pick_grade_v1")
        .select("deporte,prob_pct,acierto,kickoff")
        .not("acierto", "is", null)
        .order("kickoff", { ascending: true })
        .range(from, from + 999);
      if (error) throw error;
      if (!page || page.length === 0) break;
      data.push(...page);
      if (page.length < 1000) break;
    }

    const porDeporte: Record<string, { x: number; y: number }[]> = {};
    for (const r of (data || [])) {
      const p = Number(r.prob_pct) / 100;
      const y = Number(r.acierto);
      if (!isFinite(p) || (y !== 0 && y !== 1)) continue;
      (porDeporte[r.deporte] ||= []).push({ x: logit(p), y });
    }

    const resumen: any[] = [];
    for (const [deporte, rows] of Object.entries(porDeporte)) {
      const n = rows.length;
      const nTrain = Math.floor(n * 0.7);
      const nTest = n - nTrain;
      if (nTrain < 40 || nTest < 25) {
        resumen.push({ deporte, n, skip: "muestra insuficiente (train<40 o test<25)" });
        continue;
      }
      const train = rows.slice(0, nTrain);
      const test = rows.slice(nTrain);
      const { a, b } = fitPlatt(train.map((r) => r.x), train.map((r) => r.y));

      const ysTest = test.map((r) => r.y);
      const rawTest = test.map((r) => sigmoid(r.x));        // p original (sigmoid(logit)=p)
      const calTest = test.map((r) => sigmoid(a * r.x + b)); // p calibrada
      const bRaw = brier(rawTest, ysTest);
      const bCal = brier(calTest, ysTest);

      // Gate: solo valida si a>0 (monotona) y mejora Brier OOS con margen minimo.
      const mejora = bCal < bRaw - 1e-4 && a > 0;
      const row = {
        deporte,
        a: Number(a.toFixed(4)),
        b: Number(b.toFixed(4)),
        brier_raw: Number(bRaw.toFixed(4)),
        brier_platt: Number(bCal.toFixed(4)),
        n_train: nTrain,
        n_test: nTest,
        validado: mejora,
        nota: mejora ? "platt mejora Brier OOS" : "sin ajuste (no mejora OOS)",
        actualizado: new Date().toISOString(),
      };
      const { error: upErr } = await sb.from("reto_calibracion_platt_v1").upsert(row, { onConflict: "deporte" });
      if (upErr) resumen.push({ deporte, upsert_error: upErr.message });
      else resumen.push(row);
    }

    return new Response(JSON.stringify({ ok: true, resumen }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
