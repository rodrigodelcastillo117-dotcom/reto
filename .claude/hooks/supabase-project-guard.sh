#!/usr/bin/env bash
# Guarda de proyecto para Reto 13M.
# Las reglas de permiso de una herramienta MCP NO limitan sus parametros: permitir
# mcp__Supabase__execute_sql lo permite contra CUALQUIER project_id. Este hook es
# lo que ata las llamadas al unico proyecto autorizado.
set -euo pipefail

PROYECTO_AUTORIZADO="wpiztubmmmzclhlprgpd"

payload="$(cat)"
pid="$(printf '%s' "$payload" | jq -r '.tool_input.project_id // empty' 2>/dev/null || true)"

# Sin project_id no hay proyecto al que apuntar (list_projects, list_organizations...): pasa.
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
