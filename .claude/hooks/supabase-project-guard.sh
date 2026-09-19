#!/usr/bin/env bash
# Guarda de proyecto para Reto 13M.
# Las reglas de permiso de una herramienta MCP NO limitan sus parametros: permitir
# mcp__Supabase__execute_sql lo permite contra CUALQUIER project_id. Este hook es
# lo que ata las llamadas al unico proyecto autorizado.
#
# Ademas DEJA RASTRO de cada invocacion. Ese rastro es la unica prueba objetiva de
# si la configuracion de .claude/ esta realmente cargada en la sesion: si el log
# crece cuando llamo a Supabase, el hook corre y por tanto settings tambien.
set -uo pipefail

PROYECTO_AUTORIZADO="wpiztubmmmzclhlprgpd"
LOG="${CLAUDE_PROJECT_DIR:-/home/user/reto}/.claude/hooks/guard-invocaciones.log"

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // "?"' 2>/dev/null || echo '?')"
pid="$(printf '%s' "$payload" | jq -r '.tool_input.project_id // empty' 2>/dev/null || true)"

printf '%s\t%s\tproject_id=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tool" "${pid:-<ninguno>}" >> "$LOG" 2>/dev/null || true

if [ -z "$pid" ]; then exit 0; fi

if [ "$pid" != "$PROYECTO_AUTORIZADO" ]; then
  jq -cn --arg p "$pid" --arg ok "$PROYECTO_AUTORIZADO" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("project_id no autorizado: \($p). Reto 13M solo opera sobre \($ok).")
    },
    systemMessage: ("Llamada a Supabase BLOQUEADA: project_id \($p) no es el de Reto 13M (\($ok)).")
  }'
  exit 0
fi
exit 0
