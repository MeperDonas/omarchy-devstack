#!/usr/bin/env bash
# Prueba de `devstack use`: el proyecto de casa, el que se usa cuando no hay otro
# (el widget lo usa si la terminal activa no está en un proyecto declarado).
# Corre en CI (sin Omarchy).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack"
for p in alpha beta; do
    printf '{"name":"%s","dir":"%s","services":[]}\n' "$p" "$tmp" >"$tmp/xdg/devstack/$p.json"
done

export XDG_CONFIG_HOME="$tmp/xdg"
DEF="$tmp/xdg/devstack/default"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

printf 'use (proyecto de casa)\n'

[[ $("$DEVSTACK" use) == "Sin proyecto de casa" ]] && ok "sin default lo dice" || bad "sin default lo dice"

"$DEVSTACK" use beta >/dev/null 2>&1
[[ $(<"$DEF") == beta ]] && ok "use <p> lo guarda" || bad "use <p> lo guarda"
[[ $("$DEVSTACK" use) == beta ]] && ok "use sin argumentos lo muestra" || bad "use sin argumentos lo muestra"

# con varios proyectos y sin nombre, es el que desempata
[[ $("$DEVSTACK" json | jq -r .project) == beta ]] && ok "el CLI lo usa para desempatar" || bad "el CLI lo usa para desempatar"
[[ $("$DEVSTACK" alpha json | jq -r .project) == alpha ]] && ok "un nombre explícito manda" || bad "un nombre explícito manda"

"$DEVSTACK" use noexiste >/dev/null 2>&1 && bad "use con proyecto inexistente falla" || ok "use con proyecto inexistente falla"
[[ $(<"$DEF") == beta ]] && ok "y no pisa el guardado" || bad "y no pisa el guardado"

# archivo apuntando a un proyecto que ya no existe: `use` avisa en vez de romper
printf 'borrado\n' >"$DEF"
"$DEVSTACK" use >/dev/null 2>&1 && bad "default roto: avisa" || ok "default roto: avisa"

"$DEVSTACK" use --clear >/dev/null 2>&1
[[ ! -e $DEF ]] && ok "--clear lo borra" || bad "--clear lo borra"
"$DEVSTACK" json >/dev/null 2>&1 && bad "sin default y varios proyectos: pide nombre" || ok "sin default y varios proyectos: pide nombre"

if ((fail)); then
    printf '\033[1;31muse: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32muse: todo bien\033[0m\n'
