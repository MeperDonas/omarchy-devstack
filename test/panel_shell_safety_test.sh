#!/usr/bin/env bash
# Guard-rail: ningún dato de afuera (rutas detectadas, nombres de proyecto, ids
# de servicio) puede entrar crudo en un comando de shell del widget. Todo va por
# shq(). Corre en CI; no necesita Omarchy.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
bad() {
    printf '\033[1;31m[fail]\033[0m %s\n' "$1" >&2
    fail=1
}

# Comprobación: extrae el texto de cada llamada a runCommand/runInTerminal (que
# puede ocupar varias líneas) y busca valores de afuera sin shq(.
check() {
    local file=$1
    python3 - "$file" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
unsafe = ['repo', 'candidate.dir', 'candidate.project', 'candidate.suggested',
          'modelData.project', 'openService', 'effectiveProject', 'resolvedProject']
problems = []
for call in re.finditer(r'run(?:Command|InTerminal)\(', src):
    i = call.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                break
    text = src[i:j + 1]
    stripped = re.sub(r'shq\([^()]*\)', '', text)
    for name in unsafe:
        # el valor aparece como expresión concatenada, no como texto
        if re.search(r'[+(]\s*' + re.escape(name) + r'\s*[,)+\-?]', stripped):
            problems.append((name, text.strip().splitlines()[0][:60]))
if problems:
    for name, where in problems:
        print(f'       {name} sin shq() en: {where}', file=sys.stderr)
    sys.exit(1)
PY
}

if check Panel.qml; then
    ok "ningún dato de afuera entra crudo en un comando de shell"
else
    bad "hay interpolación sin citar (ver arriba)"
fi

# Auto-prueba: el guard tiene que detectar una violación plantada.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'function x() { root.runCommand(cli + " add " + repo) }\n' >"$tmp/bad.qml"
if check "$tmp/bad.qml" 2>/dev/null; then
    bad "el guard no detecta una violación obvia"
else
    ok "el guard detecta una violación plantada"
fi

if ((fail)); then
    printf '\033[1;31mpanel: hay fallos de seguridad de shell\033[0m\n' >&2
    exit 1
fi
printf '\033[1;32mpanel: todo bien\033[0m\n'
