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
  property string sortMode: "recency"
  property int selectedIndex: 0
  property string selectedID: ""
  property bool cursorActive: false
  property bool listing: true
  property bool refreshQueued: false
  property string pendingPath: ""
  property bool repoFormOpen: false
  // In-flight Herdr routing: createForHerdr marks a `timber create`
  // run that must notify instead of opening in Zed, and
  // pendingHerdrValue carries the name@repo for the success message.
  property bool createForHerdr: false
  property string pendingHerdrValue: ""
  // Two-phase delete: the value (name@repo) whose delete icon is
  // armed (red) and awaiting a second click; blank when nothing is
  // armed. Monochrome icons are unarmed and only arm on click.
  property string armedRemoveValue: ""

  // True while one of the `timber repo add` form fields owns keyboard
  // focus. The raw key handler below must let those keys through to the
  // focused field instead of treating them as list-filter input.
  readonly property bool formEditing: repoUrlField.activeFocus || repoNameField.activeFocus || repoAliasField.activeFocus
  readonly property bool formButtonFocused: addRepoButton.activeFocus || cancelRepoButton.activeFocus

  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int maxVisibleRows: 8
  readonly property int actionSize: Style.space(22)
  readonly property int actionsWidth: root.actionSize * 3 + Style.space(4) * 2
  readonly property real popupWidth: {
    var widest = 0
    for (var i = 0; i < displayModel.count; i++) {
      var item = displayModel.get(i)
      var nameWidth = rowFontMetrics.advanceWidth((item.kind === "create" ? "+ " : "") + item.value)
      var badgesWidth = badgeFontMetrics.advanceWidth(item.statusText) + badgeFontMetrics.advanceWidth(item.todoText)
      if (item.statusText && item.todoText) badgesWidth += Style.space(4)
      widest = Math.max(widest, nameWidth + badgesWidth)
    }
    // Row insets, gaps, reserved actions, popup padding, and rendering slop.
    var chrome = Style.space(48) + root.actionsWidth + panel.padding * 2
    return Math.max(Style.space(300), Math.min(widest + chrome, Style.space(600)))
  }
  readonly property int visibleRows: Math.max(1, Math.min(displayModel.count, root.maxVisibleRows))
  readonly property int listHeight: root.visibleRows * root.rowHeight + (root.visibleRows - 1) * Style.space(4)

  // The filesystem scan owns membership. Optional JSON enrichment supplies
  // Status/Todo badges without hiding rows if timber list fails.
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
    '    stamp=$(git -C "$d" log -1 --format=%ct 2>/dev/null) || stamp=$(stat -c %Y -- "$d" 2>/dev/null);',
    '    printf "W\\t%s@%s\\t%s\\t%s\\n" "$name" "$repo" "$d" "$stamp";',
    '  done;',
    'done;',
    'details=$(timber list --json 2>/dev/null) && printf "D\\t%s\\n" "$details";',
    'exit 0'
  ].join("\n")

  function refresh() {
    root.pendingPath = ""
    root.armedRemoveValue = ""
    root.filterText = ""
    root.selectedIndex = 0
    root.selectedID = ""
    root.cursorActive = false
    root.syncFilterField()
    root.refreshInBackground()
  }

  function refreshInBackground() {
    if (listProc.running) {
      root.refreshQueued = true
      return
    }
    listProc.running = true
  }

  function presentFromCache() {
    root.filterText = ""
    root.selectedIndex = 0
    root.selectedID = ""
    root.cursorActive = false
    root.rebuildDisplay()
    root.syncFilterField()
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.selectedID = ""
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
    var listing = TimberModel.parseListing(text)
    root.repos = listing.repos
    root.worktrees = listing.worktrees
    root.rebuildDisplay()
  }

  function rebuildDisplay() {
    // Any list change (filter edit, fresh listing) disarms delete.
    root.armedRemoveValue = ""
    var items = TimberModel.itemsForTerm(root.repos, root.worktrees, root.filterText, root.sortMode)
    displayModel.clear()
    for (var i = 0; i < items.length; i++) {
      displayModel.append(items[i])
    }
    root.selectedIndex = TimberModel.selectedItemIndex(items, root.selectedID)
    root.selectedID = items.length ? TimberModel.itemID(items[root.selectedIndex]) : ""
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  // Failures surface only here, never in the widget itself.
  function notifyFailure(subject, detail) {
    Util.execArgv([root.omarchyPath + "/bin/omarchy-notification-send", "-u", "critical", "--app-name", "Timber", "Timber " + subject + " failed", detail])
  }

  // Successes (Herdr space created) surface as a normal notification.
  function notify(subject, detail) {
    Util.execArgv([root.omarchyPath + "/bin/omarchy-notification-send", "--app-name", "Timber", "Timber " + subject, detail])
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
    root.armedRemoveValue = ""
    removeProc.command = ["timber", "remove", row.value]
    removeProc.running = true
  }

  // Two-phase delete: the first click only arms the row (its delete
  // icon turns red); a second click while armed runs `timber remove`.
  // Arming one row disarms any other.
  function armOrRemoveIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind !== "open") return
    if (removeProc.running) return
    var step = TimberModel.armOrConfirmRemove(root.armedRemoveValue, row.value)
    root.armedRemoveValue = step.armed
    if (step.confirmed) root.removeIndex(index)
  }

  // The row itself (click or Return) keeps the historical default:
  // open in Zed. The H icon routes to Herdr instead.
  function activateIndex(index) {
    root.openInZed(index)
  }

  function openInZed(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "open") {
      root.openPath(row.path)
    } else {
      if (createProc.running) return
      createProc.command = ["timber"].concat(TimberModel.createArgs(row.value, false))
      createProc.running = true
    }
  }

  function openInHerdr(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.kind === "open") {
      if (herdrProc.running) return
      root.pendingHerdrValue = row.value
      herdrProc.command = ["timber"].concat(TimberModel.herdrSpaceArgs(row.value))
      herdrProc.running = true
      root.close()
    } else {
      if (createProc.running) return
      root.createForHerdr = true
      root.pendingHerdrValue = row.value
      createProc.command = ["timber"].concat(TimberModel.createArgs(row.value, true))
      createProc.running = true
      root.close()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    root.closeRepoForm()
    root.presentFromCache()
    root.refreshInBackground()
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  // Moving selection to another row disarms a pending delete, so an
  // armed (red) icon can never trail behind navigation.
  onSelectedIndexChanged: {
    root.armedRemoveValue = ""
    if (selectedIndex >= 0 && selectedIndex < displayModel.count)
      root.selectedID = TimberModel.itemID(displayModel.get(selectedIndex))
  }

  Component.onCompleted: root.refreshInBackground()

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: if (!root.opened) root.refreshInBackground()
  }

  FontMetrics {
    id: rowFontMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
  }

  FontMetrics {
    id: badgeFontMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
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
        if (root.createForHerdr) {
          root.createForHerdr = false
          var created = root.pendingHerdrValue
          root.pendingHerdrValue = ""
          root.notify("Herdr space created", created || path)
          root.refresh()
        } else if (path) {
          root.setFilter("")
          root.openPath(path)
        } else root.notifyFailure("worktree create", "reported no path")
      } else {
        root.createForHerdr = false
        root.pendingHerdrValue = ""
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
    id: herdrProc
    stdout: StdioCollector {
      id: herdrStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: herdrStderr
      waitForEnd: true
    }
    onExited: function(code) {
      var value = root.pendingHerdrValue
      root.pendingHerdrValue = ""
      if (code === 0) {
        root.notify("Herdr space created", value)
      } else {
        var detail = String(herdrStderr.text || "").trim().split("\n").pop() || ("exit " + code)
        root.notifyFailure("herdr space", detail)
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
      id: listStdout
      waitForEnd: true
    }
    onExited: function(code) {
      root.listing = false
      if (code === 0) root.applyListOutput(listStdout.text)
      else root.notifyFailure("worktree list", "filesystem scan exited " + code)
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refreshInBackground)
      }
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
    // The quickfilter owns typing, so it takes focus on open (with a
    // visible text cursor) instead of the bare key catcher.
    focusTarget: filterField
    contentWidth: panel.fittedContentWidth(root.popupWidth)
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

        ButtonGroup {
          anchors.horizontalCenter: parent.horizontalCenter
          options: [
            { value: "recency", label: "Recency" },
            { value: "repo", label: "Repo" },
            { value: "worktree", label: "Worktree" }
          ]
          value: root.sortMode
          focusable: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) {
            root.sortMode = value
            root.rebuildDisplay()
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
            required property string statusText
            required property string todoText

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
              anchors.rightMargin: badgesRow.implicitWidth + actionsRow.implicitWidth + Style.space(28)
              verticalAlignment: Text.AlignVCenter
              text: (row.kind === "create" ? "+ " : "") + row.value
              color: root.foreground
              opacity: row.kind === "create" && !row.selected ? 0.72 : 1.0
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              elide: Text.ElideMiddle
            }

            Row {
              id: badgesRow
              anchors.right: actionsRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: row.statusText
                visible: text !== ""
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                textFormat: Text.PlainText
                text: row.todoText
                visible: text !== ""
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
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

            // Stacked after the row MouseArea so a press on one of
            // these wins and the row does not also activate underneath.
            // Z opens in Zed (creating first for `create` rows); H
            // routes to Herdr instead and posts a notification rather
            // than opening Zed.
            Row {
              id: actionsRow
              width: root.actionsWidth
              visible: row.selected
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              SvgActionButton {
                size: root.actionSize
                iconSource: "zed.svg"
                tooltipText: row.kind === "open" ? "Open in Zed" : "Create and open in Zed"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !createProc.running && !herdrProc.running
                onClicked: root.openInZed(row.index)
              }

              SvgActionButton {
                size: root.actionSize
                iconSource: "herdr.svg"
                tooltipText: row.kind === "open" ? "Open in Herdr" : "Create in Herdr"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !createProc.running && !herdrProc.running
                onClicked: root.openInHerdr(row.index)
              }

              PanelActionButton {
                size: root.actionSize
                opacity: row.kind === "open" ? 1 : 0
                // nf-md-delete (U+F0159): the destructive-row glyph the
                // first-party bluetooth panel uses for Forget.
                // Monochrome until the first click arms it; red while
                // armed, when a second click runs `timber remove`.
                iconText: "󰅙"
                tooltipText: (row.value === root.armedRemoveValue ? "Click again to remove " : "Remove ") + row.value
                foreground: row.value === root.armedRemoveValue ? Color.urgent : root.foreground
                fontFamily: root.fontFamily
                enabled: row.kind === "open" && !removeProc.running
                onClicked: root.armOrRemoveIndex(row.index)
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: displayModel.count === 0
          width: parent.width
          text: root.listing ? "Loading worktrees…" : (root.worktrees.length === 0 ? "No worktrees yet — type name@repo to create one" : "No matches")
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
