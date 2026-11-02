# Mobile Studio editor

The code editor that runs inside the app's WKWebView: CodeMirror 6 with Lua/LÖVE completions,
signature help, long-press docs, and Lua/JSON diagnostics.

```sh
npm install
npm run docs    # regenerate src/love-api.json from LuaCATS/love2d + the pinned LÖVE 12 source
npm run build   # writes ../App/Resources/Editor/editor.bundle.js
```

The built bundle and `src/love-api.json` are committed, so the iOS build (CI) doesn't need Node.
Rebuild and commit them after changing anything in `src/`.

## Tests

```sh
npm test          # every scenario in tests/scenarios
npm test -- chat  # the scenarios whose names contain "chat"
```

Each scenario runs in the real editor page (`App/Resources/Editor/editor.html` and the built
bundle) in headless Chrome or Edge (`CHROME_PATH` to pick one), with the app faked by
`tests/mock.js`. Scenarios call `check(name, ok, detail)`; any failed check, page error or timeout
fails the run. CI runs them before building the app. `VERBOSE=1` lists the checks that passed too.

`src/love-api.json` combines LÖVE 11.5 documentation (descriptions, parameters, overloads) from
[LuaCATS/love2d](https://github.com/LuaCATS/love2d), which is generated from the LÖVE wiki, with the
list of functions and methods in LÖVE 12 read from its source. Functions new in 12.0 complete but
have no description until the upstream docs are updated.
