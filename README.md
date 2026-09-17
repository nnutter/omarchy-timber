# omarchy-timber

Omarchy overlay plugin that fronts [`timber`](https://github.com/nnutter/timber)
managed Git worktrees, mirroring `timber tui`: fuzzy-filter the existing
worktrees, type `name@repo` to create, `enter` to open in Zed.

## Requirements

- `timber` on `PATH`
- `zed` on `PATH` (opening runs `zed --new <worktree dir>`)

## Install

```bash
omarchy plugin add https://github.com/nnutter/omarchy-timber.git --enable --yes
```

By hand: copy this repo to
`~/.config/omarchy/plugins/io.github.nnutter.omarchy-timber/`, then
`omarchy-shell shell rescanPlugins` and
`omarchy plugin enable io.github.nnutter.omarchy-timber`.

Enabling drops the Timber icon on the bar (center when no section is
declared); move it with `omarchy bar move`. If you installed an older
overlay revision, disable and re-enable once so the entry moves from
`plugins[]` to the bar layout.

## Use

Click the bar icon or run:

```bash
omarchy-shell io.github.nnutter.omarchy-timber toggle
```

Keys: type to filter (`@` narrows to repos), `↓` / `↑` move,
`enter` open or create, `esc` clear then close. `tab` keeps the
platform meaning of switching to the next panel. Creating runs
`timber create --no-herdr name@repo` and opens the reported path in
Zed. Hover a worktree row for its `×`, which runs `timber remove`
(no `--force`); failures arrive only as a critical desktop
notification titled `Timber worktree <op> failed`.

To register a new repo, click the repo icon (GitHub's octicon-repo)
in the panel header. The form fronts `timber repo add`: enter the
remote URL or local path, with optional `--name` and `--alias`
overrides, then `enter` or `Add repository`. `esc` closes the form;
a successful add refreshes the repo list, while failures arrive as a
critical desktop notification titled `Timber repo add failed`.

Suggested Hyprland binding:

```ini
bind = SUPER, T, exec, omarchy-shell io.github.nnutter.omarchy-timber toggle
```

## Development

```bash
mise install      # dev tools (node; qmllint is unavailable via mise, see below)
mise run test     # TimberModel unit tests (runs check first)
mise run install  # test, then copy into ~/.config/omarchy/plugins and rescan
```

`qmllint` cannot come from mise (Qt is not in the registry) and
quickshell ships as a system package, so validate `Timber.qml` by
summoning the installed plugin on a live Omarchy machine.

## Notes

Worktrees are enumerated the way timber's own zsh completion does
(`timber repo list -q` plus a scan of `$TIMBER_WORKTREE_ROOT`) rather
than parsing `timber list`, whose styled table still emits ANSI under
`NO_COLOR` and fails as a whole when one worktree directory is missing.
