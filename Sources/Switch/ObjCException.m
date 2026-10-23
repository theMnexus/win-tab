#import "ObjCException.h"

BOOL switch_try(void (NS_NOESCAPE ^block)(void), NSString **reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (reason) { *reason = e.reason ?: e.name; }
        return NO;
    }
}
