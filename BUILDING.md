# Building Mobile Studio

You don't need this to use Mobile Studio: download it from the Releases page (see the
[README](README.md)). This is for working on the app itself.

## With GitHub Actions (no Mac needed)
1. Fork this repository. GitHub Actions is free for public repositories.
2. **Actions → Build IPA** runs on every push to `main`, and on demand. The app is saved as the
   `MobileStudio-ipa` artifact of each run.
3. **Releases:** pushing a tag such as `v0.2.0` builds that commit and publishes a release with
   `MobileStudio.ipa` attached. Set `MARKETING_VERSION` in `project.yml` to match first.

Heavy dependencies are built or fetched by scripts and cached by CI (all under `third_party/`,
which is gitignored). The first build of a fork takes about an hour; later ones a few minutes.

| Script | What |
|---|---|
| `scripts/build-love-ios.sh` | LÖVE 12 and its iOS dependencies, at pinned commits |
| `scripts/compile-nodejs.sh`, `scripts/build-nodejs.sh` | Node.js for iOS (nodejs-mobile 18.20.4) built with ICU |
| `scripts/fetch-python.sh` | CPython for iOS |
| `scripts/fetch-llama.sh` | llama.cpp, for local AI completion (models download in the app) |
| `scripts/build-prepare.sh` | the Rust library that prepares and signs extensions' macOS programs |

## On a Mac
Run those scripts (Node.js needs Xcode 15 or 16 and Python 3.11), then
`brew install xcodegen && xcodegen generate && open DuoCode.xcodeproj`.

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

## Layout simulator
`tools/simulator/index.html` is a single-page model of the app's layout on each device, ported
from the layout code in `App/Shell`. Changes to it on `main` are published to GitHub Pages by
`.github/workflows/pages.yml`. When the app's layout code changes, update it to match.

## Runtime plug-ins
A runtime is an embedded `.framework` that exports one symbol, `duocode_runtime_entry`, and ships
a `runtime.json` manifest (id, language, files that detect it, priority). The host `dlopen`s it
with `RTLD_LOCAL`. Console runtimes (Lua, Python, JavaScript) print to the IDE's console; game
runtimes (LÖVE) draw in a pane next to the editor. See
[`Runtimes/include/duocode_runtime.h`](Runtimes/include/duocode_runtime.h).

A project's runtime is chosen by:
1. `.duocode/settings.json` → `{ "runtime": "python-3.14" }`
2. the manifests' `detect` files (`main.py`, `main.js`, `main.lua`...)
3. the highest `priority`
