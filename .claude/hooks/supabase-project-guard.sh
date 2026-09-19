#!/usr/bin/env bash
# Guarda de proyecto para Reto 13M.
#
# Las reglas de permiso de una herramienta MCP NO limitan sus parametros: permitir
# mcp__Supabase__execute_sql lo permite contra CUALQUIER project_id. Este hook es
# lo que ata las llamadas al unico proyecto autorizado.
#
# ISS258 — FALLA CERRADO. Antes, una herramienta sin project_id pasaba sola
# (`if [ -z "$pid" ]; then exit 0; fi`). Eso es fail-OPEN: cualquier llamada
# dirigida a un proyecto que por la razon que sea no trajera el parametro
# —renombrado del campo, wrapper distinto, version nueva del servidor— se
# colaba sin revisar. Ahora al reves: solo pasan sin project_id las herramientas
# que por contrato NO apuntan a ningun proyecto. Todo lo demas necesita un
# project_id bien formado Y autorizado, o se deniega.
#
# Ademas DEJA RASTRO de cada invocacion CON SU DECISION. Ese rastro es la unica
# prueba objetiva desde dentro de la sesion de que la configuracion de .claude/
# esta cargada: si el log crece cuando llamo a Supabase, el hook corre.
# OJO: el log prueba que el hook CORRIO y que decidio. NO prueba que al usuario
# no le aparecio un aviso de permiso; eso solo lo ve el usuario.
set -uo pipefail

PROYECTO_AUTORIZADO="wpiztubmmmzclhlprgpd"
LOG="${CLAUDE_PROJECT_DIR:-/home/user/reto}/.claude/hooks/guard-invocaciones.log"

# Unicas herramientas de Supabase que NO apuntan a un proyecto concreto y por
# tanto pueden correr sin project_id. Cualquier cosa fuera de esta lista que
# llegue sin project_id valido se DENIEGA.
#
# create_project queda DELIBERADAMENTE fuera: crear un proyecto nuevo nunca es
# parte de Reto 13M, asi que caer en la rama de denegacion es el comportamiento
# correcto, no un efecto colateral.
es_sin_proyecto() {
  case "$1" in
    *list_projects|*list_organizations|*get_organization|*get_cost|*confirm_cost|*search_docs)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

registrar() {  # $1=tool $2=project_id $3=decision
  printf '%s\t%s\tproject_id=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-<ninguno>}" "$3" >> "$LOG" 2>/dev/null || true
}

denegar() {  # $1=razon corta para el modelo  $2=mensaje para el usuario
  jq -cn --arg r "$1" --arg s "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    },
    systemMessage: $s
  }'
  exit 0
}

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // "?"' 2>/dev/null || echo '?')"
pid="$(printf '%s' "$payload" | jq -r '.tool_input.project_id // empty' 2>/dev/null || true)"

# --- Herramientas que no apuntan a un proyecto -------------------------------
if es_sin_proyecto "$tool"; then
  # Si aun asi trae un project_id, tiene que ser el autorizado: no se acepta
  # que una herramienta "global" arrastre otro proyecto de contrabando.
  if [ -n "$pid" ] && [ "$pid" != "$PROYECTO_AUTORIZADO" ]; then
    registrar "$tool" "$pid" "DENEGADA_proyecto_ajeno_en_herramienta_global"
    denegar "project_id no autorizado: $pid. Reto 13M solo opera sobre $PROYECTO_AUTORIZADO." \
            "Llamada a Supabase BLOQUEADA: project_id $pid no es el de Reto 13M."
  fi
  registrar "$tool" "$pid" "PERMITIDA_sin_proyecto"
  exit 0
fi

# --- Todo lo demas apunta a un proyecto: exige uno valido y autorizado -------
if [ -z "$pid" ]; then
  registrar "$tool" "" "DENEGADA_falta_project_id"
  denegar "La herramienta $tool apunta a un proyecto pero no trae project_id. La guarda de Reto 13M falla cerrado: sin project_id no se ejecuta. Vuelve a llamarla con project_id=$PROYECTO_AUTORIZADO." \
          "Llamada a Supabase BLOQUEADA: $tool llego sin project_id y la guarda falla cerrado."
fi

# Forma valida de una referencia de proyecto Supabase: 20 caracteres [a-z0-9].
# Un valor con forma rara (vacio tras trim, con comodines, con ruta) se deniega
# antes de compararlo, para no depender solo de la igualdad de cadenas.
if ! printf '%s' "$pid" | grep -Eq '^[a-z0-9]{20}$'; then
  registrar "$tool" "$pid" "DENEGADA_project_id_mal_formado"
  denegar "project_id mal formado: '$pid'. Una referencia de proyecto Supabase son 20 caracteres [a-z0-9]. Reto 13M solo opera sobre $PROYECTO_AUTORIZADO." \
          "Llamada a Supabase BLOQUEADA: project_id mal formado ('$pid')."
fi

if [ "$pid" != "$PROYECTO_AUTORIZADO" ]; then
  registrar "$tool" "$pid" "DENEGADA_proyecto_no_autorizado"
  denegar "project_id no autorizado: $pid. Reto 13M solo opera sobre $PROYECTO_AUTORIZADO." \
          "Llamada a Supabase BLOQUEADA: project_id $pid no es el de Reto 13M ($PROYECTO_AUTORIZADO)."
fi

registrar "$tool" "$pid" "PERMITIDA"
exit 0
