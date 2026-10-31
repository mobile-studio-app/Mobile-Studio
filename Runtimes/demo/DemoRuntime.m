// DemoRuntime — a tiny runtime with no external dependencies.
//
// Purpose: validate the whole runtime pipeline on device before LÖVE lands:
// dlopen + entry symbol, container view embedding, the blocking
// "run pumps the runloop" model, focus/resize notifications, stop requests.
// It renders a bouncing square with UIKit and reports keyboard input.

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include "duocode_runtime.h"

static const dc_host_api *g_host;
static volatile int g_stopRequested;
static int g_focused;

static void dc_log(dc_log_level lvl, NSString *msg) {
    if (g_host && g_host->log) g_host->log(g_host->ctx, lvl, msg.UTF8String);
}

static int demo_init(const dc_host_api *host) {
    if (!host || host->abi_version != DC_RUNTIME_ABI_VERSION) return -1;
    g_host = host;
    dc_log(DC_LOG_INFO, @"Demo runtime initialised");
    return 0;
}

static int demo_run(const dc_run_options *opt) {
    g_stopRequested = 0;
    if (!g_host) return -1;
    g_host->on_state(g_host->ctx, DC_STATE_STARTING);

    UIView *container = (__bridge UIView *)g_host->container_view(g_host->ctx);
    if (!container) {
        g_host->on_state(g_host->ctx, DC_STATE_STOPPED);
        return -1;
    }

    UIView *canvas = [[UIView alloc] initWithFrame:container.bounds];
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    canvas.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.12 alpha:1];
    [container addSubview:canvas];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(20, 20, 48, 48)];
    box.backgroundColor = [UIColor colorWithRed:0.91 green:0.29 blue:0.60 alpha:1]; // LÖVE pink
    box.layer.cornerRadius = 8;
    [canvas addSubview:box];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    label.numberOfLines = 0;
    [canvas addSubview:label];

    dc_log(DC_LOG_GAME, [NSString stringWithFormat:@"Hello from demo runtime! project=%s jit=%d",
                         (opt && opt->project_dir) ? opt->project_dir : "(none)",
                         opt ? opt->enable_jit : 0]);
    g_host->on_state(g_host->ctx, DC_STATE_RUNNING);

    CGFloat vx = 180, vy = 140;
    CFTimeInterval last = CACurrentMediaTime();
    unsigned long frames = 0;

    // Pump the runloop on each tick while maintaining steady 60fps pacing
    while (!g_stopRequested) {
        @autoreleasepool {
            // Process any pending events / UI updates without busy-spinning
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0 / 60.0, false);

            CFTimeInterval now = CACurrentMediaTime();
            CGFloat dt = (CGFloat)(now - last);
            if (dt < 1.0 / 60.0) continue;
            last = now;
            frames++;

            CGRect b = canvas.bounds;
            if (b.size.width <= 0 || b.size.height <= 0) continue;

            CGRect f = box.frame;
            f.origin.x += vx * dt;
            f.origin.y += vy * dt;
            if (f.origin.x < 0) {
                vx = fabs(vx);
                f.origin.x = 0;
            } else if (CGRectGetMaxX(f) > b.size.width) {
                vx = -fabs(vx);
                f.origin.x = MAX(0, b.size.width - f.size.width);
            }
            if (f.origin.y < 0) {
                vy = fabs(vy);
                f.origin.y = 0;
            } else if (CGRectGetMaxY(f) > b.size.height) {
                vy = -fabs(vy);
                f.origin.y = MAX(0, b.size.height - f.size.height);
            }
            box.frame = f;

            label.text = [NSString stringWithFormat:@"DemoRuntime (frame %lu)\nfocus: %@\nsize: %.0fx%.0f",
                          frames, g_focused ? @"GAME" : @"editor", b.size.width, b.size.height];
            label.frame = CGRectMake(8, b.size.height - 60, b.size.width - 16, 56);
        }
    }

    g_host->on_state(g_host->ctx, DC_STATE_STOPPING);
    [canvas removeFromSuperview];
    dc_log(DC_LOG_INFO, @"Demo runtime stopped");
    g_host->on_state(g_host->ctx, DC_STATE_STOPPED);
    return 0;
}

static void demo_request_stop(void) { g_stopRequested = 1; }
static void demo_set_focus(int f) { g_focused = f; }
static void demo_resized(double w, double h, double s) { (void)w; (void)h; (void)s; }
static void demo_shutdown(void) { g_host = NULL; }

static const dc_runtime kDemoRuntime = {
    .abi_version = DC_RUNTIME_ABI_VERSION,
    .id = "demo",
    .display_name = "Demo Runtime",
    .version = "1.0",
    .initialize = demo_init,
    .run = demo_run,
    .request_stop = demo_request_stop,
    .set_input_focus = demo_set_focus,
    .container_resized = demo_resized,
    .shutdown = demo_shutdown,
};

DC_EXPORT const dc_runtime *duocode_runtime_entry(void) { return &kDemoRuntime; }
