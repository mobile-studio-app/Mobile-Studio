#!/usr/bin/env python3
"""Builds Node.js's Mac-side tools for the Mac when building for iOS (scripts/build-nodejs.sh).

common.gypi gives every target on iOS the iPhone SDK and deployment target, including the
tools built to run during the build (the "host" toolset). V8's own tools undo that in
tools/v8_gypfiles/toolchain.gypi, but ICU's don't, so they come out as iOS code, and V8's
gen-regexp-special-case, a Mac tool that links them, fails: "building for 'macOS', but linking
in object file built for 'iOS'". This applies V8's override to every host target.

usage: patch-nodejs-host-tools.py <node source>/common.gypi
"""
import sys

path = sys.argv[1]
text = open(path, encoding='utf-8', newline='').read()

block = text.index("['OS==\"ios\"', {\n        'defines': ['_DARWIN_USE_64_BIT_INODE=1'],")
anchor = "        'target_conditions': [\n"
at = text.index(anchor, block) + len(anchor)
override = """          ['_toolset=="host" and host_os=="mac"', {
            'xcode_settings': {
              'SDKROOT': '',
              'IPHONEOS_DEPLOYMENT_TARGET': '',
              'MACOSX_DEPLOYMENT_TARGET': '10.15',
            },
          }],
"""
if override in text:
    sys.exit(0)
text = text[:at] + override + text[at:]
open(path, 'w', encoding='utf-8', newline='').write(text)
print('Host tools build for the Mac:', path)
