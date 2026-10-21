// Minimal host UIKit surface. Production manager code is included unchanged.
#import <Foundation/Foundation.h>
@class UIGestureRecognizer, UITouch;
@protocol UIGestureRecognizerDelegate <NSObject>
@optional
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other;
@end
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible = 0, UIGestureRecognizerStateBegan = 1,
    UIGestureRecognizerStateChanged = 2, UIGestureRecognizerStateEnded = 3
};
@interface UIGestureRecognizer : NSObject
@property(nonatomic, weak) id<UIGestureRecognizerDelegate> delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray *allowedTouchTypes;
@property(nonatomic) BOOL cancelsTouchesInView, delaysTouchesBegan, delaysTouchesEnded;
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, weak) UIGestureRecognizer *requiredFailure;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)requireGestureRecognizerToFail:(UIGestureRecognizer *)other;
@end
@interface UITapGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSUInteger numberOfTapsRequired;
@end
@interface UIPanGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSUInteger allowedScrollTypesMask;
@end
@interface UITouch : NSObject
@end
