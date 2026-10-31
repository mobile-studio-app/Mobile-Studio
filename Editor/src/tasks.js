// Tasks: Run Task. Tasks come from .vscode/tasks.json, package.json's scripts and extensions.
// They run in Node.js (node-tasks.js): `node` scripts, `npm run` and `npm install` work; other
// programs can't run on iOS. Output goes to the Tasks channel of the Output panel.
import { parseJSONC } from './ext/registry.js';
import { quickPick, inputBox, notify } from './ext/ui.js';
import { nodeJob, extensionTasks, runTask as runExtensionTask } from './ext/host.js';
import { channelOutput } from './ext/output.js';

let native = null;
let flush = async () => {};

export function setupTasks(callbacks) {
  native = callbacks.native;
  flush = callbacks.flush;
}

const readJSON = (path) => native({ cmd: 'read', path }).then((text) => parseJSONC(text), () => null);

/** Every task: [{ label, detail, group, isDefault, command | extensionId }]. */
async function allTasks() {
  const out = [];
  const tasksJSON = await readJSON('.vscode/tasks.json');
  for (const t of (tasksJSON && tasksJSON.tasks) || []) {
    const group = typeof t.group === 'string' ? t.group : t.group?.kind;
    const isDefault = typeof t.group === 'object' && !!t.group.isDefault;
    let command = null;
    if (t.type === 'npm' && t.script) command = `npm run ${t.script}`;
    else if (t.command) command = [t.command, ...(t.args || []).map((a) => (typeof a === 'string' ? a : a.value))].join(' ');
    if (!command) continue;
    out.push({ label: t.label || command, detail: t.detail || command, group, isDefault, command, cwd: t.options?.cwd });
  }
  const pkg = await readJSON('package.json');
  for (const name of Object.keys((pkg && pkg.scripts) || {})) {
    out.push({ label: `npm: ${name}`, detail: pkg.scripts[name], group: name === 'build' ? 'build' : name === 'test' ? 'test' : '', command: `npm run ${name}` });
  }
  if (pkg) out.push({ label: 'npm: install', detail: 'install dependencies from package.json', command: 'npm install' });
  for (const t of await extensionTasks()) {
    out.push({ label: t.label, detail: t.detail || t.source, group: t.group, extensionId: t.id });
  }
  return out;
}

async function run(task) {
  await flush();
  if (task.extensionId) { await runExtensionTask(task.extensionId, task.label); return; }
  channelOutput('Tasks', 'show', true);
  channelOutput('Tasks', 'append', `> ${task.command}\n`);
  const code = await nodeJob('task', { command: task.command, cwd: task.cwd }, 'Tasks');
  channelOutput('Tasks', 'append', `\n${task.label} finished${code ? ` with exit code ${code}` : ''}.\n`);
  native({ cmd: 'filesChanged' }).catch(() => {});
}

/** Tasks: Run Task (or Run Build Task / Run Test Task with a group). */
export async function pickTask(group) {
  let tasks = await allTasks();
  if (group) {
    const inGroup = tasks.filter((t) => t.group === group);
    const preferred = inGroup.find((t) => t.isDefault);
    if (preferred) { run(preferred); return; }
    if (inGroup.length === 1) { run(inGroup[0]); return; }
    if (inGroup.length) tasks = inGroup;
  }
  if (!tasks.length) {
    notify('info', 'This project has no tasks. Add them in .vscode/tasks.json or as scripts in package.json.', []);
    return;
  }
  const chosen = await quickPick({ placeholder: 'Select the task to run', items: tasks.map((t) => ({ label: t.label, detail: t.detail })) });
  if (chosen != null) run(tasks[chosen]);
}

/** npm: Install Package… (adds it to package.json). */
export async function installPackage() {
  const names = await inputBox({ prompt: 'Packages to install from npm, e.g. "lodash" or "chalk@4"', placeholder: 'package names, separated by spaces' });
  if (!names || !names.trim()) return;
  await flush();
  channelOutput('npm', 'show', true);
  const code = await nodeJob('npm', { packages: names.trim().split(/\s+/) }, 'npm');
  native({ cmd: 'filesChanged' }).catch(() => {});
  if (code) notify('error', 'npm couldn\'t install everything. The npm output has the details.', []);
}

/** npm: Install Dependencies (from package.json). */
export async function installDependencies() {
  await flush();
  channelOutput('npm', 'show', true);
  const code = await nodeJob('npm', { packages: [] }, 'npm');
  native({ cmd: 'filesChanged' }).catch(() => {});
  if (code) notify('error', 'npm couldn\'t install everything. The npm output has the details.', []);
}
