#!/usr/bin/env bash
# install.sh — instala devstack en Omarchy:
#   · el plugin de barra (meperdonas.devstack) en ~/.config/omarchy/plugins/
#   · el CLI en ~/.local/bin/devstack
#   · una entrada en la barra para el proyecto elegido
#   · un bloque en ~/.config/omarchy/extensions/omarchy-menu.jsonc  (--menu)
#   · configs de ejemplo en ~/.config/devstack/                     (--config)
#
# Uso:
#   ./install.sh [--project NOMBRE] [--config ARCHIVO] [--menu]
#                [--section left|center|right] [--no-enable] [--dry-run]
#
# Idempotente: si el plugin ya está instalado lo actualiza (`omarchy plugin
# update`), no duplica la entrada de la barra, nunca pisa un config existente y
# deja backup de cada archivo que toca.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
OMARCHY_DIR="$CONFIG_HOME/omarchy"
PLUGINS_DIR="$OMARCHY_DIR/plugins"
DEVDATA_DIR="$CONFIG_HOME/devstack"
BIN_DIR="${PREFIX:-$HOME_DIR/.local}/bin"
SHELL_JSON="$OMARCHY_DIR/shell.json"
MENU_JSONC="$OMARCHY_DIR/extensions/omarchy-menu.jsonc"
STAMP="$(date +%Y%m%d-%H%M%S)"

PLUGIN_ID="$(jq -r '.id' "$REPO/manifest.json" 2>/dev/null || echo "")"
PROJECT=""
SECTION="right"
PATCH_MENU=0
DO_ENABLE=1
DRY=0
CONFIGS=()
block=""

log() { printf '\033[1;34m[pos]\033[0m  %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
    exit 1
}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT="${2:-}"
            shift 2
            ;;
        --config)
            CONFIGS+=("${2:-}")
            shift 2
            ;;
        --menu)
            PATCH_MENU=1
            shift
            ;;
        --section)
            SECTION="${2:-right}"
            shift 2
            ;;
        --no-enable)
            DO_ENABLE=0
            shift
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

command -v jq >/dev/null || die "Falta jq (pacman -S jq)"
command -v omarchy >/dev/null || die "Este instalador es para Omarchy (falta el comando omarchy)"
[[ -n $PLUGIN_ID ]] || die "No encuentro manifest.json con 'id' en $REPO"
[[ -f $REPO/Panel.qml ]] || die "Falta Panel.qml (el entry point del plugin)"
[[ $SECTION =~ ^(left|center|right)$ ]] || die "--section tiene que ser left, center o right"

# ---------------------------------------------------------------- plugin

if [[ -d $PLUGINS_DIR/$PLUGIN_ID ]]; then
    log "El plugin ya está instalado: lo actualizo"
    if ((DRY)); then
        printf '  [dry-run] omarchy plugin update %s --yes\n' "$PLUGIN_ID"
    else
        omarchy plugin update "$PLUGIN_ID" --yes || warn "No pude actualizar el plugin; sigo con el que está"
    fi
else
    log "Instalando el plugin de barra desde $REPO"
    run omarchy plugin add "$REPO" --yes
fi
ok "plugin → $PLUGINS_DIR/$PLUGIN_ID"

# ---------------------------------------------------------------- CLI

run mkdir -p "$BIN_DIR" "$DEVDATA_DIR"
run install -m 755 "$REPO/bin/devstack" "$BIN_DIR/devstack"
ok "CLI → $BIN_DIR/devstack"

# ---------------------------------------------------------------- configs

for c in "${CONFIGS[@]:-}"; do
    [[ -n $c ]] || continue
    [[ -r $c ]] || {
        warn "No puedo leer $c"
        continue
    }
    target="$DEVDATA_DIR/$(basename "$c")"
    if [[ -e $target ]]; then
        log "Ya existe $target; lo dejo como está"
    else
        run cp -a "$c" "$target"
        ok "config → $target"
    fi
done

if [[ -z $PROJECT ]]; then
    found=()
    for f in "$DEVDATA_DIR"/*.json; do
        [[ -r $f ]] && found+=("$(basename "$f" .json)")
    done
    case ${#found[@]} in
        1) PROJECT="${found[0]}" ;;
        0) ;;
        *) warn "Hay varios proyectos (${found[*]}): pasá --project NOMBRE para registrar el widget de uno" ;;
    esac
fi

# ---------------------------------------------------------------- barra

if ((DO_ENABLE)); then
    log "Habilitando el widget en la barra (sección $SECTION)"
    if ((DRY)); then
        printf '  [dry-run] omarchy plugin enable %s --section %s\n' "$PLUGIN_ID" "$SECTION"
    else
        omarchy plugin enable "$PLUGIN_ID" --section "$SECTION" || warn "No pude habilitarlo; agregalo a mano en $SHELL_JSON"
    fi
fi

# Ajustes por instancia (project) en la entrada de la barra: el plugin los lee
# vía setting("project", ""). Sin --project se usa el proyecto por defecto del
# CLI (el único configurado) y no hace falta tocar shell.json.
if [[ -n $PROJECT && -f $SHELL_JSON ]] && command -v jq >/dev/null; then
    if ((DRY)); then
        printf '  [dry-run] jq: project=%s en la entrada %s\n' "$PROJECT" "$PLUGIN_ID"
    else
        backup "$SHELL_JSON"
        tmp=$(mktemp)
        jq --arg id "$PLUGIN_ID" --arg proj "$PROJECT" '
          .bar.layout |= with_entries(
            .value |= map(if ((.id // "") | contains($id)) then . + {project: $proj} else . end)
          )
        ' "$SHELL_JSON" >"$tmp"
        if jq -e . "$tmp" >/dev/null 2>&1; then
            mv "$tmp" "$SHELL_JSON"
            ok "widget configurado con project: $PROJECT"
        else
            rm -f "$tmp"
            warn "No pude ajustar el project en $SHELL_JSON; el widget usará el proyecto por defecto"
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
                [[ -n $c ]] || continue
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
printf '  %s\n' "probá: devstack list" "       devstack ${PROJECT:-<proyecto>} status" "       omarchy plugin list"
