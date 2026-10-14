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
    local desc=$1 filter=$2 dir=$3 json
    json=$(cd "$dir" && "$DEVSTACK" here json 2>/dev/null || true)
    if [[ -n $json ]] && printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then ok "$desc"; else
        bad "$desc"
        printf '       json: %s\n' "${json:-<vacío>}" >&2
    fi
}

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
