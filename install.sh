#!/usr/bin/env bash
# install.sh — instala devstack en Omarchy:
#   · bin/devstack         → ~/.local/bin/devstack
#   · bar/modules/devstack.qml → ~/.config/omarchy/bar/modules/devstack.qml
#   · entradas en ~/.config/omarchy/shell.json (una instancia por proyecto)
#   · bloque en ~/.config/omarchy/extensions/omarchy-menu.jsonc  (--menu)
#   · configs de ejemplo → ~/.config/devstack/                    (--config FILE)
#
# Uso:
#   ./install.sh [--project NOMBRE] [--menu] [--config ARCHIVO] [--dry-run]
#
# Idempotente: se puede correr las veces que quieras; reemplaza sus propias
# entradas y nunca duplica. Siempre deja backup de los archivos que toca.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
OMARCHY_DIR="$CONFIG_HOME/omarchy"
DEVDATA_DIR="$CONFIG_HOME/devstack"
BIN_DIR="${PREFIX:-$HOME_DIR/.local}/bin"
MODULES_DIR="$OMARCHY_DIR/bar/modules"
SHELL_JSON="$OMARCHY_DIR/shell.json"
MENU_JSONC="$OMARCHY_DIR/extensions/omarchy-menu.jsonc"
STAMP="$(date +%Y%m%d-%H%M%S)"

PROJECT=""
PATCH_MENU=0
DRY=0
CONFIGS=()
block=""

log() { printf '\033[1;34m[pos]\033[0m  %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT="${2:-}"
            shift 2
            ;;
        --menu)
            PATCH_MENU=1
            shift
            ;;
        --config)
            CONFIGS+=("${2:-}")
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            warn "Opción desconocida: $1"
            usage
            exit 2
            ;;
    esac
done

run() {
    if ((DRY)); then
        printf '  [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

backup() {
    [[ -f $1 ]] || return 0
    run cp -a "$1" "$1.bak.$STAMP"
}

command -v jq >/dev/null || {
    warn "Falta jq (pacman -S jq)"
    exit 1
}

# ---------------------------------------------------------------- script + módulo

run mkdir -p "$BIN_DIR" "$MODULES_DIR" "$DEVDATA_DIR"
run install -m 755 "$REPO/bin/devstack" "$BIN_DIR/devstack"
ok "script → $BIN_DIR/devstack"

MODULE_SRC="~/.config/omarchy/bar/modules/devstack.qml"
run install -m 644 "$REPO/bar/modules/devstack.qml" "$MODULES_DIR/devstack.qml"
ok "módulo de barra → $MODULES_DIR/devstack.qml"

# ---------------------------------------------------------------- configs

if [[ ${#CONFIGS[@]} -gt 0 ]]; then
    for c in "${CONFIGS[@]}"; do
        [[ -r $c ]] || {
            warn "No puedo leer $c"
            continue
        }
        run cp -n "$c" "$DEVDATA_DIR/$(basename "$c")" 2>/dev/null || run cp -a "$c" "$DEVDATA_DIR/$(basename "$c")"
        ok "config → $DEVDATA_DIR/$(basename "$c")"
    done
fi

# Sin --project: si hay un único config, ese; si hay varios, no registro widget.
if [[ -z $PROJECT ]]; then
    found=()
    for f in "$DEVDATA_DIR"/*.json; do
        [[ -r $f ]] && found+=("$(basename "$f" .json)")
    done
    if [[ ${#found[@]} -eq 1 ]]; then
        PROJECT="${found[0]}"
    elif [[ ${#found[@]} -gt 1 ]]; then
        warn "Hay varios proyectos (${found[*]}): corré de nuevo con --project NOMBRE para registrar el widget"
    fi
fi

# ---------------------------------------------------------------- shell.json

if [[ -n $PROJECT ]]; then
    if [[ ! -f $SHELL_JSON ]]; then
        warn "No encuentro $SHELL_JSON; registrá el widget a mano"
    else
        backup "$SHELL_JSON"
        tmp=$(mktemp)
        jq --arg src "$MODULE_SRC" --arg proj "$PROJECT" '
          ({"id": "devstack", "type": "qml", "source": $src, "project": $proj}) as $entry
          | .bar.layout.right = (
              ((.bar.layout.right // []) | map(select((.id // "") != "devstack"))) as $r
              | ($r | map(.type // "") | rindex("qml")) as $i
              | if $i == null then ($r + [$entry]) else ($r[0:$i + 1] + [$entry] + $r[$i + 1:]) end
            )
        ' "$SHELL_JSON" >"$tmp"
        if jq -e . "$tmp" >/dev/null 2>&1; then
            run mv "$tmp" "$SHELL_JSON"
            ok "widget registrado en la barra (proyecto: $PROJECT)"
        else
            rm -f "$tmp"
            warn "El shell.json resultante no es válido; no lo toqué (backup en $SHELL_JSON.bak.$STAMP)"
        fi
    fi
fi

# ---------------------------------------------------------------- menú

if ((PATCH_MENU)); then
    if [[ ${#CONFIGS[@]} -eq 0 ]]; then
        warn "--menu necesita --config ARCHIVO (para saber qué proyecto generar)"
    else
        run mkdir -p "$(dirname "$MENU_JSONC")"
        [[ -f $MENU_JSONC ]] || run printf '{\n}\n' >"$MENU_JSONC"
        backup "$MENU_JSONC"
        block=$(mktemp)
        {
            printf '  // >>> devstack (generado por install.sh --menu)\n'
            for c in "${CONFIGS[@]}"; do
                DEVDATA_CONFIG="$DEVDATA_DIR" "$REPO/bin/devstack" "$(basename "$c" .json)" menu
            done
            printf '  // <<< devstack\n'
        } >"$block" 2>/dev/null || warn "No pude generar el bloque del menú"

        awk -v blockfile="$block" '
          BEGIN { block = ""; while ((getline line < blockfile) > 0) block = block line "\n" }
          /^[[:space:]]*\/\/ >>> devstack/ { skip = 1; next }
          /^[[:space:]]*\/\/ <<< devstack/ { skip = 0; next }
          skip { next }
          { n++; out[n] = $0 }
          END {
            last = 0
            for (i = n; i >= 1; i--) { t = out[i]; gsub(/[[:space:]]/, "", t); if (t == "}") { last = i; break } }
            for (i = 1; i <= n; i++) {
              if (i == last) printf "%s", block
              print out[i]
            }
          }
        ' "$MENU_JSONC" >"$block.out"
        if ! command -v python3 >/dev/null; then
            rm -f "$block.out"
            warn "Sin python3 no puedo validar el menú; generá el bloque con 'devstack <proyecto> menu' y pegalo a mano"
        elif python3 - "$block.out" <<'PY' >/dev/null 2>&1
import json, re, sys, pathlib
raw = pathlib.Path(sys.argv[1]).read_text()
stripped = re.sub(r",(\s*[}\]])", r"\1", re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M))
json.loads(stripped)
PY
        then
            run mv "$block.out" "$MENU_JSONC"
            ok "menú de Omarchy actualizado"
        else
            rm -f "$block.out"
            warn "El menú resultante no parsea; no lo toqué (backup en $MENU_JSONC.bak.$STAMP)"
        fi
        rm -f "$block"
    fi
fi

printf '\n'
ok "Listo. Recargá el shell con: omarchy restart shell"
printf '  %s\n' "probá: devstack list" "       devstack ${PROJECT:-<proyecto>} status"
