# Contributing

Thanks for looking. This is a small tool: a bash CLI that owns the state, an
Omarchy bar widget that reads it, and an installer that wires both. Keep it that
way — the CLI is the single source of truth, the widget never touches docker or
sudo by itself.

## Layout

| Path | What it is |
|---|---|
| `bin/devstack` | the CLI. All logic lives here: service order, waits, health checks, pidfiles, docker elevation, notifications, `--force` take-over, `menu` block generation |
| `Panel.qml` | the bar widget (an Omarchy `bar-widget` plugin). Reads `devstack json`, renders the four-colour state, one chip per service and the action buttons |
| `manifest.json` | the plugin manifest: id, entry point, and the settings schema (project, command, intervals, colours) |
| `install.sh` / `uninstall.sh` | plugin lifecycle + CLI + config + Omarchy menu block |
| `config/*.json` | example stacks. `demo.json` needs nothing but python3 |
| `docs/` | screenshot and the working-state GIF used by the README |

## Try it in one minute

```bash
export DEVDATA_CONFIG="$PWD/config"      # use the repo configs, not ~/.config
export DEVDATA_PROJECT=demo
bin/devstack demo up        # starts a python http.server on :8080
bin/devstack demo status
bin/devstack demo json | jq
bin/devstack demo down
```

No docker, no node, no Omarchy needed for that path: the CLI only requires bash,
`jq`, `curl` and `ss` (iproute2), and the Omarchy-specific bits
(`omarchy-launch-browser`, `omarchy-sudo-docker`, `notify-send`) are optional
and detected at runtime.

## Add a project config

Copy `config/example.json` to `~/.config/devstack/<name>.json` and describe the
services in start order:

- `type: "docker"` → `compose` (file, relative to `dir`) + `container` + `port`.
  Brought down last, `--keep-docker` leaves it.
- `type: "process"` (default) → `dir` + `cmd` + `port` + `health`. Started with
  `setsid` so `down` can kill the whole process group.
- `health` is what turns the state green and what `report_ready` checks before
  opening the browser. `open: true` marks the service the browser button opens.
- `tasks[]` are extra commands (`seed`, `migrate`, …) with `needs: ["db"]` to
  lift dependencies first.

## Testing the widget

The widget is a plugin folder, so the shell validates it for you:

```bash
omarchy plugin validate .                 # manifest schema + entry point exists
omarchy plugin add "$PWD" --yes          # install from a local clone
omarchy plugin enable meperdonas.devstack --section right
omarchy restart shell
omarchy plugin list                      # should say: enabled  third-party bar-widget
journalctl --user _PID=$(pgrep -x omarchy-shell) | grep "Plugin widget"
```

Two rules learned the hard way:

- A QML file that fails to load makes the shell log `Plugin widget <id> failed:
  …` and **drop the widget silently**. Always grep the journal after touching
  `Panel.qml`.
- Do not redeclare a property the `Panel` base already has (`bar`, `moduleName`,
  `settings`, `ipcTarget`), and do not declare the same property twice — QML
  refuses the whole file with `Duplicate property name`.

To screenshot the popup without clicking it, temporarily replace
`Component.onCompleted: refresh()` with `Component.onCompleted: { refresh(); open() }`
in the installed copy, `omarchy restart shell`, capture, then
`git -C ~/.config/omarchy/plugins/meperdonas.devstack reset --hard HEAD`.

## Code style

- bash: `set -euo pipefail`, quoting everywhere, no `cd` without a subshell,
  comments that explain *why* (the ordering rules, the `set -e` traps, the
  process-group guard). Every command substitution that can fail either gets
  `|| true` or is used in a condition — a failing `ps`/`grep` under `set -e`
  aborts the whole script silently.
- QML: 2-space indent, `readonly property` for derived state, settings through
  `setting("key", fallback)`, no animating anything that is not in the working
  state.
- Colours come from the manifest defaults (`colorOff`, `colorError`,
  `colorWorking`, `colorOk`) so users can restyle without editing QML.

## Commits and releases

- One logical change per commit, imperative subject, body explaining the *why*.
- Update `README.md` when behaviour changes; keep the English section and the
  Spanish section in sync.
- Bump `version` in `manifest.json` for anything users will pull with
  `omarchy plugin update`.
