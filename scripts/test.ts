// One entry point for every suite.
//   bun scripts/test.ts            all of it
//   bun scripts/test.ts unit       Lune unit tests (no mise, no Tern)
//   bun scripts/test.ts integration  Lune against a real mise in a throwaway world
//   bun scripts/test.ts ui         a real, isolated Tern window (bun:test)
// Needs `lune` on PATH (or LUNE=/path/to/lune) and `mise`. UI tests need Tern installed (or TERN_BIN).
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const lune = process.env.LUNE ?? "lune";
const SUITES: Record<string, string[]> = {
  unit: ["test/unit/model.test.luau", "test/unit/tasks.test.luau"],
  integration: ["test/integration/view.test.luau", "test/integration/store.test.luau", "test/integration/window.test.luau"],
};

function run(cmd: string, args: string[], label: string): boolean {
  console.log(`\n=== ${label}`);
  const r = spawnSync(cmd, args, { cwd: root, stdio: "inherit" });
  return r.status === 0;
}

const want = process.argv[2] ? [process.argv[2]] : ["unit", "integration", "ui"];
let ok = true;
for (const group of want) {
  if (group === "ui") ok = run(process.execPath, ["test", "--timeout", "180000", "test/ui/panel.test.ts"], "ui (isolated Tern)") && ok;
  else if (SUITES[group]) for (const file of SUITES[group]) ok = run(lune, ["run", file], file) && ok;
  else { console.error(`unknown suite ${group}`); ok = false; }
}
process.exit(ok ? 0 : 1);
