#!/usr/bin/env bash
# uninstall.sh — deshace lo que hizo install.sh: el plugin de barra (y su entrada
# en el layout), el CLI, el bloque del menú y las configs del proyecto.
# No toca volúmenes de docker ni el repo clonado.
#
# Uso: ./uninstall.sh [--keep-config]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
OMARCHY_DIR="$CONFIG_HOME/omarchy"
DEVDATA_DIR="$CONFIG_HOME/devstack"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
MENU_JSONC="$OMARCHY_DIR/extensions/omarchy-menu.jsonc"
STAMP="$(date +%Y%m%d-%H%M%S)"
PLUGIN_ID="$(jq -r '.id' "$REPO/manifest.json" 2>/dev/null || echo "")"

log() { printf '\033[1;34m[pos]\033[0m  %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*" >&2; }

KEEP_CONFIG=0
[[ ${1:-} == --keep-config ]] && KEEP_CONFIG=1

if [[ -n $PLUGIN_ID ]] && [[ -d $OMARCHY_DIR/plugins/$PLUGIN_ID ]]; then
    # Quita el widget del layout y borra el plugin instalado.
    if command -v omarchy >/dev/null; then
        omarchy plugin remove "$PLUGIN_ID" --yes || warn "No pude quitarlo con omarchy plugin remove; borralo a mano de $OMARCHY_DIR/plugins"
    else
        rm -rf "${OMARCHY_DIR:?}/plugins/$PLUGIN_ID"
    fi
    ok "plugin $PLUGIN_ID quitado"
else
    log "El plugin no estaba instalado"
fi

rm -f "$BIN_DIR/devstack" && ok "CLI borrado" || log "El CLI no estaba en $BIN_DIR"

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
