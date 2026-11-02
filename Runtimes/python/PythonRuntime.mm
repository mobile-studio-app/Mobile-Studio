// CPython 3.14 as a console runtime: runs the project's main.py with stdout, stderr and stdin
// wired to DuoCode's console (input() reads what's typed into it). Python is started for each
// run and finalised afterwards, so every run starts clean.

#import <Foundation/Foundation.h>
#include <atomic>
#include <string>
#include <Python/Python.h>
#include "ConsoleAdapter.h"
#include "DebugChannel.h"

static std::string g_project;
// pip's packages (Application Support/python3.14/site-packages, on every run's path) and pip
// itself (its wheel in the bundle, imported from the zip).
static std::string g_sitePackages;
static std::string g_pipWheel;
static int g_exitCode = 0;
static std::atomic<bool> g_pythonRunning{false};

// MARK: - The _duocode module

static PyObject *duo_write(PyObject *, PyObject *args) {
    int level = DC_LOG_GAME;
    const char *text = NULL;
    Py_ssize_t length = 0;
    if (!PyArg_ParseTuple(args, "is#", &level, &text, &length)) return NULL;
    dc_console_write((dc_log_level)level, text, (size_t)length);
    Py_RETURN_NONE;
}

static PyObject *duo_readline(PyObject *, PyObject *) {
    char *line = NULL;
    Py_BEGIN_ALLOW_THREADS
    line = dc_console_read_line();
    Py_END_ALLOW_THREADS
    if (!line) Py_RETURN_NONE;
    PyObject *text = PyUnicode_DecodeUTF8(line, (Py_ssize_t)strlen(line), "replace");
    free(line);
    return text;
}

static PyObject *duo_stopping(PyObject *, PyObject *) {
    return PyBool_FromLong(dc_console_should_stop());
}

static PyObject *duo_error(PyObject *, PyObject *args) {
    const char *message = NULL, *file = NULL;
    int line = 0;
    if (!PyArg_ParseTuple(args, "szi", &message, &file, &line)) return NULL;
    dc_console_report_error(message, file, line);
    Py_RETURN_NONE;
}

static PyObject *duo_project(PyObject *, PyObject *) {
    return PyUnicode_FromString(g_project.c_str());
}

static PyObject *duo_exit(PyObject *, PyObject *args) {
    if (!PyArg_ParseTuple(args, "i", &g_exitCode)) return NULL;
    Py_RETURN_NONE;
}

// The debugger's channel (duocode_debugger.py).
static PyObject *duo_debug_send(PyObject *, PyObject *args) {
    const char *json = NULL;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    dc_debug_send(json);
    Py_RETURN_NONE;
}

static PyObject *duo_debug_receive(PyObject *, PyObject *args) {
    double timeout = -1;
    if (!PyArg_ParseTuple(args, "|d", &timeout)) return NULL;
    char *message = NULL;
    Py_BEGIN_ALLOW_THREADS
    message = dc_debug_receive(timeout);
    Py_END_ALLOW_THREADS
    if (!message) Py_RETURN_NONE;
    PyObject *text = PyUnicode_DecodeUTF8(message, (Py_ssize_t)strlen(message), "replace");
    free(message);
    return text;
}

/// The pip command line (JSON) when this run is pip's, else None.
static PyObject *duo_pip_args(PyObject *, PyObject *) {
    const char *args = dc_console_option("--pip=");
    if (!args) Py_RETURN_NONE;
    return PyUnicode_FromString(args);
}

static PyObject *duo_site_packages(PyObject *, PyObject *) {
    return PyUnicode_FromString(g_sitePackages.c_str());
}

static PyObject *duo_pip_wheel(PyObject *, PyObject *) {
    return PyUnicode_FromString(g_pipWheel.c_str());
}

static PyObject *duo_repl(PyObject *, PyObject *) {
    return PyBool_FromLong(dc_console_is_repl());
}

static PyObject *duo_debug_config(PyObject *, PyObject *) {
    const char *config = dc_debug_config();
    if (!config) Py_RETURN_NONE;
    return PyUnicode_FromString(config);
}

static PyObject *duo_debugger_path(PyObject *, PyObject *) {
    const char *path = dc_debug_resource_path("duocode_debugger.py");
    if (!path) Py_RETURN_NONE;
    return PyUnicode_FromString(path);
}

static PyMethodDef kMethods[] = {
    {"repl", duo_repl, METH_NOARGS, NULL},
    {"pip_args", duo_pip_args, METH_NOARGS, NULL},
    {"site_packages", duo_site_packages, METH_NOARGS, NULL},
    {"pip_wheel", duo_pip_wheel, METH_NOARGS, NULL},
    {"debug_send", duo_debug_send, METH_VARARGS, NULL},
    {"debug_receive", duo_debug_receive, METH_VARARGS, NULL},
    {"debug_config", duo_debug_config, METH_NOARGS, NULL},
    {"debugger_path", duo_debugger_path, METH_NOARGS, NULL},
    {"write", duo_write, METH_VARARGS, NULL},
    {"readline", duo_readline, METH_NOARGS, NULL},
    {"stopping", duo_stopping, METH_NOARGS, NULL},
    {"error", duo_error, METH_VARARGS, NULL},
    {"project", duo_project, METH_NOARGS, NULL},
    {"exit", duo_exit, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef kModule = {PyModuleDef_HEAD_INIT, "_duocode", NULL, -1, kMethods};

static PyObject *init_duocode(void) {
    return PyModule_Create(&kModule);
}

// Replaces the standard streams and runs main.py, catching everything: an exception escaping
// here would reach PyErr_Print, which ends the whole app on SystemExit.
static const char *kRunner = R"PY(
import sys, os, _duocode

class _Output:
    encoding = 'utf-8'
    errors = 'replace'
    def __init__(self, level): self.level = level
    def write(self, s):
        s = s if isinstance(s, str) else str(s)
        _duocode.write(self.level, s)
        return len(s)
    def writelines(self, lines):
        for line in lines: self.write(line)
    def flush(self): pass
    def isatty(self): return False
    def readable(self): return False
    def writable(self): return True
    def fileno(self): raise OSError('the Mobile Studio console has no file descriptor')

class _Input:
    encoding = 'utf-8'
    errors = 'replace'
    def readline(self, size=-1):
        line = _duocode.readline()
        if line is None:
            if _duocode.stopping(): raise KeyboardInterrupt
            return ''
        return line + '\n'
    def read(self, size=-1): return self.readline()
    def readlines(self, hint=-1): return [self.readline()]
    def __iter__(self): return self
    def __next__(self):
        line = self.readline()
        if not line: raise StopIteration
        return line
    def isatty(self): return False
    def readable(self): return True
    def writable(self): return False
    def fileno(self): raise OSError('the Mobile Studio console has no file descriptor')

sys.stdout = sys.__stdout__ = _Output(4)
sys.stderr = sys.__stderr__ = _Output(3)
sys.stdin = sys.__stdin__ = _Input()

def _pip(command):
    # pip, run in this process: iOS has no subprocesses, so only wheels (no builds), which pip
    # installs itself. Packages go to the site-packages every run has on its path; iOS wheels come
    # from PyPI and BeeWare's index. Certificates are pip's own (iOS has no /etc/ssl).
    import json
    args = json.loads(command)
    sys.path.insert(0, _duocode.pip_wheel())
    sys.argv = ['pip'] + args
    os.environ.update(PIP_DISABLE_PIP_VERSION_CHECK='1', PIP_NO_INPUT='1', PIP_NO_COLOR='1',
                      PIP_ROOT_USER_ACTION='ignore', PIP_PROGRESS_BAR='off')
    site = _duocode.site_packages()
    network = ['--use-deprecated=legacy-certs', '--extra-index-url', 'https://pypi.anaconda.org/beeware/simple']
    if args and args[0] == 'install':
        extra = ['--target', site, '--upgrade'] + network
        if not any(a.startswith(('--no-binary', '--only-binary', '--prefer-binary')) for a in args):
            extra += ['--only-binary', ':all:']
        args = args[:1] + extra + args[1:]
    elif args and args[0] in ('download', 'index', 'search'):
        args = args[:1] + network + args[1:]
    try:
        from pip._internal.cli.main import main
        code = main(args)
    except SystemExit as exit:
        code = exit.code
    except KeyboardInterrupt:
        _duocode.write(1, 'Stopped.\n')
        return 1
    return code if isinstance(code, int) else (0 if code is None else 1)

def _run():
    project = _duocode.project()
    os.chdir(project)
    sys.path.insert(0, project)
    command = _duocode.pip_args()
    if command is not None:
        return _pip(command)
    sys.argv = ['main.py']
    if _duocode.repl():
        import code
        sys.ps1 = sys.ps2 = ''   # the console's input field is the prompt
        try:
            code.interact(banner=f'Python {sys.version.split()[0]} in Mobile Studio. Type Python and press Return; Stop ends the session.',
                          local={'__name__': '__main__'}, exitmsg='')
        except (KeyboardInterrupt, SystemExit):
            pass
        return 0
    debugger = None
    if _duocode.debug_config() is not None:
        try:
            import importlib.util
            spec = importlib.util.spec_from_file_location('duocode_debugger', _duocode.debugger_path())
            module = importlib.util.module_from_spec(spec)
            sys.modules['duocode_debugger'] = module
            spec.loader.exec_module(module)
            debugger = module.create(project)
        except Exception as error:
            _duocode.write(3, f"The debugger couldn't start: {error}\n")
    try:
        import runpy
        if debugger is not None:
            debugger.run_path(os.path.join(project, 'main.py'))
        else:
            runpy.run_path(os.path.join(project, 'main.py'), run_name='__main__')
        return 0
    except SystemExit as exit:
        code = exit.code
        if code is None: return 0
        if isinstance(code, int): return code
        print(code, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        _duocode.write(1, 'Stopped.\n')
        return 1
    except BaseException as error:
        if debugger is not None:
            debugger.post_mortem(error)
        import traceback
        file, line = None, 0
        for frame, lineno in traceback.walk_tb(error.__traceback__):
            name = frame.f_code.co_filename
            if name.startswith(project + os.sep):
                file, line = os.path.relpath(name, project), lineno
        if isinstance(error, SyntaxError) and error.filename and error.filename.startswith(project + os.sep):
            file, line = os.path.relpath(error.filename, project), error.lineno or 0
        tb = error.__traceback__
        while tb is not None and not tb.tb_frame.f_code.co_filename.startswith(project + os.sep):
            tb = tb.tb_next
        traceback.print_exception(type(error), error, tb if tb is not None else error.__traceback__)
        _duocode.error(f'{type(error).__name__}: {error}', file, line)
        return 1

try:
    _duocode.exit(_run())
except BaseException:
    _duocode.exit(1)
)PY";

static int stop_pending(void *) {
    PyErr_SetNone(PyExc_KeyboardInterrupt);
    return -1;
}

static void interrupt(void) {
    // Raises KeyboardInterrupt in the program at its next instruction.
    if (g_pythonRunning) Py_AddPendingCall(stop_pending, NULL);
}

static bool append_path(PyConfig *config, NSString *path) {
    wchar_t *wide = Py_DecodeLocale(path.fileSystemRepresentation, NULL);
    if (!wide) return false;
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide);
    PyMem_RawFree(wide);
    return !PyStatus_Exception(status);
}

static int run_program(const char *project_dir) {
    static bool registered = false;
    if (!registered) {
        PyImport_AppendInittab("_duocode", init_duocode);
        registered = true;
    }
    g_project = project_dir;
    g_exitCode = 0;

    NSString *home = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python"];
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.14"];
    if (![NSFileManager.defaultManager fileExistsAtPath:lib]) {
        dc_console_log(DC_LOG_ERROR, "Python's standard library isn't in this build of Mobile Studio.");
        return 1;
    }

    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *site = [support stringByAppendingPathComponent:@"python3.14/site-packages"];
    [NSFileManager.defaultManager createDirectoryAtPath:site withIntermediateDirectories:YES attributes:nil error:nil];
    g_sitePackages = site.fileSystemRepresentation;
    g_pipWheel = [home stringByAppendingPathComponent:@"pip.whl"].fileSystemRepresentation;

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;          // the app bundle is read-only
    config.buffered_stdio = 0;
    config.site_import = 1;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home.fileSystemRepresentation);
    config.module_search_paths_set = 1;
    bool paths = append_path(&config, lib) && append_path(&config, [lib stringByAppendingPathComponent:@"lib-dynload"])
        && append_path(&config, site);
    if (!PyStatus_Exception(status) && paths) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status) || !paths) {
        std::string message = std::string("Python couldn't start: ") + (status.err_msg ? status.err_msg : "bad paths");
        dc_console_log(DC_LOG_ERROR, message.c_str());
        return 1;
    }

    g_pythonRunning = true;
    if (PyRun_SimpleString(kRunner) != 0) g_exitCode = 1;
    g_pythonRunning = false;
    Py_FinalizeEx();
    return g_exitCode;
}

static const dc_console_config kPythonConfig = {
    .runtime_id = "python-3.14",
    .display_name = "Python 3.14",
    .version = PY_VERSION,
    .run_program = run_program,
    .interrupt = interrupt,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) {
    return dc_create_console_runtime(&kPythonConfig);
}
