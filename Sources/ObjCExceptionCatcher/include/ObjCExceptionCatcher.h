#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil. Swift cannot catch one itself, and one that
/// escapes a main-actor job stops the main queue for good (2026-10-12 wake crash). Keep `block` to the framework call.
NSException *_Nullable MWCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
