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
LISTA_RAMAS="${CLAUDE_PROJECT_DIR:-/home/user/reto}/.claude/hooks/ramas-autorizadas-para-borrar.txt"

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

# ISS261 — POR QUE EXISTE ESTO.
# Callarse NO es aprobar. Un hook que termina sin decision deja la llamada al
# sistema normal de permisos, que puede volver a preguntarle al dueno aunque
# `permissions.allow` tenga la herramienta. Por eso seguian saliendo avisos cada
# dos por tres pese a las 30 entradas del allowlist.
#
# `permissionDecision: "allow"` SI es una aprobacion: salta el sistema de
# permisos para esa llamada concreta. Es la unica forma de que no pregunte.
#
# El alcance es estrecho a proposito: solo se auto-aprueba una herramienta de
# Supabase que apunte al proyecto de Reto 13M con un project_id bien formado.
# Cualquier otra cosa cae en denegar() o sigue preguntando como siempre.
permitir() {  # $1=motivo para la bitacora del modelo
  jq -cn --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // "?"' 2>/dev/null || echo '?')"
pid="$(printf '%s' "$payload" | jq -r '.tool_input.project_id // empty' 2>/dev/null || true)"

# --- delete_branch: apunta a una RAMA, no a un proyecto ----------------------
# ISS280. delete_branch identifica su objetivo por branch_id y su esquema RECHAZA
# project_id (unrecognized_keys). Con la regla anterior caia en "falta
# project_id" con una condicion imposible de cumplir: un bloqueo muerto, no una
# proteccion. Sigue fallando cerrado, pero la llave ahora es un branch_id
# anotado a mano en ramas-autorizadas-para-borrar.txt. Una rama que no este en
# esa lista NO se borra, aunque pertenezca al proyecto autorizado.
case "$tool" in
  *delete_branch)
    bid="$(printf '%s' "$payload" | jq -r '.tool_input.branch_id // empty' 2>/dev/null || true)"
    if ! printf '%s' "$bid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
      registrar "$tool" "rama:${bid:-<ninguna>}" "DENEGADA_branch_id_mal_formado"
      denegar "branch_id ausente o mal formado: '${bid:-<ninguno>}'. delete_branch exige un UUID." \
              "Borrado de rama BLOQUEADO: branch_id mal formado."
    fi
    # OJO: aqui NO se puede usar `tr -d '[:space:]'`. tr borra tambien los
    # saltos de linea y colapsa el archivo entero en un solo renglon, con lo que
    # `grep -Fxq` no casa nunca y TODA rama queda denegada. Probado: fallaba asi.
    # sed trabaja linea por linea y conserva los saltos.
    if [ -r "$LISTA_RAMAS" ] \
       && sed 's/#.*//; s/[[:space:]]//g' "$LISTA_RAMAS" | grep -Fxq "$bid"; then
      registrar "$tool" "rama:$bid" "PERMITIDA_rama_en_lista_explicita"
      permitir "Rama $bid anotada en ramas-autorizadas-para-borrar.txt y verificada con parent_project_ref=$PROYECTO_AUTORIZADO."
    fi
    registrar "$tool" "rama:$bid" "DENEGADA_rama_no_autorizada"
    denegar "La rama $bid no esta en ramas-autorizadas-para-borrar.txt. La guarda de Reto 13M solo borra ramas anotadas explicitamente." \
            "Borrado de rama BLOQUEADO: $bid no esta en la lista autorizada."
    ;;
esac

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
  permitir "Herramienta de Supabase que no apunta a ningun proyecto. Aprobada por la guarda de Reto 13M."
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
permitir "project_id $PROYECTO_AUTORIZADO verificado por la guarda de Reto 13M: es el unico proyecto autorizado. No hace falta preguntar."
