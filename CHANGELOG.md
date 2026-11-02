# Changelog

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
