#import "LoveAdapter.h"
#import "DebugChannel.h"

static const dc_host_api *g_host = NULL;
static const dc_love_config *g_config = NULL;

void dc_love_log(dc_log_level level, const char *message) {
    if (g_host && g_host->log && message) {
        g_host->log(g_host->ctx, level, message);
    }
}

void dc_love_report_error(const char *message, const char *file, int line) {
    if (g_host && g_host->on_error) {
        g_host->on_error(g_host->ctx, message ? message : "unknown error", file, line);
    }
}

UIView *dc_love_container(void) {
    if (!g_host || !g_host->container_view) return nil;
    return (__bridge UIView *)g_host->container_view(g_host->ctx);
}

static int love_adapter_init(const dc_host_api *host) {
    if (!host || host->abi_version != DC_RUNTIME_ABI_VERSION) return -1;
    g_host = host;
    dc_debug_setup(host);
    NSString *msg = [NSString stringWithFormat:@"%s initialized", g_config ? g_config->display_name : "LÖVE"];
    dc_love_log(DC_LOG_INFO, msg.UTF8String);
    return 0;
}

static int love_adapter_run(const dc_run_options *opt) {
    if (!g_host || !g_config || !g_config->run_game) return -1;
    g_host->on_state(g_host->ctx, DC_STATE_STARTING);
    g_host->on_state(g_host->ctx, DC_STATE_RUNNING);

    const char *project_dir = (opt && opt->project_dir) ? opt->project_dir : ".";
    dc_debug_begin(opt ? opt->debug_config : NULL);
    int exitCode = g_config->run_game(project_dir, opt ? opt->enable_jit : 0);
    dc_debug_end();

    g_host->on_state(g_host->ctx, DC_STATE_STOPPING);
    g_host->on_state(g_host->ctx, DC_STATE_STOPPED);
    return exitCode;
}

static void love_adapter_request_stop(void) {
    dc_debug_end();   // a game paused in the debugger lets go, then quits
    if (g_config && g_config->request_quit) {
        g_config->request_quit();
    }
}

static void love_adapter_set_focus(int focused) {
    if (g_config && g_config->set_focus) {
        g_config->set_focus(focused);
    }
}

static void love_adapter_container_resized(double width, double height, double scale) {
    (void)width; (void)height; (void)scale;
    if (g_config && g_config->container_changed) {
        g_config->container_changed(dc_love_container());
    }
}

static void love_adapter_shutdown(void) {
    g_host = NULL;
}

const dc_runtime *dc_create_love_runtime(const dc_love_config *config) {
    g_config = config;
    static dc_runtime rt;
    rt.abi_version = DC_RUNTIME_ABI_VERSION;
    rt.id = config->runtime_id;
    rt.display_name = config->display_name;
    rt.version = config->version;
    rt.initialize = love_adapter_init;
    rt.run = love_adapter_run;
    rt.request_stop = love_adapter_request_stop;
    rt.set_input_focus = love_adapter_set_focus;
    rt.container_resized = love_adapter_container_resized;
    rt.shutdown = love_adapter_shutdown;
    rt.debug_command = dc_debug_command;
    return &rt;
}
