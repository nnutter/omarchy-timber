# omarchy-timber

Omarchy overlay plugin that fronts [`timber`](https://github.com/nnutter/timber) Git worktrees, with the shared features of [macos-timber](https://github.com/nnutter/macos-timber).
It lists both Timber-managed worktrees and arbitrary Git worktrees that Timber discovers for registered repositories.
Fuzzy-filter the existing worktrees, type `name@repo` to create, press `enter` to open in Zed, or use the trailing Zed/Herdr icons to open in Zed or a Herdr space.

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

The plugin loads worktrees at startup and refreshes once a minute while the panel is closed.
Opening shows the cached rows immediately, then refreshes without clearing the filter or changing the selected worktree.

Click the bar icon or run:

```bash
omarchy-shell io.github.nnutter.omarchy-timber toggle
```

The centered sort picker offers **Recency** (default), **Repo**, and **Worktree**.
Recency follows the order from `timber list --json --sort recency`.
Changing the sort preserves the selected row.

Existing rows show the `timber ls` Status and Todo badges:

- Status shows `merged`, `↑N`, `↓N`, or `error`, without the upstream suffix.
- Todo shows `done/total` only when checklist items exist.
- Listing failures or invalid JSON retain the cached rows and produce a critical desktop notification.

The popup grows to fit names and badges within width and screen bounds.
Long names truncate in the middle so the repository remains visible.
Row actions remain dimmed when unselected.
Leaving the list disarms deletion and dims every row.
Arrow keys restore active selection.

Keys: the header is a quickfilter field — type to filter
(`@` narrows to repos) with native cursor editing (`←` / `→`,
`home` / `end`, `backspace`, `ctrl+u` to clear), `↓` / `↑` move,
`enter` open or create in Zed, `esc` clear then close. `tab` keeps the
platform meaning of switching to the next panel. Creating runs
`timber create --no-herdr name@repo` and opens the reported path in
Zed. Each selected row also offers trailing logo icons: the Zed icon
opens in Zed (same as `enter`), while the Herdr icon routes to Herdr —
on a `name@repo` row
it runs `timber create --herdr name@repo`, on an existing worktree it
runs `timber herdr space --new name@repo` — the panel dismisses and a
`Timber Herdr space created` notification confirms instead of opening
Zed. Existing worktree
rows carry a third icon, `×`, which deletes in two phases: the first
click only arms it (the icon turns red), the second click runs
`timber remove` (no `--force`). Moving selection to another row,
editing the filter, or refreshing disarms; failures arrive only as a
critical desktop notification titled `Timber worktree <op> failed`.

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

`qmllint` cannot come from mise because Qt is not in the registry.
The check task uses the system `qmllint` when available.
Quickshell also ships as a system package.
Validate `Panel.qml` on a live Omarchy machine to check rendering, keyboard navigation, mouse-leave behavior, scrolling, and screen bounds.

## Notes

`timber list --json --sort recency` supplies worktree membership, paths, badges, and recency order.
The plugin does not assume a directory layout or scan `$TIMBER_WORKTREE_ROOT`.
`timber repo list -q` supplies create suggestions, including repositories with no worktrees.
If either command fails, the plugin retains its cached listing.

Omarchy owns the bar, plugin enablement, and shell startup.
The macOS Quit menu, Open at Login toggle, app icon, and packaging have no plugin equivalent.
The Omarchy repository form retains its optional alias field.
