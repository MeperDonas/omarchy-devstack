#!/usr/bin/env bash
# Prueba de `devstack add`: declarar un proyecto (y no pisar lo que ya existe).
# Corre en CI (sin Omarchy).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack" "$tmp/uno" "$tmp/dos"
printf '{"name":"uno","scripts":{"dev":"vite --port 5173"},"dependencies":{"vite":"^5"}}\n' >"$tmp/uno/package.json"
printf '{"name":"dos","scripts":{"dev":"vite --port 5273"},"dependencies":{"vite":"^5"}}\n' >"$tmp/dos/package.json"

export XDG_CONFIG_HOME="$tmp/xdg"
CFG="$tmp/xdg/devstack/uno.json"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}
run() { "$DEVSTACK" add "$@" >"$tmp/out" 2>&1; printf '%s' "$?"; }

printf 'add (declarar un proyecto)\n'

[[ $(run "$tmp/uno") == 0 && -r $CFG ]] && ok "declara el stack detectado" || bad "declara el stack detectado"
[[ $(jq -r .dir "$CFG") == "$tmp/uno" ]] && ok "guarda el directorio" || bad "guarda el directorio"

# Repetirlo sobre el mismo directorio es la misma declaración, no un conflicto.
[[ $(run "$tmp/uno") == 0 ]] && ok "repetir el mismo add no falla (idempotente)" || bad "repetir el mismo add no falla"
grep -q "Ya estaba declarado" "$tmp/out" && ok "y lo dice claramente" || {
    bad "y lo dice claramente"
    sed 's/^/       /' "$tmp/out" >&2
}

# El mismo directorio con otro nombre: sí es un error (dos configs del mismo repo).
[[ $(run "$tmp/uno" --name otro) != 0 ]] && ok "el mismo dir con otro nombre avisa" || bad "el mismo dir con otro nombre avisa"
[[ $(run "$tmp/uno" --name otro --force) == 0 && -r "$tmp/xdg/devstack/otro.json" ]] \
    && ok "con --force sí lo declara" || bad "con --force sí lo declara"

# Un nombre ya tomado por otro directorio: no se pisa sin --force.
[[ $(run "$tmp/dos" --name uno) != 0 ]] && ok "un nombre tomado por otro dir no se pisa" || bad "un nombre tomado por otro dir no se pisa"

if ((fail)); then
    printf '\033[1;31madd: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32madd: todo bien\033[0m\n'
