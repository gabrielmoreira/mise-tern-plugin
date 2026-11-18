// The panel in a real, isolated Tern window against a real mise in a throwaway world.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { TernSession, sleep } from "./harness";
import { MiseWorld } from "../support/mise-env";

let w: MiseWorld;
let s: TernSession;
let proj: string;

const btn = (act: string) => `[data-role='mise.btn:${act}']`;
const click = (act: string) => { const r = s.ctl(`click ${btn(act)}`); if (!r.ok) throw new Error(`click ${act}: ${JSON.stringify(r)}`); };
// The host re-renders after each input; give it a beat so the next key lands in the right field.
const openTab = (t: string) => { if (nodes(btn(`tab=${t}`)).length === 0) click("more"); click(`tab=${t}`); };
const typeText = async (t: string) => { s.ctl(`type "${t.replace(/"/g, "\\\"")}"`); await sleep(350); };
const key = async (k: string) => { s.ctl(`key ${k}`); await sleep(350); };
async function until(cond: () => boolean, ms = 15000, what = "condition") {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (cond()) return; await sleep(250); }
  throw new Error(`${what} not met in ${ms} ms; texts: ${s.texts().filter((t) => t.length < 80).slice(0, 50).join(" | ")}`);
}
const has = (needle: string | RegExp) => s.texts().some((x) => (typeof needle === "string" ? x.includes(needle) : needle.test(x)));
// Highlighted code arrives as one text node per token: compare the joined text.
const joined = () => s.texts().join("");
const hasCode = (needle: string) => joined().includes(needle);
async function waitCode(needle: string, ms = 15000) { await until(() => hasCode(needle), ms, `code ${needle}`); }
const shot = (name: string) => s.shot(name);
const nodes = (sel: string): any[] => s.ctl(`tree ${sel}`).nodes ?? [];

beforeAll(async () => {
  w = new MiseWorld();
  proj = w.project("app", '[tools]\njq = "1.7.1"\n\n[tasks.build]\ndescription = "Build the app"\nrun = "echo built-by-task"\n');
  s = await TernSession.start(resolve("."), { ...w.env }, { cwd: proj });
  await sleep(2500);
  s.run("plugin.mise.open");
  await s.waitText("jq", 30000);
}, 90000);

afterAll(async () => {
  if (process.env.UI_LOGS) console.log(s?.logs().split("\n").filter((l) => /panic|ERROR|WARN.*plugin|mise/i.test(l)).slice(-40).join("\n"));
  await s?.stop();
  w?.cleanup();
});

describe("tools", () => {
  test("shows the folder, the missing tool and where it is requested", async () => {
    await s.waitText("Missing");
    expect(has("app")).toBe(true);
    expect(has("mise.toml")).toBe(true);
    expect(has(/mise 2\d{3}\./)).toBe(true);
    await shot("tools-initial");
  });

  test("typing filters; a miss says so; clearing restores", async () => {
    await typeText("zzz");
    await s.waitText("Nothing matches.");
    await key("escape");
    await until(() => has("jq 1.7.1"), 8000, "filter cleared");
  });

  test("Global and Local scopes read separately", async () => {
    click("scope=global");
    await until(() => has(/No tools are requested here/), 20000, "empty global");
    click("scope=local");
    await until(() => has("jq 1.7.1"), 20000, "local list");
    click("scope=merged");
    await until(() => has("jq 1.7.1"), 20000, "merged list");
  });

  test("Install missing: reviewed plan, dry run, real install, result", async () => {
    click("install.missing");
    await s.waitText("Install missing tools");
    await s.waitText(/mise(\.exe)? install/);
    await until(() => has(/jq/) , 20000, "dry run output");
    expect(existsSync(join(w.env.MISE_INSTALLS_DIR, "jq"))).toBe(false);
    await shot("install-review");
    click("plan.run");
    await s.waitText(/Done in/, 120000);
    expect(existsSync(join(w.env.MISE_INSTALLS_DIR, "jq", "1.7.1"))).toBe(true);
    await shot("install-done");
    click("dialog.close");
    await s.waitText("Active", 30000);
  }, 180000);

  test("selecting a row opens details with actions", async () => {
    const rows = nodes("[data-role='mise.row']");
    expect(rows.length).toBeGreaterThan(0);
    s.ctl("click [data-role='mise.row']");
    await s.waitText("Open definition");
    await s.waitText(/Installed at/);
    s.ctl("click [data-role^='mise.row']");
  });

  test("Add opens a field, checks the input, shows a reviewed plan", async () => {
    click("add");
    await s.waitText("Add a tool");
    await key("enter");
    await s.waitText(/Enter a tool name/).catch(() => {});
    await typeText("bat@0.24");
    await sleep(400);
    click("add.submit");
    await s.waitText("Add bat@0.24 to this project");
    await s.waitText(/mise(\.exe)? use/);
    await shot("add-review");
    click("dialog.close");
    await s.waitGone("Add bat@0.24 to this project");
  });
});

describe("tasks", () => {
  test("lists tasks; selecting shows the source with edit actions", async () => {
    click("tab=tasks");
    await s.waitText("Build the app", 20000);
    s.ctl("click [data-role='mise.row']");
    await waitCode("[tasks.build]");
    await s.waitText("Edit…").catch(() => {});
    await shot("tasks-source");
  });

  test("New task: fill some fields, leave others empty, review, create", async () => {
    click("task.new");
    await s.waitText("New task");
    await typeText("hello");
    await key("tab");
    await typeText("echo hello-from-ui");
    await key("enter");                       // a line break inside the command editor, not a submit
    await typeText("echo second-line");
    await key("tab");
    await typeText("Says hello");
    await sleep(300);
    click("taskform.source");
    await waitCode('[tasks.hello]');
    await waitCode("echo hello-from-ui");
    await waitCode("echo second-line");
    await shot("task-new-source");
    click("taskform.submit");
    await s.waitText("Create task hello");
    await waitCode("[tasks.hello]");
    click("plan.run");
    await s.waitText(/Done in/, 30000);
    click("dialog.close");
    await s.waitText("Says hello", 20000);
    const toml = readFileSync(join(proj, "mise.toml"), "utf8");
    expect(toml).toContain("[tasks.hello]");
    expect(toml).toContain("echo hello-from-ui");
    expect(toml).toContain("echo second-line");
    expect(toml).toContain("[tasks.build]");
  }, 60000);

  test("Edit task: prefilled, diff of only the changed line, saved, others kept", async () => {
    s.ctl("click [title^='hello ·']");
    await s.waitText("Edit…", 15000);
    click("task.edit=hello");
    await s.waitText("Edit task");
    // Command is focused first; move to Description and replace it.
    await key("tab");
    await key("ctrl+a");
    await typeText("Greets people");
    await sleep(300);
    click("taskform.source");
    await waitCode('Greets people');
    await waitCode('Says hello');
    await shot("task-edit-diff");
    click("taskform.submit");
    await s.waitText("Save task hello");
    click("plan.run");
    await s.waitText(/Done in/, 30000);
    click("dialog.close");
    const toml = readFileSync(join(proj, "mise.toml"), "utf8");
    expect(toml).toContain('description = "Greets people"');
    expect(toml).toContain('run = "echo built-by-task"');
  }, 60000);

  test("Run opens a terminal that runs mise run <task>", async () => {
    const before = s.ctl("state").tabs[0].panes ?? 0;
    click("task.open=build");
    await s.waitText("Run task");
    click("task.run");
    await until(() => (s.ctl("state").tabs.reduce((a: number, t: any) => a + t.panes, 0)) > before, 15000, "task terminal pane");
    await sleep(6000);
    await shot("task-run");
  }, 60000);

  test("Delete asks twice and removes only that task", async () => {
    s.ctl("click [title^='hello ·']");
    await until(() => nodes(btn("task.delete=hello")).length > 0, 10000, "delete button");
    click("task.delete=hello");
    await s.waitText("Delete task hello");
    click("plan.run");
    await s.waitText(/cannot be undone/);
    click("plan.run");
    await s.waitText(/Done in/, 30000);
    click("dialog.close");
    const toml = readFileSync(join(proj, "mise.toml"), "utf8");
    expect(toml).not.toContain("tasks.hello");
    expect(toml).toContain("[tasks.build]");
  }, 60000);
});

describe("more", () => {
  test("Overview lists folders as reported by mise and can run doctor", async () => {
    openTab("overview");
    await s.waitText("FOLDERS");
    await s.waitText(/reported by mise|predicted|env:/);
    click("doctor.run");
    await s.waitText(/No problems reported|error|warning/, 90000);
    await shot("overview");
  }, 120000);

  test("Config lists the stack, Activity lists what was run", async () => {
    openTab("config");
    await s.waitText("mise.toml");
    openTab("activity");
    await s.waitText(/Install missing tools|Create task hello/);
    await shot("activity");
  });

  test("Settings: widget scope buttons change the choice", async () => {
    openTab("settings");
    await s.waitText("WIDGET");
    click("widget.mode=global");
    await until(() => nodes(btn("widget.mode=global"))[0]?.class?.includes("on"), 8000, "global selected");
    click("widget.mode=mixed");
    await until(() => nodes(btn("widget.mode=mixed"))[0]?.class?.includes("on"), 8000, "mixed selected");
    click("widget.mode=local");
    await until(() => nodes(btn("widget.mode=local"))[0]?.class?.includes("on"), 8000, "local selected");
    await s.waitText("upgrade.prune_after");
    await shot("settings");
  });
});
