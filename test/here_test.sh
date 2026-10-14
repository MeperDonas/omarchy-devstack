#!/usr/bin/env bash
# Prueba de `devstack here`: resolver el proyecto de una ruta/terminal activa y
# reenviar los subcomandos. Corre en CI (sin Omarchy: `--window` cae a $PWD).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack" "$tmp/proj/sub" "$tmp/other" "$tmp/plain"
printf '{"name":"My app","dir":"%s/proj","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":9,"health":"http://localhost:9/"}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/myapp.json"
printf '{ "name": "other", "scripts": { "dev": "vite" } }\n' >"$tmp/other/package.json"

export XDG_CONFIG_HOME="$tmp/xdg"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}
expect() { # expect <descripción> <filtro jq> <dir>
    local desc=$1 filter=$2 dir=$3
    shift 3
    expect_args "$desc" "$filter" "$dir" "$@"
}

expect_args() { # expect_args <descripción> <filtro jq> <dir> [args...]
    local desc=$1 filter=$2 dir=$3
    shift 3
    local json
    json=$(cd "$dir" && "$DEVSTACK" here json "$@" 2>/dev/null || true)
    if [[ -n $json ]] && printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then ok "$desc"; else
        bad "$desc"
        printf '       json: %s\n' "${json:-<vacío>}" >&2
    fi
}

expect_args "--fallback responde ese proyecto cuando el foco no resuelve" \
    '.declared == true and .fallback == true and .project == "myapp" and (.services | length) == 1' "$tmp/plain" --fallback myapp
expect_args "--fallback inexistente no inventa nada: sigue el estado neutro" \
    '.declared == false and .repo == ""' "$tmp/plain" --fallback noexiste
expect_args "--fallback no pisa la resolución normal" \
    '.declared == true and .project == "myapp" and (.fallback // false) == false' "$tmp/proj" --fallback other

# --- proyecto de casa (`devstack use`) como último recurso -------------------
mkdir -p "$tmp/proj2"
printf '{"name":"Otro","dir":"%s/proj2","services":[{"id":"api","label":"api","type":"process","dir":"","cmd":"sleep 1","port":9,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/otro.json"

printf 'myapp\n' >"$tmp/xdg/devstack/default"
expect_args "--default usa el proyecto de casa si el foco no resuelve" \
    '.declared == true and .fallback == true and .project == "myapp"' "$tmp/plain" --default
expect_args "sin --default el archivo del proyecto de casa no se usa" \
    '.declared == false' "$tmp/plain"
expect_args "el foco manda sobre --default" \
    '.declared == true and .project == "otro"' "$tmp/proj2" --default
expect_args "el respaldo del ajuste manda sobre --default" \
    '.declared == true and .project == "otro"' "$tmp/plain" --default --fallback otro
printf 'borrado\n' >"$tmp/xdg/devstack/default"
expect_args "--default con proyecto borrado no inventa nada" \
    '.declared == false' "$tmp/plain" --default
rm -f "$tmp/xdg/devstack/default" "$tmp/xdg/devstack/otro.json"

# --- ventana activa: el foco se resuelve por el árbol de procesos -------------
# Omarchy sólo resuelve kitty (socket) o un hijo listado en /etc/shells; con
# ghostty devolvía $HOME. Acá se simula `hyprctl` para probar nuestra resolución.
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
fake_hyprctl() { # fake_hyprctl <pid>
    printf '#!/bin/bash\nprintf %%s %s\n' "'{\"pid\":$1}'" >"$fakebin/hyprctl"
    chmod +x "$fakebin/hyprctl"
}
( cd "$tmp/proj" && exec sleep 30 ) &
watch_proj=$!
( cd "$tmp/plain" && exec sleep 30 ) &
watch_plain=$!

fake_hyprctl "$watch_proj"
PATH="$fakebin:$PATH" expect_args "--window resuelve el foco por el árbol de procesos" \
    '.declared == true and .project == "myapp"' "$tmp/plain" --window
fake_hyprctl "$watch_plain"
PATH="$fakebin:$PATH" expect_args "--window con una ventana sin proyecto no inventa nada" \
    '.declared == false' "$tmp/plain" --window
kill "$watch_proj" "$watch_plain" 2>/dev/null || true
rm -rf "$fakebin"

printf 'here (resolver el proyecto de una ruta)\n'
expect "dentro de un proyecto declarado" '.declared == true and .project == "myapp"' "$tmp/proj"
expect "dentro de una subcarpeta del proyecto" '.declared == true and .project == "myapp"' "$tmp/proj/sub"
expect "en un repo reconocible sin declarar" '.declared == false and .suggested == "other" and (.repo | endswith("/other"))' "$tmp/other"
expect "en un directorio sin nada que declarar" '.declared == false and .repo == ""' "$tmp/plain"
expect "--window sin Omarchy cae al directorio actual" '.declared == true and .project == "myapp"' "$tmp/proj"
expect "el json declarado trae los servicios" '.services[0].id == "web"' "$tmp/proj"

# reenvío de subcomandos
if (cd "$tmp/other" && "$DEVSTACK" here up >/dev/null 2>&1); then
    bad "here up en un repo sin declarar debería fallar"
else
    ok "here up en un repo sin declarar se niega"
fi

if ((fail)); then
    printf '\033[1;31mhere: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mhere: todo bien\033[0m\n'
