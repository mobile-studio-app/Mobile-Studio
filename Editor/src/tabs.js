// Editor tabs, as in VS Code: one per open file, with a preview tab (italic) that the next file
// opened replaces until it's edited or double-tapped. Diffs open in their own preview tab.

const tabs = [];        // { key, path, title, icon, preview, dirty }
// The file icon theme's icons (FileIconTheme.swift): name → data URL, or null for none.
let iconSource = null;
const themeIcons = new Map();

/** Where a file's themed icon comes from (a function of its name returning a data URL or null). */
export function setFileIconSource(source) { iconSource = source; refreshFileIcons(); }

/** The theme changed, or more of its icons were drawn. */
export function refreshFileIcons() { themeIcons.clear(); render(); }
let activeKey = null;
let container = null;
let handlers = { select() {}, close() {} };

/** `select(tab)` opens a tab; `close(tab)` closes one (after saving it if it's dirty). */
export function setupTabs(element, callbacks) {
  container = element;
  handlers = callbacks;
  render();
}

export const activeTab = () => tabs.find((t) => t.key === activeKey) || null;
export const openTabs = () => tabs.slice();

/** Shows `key` as the active tab, adding it if it isn't open. */
export function showTab({ key, path, title, icon, preview = true }) {
  let tab = tabs.find((t) => t.key === key);
  if (!tab) {
    tab = { key, path, title, icon, preview, dirty: false };
    const replace = preview ? tabs.findIndex((t) => t.preview && !t.dirty) : -1;
    if (replace >= 0) {
      tabs[replace] = tab;
    } else {
      const at = tabs.findIndex((t) => t.key === activeKey);
      tabs.splice(at >= 0 ? at + 1 : tabs.length, 0, tab);
    }
  } else {
    if (!preview) tab.preview = false;
    if (icon) tab.icon = icon;
    if (title) tab.title = title;
  }
  activeKey = key;
  render();
  return tab;
}

export function setTabIcon(key, icon) {
  const tab = tabs.find((t) => t.key === key);
  if (tab && tab.icon !== icon) { tab.icon = icon; render(); }
}

/** The active tab has unsaved edits; an edited preview tab is kept. */
export function setActiveDirty(dirty) {
  const tab = activeTab();
  if (!tab || tab.dirty === dirty) return;
  tab.dirty = dirty;
  if (dirty) tab.preview = false;
  render();
}

export function pinTab(key) {
  const tab = tabs.find((t) => t.key === key);
  if (tab && tab.preview) { tab.preview = false; render(); }
}

/** Removes a tab; returns the tab to show next if it was the active one. */
export function removeTab(key) {
  const index = tabs.findIndex((t) => t.key === key);
  if (index < 0) return null;
  tabs.splice(index, 1);
  let next = null;
  if (key === activeKey) {
    next = tabs[Math.min(index, tabs.length - 1)] || null;
    activeKey = next ? next.key : null;
  }
  render();
  return next;
}

/** Renames tabs after a file moved (or drops them if it was deleted: newPath null). */
export function renameTabs(oldPath, newPath) {
  for (const tab of tabs.slice()) {
    if (tab.path !== oldPath && !(tab.path || '').startsWith(oldPath + '/')) continue;
    if (newPath == null) { removeTab(tab.key); continue; }
    tab.path = newPath + tab.path.slice(oldPath.length);
    if (!tab.key.startsWith('diff:')) tab.key = tab.path;
  }
  render();
}

export function clearTabs() {
  tabs.length = 0;
  activeKey = null;
  render();
}

const fileName = (path) => path.split('/').pop();

function render() {
  if (!container) return;
  container.textContent = '';
  // Files with the same name show their folder, as in VS Code.
  const counts = new Map();
  for (const t of tabs) counts.set(fileName(t.title || t.path), (counts.get(fileName(t.title || t.path)) || 0) + 1);
  for (const tab of tabs) {
    const el = document.createElement('div');
    el.className = 'tab' + (tab.key === activeKey ? ' active' : '') + (tab.preview ? ' preview' : '');
    el.title = tab.title || tab.path;
    const icon = document.createElement('span');
    icon.className = 'tab-icon';
    icon.textContent = tab.icon || '📄';
    if (tab.path && iconSource) {
      const fileName = tab.path.split('/').pop();
      const url = themeIcons.get(fileName);
      if (url) {
        const img = document.createElement('img');
        img.src = url;
        img.alt = '';
        icon.replaceChildren(img);
      } else if (url === undefined) {
        themeIcons.set(fileName, null);
        Promise.resolve(iconSource(fileName)).then((found) => { if (found) { themeIcons.set(fileName, found); render(); } }, () => {});
      }
    }
    const name = document.createElement('span');
    name.className = 'tab-name';
    const label = tab.title || fileName(tab.path);
    name.textContent = label;
    el.append(icon, name);
    if (!tab.title && counts.get(label) > 1 && tab.path.includes('/')) {
      const folder = document.createElement('span');
      folder.className = 'tab-folder';
      folder.textContent = tab.path.slice(0, tab.path.lastIndexOf('/'));
      el.append(folder);
    }
    const close = document.createElement('button');
    close.className = 'tab-close' + (tab.dirty ? ' dirty' : '');
    close.setAttribute('aria-label', 'Close ' + label);
    close.addEventListener('click', (e) => { e.stopPropagation(); handlers.close(tab); });
    el.append(close);
    el.addEventListener('click', () => { if (tab.key !== activeKey) handlers.select(tab); });
    el.addEventListener('dblclick', () => pinTab(tab.key));
    container.append(el);
    if (tab.key === activeKey) requestAnimationFrame(() => el.scrollIntoView({ block: 'nearest', inline: 'nearest' }));
  }
}
