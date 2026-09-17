import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TimberModel.js" as TimberModel

// Bar-widget frontend to `timber` (managed Git worktrees), following the
// agents panel: a bar icon plus an anchored popup. Toggle with the icon
// or `omarchy-shell io.github.nnutter.omarchy-timber toggle`.
Panel {
  id: root
  moduleName: "io.github.nnutter.omarchy-timber"
  ipcTarget: "io.github.nnutter.omarchy-timber"
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var repos: []
  property var worktrees: []
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property string pendingPath: ""
  property bool repoFormOpen: false

  // True while one of the `timber repo add` form fields owns keyboard
  // focus. The raw key handler below must let those keys through to the
  // focused field instead of treating them as list-filter input.
  readonly property bool formEditing: repoUrlField.activeFocus || repoNameField.activeFocus || repoAliasField.activeFocus
  readonly property bool formButtonFocused: addRepoButton.activeFocus || cancelRepoButton.activeFocus

  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int maxVisibleRows: 8
  readonly property int visibleRows: Math.max(1, Math.min(displayModel.count, root.maxVisibleRows))
  readonly property int listHeight: root.visibleRows * root.rowHeight + (root.visibleRows - 1) * Style.space(4)

  // Same enumeration timber's own zsh completion uses: registered repo
  // names plus a scan of the worktree root. `timber list` is avoided on
  // purpose — its styled two-per-row table still emits ANSI under
  // NO_COLOR and it enriches every row with git status, so one missing
  // worktree directory fails the whole listing.
  readonly property string listScript: [
    'data_home=${XDG_DATA_HOME:-$HOME/.local/share};',
    'root=${TIMBER_WORKTREE_ROOT:-$HOME/worktrees};',
    'repos=$(timber repo list -q 2>/dev/null);',
    'if [ -z "$repos" ]; then',
    '  repos=$(for d in "$data_home"/timber/repos/*.git; do [ -d "$d" ] || continue; b=${d##*/}; echo "${b%.git}"; done);',
    'fi;',
    'printf "%s\\n" "$repos" | while IFS= read -r repo; do [ -n "$repo" ] || continue; printf "R\\t%s\\n" "$repo"; done;',
    'shopt -s globstar nullglob;',
    'printf "%s\\n" "$repos" | while IFS= read -r repo; do [ -n "$repo" ] || continue;',
    '  for d in "$root/$repo"/**/"$repo"; do [ -e "$d/.git" ] || continue;',
    '    parent=${d%/*}; name=${parent#"$root/$repo"/}; [ -n "$name" ] || continue;',
    '    printf "W\\t%s@%s\\t%s\\n" "$name" "$repo" "$d";',
    '  done;',
    'done'
  ].join("\n")

  function refresh() {
    root.pendingPath = ""
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    listProc.running = true
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    root.syncFilterField()
  }

  // The quickfilter is a real TextField, so user edits must not fight a
  // text binding (typing would silently break it). The field pushes edits
  // via onTextEdited; this pulls programmatic state (open, clear, Escape,
  // type-to-filter while unfocused) back into the field.
  function syncFilterField() {
    if (filterField.text !== root.filterText) {
      filterField.text = root.filterText
      filterField.cursorPosition = filterField.text.length
    }
  }

  function select(delta) {
    if (displayModel.count === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function applyListOutput(text) {
    var repos = []
    var worktrees = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var parts = line.split("\t")
      if (parts[0] === "R" && parts[1]) repos.push({ name: parts[1] })
      else if (parts[0] === "W" && parts[1] && parts[2]) {
        var split = TimberModel.splitValue(parts[1])
        if (split) worktrees.push({ name: split.name, repo: split.repo, path: parts[2] })
      }
    }
    root.repos = repos
    root.worktrees = worktrees
    root.rebuildDisplay()
  }

  function rebuildDisplay() {
    var items = TimberModel.itemsForTerm(root.repos, root.worktrees, root.filterText)
    displayModel.clear()
    for (var i = 0; i < items.length; i++) {
      var path = ""
      if (items[i].kind === "open") {
        for (var j = 0; j < root.worktrees.length; j++) {
          if (root.worktrees[j].name === items[i].name && root.worktrees[j].repo === items[i].repo) {
            path = root.worktrees[j].path
            break
          }
        }
      }
      displayModel.append({ kind: items[i].kind, name: items[i].name, repo: items[i].repo, value: items[i].value, path: path })
    }
    if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  // Failures surface only here, never in the widget itself.
  function notifyFailure(subject, detail) {
    Util.execArgv([root.omarchyPath + "/bin/omarchy-notification-send", "-u", "critical", "--app-name", "Timber", "Timber " + subject + " failed", detail])
  }

  function openRepoForm() {
    root.repoFormOpen = true
    repoUrlField.clear()
    repoNameField.clear()
    repoAliasField.clear()
    Qt.callLater(function() { repoUrlField.forceActiveFocus() })
  }

  function closeRepoForm() {
    root.repoFormOpen = false
    repoUrlField.clear()
    repoNameField.clear()
    repoAliasField.clear()
  }

  function submitRepoForm() {
    if (repoAddProc.running) return
    var args = TimberModel.repoAddArgs(repoUrlField.text, repoNameField.text, repoAliasField.text)
    if (!args) {
      repoUrlField.forceActiveFocus()
      return
    }
    repoAddProc.command = ["timber"].concat(args)
    repoAddProc.running = true
  }

  function openPath(path) {
    if (!path) return
    root.close()
    Util.execArgv(["zed", "--new", path])
  }

  function removeIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "open") return
    if (removeProc.running) return
    removeProc.command = ["timber", "remove", row.value]
    removeProc.running = true
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "open") {
      root.openPath(row.path)
    } else {
      if (createProc.running) return
      createProc.command = ["timber", "create", "--no-herdr", row.value]
      createProc.running = true
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    root.closeRepoForm()
    root.refresh()
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  ListModel { id: displayModel }

  Process {
    id: createProc
    stdout: StdioCollector {
      id: createStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: createStderr
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        var path = String(createStdout.text || "").trim().split("\n").pop() || ""
        if (path) root.openPath(path)
        else root.notifyFailure("worktree create", "reported no path")
      } else {
        var detail = String(createStderr.text || "").trim().split("\n").pop() || ("exit " + code)
        root.notifyFailure("worktree create", detail)
      }
    }
  }

  Process {
    id: removeProc
    stdout: StdioCollector {
      id: removeStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: removeStderr
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        root.refresh()
      } else {
        var detail = String(removeStderr.text || "").trim().split("\n").pop() || ("exit " + code)
        root.notifyFailure("worktree remove", detail)
      }
    }
  }

  Process {
    id: repoAddProc
    stdout: StdioCollector {
      id: repoAddStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: repoAddStderr
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        root.closeRepoForm()
        root.refresh()
      } else {
        var detail = String(repoAddStderr.text || "").trim().split("\n").pop() || ("exit " + code)
        root.notifyFailure("repo add", detail)
      }
    }
  }

  Process {
    id: listProc
    command: ["bash", "-lc", root.listScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListOutput(text)
    }
    onExited: function(code) {
      if (code !== 0 && displayModel.count === 0)
        root.notifyFailure("worktree list", "timber repo list exited " + code)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) return
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    // Raw key handling instead of PanelKeyCatcher: the quickfilter is a
    // real TextField, so typing, Backspace, and cursor keys fall through
    // to the focused field while list navigation (Up/Down/PgUp/PgDn,
    // Return, Tab, Escape) is intercepted here. Tab keeps the platform
    // meaning of switching to the next panel, except on the repo form's
    // own buttons, where it walks the focus chain.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        // While a `timber repo add` field owns focus the keys belong to
        // that field (typing, Tab navigation, Enter to submit). Only
        // Escape is intercepted, to hand focus back to the panel.
        if (root.formEditing) {
          if (event.key === Qt.Key_Escape) {
            keyCatcher.forceActiveFocus()
            event.accepted = true
          }
          return
        }
        // The quickfilter field owns typing and cursor movement. Only
        // list-navigation keys are intercepted; Ctrl+U is kept as
        // clear-line because the field does not implement it natively.
        if (filterField.activeFocus) {
          if (event.key === Qt.Key_Escape) {
            if (root.repoFormOpen) root.closeRepoForm()
            else if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_U && event.modifiers === Qt.ControlModifier) {
            root.setFilter("")
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          }
          return
        }
        if (event.key === Qt.Key_Escape) {
          if (root.repoFormOpen) root.closeRepoForm()
          else if (root.filterText) root.setFilter("")
          else root.close()
          event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          // Type-to-filter while unfocused (e.g. after Escaping out of a
          // repo field): route the edit into the quickfilter and focus it
          // so continued typing flows naturally.
          root.setFilter(Util.editedFilter(event, root.filterText))
          filterField.forceActiveFocus()
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.select(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.select(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          if (root.formButtonFocused) return
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.select(-6)
          event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.select(6)
          event.accepted = true
        } else if (event.key === Qt.Key_Home) {
          root.selectAbsolute(0)
          event.accepted = true
        } else if (event.key === Qt.Key_End) {
          root.selectAbsolute(displayModel.count - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          // A focused form button activates on Return/Space itself.
          if (root.formButtonFocused) return
          if (root.cursorActive) root.activateIndex(root.selectedIndex)
          else if (displayModel.count > 0) root.cursorActive = true
          event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
          // Space activates a focused form button; anything else typed
          // while unfocused routes into the quickfilter like above.
          if (root.formButtonFocused && event.key === Qt.Key_Space) return
          root.setFilter(root.filterText + event.text)
          filterField.forceActiveFocus()
          event.accepted = true
        }
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: root.contentSpacing

        Row {
          width: parent.width
          height: root.headerHeight
          spacing: Style.space(8)

          TextField {
            id: filterField
            width: parent.width - repoAddButton.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "type worktree@repo"
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            foreground: root.foreground
            onTextEdited: root.setFilter(text)
          }

          // GitHub's New-repository mark: octicon-repo, shipped in Nerd
          // Fonts as oct-repo (U+F401) and rendered in the panel font like
          // every other kit glyph.
          PanelActionButton {
            id: repoAddButton
            iconText: "\uf401"
            tooltipText: root.repoFormOpen ? "Close repository form" : "Add repository (timber repo add)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            onClicked: {
              if (root.repoFormOpen) root.closeRepoForm()
              else root.openRepoForm()
            }
          }
        }

        // Form fronting `timber repo add <url-or-path> [--name] [--alias]`.
        // Enter in any field submits; Tab walks the fields and buttons via
        // the normal focus chain (the key handler above stands aside while
        // a field owns focus); Esc blurs a field, then closes the form.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.repoFormOpen

          TextField {
            id: repoUrlField
            width: parent.width
            placeholderText: "Remote URL or path"
            font.family: root.fontFamily
            foreground: root.foreground
            enabled: !repoAddProc.running
            onAccepted: root.submitRepoForm()
          }

          TextField {
            id: repoNameField
            width: parent.width
            placeholderText: "Name (optional, derived from URL)"
            font.family: root.fontFamily
            foreground: root.foreground
            enabled: !repoAddProc.running
            onAccepted: root.submitRepoForm()
          }

          TextField {
            id: repoAliasField
            width: parent.width
            placeholderText: "Alias (optional)"
            font.family: root.fontFamily
            foreground: root.foreground
            enabled: !repoAddProc.running
            onAccepted: root.submitRepoForm()
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              id: addRepoButton
              text: repoAddProc.running ? "Adding…" : "Add repository"
              tooltipText: "Run timber repo add"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.submitRepoForm()
            }

            Button {
              id: cancelRepoButton
              text: "Cancel"
              focusable: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.closeRepoForm()
            }
          }
        }

        ListView {
          id: resultList
          width: parent.width
          height: root.listHeight
          model: displayModel
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds

          // Plain item instead of CursorSurface: selection is a slim
          // accent marker at the leading edge, not a full-row box.
          delegate: Item {
            id: row
            required property int index
            required property string kind
            required property string value
            required property string path

            readonly property bool selected: root.cursorActive && index === root.selectedIndex

            width: ListView.view.width
            implicitHeight: root.rowHeight

            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(3)
              height: parent.height - Style.space(24)
              radius: width / 2
              color: Color.accent
              opacity: row.selected ? 1 : 0

              Behavior on opacity { NumberAnimation { duration: 90 } }
            }

            Text {
              textFormat: Text.PlainText
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(40)
              verticalAlignment: Text.AlignVCenter
              text: (row.kind === "create" ? "+ " : "") + row.value
              color: root.foreground
              opacity: row.kind === "create" && !row.selected ? 0.72 : 1.0
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideRight
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: {
                root.cursorActive = true
                root.selectedIndex = row.index
              }
              onClicked: {
                root.cursorActive = true
                root.selectedIndex = row.index
                root.activateIndex(row.index)
              }
            }

            // Stacked after the row MouseArea so its press wins and the
            // row does not also activate (open in Zed) underneath it.
            Item {
              visible: row.selected && row.kind === "open"
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(36)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                // nf-md-delete (U+F0159): the destructive-row glyph the
                // first-party bluetooth panel uses for Forget.
                text: "󰅙"
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              MouseArea {
                id: removeMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeIndex(row.index)
              }

              PanelToolTip {
                visible: removeMouse.containsMouse
                text: "Remove " + row.value
                fontFamily: root.fontFamily
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: displayModel.count === 0
          width: parent.width
          text: root.worktrees.length === 0 ? "No worktrees yet — type name@repo to create one" : "No matches"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
