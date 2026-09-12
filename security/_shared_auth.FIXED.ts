import { createClient } from "npm:@supabase/supabase-js@2";

export interface CallerIdentity {
  userId: string | null;
  apodo: string;
  isService: boolean;
}

/** Comparacion en tiempo constante (evita oraculo de timing sobre la llave). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

/**
 * 6-sep-2026 (AUTH-0). SEGURIDAD CRITICA:
 * un service_role se prueba UNICAMENTE con la llave real, comparada en tiempo
 * constante. NUNCA decodificando el payload del JWT y leyendo su 'role': eso
 * es DECODIFICAR, no VALIDAR, y permite fabricar {"role":"service_role"} sin
 * firma. La rama de usuario normal SI valida (admin.auth.getUser server-side).
 */
function isServiceToken(token: string): boolean {
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return service.length > 0 && timingSafeEqual(token, service);
}

/**
 * Valida el JWT del llamador y devuelve su identidad real (user_id + apodo de la BD).
 * Nunca confíes en el apodo que manda el cliente: usa el que devuelve esta función.
 * Las llamadas internas con service_role (crons, otras funciones) se permiten.
 */
export async function requireCaller(
  req: Request,
  opts: { requireApodo?: boolean } = {},
): Promise<CallerIdentity> {
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("unauthorized");

  if (isServiceToken(token)) return { userId: null, apodo: "", isService: true };

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) throw new Error("unauthorized");

  const { data: perfil } = await admin
    .from("usuarios")
    .select("apodo")
    .eq("user_id", data.user.id)
    .maybeSingle();

  const apodo = perfil?.apodo || "";
  if (!apodo && opts.requireApodo !== false) throw new Error("sin_apodo");

  return { userId: data.user.id, apodo, isService: false };
}


export function unauthorizedResponse(headers: Record<string, string>, message = "No autorizado") {
  return new Response(JSON.stringify({ error: message }), {
    status: 401,
    headers: { ...headers, "Content-Type": "application/json" },
  });
}
