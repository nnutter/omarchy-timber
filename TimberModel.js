// Pure filter logic for the timber overlay, ported from timber's
// tui_create_wizard.go (wizardItemsForTerm, filterWizardWorktrees).
// No QML dependencies so the matching stays testable in isolation.
//
// repos:    [{ name: "timber" }]
// worktrees:[{ name: "feature/login", repo: "timber" }]
// items:    [{ kind: "open"|"create", name, repo, value: "name@repo" }]

// R-prefixed repository names, then D-prefixed timber list --json output.
// JSON owns membership and paths. Reject invalid data before replacing cache.
function parseListing(text) {
  var repos = []
  var worktrees = []
  var lines = String(text || "").split("\n")
  var dataIndex = -1
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].slice(0, 2) === "D\t") {
      dataIndex = i
      break
    }
    if (lines[i].slice(0, 2) === "R\t" && lines[i].length > 2)
      repos.push({ name: lines[i].slice(2) })
  }
  if (dataIndex === -1) throw new Error("Missing worktree JSON")
  var rows = JSON.parse(lines.slice(dataIndex).join("\n").slice(2))
  if (!Array.isArray(rows)) throw new Error("Expected a worktree JSON array")
  for (var j = 0; j < rows.length; j++) {
    var row = rows[j]
    if (!row || typeof row.name !== "string" || !row.name ||
        typeof row.repo !== "string" || !row.repo ||
        typeof row.path !== "string" || !row.path)
      throw new Error("Invalid worktree JSON record")
    worktrees.push({ name: row.name, repo: row.repo, path: row.path,
      statusText: listStatusText(row), todoText: todoText(row) })
  }
  return { repos: repos, worktrees: worktrees }
}

// Case-insensitive fuzzy match: every char of term appears in order.
function fuzzyMatch(term, target) {
  var t = String(term || "").toLowerCase()
  var s = String(target || "").toLowerCase()
  if (!t) return { matched: true, indexes: [] }
  var indexes = []
  var pos = 0
  for (var i = 0; i < t.length; i++) {
    var found = s.indexOf(t[i], pos)
    if (found === -1) return { matched: false, indexes: [] }
    indexes.push(found)
    pos = found + 1
  }
  return { matched: true, indexes: indexes }
}

function filterTerm(term, targets) {
  var out = []
  if (!term) {
    for (var i = 0; i < targets.length; i++) out.push({ index: i, matchedIndexes: [] })
    return out
  }
  for (var j = 0; j < targets.length; j++) {
    var m = fuzzyMatch(term, targets[j])
    if (m.matched) out.push({ index: j, matchedIndexes: m.indexes })
  }
  return out
}

function cutLast(value, sep) {
  var s = String(value || "")
  var i = s.lastIndexOf(sep)
  if (i === -1) return { before: s, after: "", qualified: false }
  return { before: s.slice(0, i), after: s.slice(i + 1), qualified: true }
}

function worktreeValue(worktree) {
  return worktree.name + "@" + worktree.repo
}

function hasWorktree(worktrees, name, repo) {
  for (var i = 0; i < worktrees.length; i++) {
    if (worktrees[i].name === name && worktrees[i].repo === repo) return true
  }
  return false
}

function hasRepository(repos, name) {
  for (var i = 0; i < repos.length; i++) {
    if (repos[i].name === name) return true
  }
  return false
}

// Mirror filterWizardWorktrees: filter on the worktree half, then when the
// term holds `@`, intersect with the repo-half matches.
function filterWorktrees(term, worktrees) {
  var values = []
  for (var i = 0; i < worktrees.length; i++) values.push(worktreeValue(worktrees[i]))

  var worktreeTargets = []
  var repoTargets = []
  for (var j = 0; j < values.length; j++) {
    var parts = cutLast(values[j], "@")
    worktreeTargets.push(parts.before)
    repoTargets.push(parts.after)
  }

  var termParts = cutLast(term, "@")
  var worktreeRanks = filterTerm(termParts.before, worktreeTargets)
  if (!termParts.qualified) return worktreeRanks

  var repoRanks = filterTerm(termParts.after, repoTargets)
  var repoMatch = {}
  for (var k = 0; k < repoRanks.length; k++) repoMatch[repoRanks[k].index] = repoRanks[k]

  var out = []
  for (var r = 0; r < worktreeRanks.length; r++) {
    var rank = worktreeRanks[r]
    var repoRank = repoMatch[rank.index]
    if (!repoRank) continue
    var offset = worktreeTargets[rank.index].length + 1
    var shifted = []
    for (var m = 0; m < repoRank.matchedIndexes.length; m++) shifted.push(repoRank.matchedIndexes[m] + offset)
    out.push({ index: rank.index, matchedIndexes: rank.matchedIndexes.concat(shifted) })
  }
  return out
}

// Mirror timber ls Status without its upstream suffix.
function listStatusText(detail) {
  if (detail.statusError === true) return "error"
  if (detail.merged === true) return "merged"
  var parts = []
  if (typeof detail.ahead === "number" && detail.ahead > 0) parts.push("↑" + detail.ahead)
  if (typeof detail.behind === "number" && detail.behind > 0) parts.push("↓" + detail.behind)
  return parts.join(" ")
}

function todoText(detail) {
  if (typeof detail.todoTotal !== "number" || detail.todoTotal <= 0) return ""
  var done = typeof detail.todoDone === "number" ? detail.todoDone : 0
  return done + "/" + detail.todoTotal
}

function compareText(a, b) {
  return a < b ? -1 : (a > b ? 1 : 0)
}

// Sort a copy, preserving timber list --sort recency order by default.
function sortWorktrees(worktrees, mode) {
  var rows = worktrees.slice()
  if (mode !== "repo" && mode !== "worktree") return rows
  return rows.sort(function(a, b) {
    if (mode === "repo") return compareText(a.repo, b.repo) || compareText(a.name, b.name)
    return compareText(a.name, b.name) || compareText(a.repo, b.repo)
  })
}

// Mirror wizardItemsForTerm: existing worktrees first, then one `create`
// row per matching repo when the term is a qualified `name@repo`.
function itemsForTerm(repos, worktrees, term, sort) {
  worktrees = sortWorktrees(worktrees || [], sort || "recency")
  var t = String(term || "")
  var items = []
  var ranks = filterWorktrees(t, worktrees || [])
  for (var i = 0; i < ranks.length; i++) {
    var w = (worktrees || [])[ranks[i].index]
    items.push({ kind: "open", name: w.name, repo: w.repo, value: worktreeValue(w), path: w.path || "", statusText: w.statusText || "", todoText: w.todoText || "" })
  }

  var termParts = cutLast(t, "@")
  if (!termParts.qualified || !termParts.before || termParts.before.indexOf("@") !== -1) return items

  var repoNames = []
  for (var j = 0; j < (repos || []).length; j++) repoNames.push(repos[j].name)
  var repoRanks = filterTerm(termParts.after, repoNames)
  for (var k = 0; k < repoRanks.length; k++) {
    var repo = (repos || [])[repoRanks[k].index]
    if (hasWorktree(worktrees || [], termParts.before, repo.name)) continue
    items.push({ kind: "create", name: termParts.before, repo: repo.name, value: termParts.before + "@" + repo.name, path: "", statusText: "", todoText: "" })
  }
  return items
}

// Kind distinguishes a create row from an existing worktree of the same name.
function itemID(item) {
  return item.kind + ":" + item.value
}

// Keep selection on the same row when a refresh changes its position.
function selectedItemIndex(items, selectedID) {
  for (var i = 0; i < items.length; i++) {
    if (itemID(items[i]) === selectedID) return i
  }
  return 0
}

function splitValue(value) {
  var parts = cutLast(value, "@")
  if (!parts.qualified || !parts.before || !parts.after) return null
  return { name: parts.before, repo: parts.after }
}

// argv (after `timber`) for `timber create [--no-herdr|--herdr]
// <name@repo>`. withHerdr selects the `--herdr` variant, which also
// creates a Herdr workspace for the new worktree.
function createArgs(value, withHerdr) {
  return ["create", withHerdr ? "--herdr" : "--no-herdr", String(value || "")]
}

// argv (after `timber`) for `timber herdr space --new <name@repo>`,
// which sets up (and opens) a Herdr space for an existing worktree.
function herdrSpaceArgs(value) {
  return ["herdr", "space", "--new", String(value || "")]
}

// One two-phase delete step for `armedRemoveValue`. Clicking the
// armed row confirms the remove; clicking any other row arms it
// instead (disarming the previous one). A blank click changes
// nothing and never confirms.
function armOrConfirmRemove(armed, value) {
  var v = String(value || "")
  if (!v) return { armed: String(armed || ""), confirmed: false }
  if (String(armed || "") === v) return { armed: "", confirmed: true }
  return { armed: v, confirmed: false }
}

// argv (after `timber`) for `timber repo add <url-or-path>
// [--name <name>] [--alias <alias>]`. Blank name/alias flags are omitted
// and surrounding whitespace is trimmed; returns null when the URL is
// blank so callers can refuse to run instead of registering nothing.
function repoAddArgs(url, name, alias) {
  var u = String(url || "").trim()
  if (!u) return null
  var args = ["repo", "add"]
  var n = String(name || "").trim()
  if (n) args.push("--name", n)
  var a = String(alias || "").trim()
  if (a) args.push("--alias", a)
  args.push(u)
  return args
}
