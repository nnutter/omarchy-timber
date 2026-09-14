#!/usr/bin/env bash
# Lint plugin QML with qmllint. Exits non-zero on parse errors (255);
# the missing-property/signal-handler warnings qmllint emits for
# host-injected members (bar, Style singletons) also appear for
# first-party panels and do not fail the run. Without qmllint
# installed the lint skips so the task stays runnable off-machine.
set -u

file="${1:-Panel.qml}"

qmllint=""
for candidate in qmllint /usr/lib/qt6/bin/qmllint /lib64/qt6/bin/qmllint /lib/qt6/bin/qmllint; do
  if command -v "$candidate" >/dev/null 2>&1; then
    qmllint="$candidate"
    break
  fi
done

if [[ -z $qmllint ]]; then
  echo "qml_lint: qmllint not found; skipping QML lint" >&2
  exit 0
fi

args=()
shell_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
if [[ -f $shell_dir/Commons/qmldir && -f $shell_dir/Ui/qmldir ]]; then
  mapdir=$(mktemp -d)
  trap 'rm -rf "$mapdir"' EXIT
  mkdir -p "$mapdir/qs"
  ln -s "$shell_dir/Commons" "$mapdir/qs/Commons"
  ln -s "$shell_dir/Ui" "$mapdir/qs/Ui"
  args+=(-I "$mapdir")
fi

exec "$qmllint" "${args[@]}" "$file"
