# Mobile Studio

A VS Code-style IDE for iPhone and iPad that runs your code on the device: no server, no streaming.

- **Languages and runtimes:** Lua 5.4, Python 3, JavaScript (Node.js 18 with ICU), and LÖVE 11.5 / 12 games, each built in as a plug-in runtime. More languages can be added through the same runtime interface.
- **VS Code extensions** from [Open VSX](https://open-vsx.org): themes, grammars, snippets, language settings, web extensions and Node.js extensions, with views, custom editors and tasks. Each extension is checked before it installs and labelled as working, partly working or not supported.
- **macOS programs from extensions** (language servers, linters) run inside the app, signed with your own development certificate. No JIT or VPN is needed (Settings → Programs from Extensions).
- **Debugging** with breakpoints, stepping and variables for Lua, Python and JavaScript.
- **Git** (clone, commit, branches, merge, push) with GitHub sign-in.
- **AI code completion** on the device (Apple Intelligence or a local model).
- **Editor:** CodeMirror 6 with completions, diagnostics, split editor, Output panel and Command Palette.

## Building (no Mac needed)
1. Push this repo to GitHub.
2. **Actions → Build IPA** runs on every push to `main`, or on demand. Download the `MobileStudio-ipa` artifact.
3. Sideload `MobileStudio.ipa` with Plume Impactor, SideStore, AltStore, Sideloadly or similar.
   - To keep the **increased memory limit** entitlement, use a sideloader that preserves app entitlements.
   - **LuaJIT's JIT** needs a JIT enabler such as StikDebug; without one, LuaJIT uses its interpreter.

Heavy dependencies are built or fetched by scripts and cached by CI (all under `third_party/`, which is gitignored):

| Script | What |
|---|---|
| `scripts/build-love-ios.sh` | LÖVE 12 and its iOS dependencies, at pinned commits |
| `scripts/compile-nodejs.sh`, `scripts/build-nodejs.sh` | Node.js for iOS (nodejs-mobile 18.20.4) built with ICU |
| `scripts/fetch-python.sh` | CPython for iOS |
| `scripts/fetch-llama.sh` | llama.cpp, for local AI completion (models download in the app) |
| `scripts/build-prepare.sh` | the Rust library that prepares and signs extensions' macOS programs |

On a Mac with Xcode: run those scripts, then `brew install xcodegen && xcodegen generate && open DuoCode.xcodeproj`.

## Layout
```
App/                    Swift host: shell, editor bridge, runtimes, projects, extensions, git, AI
App/NativeTools/        runs extensions' macOS programs in the app
Editor/                 the editor page (CodeMirror 6) and the extension hosts (web worker, Node.js)
NativeTools/prepare/    Rust: rewrites a macOS program as a loadable library and signs it
Runtimes/include/       duocode_runtime.h, the runtime plug-in interface
Runtimes/<id>/          one framework per runtime, with a runtime.json manifest
scripts/                build and packaging scripts
project.yml             XcodeGen spec
```

## Runtime plug-ins
A runtime is an embedded `.framework` that exports one symbol, `duocode_runtime_entry`, and ships a `runtime.json` manifest (id, language, files that detect it, priority). The host `dlopen`s it with `RTLD_LOCAL`. Console runtimes (Lua, Python, JavaScript) print to the IDE's console; game runtimes (LÖVE) draw in a pane next to the editor. See [`Runtimes/include/duocode_runtime.h`](Runtimes/include/duocode_runtime.h).

A project's runtime is chosen by:
1. `.duocode/settings.json` → `{ "runtime": "python-3.14" }`
2. the manifests' `detect` files (`main.py`, `main.js`, `main.lua`...)
3. the highest `priority`

## Screens
- **Portrait** stacks the output above the editor; **landscape** puts them side by side. Swap flips either.
- **iPhone Duo inner display:** each pane gets one half of the screen, with the seam on the hinge.

## Shortcuts
| Keys | Action |
|---|---|
| ⌘R | Run / restart |
| ⌘. | Stop |
| ⇧⌘P | Command Palette |
| ⇧⌘U | Output panel |
| ⌘\ | Split editor |
| ⌃⇧G | Toggle input focus between game and editor |
| ⌃⇧S | Swap the panes |
| ⌃⇧M | Maximize / restore the output |

## Licence
Mobile Studio is under the [MIT License](LICENSE). The components it includes keep their own licences; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
