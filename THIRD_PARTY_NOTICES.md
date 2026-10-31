# Third-party notices

Mobile Studio's own code is under the MIT License (see [LICENSE](LICENSE)). The app also
includes, or downloads while it builds, the components below, each under its own licence.
Their licences allow redistribution in Mobile Studio; most require their copyright notice and
licence text to go with copies of the app.

## In the app

| Component | Used for | Licence |
|---|---|---|
| [LÖVE](https://love2d.org) 11.5 and 12 | game runtimes | zlib |
| [SDL 3](https://libsdl.org) | LÖVE 12's window, input and audio | zlib |
| [LuaJIT](https://luajit.org) | LÖVE's Lua | MIT |
| LÖVE's iOS dependencies ([love-apple-dependencies](https://github.com/love2d/love-apple-dependencies)): FreeType, HarfBuzz, libmodplug, libogg, libvorbis, libtheora | fonts, text shaping, audio and video in LÖVE | FreeType License, MIT, public domain, BSD-3-Clause |
| [Lua 5.4](https://www.lua.org) | the Lua runtime | MIT |
| [CPython](https://www.python.org) 3.14, from [BeeWare's Python-Apple-support](https://github.com/beeware/Python-Apple-support) | the Python runtime | PSF License 2.0 (its bundled libraries: see that project) |
| [Node.js](https://nodejs.org) 18.20.4, as [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) | the JavaScript runtime and extension host | MIT; includes V8 (BSD-3-Clause), ICU (Unicode License v3), OpenSSL (Apache-2.0), libuv (MIT) and others listed in its LICENSE |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | on-device AI completion | MIT |
| [CodeMirror 6](https://codemirror.net) and [Lezer](https://lezer.codemirror.net) | the code editor | MIT |
| [vscode-textmate](https://github.com/microsoft/vscode-textmate), [vscode-oniguruma](https://github.com/microsoft/vscode-oniguruma) | extensions' syntax highlighting | MIT (Oniguruma: BSD-2-Clause) |
| [luaparse](https://github.com/fstirlitz/luaparse) | Lua diagnostics | MIT |
| [Codicons](https://github.com/microsoft/vscode-codicons) | icons | CC BY 4.0 ([licence](App/Resources/Fonts/codicon-LICENSE.txt)) |
| [apple-codesign](https://github.com/indygreg/apple-platform-rs) and its Rust dependencies | signing extensions' macOS programs | MPL-2.0 (used unmodified); dependencies under MIT, Apache-2.0, BSD, ISC and Unicode-3.0 |

## Not included

- AI models (Qwen2.5-Coder) are downloaded by the user from Settings, under their own licences.
- VS Code extensions are downloaded by the user from Open VSX, under their own licences.
