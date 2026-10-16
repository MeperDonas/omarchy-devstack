#!/usr/bin/env bash
# Prueba del directorio de estado: nada de rutas predecibles en /tmp que otro
# usuario pueda preparar (symlink o carpeta ajena). Corre en CI, sin Omarchy.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack" "$tmp/st" "$tmp/evil"
printf '{"name":"p","dir":"%s/st","services":[]}\n' "$tmp" >"$tmp/xdg/devstack/p.json"
state="$tmp/devstack-$(id -u)"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}
run() { TMPDIR="$tmp" XDG_RUNTIME_DIR= XDG_CONFIG_HOME="$tmp/xdg" "$DEVSTACK" p "$@" 2>&1; }

printf 'runtime (directorio de estado seguro)\n'

# 1) el caso normal: se crea 0700 y es nuestro
run json >/dev/null
[[ -d $state && ! -L $state ]] && ok "crea el directorio de estado" || bad "no creó el directorio"
[[ $(stat -c %a "$state") == 700 ]] && ok "con permisos 0700" || bad "permisos distintos de 700 (son $(stat -c %a "$state"))"
rmdir "$state" 2>/dev/null || rm -rf "$state"

# 2) un symlink plantado en esa ruta: se rechaza y no se escribe a través
printf 'ORIGINAL\n' >"$tmp/evil/victim"
ln -s "$tmp/evil/victim" "$state"
out=$(run status || true)
printf '%s' "$out" | grep -q "es un symlink" && ok "rechaza un symlink en la ruta predecible" || {
    bad "no rechazó el symlink"
    printf '       %s\n' "$out" >&2
}
[[ $(cat "$tmp/evil/victim") == "ORIGINAL" ]] && ok "no escribió a través del symlink" || bad "escribió a través del symlink"
rm -f "$state"

# 3) una carpeta que no es nuestra: también se rechaza
mkdir -p "$state"
chmod 755 "$state"
if [[ $EUID -ne 0 ]]; then
    chown 0:0 "$state" 2>/dev/null || true
fi
out=$(run status || true)
if [[ $(stat -c %U "$state") == "$(id -un)" ]]; then
    ok "(sin otro dueño para probar: se salta)"
else
    printf '%s' "$out" | grep -q "no es tuyo" && ok "rechaza una carpeta ajena" || bad "no rechazó la carpeta ajena"
fi
rm -rf "$state"

# 4) con XDG_RUNTIME_DIR presente no se toca la ruta de /tmp (y `up` la usa)
mkdir -p "$tmp/run" "$tmp/st2"
printf '{"name":"q","dir":"%s/st2","services":[{"id":"w","label":"w","type":"process","dir":"","cmd":"sleep 5","port":4799,"wait":0}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/q.json"
TMPDIR="$tmp" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/xdg" "$DEVSTACK" q up >/dev/null 2>&1 || true
[[ -d $tmp/run/devstack/q ]] && ok "usa XDG_RUNTIME_DIR cuando está" || bad "no usó XDG_RUNTIME_DIR"
[[ ! -e $state ]] && ok "y no creó nada en la ruta de /tmp" || bad "creó $state de más"
TMPDIR="$tmp" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/xdg" "$DEVSTACK" q down >/dev/null 2>&1 || true

if ((fail)); then
    printf '\033[1;31mruntime: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mruntime: todo bien\033[0m\n'
