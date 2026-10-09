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
  { name: "alpha", repo: "persona" },
  { name: "alpha", repo: "timber" },
  { name: "beta", repo: "persona" },
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

describe("JSON worktree listing", () => {
  const display = (json) => {
    const listing = parseListing("R\ttimber\nD\t" + json + "\n");
    return itemsForTerm(listing.repos, listing.worktrees, "");
  };
  for (const [detail, status, todo] of [
    [{ ahead: 2, behind: 3, todoDone: 1, todoTotal: 4 }, "↑2 ↓3", "1/4"],
    [{ merged: true, ahead: 2, todoDone: 4, todoTotal: 4 }, "merged", "4/4"],
    [{ statusError: true, merged: true, ahead: 2 }, "error", ""],
    [{ behind: 3, todoTotal: 2 }, "↓3", "0/2"],
    [{ ahead: 0, behind: 0, todoTotal: 0 }, "", ""],
    [{ ahead: "2", merged: "false", todoTotal: "4" }, "", ""],
  ]) {
    it(`renders ${JSON.stringify(detail)} as quiet or explicit badges`, () => {
      const items = display(JSON.stringify([{ name: "alpha", repo: "timber", path: "/tmp/alpha", upstream: "origin/main", ...detail }]));
      assert.equal(items[0].statusText, status);
      assert.equal(items[0].todoText, todo);
      assert.equal(items[0].path, "/tmp/alpha");
    });
  }
  it("opens arbitrary paths from JSON and offers creation in empty repositories", () => {
    const listing = parseListing("R\torg/repo\nR\tempty\nD\t" + JSON.stringify([
      { name: "feature/login", repo: "org/repo", path: "/srv/my projects/login", ahead: 2 },
      { name: "main", repo: "org/repo", path: "/opt/checkout" },
    ], null, 2));
    const items = itemsForTerm(listing.repos, listing.worktrees, "feature/login@org/repo");
    assert.deepEqual(kinds(items), ["open"]);
    assert.equal(items[0].path, "/srv/my projects/login");
    assert.equal(items[0].statusText, "↑2");
    const created = itemsForTerm(listing.repos, listing.worktrees, "new@empty");
    assert.deepEqual(kinds(created), ["create"]);
    assert.equal(created[0].statusText, "");
    assert.equal(created[0].todoText, "");
  });
  it("rejects malformed or incomplete JSON listings", () => {
    for (const json of ["", "not JSON", "{}", "null", "[null]",
      '[{"name":"alpha","repo":"timber"}]',
      '[{"name":"alpha","repo":"timber","path":"/tmp/alpha"},{"name":"bad","path":"/tmp/bad"}]']) {
      assert.throws(() => display(json));
    }
    assert.throws(() => parseListing("R\ttimber\n"));
  });
  it("accepts an empty worktree list without losing create suggestions", () => {
    const listing = parseListing("R\ttimber\nD\t[]\n");
    assert.deepEqual(values(itemsForTerm(listing.repos, listing.worktrees, "")), []);
    assert.deepEqual(kinds(itemsForTerm(listing.repos, listing.worktrees, "new@timber")), ["create"]);
  });
});

describe("display sorting", () => {
  const rows = [
    { name: "z", repo: "a" },
    { name: "a", repo: "z" },
    { name: "a", repo: "a" },
    { name: "b", repo: "a" },
  ];
  for (const [mode, expected] of [
    [undefined, ["z@a", "a@z", "a@a", "b@a"]],
    ["repo", ["a@a", "b@a", "z@a", "a@z"]],
    ["worktree", ["a@a", "a@z", "b@a", "z@a"]],
  ]) {
    it(`orders filtered rows by ${mode || "recency by default"}`, () => {
      assert.deepEqual(values(itemsForTerm([], rows, "@a", mode)), expected.filter(v => v.endsWith("@a")));
      assert.deepEqual(values(itemsForTerm([], rows, "", mode)), expected);
      assert.equal(rows[0].name, "z", "sorting does not reorder the cache");
    });
  }
  it("restores Timber's recency order after another sort mode", () => {
    const listing = parseListing("R\ttimber\nD\t" + JSON.stringify([
      { name: "z-new", repo: "timber", path: "/tmp/new" },
      { name: "a-old", repo: "timber", path: "/tmp/old" },
    ]));
    assert.deepEqual(values(itemsForTerm(listing.repos, listing.worktrees, "", "worktree")), ["a-old@timber", "z-new@timber"]);
    const items = itemsForTerm(listing.repos, listing.worktrees, "", "recency");
    assert.deepEqual(values(items), ["z-new@timber", "a-old@timber"]);
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
