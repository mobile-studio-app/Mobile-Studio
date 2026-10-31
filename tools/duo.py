#!/usr/bin/env python3
"""Drive Mobile Studio on a phone over Wi-Fi (Settings → Developer → Test Automation over Wi-Fi).

  python tools/duo.py pair 192.168.1.20 123456     # once: the address and code from Settings
  python tools/duo.py shot screen.png              # screenshot of the app
  python tools/duo.py tree                         # labelled elements with their positions
  python tools/duo.py tap "Commit"                 # tap by label (or: tap --xy 120 300)
  python tools/duo.py type "Fix jump" --label Message
  python tools/duo.py menu "More Actions" Branch "Merge Branch..." feature
  python tools/duo.py ctx "main.lua" "Stage Changes"   # a row's long-press menu
  python tools/duo.py swipe "main.lua" Stage
  python tools/duo.py alert                        # show the alert; alert Create --field feature
  python tools/duo.py js "return window.duocode.view.state.doc.toString()"
  python tools/duo.py state                        # branch, changes, conflicts, history
  python tools/duo.py dismiss                      # close the front sheet (Settings, Welcome)
  python tools/duo.py write src/a.lua "print(1)"   # read PATH, rm PATH
  python tools/duo.py git commit --message "Setup" # init, branch NAME, checkout NAME, merge NAME, ...

Only the standard library is used. The pairing is saved in ~/.duo.json.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

CONFIG = os.path.join(os.path.expanduser("~"), ".duo.json")


def load_config():
    host = os.environ.get("DUO_HOST")
    token = os.environ.get("DUO_TOKEN")
    if (not host or not token) and os.path.exists(CONFIG):
        with open(CONFIG) as f:
            saved = json.load(f)
        host = host or saved.get("host")
        token = token or saved.get("token")
    if not host or not token:
        sys.exit("Not paired. Run: duo.py pair <address from Settings> <pairing code>")
    if not host.startswith("http"):
        host = f"http://{host}"
    if host.count(":") < 2:
        host += ":8765"
    return host.rstrip("/"), token


def call(method, path, body=None, raw=False, timeout=120):
    host, token = load_config()
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(host + path, data=data, method=method,
                                     headers={"X-Duo-Token": token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        payload = error.read()
        try:
            message = json.loads(payload).get("error", payload.decode())
        except ValueError:
            message = payload.decode(errors="replace")
        sys.exit(f"Error {error.code}: {message}")
    except urllib.error.URLError as error:
        sys.exit(f"Can't reach Mobile Studio at {host}: {error.reason}. Is the app open with Test Automation on?")
    return payload if raw else json.loads(payload)


def show(result):
    print(json.dumps(result, indent=2, ensure_ascii=False))


def main():
    # Windows consoles default to a code page that can't print labels like "→" or "✦".
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser =argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pair"); p.add_argument("host"); p.add_argument("code")
    sub.add_parser("ping")
    p = sub.add_parser("shot"); p.add_argument("file", nargs="?", default="duo-screen.png"); p.add_argument("--scale", type=float, default=1)
    p = sub.add_parser("tree"); p.add_argument("--filter", default="")
    p = sub.add_parser("tap"); p.add_argument("label", nargs="?"); p.add_argument("--nth", type=int, default=0); p.add_argument("--xy", nargs=2, type=float)
    p = sub.add_parser("type"); p.add_argument("text"); p.add_argument("--label"); p.add_argument("--replace", action="store_true")
    p.add_argument("--submit", action="store_true"); p.add_argument("--done", action="store_true", help="dismiss the keyboard afterwards")
    p = sub.add_parser("alert"); p.add_argument("button", nargs="?"); p.add_argument("--field", action="append", default=[])
    p = sub.add_parser("menu"); p.add_argument("label"); p.add_argument("path", nargs="*"); p.add_argument("--nth", type=int, default=0)
    p = sub.add_parser("ctx"); p.add_argument("label"); p.add_argument("path", nargs="*"); p.add_argument("--nth", type=int, default=0)
    p = sub.add_parser("swipe"); p.add_argument("label"); p.add_argument("action"); p.add_argument("--nth", type=int, default=0)
    p = sub.add_parser("js"); p.add_argument("script")
    sub.add_parser("state")
    sub.add_parser("dismiss")
    p = sub.add_parser("write"); p.add_argument("path"); p.add_argument("contents")
    p = sub.add_parser("read"); p.add_argument("path")
    p = sub.add_parser("rm"); p.add_argument("path")
    p = sub.add_parser("git"); p.add_argument("op"); p.add_argument("name", nargs="?", default="")
    p.add_argument("--message", default="Automation"); p.add_argument("--force", action="store_true"); p.add_argument("--stay", action="store_true")
    p = sub.add_parser("wait"); p.add_argument("seconds", type=float)
    args = parser.parse_args()

    if args.command == "pair":
        with open(CONFIG, "w") as f:
            json.dump({"host": args.host, "token": args.code}, f)
        show(call("GET", "/ping"))
    elif args.command == "ping":
        show(call("GET", "/ping"))
    elif args.command == "shot":
        png = call("GET", f"/screenshot?scale={args.scale}", raw=True)
        with open(args.file, "wb") as f:
            f.write(png)
        print(args.file)
    elif args.command == "tree":
        result = call("GET", "/tree")
        for e in result["elements"]:
            if args.filter.lower() in e["label"].lower():
                flags = " ".join(k for k in ("menu", "checked", "focused", "selected") if e.get(k))
                if e.get("enabled") is False:
                    flags += " disabled"
                if "on" in e:
                    flags += f" on={e['on']}"
                print(f"{e['kind']:9} {e['x']:4},{e['y']:<4} {e['label'][:70]!r} {flags}".rstrip())
        if result.get("alert"):
            print("alert:", json.dumps(result["alert"], ensure_ascii=False))
    elif args.command == "tap":
        body = {"x": args.xy[0], "y": args.xy[1]} if args.xy else {"label": args.label, "nth": args.nth}
        show(call("POST", "/tap", body))
    elif args.command == "type":
        show(call("POST", "/type", {"text": args.text, "label": args.label, "replace": args.replace,
                                    "submit": args.submit, "dismissKeyboard": args.done}))
    elif args.command == "alert":
        if args.button:
            show(call("POST", "/alert", {"button": args.button, "fields": args.field}))
        else:
            show(call("GET", "/alert"))
    elif args.command in ("menu", "ctx"):
        path = "/menu" if args.command == "menu" else "/contextmenu"
        show(call("POST", path, {"label": args.label, "path": args.path, "nth": args.nth}))
    elif args.command == "swipe":
        show(call("POST", "/swipe", {"label": args.label, "action": args.action, "nth": args.nth}))
    elif args.command == "js":
        show(call("POST", "/js", {"script": args.script}))
    elif args.command == "dismiss":
        show(call("POST", "/dismiss"))
    elif args.command == "state":
        show(call("GET", "/state"))
    elif args.command == "write":
        show(call("POST", "/file", {"path": args.path, "contents": args.contents.encode().decode("unicode_escape")}))
    elif args.command == "read":
        print(call("GET", f"/file?path={urllib.request.quote(args.path)}")["contents"], end="")
    elif args.command == "rm":
        show(call("POST", "/file", {"path": args.path, "delete": True}))
    elif args.command == "git":
        show(call("POST", "/git", {"op": args.op, "name": args.name, "message": args.message,
                                   "force": args.force, "checkout": not args.stay}))
    elif args.command == "wait":
        time.sleep(args.seconds)


if __name__ == "__main__":
    main()
