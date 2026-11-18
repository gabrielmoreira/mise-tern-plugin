// Isolated Tern for UI tests: private config dir, private daemon pipe, one window with a control port.
// Never touches the user's own daemon or config. Works on Windows (named pipe) and macOS (unix socket).
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, existsSync, readFileSync, cpSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir, platform } from "node:os";
import { join, resolve } from "node:path";

export const IS_WIN = platform() === "win32";

export function ternBinary(): { exe: string; cli: string } {
  const env = process.env.TERN_BIN;
  if (env) return { exe: env, cli: env };
  if (IS_WIN) {
    const base = join(process.env.LOCALAPPDATA ?? "", "Programs", "Tern");
    return { exe: join(base, "tern.exe"), cli: join(base, "tern.com") };
  }
  const mac = "/Applications/Tern.app/Contents/MacOS/tern";
  const exe = existsSync(mac) ? mac : join(process.env.HOME ?? "", ".local/bin/tern");
  return { exe, cli: exe };
}

async function freePort(): Promise<number> {
  return new Promise((ok, fail) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => ok(port));
    });
    s.on("error", fail);
  });
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class TernSession {
  dir = "";
  port = 0;
  env: NodeJS.ProcessEnv = {};
  daemon?: ChildProcess;
  gui?: ChildProcess;
  bin = ternBinary();
  shots = "";

  /** Starts an isolated daemon and window with `pluginDir` installed. `env` extra variables reach every Tern process (and so the plugin's children). */
  static async start(pluginDir: string, extraEnv: Record<string, string> = {}, opts: { settings?: object; cwd?: string; extraPlugins?: string[] } = {}): Promise<TernSession> {
    const s = new TernSession();
    s.dir = mkdtempSync(join(tmpdir(), "tern-ui-"));
    const cfg = join(s.dir, "cfg");
    mkdirSync(cfg, { recursive: true });
    s.shots = join(s.dir, "shots");
    mkdirSync(s.shots, { recursive: true });
    s.port = await freePort();
    const sock = IS_WIN ? `\\\\.\\pipe\\tern-ui-${process.pid}-${s.port}` : join(s.dir, "d.sock");
    const clean: NodeJS.ProcessEnv = { ...process.env };
    for (const k of Object.keys(clean)) if (k.startsWith("TERN_PANE") || k.startsWith("TERN_WINDOW") || k === "TERN_IDENTITY") delete clean[k];
    s.env = {
      ...clean,
      TERN_CONFIG_DIR: cfg,
      TERN_DAEMON_SOCKET: sock,
      STENCIL_LOG_DIR: join(s.dir, "logs"),
      STENCIL_LOG: "warn,tern::plugin=debug",
      ...extraEnv,
    };
    if (opts.settings) {
      const fs = await import("node:fs");
      fs.writeFileSync(join(cfg, "settings.json"), JSON.stringify(opts.settings));
    }
    for (const dir of [pluginDir, ...(opts.extraPlugins ?? [])]) {
      const inst = spawnSync(s.bin.cli, ["plugin", "install", resolve(dir), "--force"], { env: s.env, encoding: "utf8" });
      if (inst.status !== 0) throw new Error("plugin install failed: " + inst.stdout + inst.stderr);
    }
    s.daemon = spawn(s.bin.exe, ["daemon", "--socket", sock], { env: s.env, stdio: "ignore", detached: !IS_WIN });
    await sleep(1500);
    s.gui = spawn(s.bin.exe, ["--control", String(s.port), opts.cwd ?? s.dir], { env: s.env, stdio: "ignore", detached: !IS_WIN });
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      const r = s.ctlRaw("state");
      if (r.includes('"ok":true')) { await s.dismissFirstRunCards(); return s; }
      await sleep(400);
    }
    await s.stop();
    throw new Error("tern window did not answer ctl in 30 s");
  }

  /** A fresh Tern config shows its macOS permissions card first and it takes the keyboard; close it. */
  async dismissFirstRunCards() {
    if (IS_WIN) return;
    for (let i = 0; i < 8; i++) {
      if (this.ctlRaw("tree").includes("macOS permissions")) {
        this.ctlRaw("click button.mdl-cancel");
        await sleep(500);
        return;
      }
      await sleep(400);
    }
  }

  ctlRaw(cmd: string): string {
    const r = spawnSync(this.bin.cli, ["ctl", "--control", String(this.port), cmd], { env: this.env, encoding: "utf8", timeout: 20000 });
    return (r.stdout ?? "") + (r.stderr ?? "");
  }
  ctl(cmd: string): any {
    const out = this.ctlRaw(cmd).trim();
    try { return JSON.parse(out); } catch { return { ok: false, raw: out }; }
  }
  /** Every text and title in the visible tree, joined, for substring assertions. */
  texts(): string[] {
    const t = this.ctl("tree");
    const out: string[] = [];
    const walk = (n: any) => {
      if (!n || typeof n !== "object") return;
      if (typeof n.text === "string") out.push(n.text);
      if (typeof n.title === "string") out.push(n.title);
      if (Array.isArray(n.children)) n.children.forEach(walk);
      if (Array.isArray(n.tree)) n.tree.forEach(walk);
    };
    walk(t);
    return out;
  }
  async waitText(needle: string | RegExp, ms = 15000): Promise<string> {
    const end = Date.now() + ms;
    let last: string[] = [];
    while (Date.now() < end) {
      last = this.texts();
      const hit = last.find((x) => (typeof needle === "string" ? x.includes(needle) : needle.test(x)));
      if (hit) return hit;
      await sleep(300);
    }
    throw new Error(`text ${needle} not shown in ${ms} ms; saw: ${last.slice(0, 40).join(" | ").slice(0, 600)}`);
  }
  async waitGone(needle: string | RegExp, ms = 8000) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (!this.texts().some((x) => (typeof needle === "string" ? x.includes(needle) : needle.test(x)))) return;
      await sleep(300);
    }
    throw new Error(`text ${needle} still shown after ${ms} ms`);
  }
  run(action: string) { return this.ctl(`plugins run ${action}`); }
  async shot(name: string): Promise<string> {
    const r = this.ctl(`shot ${name}`);
    return r.png ?? "";
  }
  logs(): string {
    const fs = require("node:fs");
    const dir = join(this.dir, "logs");
    if (!existsSync(dir)) return "";
    return fs.readdirSync(dir).map((f: string) => { try { return readFileSync(join(dir, f), "utf8"); } catch { return ""; } }).join("\n");
  }
  async stop() {
    try { this.ctlRaw("quit"); } catch {}
    await sleep(500);
    for (const p of [this.gui, this.daemon]) {
      if (p?.pid) { try { if (IS_WIN) spawnSync("taskkill", ["/PID", String(p.pid), "/T", "/F"]); else process.kill(-p.pid, "SIGKILL"); } catch {} }
    }
    await sleep(300);
    try { rmSync(this.dir, { recursive: true, force: true, maxRetries: 3 }); } catch {}
  }
}
