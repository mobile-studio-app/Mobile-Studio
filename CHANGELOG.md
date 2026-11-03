# Changelog

## 0.3.0

### Git, for real
- **Git now runs on libgit2.** Projects are real `.git` repositories that any other git tool understands, and clones bring the whole history. Fetch, pull and push work over HTTPS with GitHub (your signed-in account) or any other server. For other servers, your login is asked for once and kept in the Keychain.
- Merges, reverts and cherry-picks with real conflicts and abort; reset (soft, mixed or hard); tags; several remotes; detached HEAD; blame and file history.
- **Rebase** onto a branch, with continue, skip and abort at conflicts; also pull with rebase, and merge options (no fast-forward, fast-forward only, squash).
- **Interactive rebase**: pick, reword, edit, squash, fixup, drop and reorder commits in a sheet. Open it from Source Control's Branch menu, from a commit's menu, or with `git rebase -i`.
- **Submodules**: cloned with the repository, listed, updated, added and synced.
- **Source Control**: a multi-lane Graph of every branch, with branch, remote and tag labels. Fetch and Force Push. Commits have Checkout, Create Branch/Tag Here, Cherry-Pick, Revert and Reset.
- **The merge editor** shows the common ancestor and names each side (the branch, or the commit being replayed). Its menu compares the sides and takes either side's whole file.
- The Terminal's `git` does much more: rebase, submodule, mv, blame, shortlog, describe, reflog, grep, ls-files, clean, cat-file, rev-list, ls-remote, `log --graph/-p/--stat/--format`, `diff --stat`, `status -sb`, `push --delete` and more.

### VS Code extensions
- Much more of the VS Code API works:
  - terminals (an extension's commands run in a Terminal tab), quick picks and input boxes made by extensions, open and save dialogs, and cancellable progress in the status bar
  - file operations in workspace edits, file watchers, secrets (kept in the Keychain), and read-only virtual documents
  - activation when the project contains certain files, and the Testing, Comments, Chat and Language Model namespaces (so extensions that use them start)
- **Language features from extensions**:
  - completions that bring their imports with them, and signature help as you type a call
  - folding, code lenses, semantic colouring, ⌘-click links, colour swatches with a picker, and highlights of the symbol under the cursor
  - on-type formatting and **Format Selection** (⌘K ⌘F)
  - **Go to Type Definition**, **Go to Implementations** (⌘F12) and **Go to Declaration**, and **Go to Symbol in Workspace** (⌘T)
- **Menus**:
  - editor title buttons in the tab bar (the rest under "…")
  - editor context items with a right-click
  - Explorer context items
  - file badges and colours in the Explorer
  - `when` clauses in full
  - codicons in the status bar
- Fixed: an extension could start twice when extensions changed while the editor was loading.
- Extensions that need native programs still aren't supported.

### Python
- Fixed: Python programs didn't run at all because of a mistake in the runner.
- **pip** in the Terminal (`pip install …`, `python -m pip …`) installs pure-Python packages from PyPI, and packages with native code from BeeWare's iOS index. Native modules are signed on the device with your certificate so iOS can load them.

### AI chat agent
- The agent no longer loses track of the task: the question it's working on is never dropped to make room, and compacting keeps it word for word. Its reasoning carries between tool steps, and repeated tool calls are caught.
- Only models that use tools reliably can be the agent, and Think is offered only for models that reason. Other models still chat about the open file.
- **Up to 128K context** for Qwen3 4B and Qwen2.5-Coder 7B Instruct. A new cache precision setting (4-bit) fits about twice as much.
- Suggested models: Qwen2.5-Coder 3B and 7B Instruct, and Qwen3 4B.

### Reliability
- The Node.js extension host reconnects after iOS suspends the app, instead of being reported as stopped.

## 0.2.1

### AI chat
- **Cloud models, if you want them**: Settings → AI → Cloud Models connects Chat to Anthropic, OpenAI or OpenRouter with your own API key, or to Ollama or LM Studio on your network. It's off until you add a key, and the key is kept in the Keychain. The chat lists cloud models separately and says that your messages, and the files the agent reads, go to the provider. Tools, modes, thinking and subagents work the same as with local models.
- Fixed: after using the Extensions panel, the chat sometimes couldn't be opened.

### Getting started
- The Welcome screen has a **Get Started** section: **Open Sample Game** (a small LÖVE game to play with and change), **Set Up AI Chat…**, and a tip on where the chat agent is.

### Updates
- Mobile Studio now tells you when a new version is out (it checks GitHub at most once a day), and shows what's new after you update. Settings → About also has **Check for Updates** and **What's New**.

### Accessibility and diagnostics
- VoiceOver names for the chat's controls; selected activity bar buttons and search options are announced as selected.
- The Welcome screen and What's New follow your text size.
- **Settings → Advanced → Export Diagnostics** makes one text file for bug reports: app and device details, a few settings, your extensions, crash reports, the program console and the extension host's log. It has no keys, tokens or project files.

### Behind the scenes
- The editor's browser tests now live in the repository and run before every build.

## 0.2.0

### AI chat agent
- **Chat panel** (⌃⌘I, or the chat button in the tab bar): ask about your code with Apple Intelligence or a downloaded model. Everything runs on the device.
- **An agent, not just a chat.** It reads, searches and edits files across the project, runs shell commands, runs your program and reads its console, and reads the Terminal, the Output panel and the Problems list.
- **Modes** for what it may do without asking: Manual, Edit, Auto (asks before risky commands) and Turbo. Approval cards let you allow a change once, always for the chat, or deny it.
- **Thinking**: a Think toggle makes the agent reason before it answers. Qwen3 and DeepSeek-R1 reason natively, and other models are prompted to. The reasoning shows folded above the answer.
- **Subagents** research several questions side by side. You can give them their own model and context size and choose how many run at once.
- **Context**: a meter shows how much of the context is used. `/compact` (or Compact Now) summarises the conversation, and it compacts by itself near the limit. Context sizes go up to each model's maximum that fits in memory, with an 8-bit KV cache to fit more.
- **Suggested models**: Qwen2.5-Coder 3B Instruct, Qwen3 4B and Qwen2.5-Coder 1.5B Instruct, offered in Settings → AI → Chat and in the chat's model menu.
- More models to download in Settings → Advanced → AI Models: Qwen2.5-Coder, Qwen3, Llama 3.2, Gemma 3, Phi-4 mini, DeepSeek-R1 Distill and SmolLM2.

### Editor
- Side-by-side diff editor, git blame and file history.
- GitHub pull requests: browse, review diffs and create them.
- Quick Fix light bulb, inlay hints, Peek Definition and References, and Rename Symbol.
- Live Preview for HTML pages.
- Terminal, with a VS Code-style panel: Problems, Output, Debug Console and Terminal.
- File icon themes, such as Material Icon Theme.
- iPad: a menu bar, an editor context menu, a minimap, sticky scroll, and folders from the Files app.
- Settings split into pages, plus settings.json, keybindings.json and workspace settings.
- Easier to tap: the tab bar's buttons are finger-sized on touch screens.
- The activity bar's top buttons scroll instead of running into the bottom ones, and the status bar no longer has a tall empty strip under it.

### Extensions
- Extensions with views get one activity bar button each.
- Webviews of Node.js extensions load their scripts, styles and files.
- The Node.js extension host survives misbehaving extensions and says when it stops. Extensions see macOS as the platform, and more of the VS Code API works (notebooks, fetch, newer regular expressions).
- The extension list can filter by support (full, partial, not supported), by category and by sort order.
- Extensions that ship macOS programs, such as Claude Code and Codex, are marked not supported, because iOS can't run those programs. **Install Anyway (Experimental)** installs one regardless.

### Fixes
- LÖVE functions written in Lua are no longer flagged as unknown.

## 0.1.0

The first release.
