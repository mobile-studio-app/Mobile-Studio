#ifndef DUO_HINGE_BRIDGE_H
#define DUO_HINGE_BRIDGE_H

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (^DuoHingeUpdateHandler)(CGFloat angleDegrees, NSInteger status);

@interface DuoHingeBridge : NSObject

+ (id<UIInteraction>)attachToView:(UIView *)view onUpdate:(DuoHingeUpdateHandler)handler;

@end

#ifdef __cplusplus
}
#endif

#endif /* DUO_HINGE_BRIDGE_H */
