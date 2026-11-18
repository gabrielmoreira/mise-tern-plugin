// A throwaway mise world: every MISE_*_DIR points into one temp folder, so nothing of the user's can be touched.
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir, platform } from "node:os";
import { join } from "node:path";

export const IS_WIN = platform() === "win32";

export function findMise(): string {
  if (process.env.MISE_BIN) return process.env.MISE_BIN;
  const home = process.env.HOME ?? process.env.USERPROFILE ?? "";
  const cands: string[] = [];
  if (IS_WIN) {
    const la = process.env.LOCALAPPDATA ?? "";
    const pk = join(la, "Microsoft", "WinGet", "Packages");
    if (existsSync(pk)) for (const d of readdirSync(pk)) if (d.startsWith("jdx.mise_")) cands.push(join(pk, d, "mise", "bin", "mise.exe"));
    cands.push(join(la, "Microsoft", "WinGet", "Links", "mise.exe"), join(home, "scoop", "shims", "mise.exe"));
  } else {
    cands.push(join(home, ".local/bin/mise"), "/opt/homebrew/bin/mise", "/usr/local/bin/mise", "/opt/local/bin/mise", join(home, ".cargo/bin/mise"));
  }
  for (const c of cands) if (existsSync(c)) return c;
  const which = spawnSync(IS_WIN ? "where" : "which", ["mise"], { encoding: "utf8" });
  const first = (which.stdout ?? "").split(/\r?\n/).find((l) => l.trim());
  if (first) return first.trim();
  throw new Error("mise executable not found; set MISE_BIN");
}

export class MiseWorld {
  root: string;
  env: Record<string, string>;
  mise: string;
  proj: string;
  /** `root` pins the world's folder (for screenshots whose paths are shown); else a fresh temp folder. */
  constructor(mise = findMise(), root?: string) {
    this.mise = mise;
    if (root) {
      // Never reuse a folder that is already there: cleanup() deletes the root recursively.
      if (existsSync(root)) throw new Error(`world root ${root} already exists; pass a path that does not`);
      mkdirSync(root, { recursive: true });
      this.root = root;
    }
    else this.root = mkdtempSync(join(tmpdir(), "mise-world-"));
    const d = (n: string) => { const p = join(this.root, n); mkdirSync(p, { recursive: true }); return p; };
    this.proj = d("proj");
    this.env = {
      MISE_DATA_DIR: d("data"), MISE_INSTALLS_DIR: d("inst"), MISE_CONFIG_DIR: d("cfg"), MISE_CACHE_DIR: d("cache"),
      MISE_STATE_DIR: d("state"), MISE_TMP_DIR: d("tmp"), MISE_SYSTEM_CONFIG_DIR: d("sys"),
      MISE_GLOBAL_CONFIG_FILE: join(this.root, "cfg", "config.toml"),
      MISE_AUTO_INSTALL: "0", MISE_EXPERIMENTAL: "0", NO_COLOR: "1",
      // The login environment of the developer must not leak in.
      MISE_ENV: "", MISE_CEILING_PATHS: this.root,
    };
  }
  get cfgFile() { return this.env.MISE_GLOBAL_CONFIG_FILE; }
  write(rel: string, text: string) {
    const p = join(this.root, rel);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, text);
    return p;
  }
  project(name: string, toml: string): string {
    const dir = join(this.root, name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "mise.toml"), toml);
    return dir;
  }
  run(args: string[], cwd = this.proj) {
    const env = { ...process.env, ...this.env };
    const r = spawnSync(this.mise, args, { cwd, env, encoding: "utf8", timeout: 120000 });
    return { status: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  }
  trust(...files: string[]) { for (const f of files) this.run(["trust", f]); }
  cleanup() { try { rmSync(this.root, { recursive: true, force: true, maxRetries: 3 }); } catch {} }
}
