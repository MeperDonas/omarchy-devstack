#!/usr/bin/env bash
# Prueba de `devstack <p> port`: variar el puerto de un servicio del config y
# hacer que el servicio se entere ({port} en el cmd, PORT en el entorno).
# Corre en CI (sin Omarchy).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/xdg/devstack" "$tmp/p" "$tmp/otro"
printf '#!/bin/bash\necho "arg=$1 PORT=$PORT" >"%s/p/out.txt"\nsleep 30\n' "$tmp" >"$tmp/p/probe.sh"
printf '{"name":"p","dir":"%s/p","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"npm run dev","port":4400,"url":"http://localhost:4400","health":"http://localhost:4400/"},{"id":"db","label":"db","type":"docker","dir":"","compose":"","port":4432,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/p.json"
printf '{"name":"otro","dir":"%s/otro","services":[{"id":"x","label":"x","type":"process","dir":"","cmd":"sleep 1","port":4401,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/otro.json"
# proyecto con dos servicios: --auto no puede elegir el puerto del otro servicio
printf '{"name":"gemelo","dir":"%s/p","services":[{"id":"api","label":"api","type":"process","dir":"","cmd":"sleep 1","port":4402,"health":""},{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":4403,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/gemelo.json"

export XDG_CONFIG_HOME="$tmp/xdg"
CFG="$tmp/xdg/devstack/p.json"
port_of() { jq -r --arg id "$1" '.services[] | select(.id == $id) | .port' "$CFG"; }

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

printf 'port (variar el puerto de un servicio)\n'

# El bug que rompió una config real: --auto elegía el puerto del backend del
# MISMO proyecto para el frontend.
"$DEVSTACK" gemelo port --auto web >/dev/null 2>&1
[[ $(jq -r '.services[] | select(.id=="web") | .port' "$tmp/xdg/devstack/gemelo.json") != 4402 ]] \
    && ok "--auto no elige el puerto de otro servicio del mismo proyecto" \
    || bad "--auto no elige el puerto de otro servicio del mismo proyecto"
"$DEVSTACK" gemelo port --to 4402 api >/dev/null 2>&1 && bad "mismo proyecto: no se pisa" || ok "mismo proyecto: no se pisa"

# Dos servicios del mismo proyecto con el mismo puerto: se avisa.
printf '{"name":"dup","dir":"%s/p","services":[{"id":"a","label":"a","type":"process","dir":"","cmd":"sleep 1","port":4404,"health":""},{"id":"b","label":"b","type":"process","dir":"","cmd":"sleep 1","port":4404,"health":""}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/dup.json"
"$DEVSTACK" all status 2>&1 | grep -q ":4404" && ok "avisa puertos repetidos dentro de un proyecto" \
    || bad "avisa puertos repetidos dentro de un proyecto"
rm -f "$tmp/xdg/devstack/dup.json"

"$DEVSTACK" p port --dry-run web >/dev/null 2>&1
[[ $(port_of web) == 4400 ]] && ok "--dry-run no toca el config" || bad "--dry-run no toca el config"

"$DEVSTACK" p port --to 4600 web >/dev/null 2>&1
[[ $(port_of web) == 4600 ]] && ok "--to cambia el puerto" || bad "--to cambia el puerto"
[[ $(jq -r '.services[0].url' "$CFG") == "http://localhost:4600" ]] && ok "reescribe la url" || bad "reescribe la url"
[[ $(jq -r '.services[0].health' "$CFG") == "http://localhost:4600/" ]] && ok "reescribe el health" || bad "reescribe el health"
[[ $(jq -r '.services[0].cmd' "$CFG") == "npm run dev -- --port {port}" ]] && ok "el cmd pasa el puerto ({port})" || bad "el cmd pasa el puerto"

"$DEVSTACK" p port --to 4600 web >/dev/null 2>&1 && bad "el mismo puerto se rechaza" || ok "el mismo puerto se rechaza"

# Elegir libre: no pisa lo que declara otro proyecto ni lo que ya escucha.
"$DEVSTACK" p port --auto web >/dev/null 2>&1
new=$(port_of web)
[[ $new != 4600 && $new != 4401 ]] && ok "--auto elige uno libre (no el de otro proyecto)" || bad "--auto elige uno libre"

"$DEVSTACK" p port --to 4401 web >/dev/null 2>&1 && bad "un puerto de otro proyecto se rechaza" || ok "un puerto de otro proyecto se rechaza"
"$DEVSTACK" p port --to 4401 --force web >/dev/null 2>&1 && ok "con --force sí" || bad "con --force sí"
"$DEVSTACK" p port --to 4700 db >/dev/null 2>&1 && bad "docker se rechaza (su puerto lo define el compose)" || ok "docker se rechaza"
[[ $(port_of db) == 4432 ]] && ok "y no le toca el config" || bad "y no le toca el config"

# El servicio se entera: {port} sustituido en el cmd y PORT exportado.
# (el servicio docker se va: su rechazo ya se probó y `down` no debe llamar a docker)
jq 'del(.services[] | select(.id == "db"))' "$CFG" >"$CFG.new" && mv "$CFG.new" "$CFG"
"$DEVSTACK" p port --to 4701 db >/dev/null 2>&1 || true
jq '(.services[] | select(.id == "web")) |= (.cmd = "bash probe.sh {port}" | .port = 4701 | .wait = 2)' "$CFG" >"$CFG.new" && mv "$CFG.new" "$CFG"
"$DEVSTACK" p up web >/dev/null 2>&1 || true
sleep 1
[[ $(cat "$tmp/p/out.txt" 2>/dev/null) == "arg=4701 PORT=4701" ]] \
    && ok "el servicio recibe {port} y PORT" || {
    bad "el servicio recibe {port} y PORT"
    printf '       out: %s\n' "$(cat "$tmp/p/out.txt" 2>/dev/null)" >&2
}
"$DEVSTACK" p down >/dev/null 2>&1 || true

# El resultado de la acción queda en el json (el widget lo usa para no quedarse
# "levantando" cuando el CLI ya terminó).
jq '(.services[] | select(.id == "web")) |= (.cmd = "exit 1" | .wait = 2)' "$CFG" >"$CFG.new" && mv "$CFG.new" "$CFG"
"$DEVSTACK" p up web >/dev/null 2>&1 || true
"$DEVSTACK" p json | jq -e '.lastResult.ok == false and (.lastResult.detail | length > 0)' >/dev/null \
    && ok "json trae el resultado de la acción (para no quedarse levantando)" \
    || bad "json trae el resultado de la acción"

# Un servicio que muere por una dependencia faltante: el mensaje (y la
# notificación) tienen que decir qué hacer, no sólo "no arrancó".
mkdir -p "$tmp/sin-deps"
printf '{"scripts":{"dev":"next dev"}}\n' >"$tmp/sin-deps/package.json"
printf '{"name":"deps","dir":"%s/sin-deps","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"next dev","port":4411,"wait":2}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/deps.json"
out=$("$DEVSTACK" deps up 2>&1 || true)
printf '%s' "$out" | grep -q 'npm install' && ok "el error dice qué hacer (npm install)" \
    || { bad "el error dice qué hacer (npm install)"; printf '       %s\n' "$out" >&2; }
"$DEVSTACK" deps json | jq -e '.lastResult.ok == false and (.lastResult.detail | test("npm install"))' >/dev/null \
    && ok "y el json lo lleva para el widget" || bad "y el json lo lleva para el widget"

if ((fail)); then
    printf '\033[1;31mport: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mport: todo bien\033[0m\n'
