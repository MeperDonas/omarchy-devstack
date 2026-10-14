#!/usr/bin/env bash
# Prueba de `devstack find`: buscar repos con stack detectable en tus carpetas.
# Corre en CI (sin Omarchy).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack" "$tmp/root/uno" "$tmp/root/dos/front" "$tmp/root/tres" "$tmp/root/nada"
printf '{"scripts":{"dev":"vite --port 5173"},"dependencies":{"vite":"^5"}}\n' >"$tmp/root/uno/package.json"
printf '{"scripts":{"dev":"next dev"},"dependencies":{"next":"16"}}\n' >"$tmp/root/dos/package.json"
printf '{"scripts":{"dev":"vite --port 3100"},"dependencies":{"vite":"^5"}}\n' >"$tmp/root/dos/front/package.json"
printf '{"services":{"db":{"image":"postgres:16"}}}\n' >"$tmp/root/tres/docker-compose.yml"
printf 'hola\n' >"$tmp/root/nada/notas.txt"
mkdir -p "$tmp/root/uno/.next" && printf '{"scripts":{"dev":"x"}}\n' >"$tmp/root/uno/.next/package.json"

# Un stack anidado que el padre no puede describir: el candidato es el hijo, con
# la ruta como etiqueta (así "backend" y "frontend" no se confunden entre sí).
mkdir -p "$tmp/root/caja/servicio"
printf '{"services":{"db":{"image":"postgres:16"},"web":{"image":"node:22"}}}\n' >"$tmp/root/caja/servicio/docker-compose.yml"

# `dos` ya declarado (con otro nombre) apuntando a su ruta
printf '{"name":"Dos","dir":"%s/root/dos","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":9,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/dos-proyecto.json"

export XDG_CONFIG_HOME="$tmp/xdg"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

printf 'find (buscar proyectos en tus carpetas)\n'
json=$("$DEVSTACK" find "$tmp/root" --json)

[[ $(printf '%s' "$json" | jq 'length') == 4 ]] && ok "encuentra los 4 repos (y no las subcarpetas ni .next)" \
    || bad "encuentra los 4 repos (y no las subcarpetas ni .next)"
[[ $(printf '%s' "$json" | jq -r '.[] | select(.suggested == "servicio") | .label') == "servicio" ]] \
    && ok "el stack anidado usa el nombre de su carpeta" || bad "el stack anidado usa el nombre de su carpeta"
[[ $(printf '%s' "$json" | jq -r '[.[].suggested] | sort | join(",")') == "dos-proyecto,servicio,tres,uno" ]] \
    && ok "sugiere un nombre por carpeta (y el del proyecto si ya está declarado)" || bad "sugiere un nombre por carpeta"
[[ $(printf '%s' "$json" | jq -r '.[] | select(.suggested == "dos-proyecto") | .declared') == true ]] \
    && ok "marca declarado al que ya lo está (aunque el nombre no coincida)" || bad "marca declarado al que ya lo está"
[[ $(printf '%s' "$json" | jq -r '.[] | select(.suggested == "tres") | .docker') == 1 ]] \
    && ok "cuenta los servicios docker" || bad "cuenta los servicios docker"
[[ $(printf '%s' "$json" | jq -r '.[0].declared') == true ]] \
    && ok "los declarados van primero" || bad "los declarados van primero"

# Dos carpetas con el mismo nombre en raíces distintas: la ruta desambigua.
mkdir -p "$tmp/raiz-a/front" "$tmp/raiz-b/front"
for r in raiz-a raiz-b; do
    printf '{"services":{"db":{"image":"postgres:16"},"web":{"image":"node:22"}}}\n' >"$tmp/$r/front/docker-compose.yml"
done
dup=$("$DEVSTACK" find "$tmp/raiz-a" "$tmp/raiz-b" --json)
[[ $(printf '%s' "$dup" | jq -r '[.[].label] | unique | length') == 2 ]] \
    && ok "dos carpetas homónimas no se confunden" || {
    bad "dos carpetas homónimas no se confunden"
    printf '       labels: %s\n' "$(printf '%s' "$dup" | jq -c '[.[].label]')" >&2
}
[[ $(printf '%s' "$json" | jq -r '.[] | select(.suggested == "nada") | .suggested') == "" ]] \
    && ok "no inventa proyectos donde no hay stack" || bad "no inventa proyectos donde no hay stack"
[[ $(printf '%s' "$json" | jq -r '.[] | select(.suggested == "dos-proyecto") | .services | length') -ge 1 ]] \
    && ok "el candidato trae sus servicios" || bad "el candidato trae sus servicios"

"$DEVSTACK" find "$tmp/root/nada" >/dev/null 2>&1 && bad "sin candidatos avisa y sale != 0" || ok "sin candidatos avisa y sale != 0"
DEVDATA_SEARCH_ROOTS="$tmp/root" "$DEVSTACK" find --json | jq -e 'length == 4' >/dev/null \
    && ok "DEVDATA_SEARCH_ROOTS define dónde buscar" || bad "DEVDATA_SEARCH_ROOTS define dónde buscar"

if ((fail)); then
    printf '\033[1;31mfind: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mfind: todo bien\033[0m\n'
