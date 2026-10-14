#!/usr/bin/env bash
# Prueba del servidor MCP: un diálogo JSON-RPC real por stdio. Verifica que el
# protocolo se respete (una respuesta por request, ninguna por notificación),
# que stdout sea sólo JSON, y que las tools devuelvan datos útiles.
# Corre en CI, sin red ni Omarchy.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MCP="$PWD/bin/devstack-mcp"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/xdg/devstack" "$tmp/proj"
printf '{"name":"My app","dir":"%s/proj","services":[{"id":"web","label":"web","type":"process","dir":"","cmd":"sleep 1","port":9}]}\n' \
    "$tmp" >"$tmp/xdg/devstack/myapp.json"
export XDG_CONFIG_HOME="$tmp/xdg"

{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"devstack_list","arguments":{}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"devstack_scan","arguments":{"path":"test/fixtures/two-package"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"devstack_status","arguments":{}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"no_existe","arguments":{}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"metodo/inexistente"}'
} | "$MCP" >"$tmp/out.jsonl" 2>"$tmp/err.log"

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

check() { # check <descripción> <filtro jq sobre todas las respuestas>
    local desc=$1 filter=$2
    if jq -s -e "$filter" "$tmp/out.jsonl" >/dev/null 2>&1; then ok "$desc"; else
        bad "$desc"
        sed 's/^/       /' "$tmp/out.jsonl" >&2
    fi
}

printf 'servidor MCP (stdio)\n'

# stdout limpio: cada línea es un JSON-RPC válido
if [[ $(wc -l <"$tmp/out.jsonl") -eq $(grep -c . "$tmp/out.jsonl") ]] &&
    jq -s -e 'all(.[]; .jsonrpc == "2.0")' "$tmp/out.jsonl" >/dev/null 2>&1; then
    ok "stdout es sólo JSON-RPC"
else
    bad "stdout tiene basura (¿logs por stdout?)"
fi

check "initialize responde la versión y el nombre del servidor" \
    'any(.[]; .id == 1 and .result.serverInfo.name == "devstack" and .result.protocolVersion == "2025-06-18")'
check "la notificación no recibe respuesta (7 requests → 7 respuestas)" \
    'length == 7'
check "tools/list trae 8 tools con schema" \
    'any(.[]; .id == 2 and (.result.tools | length) == 8 and all(.result.tools[]; (.name|length) > 0 and .inputSchema.type == "object"))'
check "devstack_list devuelve el proyecto declarado" \
    'any(.[]; .id == 3 and (.result.content[0].text | fromjson | .[0].project) == "myapp")'
check "devstack_scan propone los tres servicios del fixture" \
    'any(.[]; .id == 4 and (.result.content[0].text | fromjson | [.services[].id]) == ["db","api","web"])'
check "devstack_status sin proyecto devuelve todos" \
    'any(.[]; .id == 5 and (.result.content[0].text | fromjson | length) == 1)'
check "tool desconocida → isError" \
    'any(.[]; .id == 6 and .result.isError == true)'
check "método desconocido → error -32601" \
    'any(.[]; .id == 7 and .error.code == -32601)'

if ((fail)); then
    printf '\033[1;31mmcp: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mmcp: todo bien\033[0m\n'
