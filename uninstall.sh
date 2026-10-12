#!/usr/bin/env bash
# uninstall.sh — deshace lo que hizo install.sh: script, módulo de barra, su
# entrada en shell.json, su bloque en el menú y las configs del proyecto.
# No toca volúmenes de docker ni el repo clonado.

set -euo pipefail

HOME_DIR="${HOME}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
OMARCHY_DIR="$CONFIG_HOME/omarchy"
DEVDATA_DIR="$CONFIG_HOME/devstack"
BIN_DIR="${PREFIX:-$HOME_DIR/.local}/bin"
SHELL_JSON="$OMARCHY_DIR/shell.json"
MENU_JSONC="$OMARCHY_DIR/extensions/omarchy-menu.jsonc"
MODULE="$OMARCHY_DIR/bar/modules/devstack.qml"
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { printf '\033[1;34m[pos]\033[0m  %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }

KEEP_CONFIG=0
[[ ${1:-} == --keep-config ]] && KEEP_CONFIG=1

rm -f "$BIN_DIR/devstack" && ok "script borrado"
rm -f "$MODULE" && ok "módulo de barra borrado"

if [[ -f $SHELL_JSON ]] && command -v jq >/dev/null; then
    cp -a "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP"
    tmp=$(mktemp)
    jq 'if .bar.layout.right then .bar.layout.right |= map(select((.id // "") != "devstack")) else . end' \
        "$SHELL_JSON" >"$tmp" && mv "$tmp" "$SHELL_JSON"
    ok "entrada de la barra quitada (backup: $SHELL_JSON.bak.$STAMP)"
fi

if [[ -f $MENU_JSONC ]]; then
    cp -a "$MENU_JSONC" "$MENU_JSONC.bak.$STAMP"
    awk '
      /^[[:space:]]*\/\/ >>> devstack/ { skip = 1; next }
      /^[[:space:]]*\/\/ <<< devstack/ { skip = 0; next }
      skip { next }
      { print }
    ' "$MENU_JSONC" >"$MENU_JSONC.tmp" && mv "$MENU_JSONC.tmp" "$MENU_JSONC"
    ok "bloque del menú quitado (backup: $MENU_JSONC.bak.$STAMP)"
fi

if ((KEEP_CONFIG)); then
    log "Configs conservadas en $DEVDATA_DIR"
else
    rm -f "$DEVDATA_DIR"/*.json 2>/dev/null || true
    rmdir "$DEVDATA_DIR" 2>/dev/null || true
    ok "configs borradas"
fi

printf '\n'
ok "Listo. omarchy restart shell para recargar la barra"
