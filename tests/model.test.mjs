import { readFileSync } from "node:fs";
import vm from "node:vm";
import { describe, it } from "node:test";
import assert from "node:assert/strict";

const src = readFileSync(new URL("../TimberModel.js", import.meta.url), "utf8");
const sandbox = {};
vm.createContext(sandbox);
// TimberModel.js declares bare functions (QML import style), so export
// them explicitly for the test context.
vm.runInContext(
  src + "\n;globalThis.__timberModel = { itemsForTerm, splitValue, repoAddArgs, createArgs, herdrSpaceArgs, armOrConfirmRemove, selectedItemIndex, parseListing };",
  sandbox,
);
const {
  itemsForTerm,
  splitValue,
  repoAddArgs,
  createArgs,
  herdrSpaceArgs,
  armOrConfirmRemove,
  selectedItemIndex,
  parseListing,
} = sandbox.__timberModel;

const repos = [{ name: "timber" }, { name: "persona" }];
const worktrees = [
  { name: "alpha", repo: "timber" },
  { name: "beta", repo: "persona" },
  { name: "alpha", repo: "persona" },
];

// Array.from re-roots the results in this realm: itemsForTerm returns
// vm-context arrays, whose prototype deepStrictEqual would reject.
const values = (items) => Array.from(items, (item) => item.value);
const kinds = (items) => Array.from(items, (item) => item.kind);

describe("itemsForTerm", () => {
  it("lists every worktree on an empty term", () => {
    assert.deepEqual(values(itemsForTerm(repos, worktrees, "")), [
      "alpha@persona",
      "alpha@timber",
      "beta@persona",
    ]);
  });

  it("fuzzy-filters on the worktree half", () => {
    assert.deepEqual(values(itemsForTerm(repos, worktrees, "alp")), [
      "alpha@persona",
      "alpha@timber",
    ]);
  });

  it("keeps every repo while the repo half is empty", () => {
    assert.deepEqual(values(itemsForTerm(repos, worktrees, "alpha@")), [
      "alpha@persona",
      "alpha@timber",
    ]);
  });

  it("narrows to one repo once @ is qualified", () => {
    assert.deepEqual(values(itemsForTerm(repos, worktrees, "alpha@timber")), [
      "alpha@timber",
    ]);
  });

  it("offers one create row per matching repo", () => {
    const items = itemsForTerm(repos, worktrees, "newfeat@");
    assert.deepEqual(kinds(items), ["create", "create"]);
    assert.deepEqual(values(items), ["newfeat@timber", "newfeat@persona"]);
  });

  it("filters create rows by the repo half", () => {
    assert.deepEqual(values(itemsForTerm(repos, worktrees, "newfeat@per")), [
      "newfeat@persona",
    ]);
  });

  it("opens instead of creating when the worktree exists", () => {
    const items = itemsForTerm(repos, worktrees, "beta@persona");
    assert.deepEqual(kinds(items), ["open"]);
    assert.deepEqual(values(items), ["beta@persona"]);
  });
});

describe("display sorting", () => {
  const rows = [
    { name: "z", repo: "a", lastCommitAt: 200 },
    { name: "a", repo: "z", lastCommitAt: 100 },
    { name: "a", repo: "a", lastCommitAt: 200 },
    { name: "b", repo: "a" },
  ];
  for (const [mode, expected] of [
    [undefined, ["a@a", "z@a", "a@z", "b@a"]],
    ["repo", ["a@a", "b@a", "z@a", "a@z"]],
    ["worktree", ["a@a", "a@z", "b@a", "z@a"]],
  ]) {
    it(`orders filtered rows by ${mode || "recency by default"}`, () => {
      assert.deepEqual(values(itemsForTerm([], rows, "@a", mode)), expected.filter(v => v.endsWith("@a")));
      assert.deepEqual(values(itemsForTerm([], rows, "", mode)), expected);
      assert.equal(rows[0].name, "z", "sorting does not reorder the cache");
    });
  }
  it("uses scan timestamps and tolerates old records without a date", () => {
    const listing = parseListing("R\ttimber\nW\told@timber\t/tmp/old\nW\tnew@timber\t/tmp/new\t300\n");
    const items = itemsForTerm(listing.repos, listing.worktrees, "");
    assert.deepEqual(values(items), ["new@timber", "old@timber"]);
    assert.equal(items[0].path, "/tmp/new");
  });
});

describe("repoAddArgs", () => {
  it("builds timber repo add argv with name and alias", () => {
    assert.deepEqual(
      Array.from(
        repoAddArgs("git@github.com:org/repo.git", "repo", "My Repo"),
      ),
      ["repo", "add", "--name", "repo", "--alias", "My Repo", "git@github.com:org/repo.git"],
    );
  });

  it("omits blank name and alias flags", () => {
    assert.deepEqual(Array.from(repoAddArgs("https://github.com/org/repo.git", "", "  ")), [
      "repo",
      "add",
      "https://github.com/org/repo.git",
    ]);
  });

  it("trims surrounding whitespace", () => {
    assert.deepEqual(Array.from(repoAddArgs("  /srv/git/repo.git  ", " r ", "")), [
      "repo",
      "add",
      "--name",
      "r",
      "/srv/git/repo.git",
    ]);
  });

  it("refuses a blank URL", () => {
    assert.equal(repoAddArgs("   ", "repo", "alias"), null);
  });
});

describe("createArgs", () => {
  it("creates without Herdr by default", () => {
    assert.deepEqual(Array.from(createArgs("newfeat@timber", false)), [
      "create",
      "--no-herdr",
      "newfeat@timber",
    ]);
  });

  it("creates with a Herdr workspace when asked", () => {
    assert.deepEqual(Array.from(createArgs("newfeat@timber", true)), [
      "create",
      "--herdr",
      "newfeat@timber",
    ]);
  });
});

describe("herdrSpaceArgs", () => {
  it("opens a new Herdr space for the worktree", () => {
    assert.deepEqual(Array.from(herdrSpaceArgs("alpha@timber")), [
      "herdr",
      "space",
      "--new",
      "alpha@timber",
    ]);
  });
});

describe("armOrConfirmRemove", () => {
  // Spread into this realm: the step is a vm-context object.
  const step = (armed, value) => ({ ...armOrConfirmRemove(armed, value) });

  it("arms on the first click without confirming", () => {
    assert.deepEqual(step("", "alpha@timber"), {
      armed: "alpha@timber",
      confirmed: false,
    });
  });

  it("confirms and disarms on the second click", () => {
    assert.deepEqual(step("alpha@timber", "alpha@timber"), {
      armed: "",
      confirmed: true,
    });
  });

  it("re-arms to another row instead of confirming", () => {
    assert.deepEqual(step("alpha@timber", "beta@persona"), {
      armed: "beta@persona",
      confirmed: false,
    });
  });

  it("ignores a blank click without confirming", () => {
    assert.deepEqual(step("alpha@timber", ""), {
      armed: "alpha@timber",
      confirmed: false,
    });
  });
});

describe("selection across refreshes", () => {
  it("follows the selected worktree through insertion and reordering", () => {
    const rows = [
      { kind: "open", value: "new@timber" },
      { kind: "create", value: "alpha@timber" },
      { kind: "open", value: "alpha@timber" },
    ];
    assert.equal(selectedItemIndex(rows, "open:alpha@timber"), 2);
    assert.equal(selectedItemIndex(rows, "open:removed@timber"), 0);
    assert.equal(selectedItemIndex([], "open:alpha@timber"), 0);
  });
});

describe("splitValue", () => {
  it("splits on the last @ so slashes survive in names", () => {
    // Spread into this realm: splitValue returns a vm-context object.
    assert.deepEqual({ ...splitValue("a/b@c") }, { name: "a/b", repo: "c" });
  });

  it("rejects unqualified values", () => {
    assert.equal(splitValue("nope"), null);
  });
});
