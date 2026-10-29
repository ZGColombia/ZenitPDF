#import "include/ZPDFEngineBarrier.h"

@implementation ZPDFRaisedException

- (instancetype)initWithName:(NSString *)name reason:(NSString *)reason {
    self = [super init];
    if (self) {
        _name = [name copy];
        _reason = [reason copy];
    }
    return self;
}

@end

ZPDFRaisedException * _Nullable ZPDFRunCatchingObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"";
        return [[ZPDFRaisedException alloc] initWithName:name reason:reason];
    }
    return nil;
}
