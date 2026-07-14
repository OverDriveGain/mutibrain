#import "ExcCatch.h"

NSError *ExcCatch(NSString *label, void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        NSString *msg = [NSString stringWithFormat:@"%@: %@ %@",
                         label, e.name, e.reason ?: @""];
        return [NSError errorWithDomain:@"ExcCatch" code:1
                               userInfo:@{NSLocalizedDescriptionKey: msg}];
    }
}
