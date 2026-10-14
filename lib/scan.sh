#!/usr/bin/env bash
# scan.sh — capa de DETECCIÓN de devstack.
#
# Lee un repositorio (sólo lee: nunca ejecuta el proyecto, nunca eleva permisos,
# nunca copia valores de .env) y **propone** un stack: servicios docker y de
# proceso, puertos, health checks y tareas. Lo consume `devstack scan` (imprime
# la propuesta) y `devstack add` (la escribe en ~/.config/devstack/<nombre>.json).
#
# Cubre los stacks más usados — Node (Next, Nuxt, SvelteKit, Astro, Vite, CRA,
# Nest, Express/Fastify/Hono), Python (FastAPI/uvicorn, Django, Flask), Go, Rust,
# PHP/Laravel, Ruby/Rails — y los repos que hoy se trabajan *dentro de agentes*:
# AGENTS.md, CLAUDE.md, .claude/, .codex/, .opencode/, .pi/, .crush/, herdr*.
# De esos archivos también saca los comandos que el proyecto ya documenta
# (`npm run seed`, `docker compose up`, …) para confirmar o completar la
# propuesta: es la forma más fiable de saber cómo se levanta un proyecto.
#
# Requiere: bash + jq. Docker es opcional (si está, usa `docker compose config`
# para leer el compose con precisión; si no, lo lee con heurísticas).

# ---------------------------------------------------------------- utilidades

scan_jq() { jq -r "$1" "$2" 2>/dev/null || true; }

# ¿el archivo menciona alguna de estas palabras? (deps de package.json, etc.)
has_word() {
    local file=$1 pattern=$2
    [[ -r $file ]] || return 1
    grep -qE "$pattern" "$file" 2>/dev/null
}

# Directorios de primer/segundo nivel con un marcador, sin bajar a node_modules
# ni a directorios de agentes/build.
scan_dirs_with() {
    local root=$1 marker=$2 depth=${3:-2} d
    for d in "$root" "$root"/* "$root"/*/*; do
        [[ -d $d ]] || continue
        case $d in
            */node_modules* | */.git* | */dist* | */build* | */.next* | */vendor* | */target*) continue ;;
        esac
        # profundidad máxima
        local rel=${d#"$root"/}
        [[ $rel == "$d" ]] && rel=""
        local slashes=${rel//[!\/]/}
        (( ${#slashes} < depth )) || continue
        [[ -e $d/$marker ]] && printf '%s\n' "$d"
    done
}

# Primer valor de una clave en los .env del directorio (sin .example/.sample).
# Devuelve SÓLO el valor tal cual; el llamador decide si es seguro copiarlo.
env_value() {
    local dir=$1 key=$2 f
    for f in "$dir"/.env "$dir"/.env.*; do
        [[ -r $f ]] || continue
        case $f in
            *.example | *.sample | *.template | *.dist) continue ;;
        esac
        local v
        v=$(grep -E "^\s*(export\s+)?$key=" "$f" 2>/dev/null | head -1 | sed -E "s/^\s*(export\s+)?$key=//; s/^['\"]//; s/['\"]$//")
        [[ -n $v ]] && {
            printf '%s' "$v"
            return 0
        }
    done
    return 1
}

# Puerto PROPIO de un servicio: PORT, o el de APP_URL. Las URLs de API o de base
# de datos son de otro servicio (el frontend declara :3001 del backend, no el
# suyo): para eso está peer_api_port.
env_port() {
    local dir=$1 v p
    if v=$(env_value "$dir" PORT); then
        [[ $v =~ ^[0-9]+$ ]] && {
            printf '%s' "$v"
            return 0
        }
    fi
    if v=$(env_value "$dir" APP_URL); then
        p=$(printf '%s' "$v" | grep -oE ':[0-9]{2,5}(/|$)' | head -1 | tr -d ':/')
        [[ -n $p ]] && {
            printf '%s' "$p"
            return 0
        }
    fi
    return 1
}

# Puerto del backend tal como lo declara otro servicio: el frontend suele traer
# NEXT_PUBLIC_API_URL / VITE_API_URL apuntando a :3001. Devuelve "puerto<TAB>origen".
peer_api_port() {
    local root=$1 dir key v p
    for dir in "$root" "$root"/*; do
        [[ -d $dir ]] || continue
        case $dir in */node_modules* | */.git*) continue ;; esac
        for key in NEXT_PUBLIC_API_URL VITE_API_URL PUBLIC_API_URL API_URL; do
            v=$(env_value "$dir" "$key" 2>/dev/null) || continue
            p=$(printf '%s' "$v" | grep -oE ':[0-9]{2,5}(/|$)' | head -1 | tr -d ':/')
            [[ -n $p ]] && {
                printf '%s\t%s/%s' "$p" "${dir#"$root"/}" "$key"
                return 0
            }
        done
    done
    return 1
}

# ---------------------------------------------------------------- compose

# Un archivo compose → una línea TSV: tipo|id_contenedor|puerto|servicios|imagenes
scan_compose_file() {
    local file=$1 json
    if command -v docker >/dev/null 2>&1 && json=$(docker compose -f "$file" config --format json 2>/dev/null) && [[ -n $json ]]; then
        printf '%s' "$json" | jq -r '
          .services as $s
          | ($s | to_entries
             | map({name: .key,
                    image: (.value.image // ""),
                    container: (.value.container_name // .key),
                    port: ((.value.ports // []) | map(.published // empty) | map(tostring) | first // "")}))
          | {
              container: (map(select(.image | test("postgres|mysql|mariadb|mongo|redis|rabbit|minio|mailhog|memcached"))) | first // first).container,
              port: (map(select(.image | test("postgres|mysql|mariadb|mongo|redis|rabbit|minio|mailhog|memcached"))) | first // first).port,
              engine: (map(select(.image | test("postgres|mysql|mariadb|mongo|redis|rabbit|minio|mailhog|memcached"))) | first // first).image,
              count: (length),
              names: (map(.name) | join(","))
            } | "\(.container // "?")\u001f\(.port // "")\u001f\(.count)\u001f\(.names)\u001f\(.engine // "")"
        '
        return 0
    fi
    # Sin docker: heurística sobre el YAML.
    local container image port count names
    container=$(grep -E '^\s+container_name:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
    image=$(grep -E '^\s+image:' "$file" 2>/dev/null | grep -iE "postgres|mysql|mariadb|mongo|redis|rabbit|minio|mailhog" | head -1 | awk '{print $2}')
    port=$(grep -oE '"?[0-9]{2,5}:[0-9]{2,5}"?' "$file" 2>/dev/null | head -1 | cut -d: -f1 | tr -d '"')
    count=$(grep -cE '^\s{2}[a-zA-Z0-9_.-]+:' "$file" 2>/dev/null || echo 0)
    names=$(grep -oE '^\s{2}[a-zA-Z0-9_.-]+:' "$file" 2>/dev/null | tr -d ' :' | paste -sd, -)
    [[ -z $container ]] && container=$(printf '%s' "$names" | cut -d, -f1)
    printf '%s\t%s\t%s\t%s\t%s\n' "${container:-?}" "${port:-}" "${count:-0}" "${names:-}" "${image:-}"
}

# ---------------------------------------------------------------- node

# Servicio de proceso desde un package.json. Salida TSV:
# rol|carpeta|comando|puerto|health|etiqueta|tareas|evidencia
scan_node_package() {
    local dir=$1 rel=$2 deps cmd port health role label tasks="" ev="" engine=""
    deps=$(jq -r '((.dependencies//{}) + (.devDependencies//{})) | keys | join(" ")' "$dir/package.json" 2>/dev/null || true)
    local scripts
    scripts=$(jq -r '(.scripts//{}) | keys | join(" ")' "$dir/package.json" 2>/dev/null || true)

    pick_script() { # devuelve el primer script existente de la lista
        local want
        for want in "$@"; do
            [[ " $scripts " == *" $want "* ]] && {
                printf '%s' "$want"
                return 0
            }
        done
        return 1
    }

    case " $deps " in
        *" next "*) engine=next; role=web; port=3000; health=/ ;;
        *" nuxt "*) engine=nuxt; role=web; port=3000; health=/ ;;
        *" @sveltejs/kit "*) engine=sveltekit; role=web; port=5173; health=/ ;;
        *" astro "*) engine=astro; role=web; port=4321; health=/ ;;
        *" vite "*) engine=vite; role=web; port=5173; health=/ ;;
        *" react-scripts "*) engine=cra; role=web; port=3000; health=/ ;;
        *" @nestjs/core "*) engine=nest; role=api; port=3001; health=/health ;;
        *" express "* | *" fastify "* | *" hono "* | *" koa "*) engine=node-http; role=api; port=3000; health=/ ;;
        *) engine=node; role=api; port=3000; health=/ ;;
    esac

    # Comando: el convencional del framework y, si no, lo que declare el repo.
    case $engine in
        nest) cmd=$(pick_script start:dev dev start) ;;
        cra) cmd=$(pick_script start dev) ;;
        *) cmd=$(pick_script dev start:dev start serve) ;;
    esac
    [[ -n ${cmd:-} ]] || return 1
    cmd="npm run $cmd"

    # Puerto real: .env manda sobre la convención.
    local p
    if p=$(env_port "$dir"); then
        port=$p
        ev="puerto ${port} ← .env"
    fi

    # Prefijo global + ruta de salud (Nest): /api/health si el código lo declara.
    if [[ $engine == nest ]]; then
        if grep -rqs "setGlobalPrefix('api')\|setGlobalPrefix(\"api\")" "$dir/src" 2>/dev/null; then
            health=/api/health
            ev="$ev · setGlobalPrefix('api')"
        fi
    fi

    # Prisma → tareas típicas (migrate/seed/studio), si los scripts existen.
    if [[ -e $dir/prisma/schema.prisma ]] || has_word "$dir/package.json" '"(prisma|@prisma/client)"'; then
        local t
        for t in migrate:dev migrate seed studio; do
            [[ " $scripts " == *" $t "* ]] || continue
            case $t in
                migrate:dev | migrate) tasks="$tasks migrate" ;;
                seed) tasks="$tasks seed" ;;
                studio) tasks="$tasks studio" ;;
            esac
        done
        ev="$ev · prisma"
    fi

    label=${rel:-$(basename "$dir")}
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$role" "$rel" "$cmd" "$port" "$health" "$label" "${tasks# }" "$ev"
}

# ---------------------------------------------------------------- otros lenguajes

# Python / Go / Rust / PHP / Ruby: una línea TSV igual que scan_node_package.
scan_other_project() {
    local dir=$1 rel=$2
    if [[ -f $dir/manage.py ]]; then
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "python manage.py runserver" 8000 / "$rel" "migrate" "django"
        return 0
    fi
    if [[ -f $dir/pyproject.toml || -f $dir/requirements.txt ]]; then
        if has_word "$dir/pyproject.toml" "fastapi|uvicorn" || has_word "$dir/requirements.txt" "fastapi|uvicorn"; then
            local app=main
            [[ -f $dir/app.py ]] && app=app
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "uvicorn ${app}:app --reload" 8000 / "$rel" "" "fastapi"
            return 0
        fi
        if has_word "$dir/pyproject.toml" "flask" || has_word "$dir/requirements.txt" "flask"; then
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "flask run --debug" 5000 / "$rel" "" "flask"
            return 0
        fi
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "python -m ${rel:-app}" 8000 / "$rel" "" "python"
        return 0
    fi
    if [[ -f $dir/go.mod ]]; then
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "go run ." 8080 / "$rel" "" "go"
        return 0
    fi
    if [[ -f $dir/Cargo.toml ]]; then
        local cmd="cargo run"
        has_word "$dir/Cargo.toml" "trunk" && cmd="trunk serve"
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "$cmd" 8080 / "$rel" "" "rust"
        return 0
    fi
    if [[ -f $dir/composer.json ]] && has_word "$dir/composer.json" "laravel"; then
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "php artisan serve" 8000 / "$rel" "migrate" "laravel"
        return 0
    fi
    if [[ -f $dir/Gemfile ]] && has_word "$dir/Gemfile" "rails"; then
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' api "$rel" "bin/rails server" 3000 / "$rel" "migrate" "rails"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------- comandos documentados

# Comandos que el repo ya documenta (AGENTS.md, CLAUDE.md, README.md): la señal
# más fiable de cómo se levanta un proyecto, sobre todo en repos trabajados por
# agentes. Se usa para confirmar y para completar tareas.
scan_documented_commands() {
    local root=$1 f
    for f in "$root/AGENTS.md" "$root/CLAUDE.md" "$root/README.md" "$root/README.en.md" "$root/docs/README.md"; do
        [[ -r $f ]] || continue
        grep -ohE '^[[:space:]]*(npm run [a-zA-Z0-9:_-]+|docker compose [a-z-]+|uvicorn [a-zA-Z0-9_.:]+|python manage\.py [a-z]+|go run \.|cargo run|trunk serve|php artisan [a-z:-]+|bin/rails [a-z:-]+)' "$f" 2>/dev/null
    done | sort -u
}

# ---------------------------------------------------------------- propuesta

# Imprime el JSON del proyecto detectado. No escribe nada.
scan_project_json() {
    local root=$1 name=$2
    local services=() tasks=() evidence=() rel d line svc_obj

    # 1) docker: un servicio por archivo compose (el archivo es la unidad de up/down)
    local compose_files=()
    for d in "$root" "$root"/* "$root"/*/*; do
        [[ -d $d ]] || continue
        case $d in */node_modules* | */.git*) continue ;; esac
        for f in "$d"/docker-compose*.y*ml "$d"/compose*.y*ml; do
            [[ -r $f ]] && compose_files+=("$f")
        done
    done

    local db_port=""
    for f in "${compose_files[@]:-}"; do
        [[ -n $f ]] || continue
        rel=${f#"$root"/}
        IFS=$'\x1f' read -r cname cport ccount cnames cimage < <(scan_compose_file "$f")
        local id=db label="postgres"
        case $cimage in
            *mysql* | *mariadb*) label="mysql" ;;
            *mongo*) label="mongo" ;;
            *redis*) label="redis" ;;
            *rabbit*) label="rabbitmq" ;;
            *) label="postgres" ;;
        esac
        case $label in
            postgres | mysql | mongo) id=db ;;
            *) id=$label ;;
        esac
        # ids únicos si hay varios compose
        while [[ " ${services[*]:-} " == *"\"id\":\"$id\""* ]]; do id="$id-2"; done
        svc_obj="{\"id\":\"$id\",\"label\":\"$label\",\"type\":\"docker\",\"compose\":\"$rel\",\"container\":\"$cname\""
        [[ -n $cport ]] && svc_obj="$svc_obj,\"port\":$cport"
        services+=("$svc_obj}")
        [[ -z $db_port && -n $cport ]] && db_port=$cport
        evidence+=("docker: $rel → contenedor $cname${cport:+ en :$cport}${cimage:+ ($cimage)}${ccount:+ · $ccount contenedor/es: $cnames}")
    done

    # 2) procesos: node y otros lenguajes, en la raíz y en subcarpetas
    local seen_dirs=""
    local node_dirs=() other_dirs=()
    while IFS= read -r d; do node_dirs+=("$d"); done < <(scan_dirs_with "$root" package.json 1)
    for d in "$root" "$root"/*; do
        [[ -d $d ]] || continue
        case $d in */node_modules* | */.git*) continue ;; esac
        [[ -e $d/package.json ]] && continue
        if [[ -e $d/manage.py || -e $d/pyproject.toml || -e $d/requirements.txt || -e $d/go.mod || -e $d/Cargo.toml || -e $d/composer.json || -e $d/Gemfile ]]; then
            other_dirs+=("$d")
        fi
    done

    local api_port="" task_list="" documented peer_port="" peer_origin=""
    if peer=$(peer_api_port "$root"); then
        peer_port=${peer%%$'\x1f'*}
        peer_origin=${peer#*$'\x1f'}
    fi
    documented=$(scan_documented_commands "$root")

    for d in "${node_dirs[@]:-}"; do
        [[ -n $d ]] || continue
        rel=${d#"$root"/}
        [[ $rel == "$d" ]] && rel=""
        # clave no vacía: la raíz es "." (con rel="" el control de duplicados
        # hacía match con el patrón vacío y se saltaba la app de la raíz)
        local key="${rel:-.}"
        [[ " $seen_dirs " == *" $key "* ]] && continue
        seen_dirs="$seen_dirs $key"
        line=$(scan_node_package "$d" "$rel") || continue
        IFS=$'\x1f' read -r role rel cmd port health label tasks ev <<<"$line"
        [[ -n $health ]] || health="/"
        # Backend sin PORT propio: se usa el que declara el frontend (con evidencia).
        if [[ $role == api && -n $peer_port && $ev != *"puerto "* ]]; then
            port=$peer_port
            ev="puerto $port ← $peer_origin"
        fi
        api_port=$port
        svc_obj="{\"id\":\"$role\",\"label\":\"$label\",\"type\":\"process\",\"dir\":\"${rel}\",\"cmd\":\"$cmd\",\"port\":$port,\"url\":\"http://localhost:$port\",\"health\":\"http://localhost:$port$health\""
        [[ $role == web ]] && svc_obj="$svc_obj,\"open\":true"
        services+=("$svc_obj}")
        for t in $tasks; do
            [[ " $task_list " == *" $t "* ]] && continue
            task_list="$task_list $t"
        done
        evidence+=("${rel:-raíz}: $cmd en :$port${ev:+ · $ev}")
    done

    for d in "${other_dirs[@]:-}"; do
        [[ -n $d ]] || continue
        rel=${d#"$root"/}
        line=$(scan_other_project "$d" "$rel") || continue
        IFS=$'\x1f' read -r role rel cmd port health label tasks ev <<<"$line"
        services+=("{\"id\":\"$role\",\"label\":\"$label\",\"type\":\"process\",\"dir\":\"${rel}\",\"cmd\":\"$cmd\",\"port\":$port,\"url\":\"http://localhost:$port\",\"health\":\"http://localhost:$port$health\"}")
        api_port=${api_port:-$port}
        for t in $tasks; do
            [[ " $task_list " == *" $t "* ]] && continue
            task_list="$task_list $t"
        done
        evidence+=("${rel:-raíz}: $cmd en :$port${ev:+ · $ev}")
    done

    # 3) tareas: sólo las que existen como script/comando en el proyecto
    local needs=""
    [[ -n $db_port ]] && needs='"needs":["db"],'
    local task_arr=()
    for t in $task_list; do
        local tcmd="" tdir=""
        case $t in
            seed)
                # el script de seed del backend que lo tenga
                for d in "${node_dirs[@]:-}"; do
                    [[ -n $d ]] || continue
                    if jq -e --arg s "seed" '.scripts[$s] != null' "$d/package.json" >/dev/null 2>&1; then
                        tdir=${d#"$root"/}
                        [[ $tdir == "$d" ]] && tdir=""
                        tcmd="npm run seed"
                        break
                    fi
                done
                ;;
            migrate)
                for d in "${node_dirs[@]:-}"; do
                    [[ -n $d ]] || continue
                    if jq -e '.scripts["migrate:dev"] != null' "$d/package.json" >/dev/null 2>&1; then
                        tdir=${d#"$root"/}
                        [[ $tdir == "$d" ]] && tdir=""
                        tcmd="npm run migrate:dev"
                    elif jq -e '.scripts["migrate"] != null' "$d/package.json" >/dev/null 2>&1; then
                        tdir=${d#"$root"/}
                        [[ $tdir == "$d" ]] && tdir=""
                        tcmd="npm run migrate"
                    fi
                    [[ -n $tcmd ]] && break
                done
                [[ -z $tcmd && -f $root/manage.py ]] && tcmd="python manage.py migrate"
                [[ -z $tcmd && -f $root/bin/rails ]] && tcmd="bin/rails db:prepare"
                [[ -z $tcmd && -f $root/artisan ]] && tcmd="php artisan migrate"
                ;;
            studio)
                for d in "${node_dirs[@]:-}"; do
                    [[ -n $d ]] || continue
                    if jq -e '.scripts["studio"] != null' "$d/package.json" >/dev/null 2>&1; then
                        tdir=${d#"$root"/}
                        [[ $tdir == "$d" ]] && tdir=""
                        tcmd="npm run studio"
                        break
                    fi
                done
                ;;
        esac
        [[ -n $tcmd ]] || continue
        task_arr+=("{\"id\":\"$t\",\"label\":\"$t\",\"dir\":\"$tdir\",\"cmd\":\"$tcmd\",$needs\"post\":\"\"}")
    done

    # 4) nombre, JSON final y evidencias
    local pretty="${name:-$(basename "$root")}" svc_join="" task_join="" json
    [[ ${#services[@]} -gt 0 ]] && svc_join=$(printf '%s\n' "${services[@]}" | paste -sd, -)
    [[ ${#task_arr[@]} -gt 0 ]] && task_join=$(printf '%s\n' "${task_arr[@]}" | paste -sd, -)
    json="{\"name\":\"$pretty\",\"dir\":\"${root/#$HOME/~}\",\"services\":[$svc_join]"
    [[ -n $task_join ]] && json="$json,\"tasks\":[$task_join]"
    json="$json}"
    # Autochequeo: si el JSON no parsea, es un bug del detector y hay que verlo.
    if printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$json" | jq -c .
    else
        printf '# ERROR: el detector generó un JSON inválido: %s\n' "$json" >&2
        return 1
    fi
    printf '# evidencias\n'
    local e
    for e in "${evidence[@]:-}"; do
        [[ -n $e ]] && printf '#   %s\n' "$e"
    done
    if [[ -n $documented ]]; then
        printf '# comandos que el repo documenta:\n'
        while IFS= read -r c; do
            [[ -n $c ]] && printf '#   %s\n' "$c"
        done <<<"$documented"
    fi
    [[ ${#node_dirs[@]} -eq 0 && ${#other_dirs[@]} -eq 0 && ${#compose_files[@]} -eq 0 ]] &&
        printf '#   (no reconocí ningún stack: probá devstack init %s)\n' "$pretty"
    printf '# los valores de .env NO se copian: sólo se leen puertos y URLs locales\n'
}

# Nodo "tasks" con la forma que espera el CLI (id, label, dir, cmd, needs, post)
scan_project_config() {
    scan_project_json "$1" "$2" | sed '/^#/d'
}
