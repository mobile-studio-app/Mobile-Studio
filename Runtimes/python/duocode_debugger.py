"""DuoCode's Python debugger: bdb driven by the IDE over the runtime's debug channel.

The runner imports this when a run is debugged and calls run(path) in place of runpy, and
post_mortem(error) when the program fails. Commands and events are JSON, as described in
Runtimes/common/DebugChannel.h. send(json) and receive(timeout) come from _duocode.
"""
import bdb
import json
import os
import reprlib
import sys

import _duocode

_repr = reprlib.Repr()
_repr.maxstring = 300
_repr.maxother = 300
_repr.maxlist = _repr.maxtuple = _repr.maxdict = _repr.maxset = 8


def _send(message):
    _duocode.debug_send(json.dumps(message))


class Debugger(bdb.Bdb):
    def __init__(self, project, config):
        super().__init__(skip=['bdb', 'runpy', 'importlib.*', 'duocode_debugger', 'reprlib', 'json.*', 'codecs', 'encodings.*'])
        # Code names files by the path it was given; realpath can differ (/var vs /private/var).
        self.project = os.path.abspath(project)
        self.real_project = os.path.realpath(project)
        self.stop_on_errors = config.get('stopOnErrors', True)
        self.frames = []
        self.refs = []
        self.lines_seen = 0
        self.pause_requested = False
        self.logpoints = {}
        self.set_breakpoints(config.get('breakpoints') or {})

    # Paths ---------------------------------------------------------------------------

    def relative(self, filename):
        """A project file's relative path, or None for code outside the project."""
        if not filename or filename.startswith('<'):
            return None
        for root, path in ((self.project, os.path.abspath(filename)), (self.real_project, os.path.realpath(filename))):
            if path.startswith(root + os.sep):
                return os.path.relpath(path, root).replace(os.sep, '/')
        return None

    def set_breakpoints(self, breakpoints):
        self.clear_all_breaks()
        self.logpoints = {}
        for file, entries in breakpoints.items():
            path = os.path.join(self.project, file)
            for bp in entries:
                line = bp.get('line')
                if not line:
                    continue
                if bp.get('logMessage'):
                    # Logpoints print and carry on: a breakpoint whose condition logs, then is false.
                    self.logpoints[(os.path.abspath(path), line)] = bp['logMessage']
                self.set_break(path, line, cond=bp.get('condition') or None)

    # bdb hooks -----------------------------------------------------------------------

    def set_continue(self):
        # Keep tracing even without breakpoints, so Pause and new breakpoints still work. The stop
        # frame must be a real one: without one, bdb stops at the next line.
        self._set_stopinfo(self.botframe or sys._getframe(), None, -1)

    def dispatch_call(self, frame, arg):
        # bdb only traces into functions with breakpoints; project code is always traced so
        # Pause and breakpoints added while running work everywhere.
        result = super().dispatch_call(frame, arg)
        if result is None and not self.quitting and self.relative(frame.f_code.co_filename):
            return self.trace_dispatch
        return result

    def dispatch_line(self, frame):
        self.lines_seen += 1
        if self.lines_seen % 200 == 0:
            self.poll()
        if self.pause_requested and self.relative(frame.f_code.co_filename):
            self.pause_requested = False
            self.interaction(frame, 'pause')
            return self.trace_dispatch
        return super().dispatch_line(frame)

    def break_here(self, frame):
        key = (os.path.abspath(frame.f_code.co_filename), frame.f_lineno)
        message = self.logpoints.get(key)
        if message is not None and super().break_here(frame):
            _send({'event': 'output', 'text': self.interpolate(message, frame), 'file': self.relative(key[0]), 'line': key[1]})
            return False
        return super().break_here(frame)

    def user_line(self, frame):
        if not self.relative(frame.f_code.co_filename):
            # Stepping into library code: keep going until we're back in the project.
            self.set_step()
            return
        filename = self.canonic(frame.f_code.co_filename)
        reason = 'breakpoint' if self.get_breaks(filename, frame.f_lineno) else 'step'
        self.interaction(frame, reason)

    def user_return(self, frame, value):
        pass

    def user_exception(self, frame, info):
        pass

    # Running commands ----------------------------------------------------------------

    def poll(self):
        while True:
            raw = _duocode.debug_receive(0)
            if raw is None:
                return
            self.handle_running(json.loads(raw))

    def handle_running(self, message):
        command = message.get('command')
        if command == 'setBreakpoints':
            self.set_breakpoints(message.get('breakpoints') or {})
            if 'stopOnErrors' in message:
                self.stop_on_errors = message['stopOnErrors']
            self.reply(message, True)
        elif command == 'pause':
            self.pause_requested = True
        elif 'id' in message:
            self.reply(message, None, 'The program is running.')

    def reply(self, message, body, error=None):
        if 'id' not in message:
            return
        out = {'response': message['id']}
        if error is not None:
            out['error'] = error
        else:
            out['body'] = body
        _send(out)

    # Stopped -------------------------------------------------------------------------

    def stack_frames(self, frame=None, tb=None):
        """Project frames, innermost first."""
        stack = []
        if tb is not None:
            while tb is not None:
                stack.append((tb.tb_frame, tb.tb_lineno))
                tb = tb.tb_next
            stack.reverse()
        else:
            while frame is not None:
                stack.append((frame, frame.f_lineno))
                frame = frame.f_back
        out = []
        for f, line in stack:
            file = self.relative(f.f_code.co_filename)
            if file:
                name = f.f_code.co_qualname if hasattr(f.f_code, 'co_qualname') else f.f_code.co_name
                out.append({'frame': f, 'id': len(out) + 1, 'name': '<module>' if name == '<module>' else name, 'file': file, 'line': line})
        return out

    def interaction(self, frame, reason, text=None, tb=None):
        self.frames = self.stack_frames(frame, tb)
        self.refs = []
        _send({'event': 'stopped', 'reason': reason, 'text': text,
               'frames': [{k: v for k, v in f.items() if k != 'frame'} for f in self.frames]})
        top = self.frames[0]['frame'] if self.frames else frame
        while True:
            raw = _duocode.debug_receive(-1)
            if raw is None:
                # The run is ending.
                self.clear_all_breaks()
                self.set_continue()
                raise KeyboardInterrupt
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            command = message.get('command')
            if command == 'continue':
                self.set_continue()
                break
            if command in ('next', 'stepIn', 'stepOut'):
                if reason == 'exception':
                    self.set_continue()
                elif command == 'next':
                    self.set_next(top)
                elif command == 'stepIn':
                    self.set_step()
                else:
                    self.set_return(top)
                break
            if command == 'setBreakpoints':
                self.set_breakpoints(message.get('breakpoints') or {})
                if 'stopOnErrors' in message:
                    self.stop_on_errors = message['stopOnErrors']
                self.reply(message, True)
            elif command == 'scopes':
                f = self.frame_at(message.get('frame', 1))
                if f is None:
                    self.reply(message, [])
                else:
                    scopes = [{'name': 'Locals', 'ref': self.new_ref(('mapping', f.f_locals))}]
                    if f.f_globals is not f.f_locals:
                        scopes.append({'name': 'Globals', 'ref': self.new_ref(('globals', f.f_globals))})
                    self.reply(message, scopes)
            elif command == 'variables':
                try:
                    self.reply(message, self.children(message.get('ref', 0)))
                except Exception as error:
                    self.reply(message, None, str(error))
            elif command == 'evaluate':
                self.reply(message, *self.evaluate(message.get('expression', ''), self.frame_at(message.get('frame', 1)), message.get('context')))
            elif 'id' in message:
                self.reply(message, None, 'Unknown request %s' % command)
        self.frames = []
        self.refs = []
        _send({'event': 'continued'})

    def frame_at(self, frame_id):
        for f in self.frames:
            if f['id'] == frame_id:
                return f['frame']
        return None

    # Values --------------------------------------------------------------------------

    def new_ref(self, entry):
        self.refs.append(entry)
        return len(self.refs)

    def describe(self, value):
        kind = type(value).__name__
        try:
            text = _repr.repr(value)
        except Exception:
            text = '<%s>' % kind
        out = {'value': text, 'type': kind}
        if isinstance(value, (dict, list, tuple, set, frozenset)) and len(value):
            out['ref'] = self.new_ref(('value', value))
        elif hasattr(value, '__dict__') and not isinstance(value, type(sys)) and not callable(value):
            out['ref'] = self.new_ref(('value', value))
        return out

    def variable(self, name, value):
        out = self.describe(value)
        out['name'] = name
        return out

    def children(self, ref):
        if ref < 1 or ref > len(self.refs):
            return []
        kind, value = self.refs[ref - 1]
        if kind in ('mapping', 'globals'):
            return [self.variable(k, v) for k, v in value.items()
                    if not (k.startswith('__') and k.endswith('__')) and not isinstance(v, type(sys))]
        if isinstance(value, dict):
            return [self.variable(_repr.repr(k), v) for k, v in list(value.items())[:500]]
        if isinstance(value, (list, tuple)):
            return [self.variable('[%d]' % i, v) for i, v in enumerate(value[:500])]
        if isinstance(value, (set, frozenset)):
            return [self.variable('[%d]' % i, v) for i, v in enumerate(list(value)[:500])]
        return [self.variable(k, v) for k, v in vars(value).items() if not k.startswith('__')]

    def evaluate(self, expression, frame, context=None):
        if frame is None:
            return None, 'No frame selected.'
        try:
            code = compile(expression, '<debug console>', 'eval')
        except SyntaxError:
            try:
                code = compile(expression, '<debug console>', 'exec')
            except SyntaxError as error:
                return None, 'SyntaxError: %s' % error.msg
        try:
            value = eval(code, frame.f_globals, frame.f_locals)
        except Exception as error:
            return None, '%s: %s' % (type(error).__name__, error)
        if value is None and context == 'repl':
            return {'value': '', 'type': 'NoneType'}, None
        return self.describe(value), None

    def interpolate(self, message, frame):
        import re

        def one(match):
            body, error = self.evaluate(match.group(1), frame)
            return '{%s}' % error if error else (body['value'].strip('\'"') if body['type'] == 'str' else body['value'])
        return re.sub(r'\{(.*?)\}', one, message)

    # Entry points --------------------------------------------------------------------

    def run_path(self, path):
        import runpy
        self.reset()
        self.set_continue()
        sys.settrace(self.trace_dispatch)
        try:
            return runpy.run_path(path, run_name='__main__')
        finally:
            self.quitting = True
            sys.settrace(None)

    def post_mortem(self, error):
        """Shows an uncaught error where it happened, before the program ends."""
        if not self.stop_on_errors or isinstance(error, (KeyboardInterrupt, SystemExit)):
            return
        sys.settrace(None)
        tb = error.__traceback__
        if not self.stack_frames(tb=tb):
            return
        try:
            self.interaction(None, 'exception', '%s: %s' % (type(error).__name__, error), tb=tb)
        except KeyboardInterrupt:
            pass


def create(project):
    config = json.loads(_duocode.debug_config() or '{}')
    return Debugger(project, config)
