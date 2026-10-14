#!/usr/bin/env bash
# Prueba del detector (lib/scan.sh): cada fixture debe producir exactamente los
# servicios, puertos, health y tareas esperados. Corre en CI.
#
# Los fixtures son repos de juguete que reproducen las formas reales:
#   two-package  backend Nest + Prisma, frontend Next, compose de postgres, .env
#                con PORT y una URL de API en el frontend
#   single-astro una sola app en la raíz
#   empty        nada reconocible (no debe inventar servicios)
#   documented   comandos documentados en AGENTS.md (el caso de los agentes)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEVSTACK="$PWD/bin/devstack"

fail=0

check() { # check <fixture> <filtro jq> <descripción>
    local fixture=$1 filter=$2 desc=$3 json
    json=$("$DEVSTACK" scan "test/fixtures/$fixture" --json 2>/dev/null || true)
    if [[ -n $json ]] && printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
        printf '\033[1;32m[ok]\033[0m   %s\n' "$desc"
    else
        printf '\033[1;31m[fail]\033[0m %s\n' "$desc" >&2
        printf '       json: %s\n' "${json:-<vacío>}" >&2
        fail=1
    fi
}

check_raw() { # check_raw <fixture> <texto esperado> <descripción>
    local fixture=$1 needle=$2 desc=$3 out
    out=$("$DEVSTACK" scan "test/fixtures/$fixture" 2>/dev/null || true)
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        printf '\033[1;32m[ok]\033[0m   %s\n' "$desc"
    else
        printf '\033[1;31m[fail]\033[0m %s (no encontré «%s»)\n' "$desc" "$needle" >&2
        fail=1
    fi
}

printf 'detector (lib/scan.sh)\n'

check two-package '[.services[] | select(.id=="db") | .port] == [5432]' "two-package: postgres del compose en :5432"
check two-package '[.services[] | select(.id=="db") | .container] == ["postgres-db"]' "two-package: contenedor declarado en el compose"
check two-package '[.services[] | select(.id=="api") | .cmd] == ["npm run start:dev"]' "two-package: comando del backend"
check two-package '[.services[] | select(.id=="api") | .port] == [3001]' "two-package: puerto del backend leído del .env"
check two-package '[.services[] | select(.id=="api") | .health] == ["http://localhost:3001/api/health"]' "two-package: health del backend"
check two-package '[.services[] | select(.id=="web") | .port] == [3000]' "two-package: puerto propio del frontend (no el del backend)"
check two-package '[.services[] | select(.id=="web") | .open] == [true]' "two-package: el frontend es el que abre el navegador"
check two-package '[.tasks[].id] | sort == ["migrate","seed","studio"]' "two-package: tareas de prisma"
check two-package '[.tasks[] | select(.id=="seed") | .needs] == [["db"]]' "two-package: la tarea seed declara que necesita la base"
check two-package '[.tasks[] | select(.id=="migrate") | .cmd] == ["npm run migrate:dev"]' "two-package: comando de migraciones"
check single-astro '[.services[0].port] == [4321]' "single-astro: puerto de astro"
check single-astro '[.services[0].id] == ["web"]' "single-astro: una sola app en la raíz"
check empty '(.services | length) == 0' "empty: no inventa servicios"
check documented '[.services[0].id] == ["api"]' "documented: express detectado"
check documented '[.services[0].port] == [3000]' "documented: puerto por defecto del servicio"
check_raw documented "npm run start" "documented: saca los comandos del AGENTS.md"
check_raw two-package "puerto 3001 ← .env" "two-package: muestra de dónde salió el puerto"
check_raw empty "no reconocí ningún stack" "empty: avisa que no reconoció nada"

if ((fail)); then
    printf '\033[1;31mdetector: hay fallos\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mdetector: todo bien\033[0m\n'
