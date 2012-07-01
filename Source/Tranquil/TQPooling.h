// Macros to enable allocation pooling for a class

#define TQ_POOL_IVARS \
    @private \
    TQNumber *_poolPredecessor; \
    NSUInteger _retainCount;

#define TQ_POOL_INTERFACE \
    + (int)purgeCache;

#define TQ_POOL_IMPLEMENTATION \
static struct { \
    TQNumber *lastElement; \
} _Pool = { nil }; \
\
+ (id)allocWithZone:(NSZone *)aZone \
{ \
    if(!_Pool.lastElement) { \
        TQNumber *object = NSAllocateObject(self, 0, aZone); \
        object->_retainCount = 1; \
        return object; \
    } \
    else { \
        TQNumber *object = _Pool.lastElement; \
        _Pool.lastElement = object->_poolPredecessor; \
 \
        object->_retainCount = 1; \
        return object; \
    } \
} \
 \
- (NSUInteger)retainCount \
{ \
    return _retainCount; \
} \
 \
- (id)retain \
{ \
    __sync_add_and_fetch(&_retainCount, 1); \
    return self; \
} \
 \
- (oneway void)release \
{ \
    if(!__sync_sub_and_fetch(&_retainCount, 1)) \
    { \
        _poolPredecessor = _Pool.lastElement; \
        _Pool.lastElement = self; \
    } \
} \
 \
- (void)_purge \
{ \
    [super release]; \
} \
 \
+ (int)purgeCache \
{ \
    TQNumber *lastElement; \
    int count=0; \
    while ((lastElement = _Pool.lastElement)) \
    { \
        ++count; \
        _Pool.lastElement = lastElement->_poolPredecessor; \
        [lastElement _purge]; \
    } \
    return count; \
}
