# Changelog

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
