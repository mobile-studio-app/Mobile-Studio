#import "DuoHingeBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

@implementation DuoHingeBridge

+ (id<UIInteraction>)attachToView:(UIView *)view onUpdate:(DuoHingeUpdateHandler)handler {
    Class hingeClass = NSClassFromString(@"UIHingeInteraction");
    if (!hingeClass || !view || !handler) {
        return nil;
    }

    // UIHingeInteraction init(updateHandler: @escaping (UIHingeInteraction, UIHingeInteraction.Update) -> Void)
    SEL initSel = NSSelectorFromString(@"initWithHandler:");
    if (![hingeClass instancesRespondToSelector:initSel]) {
        // Fallback selector variants
        initSel = NSSelectorFromString(@"initWithUpdateHandler:");
    }

    if (![hingeClass instancesRespondToSelector:initSel]) {
        return nil;
    }

    id interaction = [hingeClass alloc];
    void (^block)(id interaction, id update) = ^(id inter, id update) {
        if (!update) return;
        SEL hingeSel = NSSelectorFromString(@"hinge");
        if (![update respondsToSelector:hingeSel]) return;

        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id hinge = [update performSelector:hingeSel];
        #pragma clang diagnostic pop

        if (!hinge) return;

        CGFloat angleRad = 0.0;
        NSInteger status = 3; // unknown

        SEL angleSel = NSSelectorFromString(@"angle");
        SEL statusSel = NSSelectorFromString(@"status");

        if ([hinge respondsToSelector:angleSel]) {
            NSMethodSignature *sig = [hinge methodSignatureForSelector:angleSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:angleSel];
            [inv setTarget:hinge];
            [inv invoke];
            [inv getReturnValue:&angleRad];
        }

        if ([hinge respondsToSelector:statusSel]) {
            NSMethodSignature *sig = [hinge methodSignatureForSelector:statusSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:statusSel];
            [inv setTarget:hinge];
            [inv invoke];
            [inv getReturnValue:&status];
        }

        CGFloat angleDeg = angleRad * (180.0 / M_PI);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(angleDeg, status);
        });
    };

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    interaction = ((id (*)(id, SEL, id))objc_msgSend)(interaction, initSel, block);
    #pragma clang diagnostic pop

    if (interaction && [interaction conformsToProtocol:@protocol(UIInteraction)]) {
        [view addInteraction:(id<UIInteraction>)interaction];
        return (id<UIInteraction>)interaction;
    }

    return nil;
}

@end
