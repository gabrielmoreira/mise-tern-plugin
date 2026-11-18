// Phase 0: records what the installed mise prints, in a throwaway world, as fixtures under
// test/fixtures/<os>/<mise-version>/. Paths under the world's root are replaced by <ROOT>.
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { homedir, userInfo } from "node:os";
import { MiseWorld, IS_WIN } from "../test/support/mise-env";

const w = new MiseWorld();
try {
  const ver = w.run(["--version"]).stdout.trim();
  const short = ver.split(/\s+/)[0];
  const os = IS_WIN ? "windows" : process.platform === "darwin" ? "macos" : "linux";
  const out = resolve(import.meta.dir, "..", "test", "fixtures", os, short);
  mkdirSync(out, { recursive: true });
  w.write("cfg/config.toml", '[tools]\njq = "1.7.1"\n');
  const proj = w.project("app", '[tools]\njq = "1.6"\nnode = "latest"\n\n[tasks.build]\ndescription = "Build the app"\nrun = "echo build"\n\n[tasks.test]\ndescription = "Run tests"\nrun = "echo test"\n');
  const untrusted = w.project("untrusted", '[tools]\njq = "1.7.1"\n');
  w.trust(w.cfgFile, join(proj, "mise.toml"));
  w.run(["install", "jq@1.7.1", "jq@1.6"], proj);
  // Fixtures are committed: nothing about the machine that recorded them may remain.
  const home = homedir();
  const forms = (p: string) => [p.replace(/\\/g, "\\\\"), p, p.replace(/\\/g, "/")];
  const replaceAll = (text: string, from: string, to: string) => (from ? text.split(from).join(to) : text);
  const norm = (text: string) => {
    let t = text;
    for (const f of forms(w.root)) t = replaceAll(t, f, "<ROOT>");
    for (const f of forms(home)) t = replaceAll(t, f, "<HOME>");
    t = replaceAll(t, userInfo().username, "<USER>");
    return t;
  };
  const ops: Record<string, string[]> = {
    version: ["--version"],
    ls: ["ls", "--json"],
    "ls-current": ["ls", "--current", "--json"],
    "ls-global": ["ls", "--global", "--json"],
    "ls-local": ["ls", "--local", "--json"],
    "ls-installed": ["ls", "--installed", "--json"],
    "ls-missing": ["ls", "--missing", "--json"],
    "ls-prunable": ["ls", "--prunable", "--json"],
    outdated: ["outdated", "--json"],
    "outdated-bump": ["outdated", "--bump", "--json"],
    "outdated-local": ["outdated", "--local", "--json"],
    "config-ls": ["config", "ls", "--json"],
    "tasks-ls": ["tasks", "ls", "--json"],
    "settings-ls": ["settings", "ls", "--json-extended"],
    doctor: ["doctor", "--json"],
    env: ["env", "--json"],
    where: ["where", "jq"],
    which: ["which", "jq"],
    "cache-path": ["cache", "path"],
    "use-dry-run": ["use", "--dry-run", "jq@1.7.1"],
    "use-dry-run-global": ["use", "--dry-run", "--global", "jq@1.7.1"],
    "upgrade-dry-run": ["upgrade", "--dry-run"],
    "prune-dry-run": ["prune", "--tools", "--dry-run"],
    "trust-show": ["trust", "--show"],
    "ls-help": ["ls", "--help"], "use-help": ["use", "--help"], "upgrade-help": ["upgrade", "--help"], "unuse-help": ["unuse", "--help"], "outdated-help": ["outdated", "--help"],
  };
  const index: any = { mise: ver, os, captured: new Date().toISOString(), ops: {} };
  for (const [name, args] of Object.entries(ops)) {
    const cwd = name === "trust-show" ? untrusted : proj;
    const r = w.run(args, cwd);
    let stdout = r.stdout;
    if (name === "env") {
      // The whole PATH of the machine is not a fixture: keep the shape, drop the contents.
      try { const j = JSON.parse(stdout); for (const k of Object.keys(j)) if (/^path$/i.test(k)) j[k] = "<PATH>"; stdout = JSON.stringify(j); } catch {}
    }
    if (name === "doctor") {
      try {
        const j = JSON.parse(stdout);
        j.paths = ["<PATH entries>"];
        if (j.env_vars) for (const k of Object.keys(j.env_vars)) if (/^MISE_BASH_PATH$/.test(k)) j.env_vars[k] = "<PATH>";
        stdout = JSON.stringify(j);
      } catch {}
    }
    writeFileSync(join(out, name + ".out"), norm(stdout));
    writeFileSync(join(out, name + ".err"), norm(r.stderr));
    index.ops[name] = { argv: args, status: r.status };
  }
  const reg = w.run(["registry", "--json"]);
  try { const j = JSON.parse(reg.stdout); writeFileSync(join(out, "registry.out"), JSON.stringify(j.slice(0, 40), null, 1)); index.ops.registry = { argv: ["registry", "--json"], status: reg.status, trimmed: 40 }; } catch {}
  const lr = w.run(["ls-remote", "--json", "jq"]);
  try { const j = JSON.parse(lr.stdout); writeFileSync(join(out, "ls-remote.out"), JSON.stringify(j.slice(-15), null, 1)); index.ops["ls-remote"] = { argv: ["ls-remote", "--json", "jq"], status: lr.status, trimmed: 15 }; } catch { writeFileSync(join(out, "ls-remote.out"), norm(lr.stdout)); }
  writeFileSync(join(out, "index.json"), JSON.stringify(index, null, 1));
  console.log("fixtures ->", out);
} finally { w.cleanup(); }
