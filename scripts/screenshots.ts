// Regenerates docs/images/*.png from a real, isolated Tern window and a throwaway mise world.
// Needs network (installs a few small tools). The world lives in a new folder under DEMO_BASE so the
// paths in the pictures say nothing about the machine; the window chrome (terminal pane, avatar) is cropped away.
import { mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { TernSession, sleep, IS_WIN } from "../test/ui/harness";
import { MiseWorld } from "../test/support/mise-env";

const out = resolve(import.meta.dir, "..", "docs", "images");
mkdirSync(out, { recursive: true });
// DEMO_BASE (default: the temp folder) must exist; the world is a new child of it and is deleted afterwards.
const root = join(process.env.DEMO_BASE ?? tmpdir(), "projects");
const w = new MiseWorld(undefined, root);

w.write("cfg/config.toml", '[tools]\nripgrep = "14"\n');
const proj = w.project("acme-web", `[tools]
node = "22"
jq = "1.6"
fd = "10"

[env]
NODE_ENV = "development"

[tasks.dev]
description = "Start the dev server with live reload"
run = "bun run dev"

[tasks.build]
description = "Build the production bundle"
depends = ["lint"]
run = "bun run build"

[tasks.lint]
description = "Check style and types"
run = "bun run lint"

[tasks.test]
description = "Run the unit and integration tests"
depends = ["lint"]
run = "bun test"
quiet = true

[tasks.deploy]
description = "Build, then publish to staging"
depends = ["build", "test"]
run = '''
set -e
echo "Publishing $(git rev-parse --short HEAD)"
bun run deploy --env staging
'''
`);
w.trust(w.cfgFile, join(proj, "mise.toml"));
// An older fd is installed first so the "10" request shows an update.
for (const spec of ["ripgrep@14", "fd@10.1.0", "jq@1.6"]) console.log(spec, w.run(["install", spec], proj).status);

const s = await TernSession.start(resolve(import.meta.dir, ".."), { ...w.env }, { cwd: proj });
const crop = (src: string, dest: string) => {
  // The window is 1280x800 with the plugin pane on the right; keep the pane only.
  if (IS_WIN) {
    const ps = `Add-Type -AssemblyName System.Drawing; $i=[System.Drawing.Bitmap]::FromFile('${src}'); $r=New-Object System.Drawing.Rectangle 442,40,($i.Width-442-8),($i.Height-40-8); $c=$i.Clone($r,$i.PixelFormat); $c.Save('${dest}'); $c.Dispose(); $i.Dispose()`;
    spawnSync("powershell.exe", ["-NoProfile", "-Command", ps], { stdio: "inherit" });
  } else {
    spawnSync("sips", ["-c", String(800 - 48), String(1280 - 450), "--cropOffset", "40", "442", src, "--out", dest], { stdio: "inherit" });
  }
};
const shot = async (name: string) => {
  const png = await s.shot(name);
  crop(png, join(out, name + ".png"));
  console.log("wrote", join(out, name + ".png"));
};
const click = (act: string) => s.ctl(`click [data-role='mise.btn:${act}']`);
try {
  await sleep(2500);
  s.run("plugin.mise.open");
  await s.waitText("ripgrep", 40000);
  await s.waitText("jq", 20000);
  if (s.texts().some((t) => t.includes("Environment differs"))) { click("drift.hide"); await sleep(500); }
  await sleep(2500);
  await shot("tools");
  click("tab=tasks");
  await s.waitText("Start the dev server", 20000);
  s.ctl("click [title^='deploy ·']");
  await sleep(1500);
  await shot("tasks");
  click("task.new");
  await s.waitText("New task");
  for (const c of ['type "release"', "key tab", 'type "bun run build"', "key enter", 'type "bun run publish --tag latest"', "key tab", 'type "Tag and publish a release"']) { s.ctl(c); await sleep(350); }
  click("taskform.source");
  await sleep(1500);
  await shot("task-editor");
} finally {
  await s.stop();
  w.cleanup();
}
