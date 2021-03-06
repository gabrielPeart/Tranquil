#import "TQNothingness.h"
#import <objc/runtime.h>
#import "TQRuntime.h"

static TQNothingness *sharedInstance;

@implementation TQNothingness

+ (id)nothing
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = class_createInstance(self, 0);
    });
    return sharedInstance;
}

+ (id)include:(Class)aClass recursive:(id)aRecursive
{
    NSAssert(NO, @"Extending nothing is not allowed");
    return nil;
}

+ (id)allocWithZone:(NSZone *)aZone
{
    NSAssert(NO, @"You're trying to create nothing. You make no sense.");
    return nil;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSAssert(NO, @"You're trying to copy nothing. You make no sense.");
    return nil;
}

- (oneway void)release {}
- (id)retain
{
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector
{
    return NO;
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol
{
    return NO;
}

- (NSUInteger)hash
{
    return 0;
}

- (BOOL)isEqual:(id)obj
{
    return obj == self; // There's only one instance
}

- (NSString *)description
{
    return @"(nothing)";
}

- (Class)class
{
    return nil;
}
@end

