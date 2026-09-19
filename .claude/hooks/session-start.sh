#!/bin/bash
# =====================================================================
# SessionStart -- Reto 13M
# Deja el contenedor listo para que el linter y las pruebas corran sin
# tener que instalar nada a mano a mitad de una sesion.
#
# Este repo es 337 ficheros SQL y 5 de Python: la app legada de Streamlit
# (reto.py) y los ajustes de lab/. La superficie de prueba real es
# shadow-patches/ejecutables/verificar_reproducible_desde_git.sh, que a
# proposito NO se conecta a la base.
# =====================================================================
set -euo pipefail

# Solo en Claude Code on the web. En local no toca nada.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

PIP=(python3 -m pip install --quiet --disable-pip-version-check --root-user-action=ignore)

# 1. Dependencias de la app y del lab. Idempotente: pip no reinstala lo que ya esta.
if [ -f requirements.txt ]; then
  "${PIP[@]}" -r requirements.txt
fi

# 2. Herramientas de calidad. Van aparte de requirements.txt porque no son de la app.
"${PIP[@]}" ruff pytest

# 3. PYTHONPATH: validate_v2.py importa fit_crossleague, que esta en su misma
#    carpeta pero no es un paquete instalado.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PYTHONPATH="."' >> "$CLAUDE_ENV_FILE"
fi

echo "session-start: dependencias listas"
