# Mobile Studio

A VS Code-style IDE for iPhone and iPad that runs your code on the device: no server, no streaming.

- **Languages and runtimes:** Lua 5.4, Python 3, JavaScript (Node.js 18 with ICU), and LÖVE 11.5 / 12 games, each built in as a plug-in runtime. More languages can be added through the same runtime interface.
- **VS Code extensions** from [Open VSX](https://open-vsx.org): themes, grammars, snippets, language settings, web extensions and Node.js extensions, with views, custom editors and tasks. Each extension is checked before it installs and labelled as working, partly working or not supported.
- **macOS programs from extensions** (language servers, linters) run inside the app, signed with your own development certificate. No JIT or VPN is needed (Settings → Programs from Extensions).
- **Debugging** with breakpoints, stepping and variables for Lua, Python and JavaScript.
- **Git** (clone, commit, branches, merge, push) with GitHub sign-in.
- **AI code completion** on the device (Apple Intelligence or a local model).
- **Editor:** CodeMirror 6 with completions, diagnostics, split editor, Output panel and Command Palette.

## Installing

Mobile Studio isn't on the App Store. You install it yourself ("sideloading"), signed with your own Apple ID.

**You need:**
- An iPhone or iPad on **iOS 17 or later**.
- An **Apple ID**. A free one works.
- A **Windows PC or Mac** for the first install.

**Steps:**
1. **Download the app.** Open this repository's **Releases**, find **Latest build**, and download `MobileStudio.ipa`.
2. **Install a sideloading tool.** We recommend **SideStore**: it keeps the app's *increased memory limit* (room for games, language servers and the AI model), and it can refresh the app from the iPhone itself, without a computer. AltStore works the same way. Plume Impactor and Sideloadly also install the app, but may not keep the higher memory limit. Set the tool up by following its own guide.
3. **Turn on Developer Mode** on the iPhone: **Settings → Privacy & Security → Developer Mode**, then restart when asked and confirm. iOS 16 and later need this for any sideloaded app.
4. **Install Mobile Studio.** In your sideloading tool, choose to install an app (in SideStore: **My Apps → +**) and pick `MobileStudio.ipa`. Sign in with your Apple ID if it asks.
5. **If iOS says "Untrusted Developer"** when you open it, go to **Settings → General → VPN & Device Management**, tap your Apple ID and choose **Trust**.

**Keeping it working:**
- With a **free Apple ID**, the app has to be refreshed every **7 days** or it stops opening (your files are kept). SideStore and AltStore can do this on the phone; with other tools, install the IPA again from the computer. A paid Apple Developer account lasts a year.
- **To update**, install a newer `MobileStudio.ipa` the same way. It replaces the old one and keeps your projects, extensions and settings.

**Optional extras:**
- **Programs from extensions** (for example Ruff's or rust-analyzer's macOS programs) need the signing certificate your sideloading tool used. Export it as a `.p12` file (Plume Impactor: **Settings → Export P12**), save it to the iPhone, then import it in **Mobile Studio → Settings → Programs from Extensions**.
- **LuaJIT's JIT compiler** (faster LÖVE games) needs a JIT enabler such as StikDebug. Without one, LuaJIT uses its interpreter.

## Building (no Mac needed)
1. Fork or push this repo to GitHub. Builds use GitHub Actions, which is free for public repositories.
2. **Actions → Build IPA** runs on every push to `main`, or on demand. Each build of `main` replaces the **Latest build** release and is also kept as the `MobileStudio-ipa` artifact.
3. Install `MobileStudio.ipa` as described above.

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
