// Pure filter logic for the timber overlay, ported from timber's
// tui_create_wizard.go (wizardItemsForTerm, filterWizardWorktrees).
// No QML dependencies so the matching stays testable in isolation.
//
// repos:    [{ name: "timber" }]
// worktrees:[{ name: "feature/login", repo: "timber" }]
// items:    [{ kind: "open"|"create", name, repo, value: "name@repo" }]

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

// Mirror wizardItemsForTerm: existing worktrees first, then one `create`
// row per matching repo when the term is a qualified `name@repo`.
function itemsForTerm(repos, worktrees, term) {
  var t = String(term || "")
  var items = []
  var ranks = filterWorktrees(t, worktrees || [])
  for (var i = 0; i < ranks.length; i++) {
    var w = (worktrees || [])[ranks[i].index]
    items.push({ kind: "open", name: w.name, repo: w.repo, value: worktreeValue(w) })
  }

  var termParts = cutLast(t, "@")
  if (!termParts.qualified || !termParts.before || termParts.before.indexOf("@") !== -1) return items

  var repoNames = []
  for (var j = 0; j < (repos || []).length; j++) repoNames.push(repos[j].name)
  var repoRanks = filterTerm(termParts.after, repoNames)
  for (var k = 0; k < repoRanks.length; k++) {
    var repo = (repos || [])[repoRanks[k].index]
    if (hasWorktree(worktrees || [], termParts.before, repo.name)) continue
    items.push({ kind: "create", name: termParts.before, repo: repo.name, value: termParts.before + "@" + repo.name })
  }
  return items
}

function splitValue(value) {
  var parts = cutLast(value, "@")
  if (!parts.qualified || !parts.before || !parts.after) return null
  return { name: parts.before, repo: parts.after }
}
