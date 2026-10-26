#import "ObjCExceptionCatcher.h"

NSException *_Nullable MWCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
