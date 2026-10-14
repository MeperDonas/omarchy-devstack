#!/usr/bin/env bash
# Prueba de `devstack all`: la vista de todos tus proyectos (y el aviso de
# puertos compartidos, que es lo que hace que dos stacks se contesten cruzado).
# Corre en CI (sin Omarchy).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack"
printf '{"name":"uno","dir":"%s","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":3901,"health":""},{"id":"db","label":"db","type":"docker","dir":"","compose":"","port":5432,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/uno.json"
printf '{"name":"dos","dir":"%s","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":3901,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/dos.json"

export XDG_CONFIG_HOME="$tmp/xdg"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

printf 'all (todos tus proyectos)\n'
out=$("$DEVSTACK" all status 2>&1)
printf '%s' "$out" | grep -q "puertos compartidos" && ok "avisa los puertos repetidos" || bad "avisa los puertos repetidos"
printf '%s' "$out" | grep -q ":3901" && ok "dice cuál puerto" || bad "dice cuál puerto"
printf '%s' "$out" | grep -q "uno" && printf '%s' "$out" | grep -q "dos" \
    && ok "nombra a los dos proyectos" || bad "nombra a los dos proyectos"

# El widget compara estos puertos: tienen que venir en el json.
json=$("$DEVSTACK" all json)
[[ $(printf '%s' "$json" | jq -r '.[] | select(.project=="uno") | .services[] | select(.id=="db") | .port') == 5432 ]] \
    && ok "el json trae el puerto de cada servicio" || bad "el json trae el puerto de cada servicio"

# Cada proyecto trae el resultado de su última acción (la fila lo usa para
# mostrar "levantando…" y soltarse cuando el CLI termina).
printf '{"name":"uno","dir":"%s","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"exit 1","port":4421,"wait":2}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/uno.json"
"$DEVSTACK" uno up >/dev/null 2>&1 || true
"$DEVSTACK" all json | jq -e '.[] | select(.project=="uno") | .lastResult.ok == false' >/dev/null \
    && ok "cada proyecto trae el resultado de su última acción" || bad "cada proyecto trae su último resultado"

# Sin puertos repetidos, el aviso no aparece.
rm "$tmp/xdg/devstack/dos.json"
"$DEVSTACK" all status 2>&1 | grep -q "puertos compartidos" && bad "sin repetidos no avisa" || ok "sin repetidos no avisa"

if ((fail)); then
    printf '\033[1;31mall: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mall: todo bien\033[0m\n'
