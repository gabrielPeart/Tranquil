#import "TQBoxedObject.h"
#import "TQRuntimePrivate.h"
#import "TQFFIType.h"
#import "TQRuntime.h"
#import "TQNumber.h"
#import "NSCollections+Tranquil.h"
#import "TQPointer.h"
#import "TQBlockClosure.h"
#import "../../../Build/TQStubs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <assert.h>
#import <ctype.h>

#define TQBoxedObject_PREFIX "TQBoxedObject_"
#define BlockImp imp_implementationWithBlock

// To identify whether a block is a wrapper or not
#define TQ_BLOCK_IS_WRAPPER_BLOCK (1 << 20)

static int _TQRetTypeAssocKey, _TQArgTypesAssocKey, _TQFFIResourcesAssocKey;
static void _freeRelinquishFunction(const void *item, NSUInteger (*size)(const void *item));

// Used to wrap blocks that take or return non-objects
struct TQBoxedBlockLiteral;
struct TQBoxedBlockDescriptor {
    unsigned long int reserved; // NULL
    unsigned long int size;     // sizeof(struct TQBoxedBlockLiteral)
};
struct TQBoxedBlockLiteral {
    void *isa; // _NSConcreteStackBlock
    int flags;
    int reserved;
    void *invoke;
    struct TQBoxedBlockDescriptor *descriptor;
    // The required data to call the boxed function
    void *funPtr;
    const char *type;
    NSInteger argSize;
    ffi_cif *cif;
};

static id __wrapperBlock_invoke(struct TQBoxedBlockLiteral *__blk, ...);
static void block_closure(ffi_cif *closureCif, void *ret, void *args[], struct TQBlockLiteral *__blk);

static struct TQBoxedBlockDescriptor boxedBlockDescriptor = {
    0,
    sizeof(struct TQBoxedBlockLiteral),
};

// Boxing imps
static id _box_C_ID_imp(TQBoxedObject *self, SEL _cmd, id *aPtr);
static id _box_C_SEL_imp(TQBoxedObject *self, SEL _cmd, SEL *aPtr);
static id _box_C_VOID_imp(TQBoxedObject *self, SEL _cmd, id *aPtr);
static id _box_C_CHARPTR_imp(TQBoxedObject *self, SEL _cmd, char **aPtr);
static id _box_C_DBL_imp(TQBoxedObject *self, SEL _cmd, double *aPtr);
static id _box_C_FLT_imp(TQBoxedObject *self, SEL _cmd, float *aPtr);
static id _box_C_INT_imp(TQBoxedObject *self, SEL _cmd, int *aPtr);
static id _box_C_SHT_imp(TQBoxedObject *self, SEL _cmd, short *aPtr);
static id _box_C_CHR_imp(TQBoxedObject *self, SEL _cmd, char *aPtr);
static id _box_C_UCHR_imp(TQBoxedObject *self, SEL _cmd, char *aPtr);
static id _box_C_BOOL_imp(TQBoxedObject *self, SEL _cmd, _Bool *aPtr);
static id _box_C_LNG_imp(TQBoxedObject *self, SEL _cmd, long *aPtr);
static id _box_C_LNG_LNG_imp(TQBoxedObject *self, SEL _cmd, long long *aPtr);
static id _box_C_UINT_imp(TQBoxedObject *self, SEL _cmd, unsigned int *aPtr);
static id _box_C_USHT_imp(TQBoxedObject *self, SEL _cmd, unsigned short *aPtr);
static id _box_C_ULNG_imp(TQBoxedObject *self, SEL _cmd, unsigned long *aPtr);
static id _box_C_ULNG_LNG_imp(TQBoxedObject *self, SEL _cmd, unsigned long long *aPtr);

@interface TQBoxedObject ()
+ (NSString *)_classNameForType:(const char *)aType;
+ (Class)_prepareAggregateWrapper:(const char *)aClassName withType:(const char *)aType;
+ (Class)_prepareScalarWrapper:(const char *)aClassName withType:(const char *)aType;
+ (Class)_prepareLambdaWrapper:(const char *)aClassName withType:(const char *)aType;
+ (NSString *)_getFieldName:(const char **)aType;
+ (const char *)_findEndOfPair:(const char *)aStr start:(char)aStartChar end:(char)aEndChar;
+ (const char *)_skipQualifiers:(const char *)aType;
@end

@implementation TQBoxedObject
@synthesize valuePtr=_ptr;

+ (id)box:(void *)aPtr withType:(const char *)aType
{
    aType = [self _skipQualifiers:aType];
    // Check if this type has been handled already
    const char *className = [[self _classNameForType:aType] UTF8String];
    Class boxingClass = objc_getClass(className);
    if(boxingClass)
        return [boxingClass box:aPtr];

    @synchronized(self) {
        // Seems it hasn't. Let's.
        if([self typeIsScalar:aType])
            boxingClass = [self _prepareScalarWrapper:className withType:aType];
        else if(*aType == _C_STRUCT_B || *aType == _C_UNION_B)
            boxingClass = [self _prepareAggregateWrapper:className withType:aType];
        else if(*aType == _TQ_C_LAMBDA_B)
            boxingClass = [self _prepareLambdaWrapper:className withType:aType];
        else if(TYPE_IS_TOLLFREE(aType)) // CF types accept messages, and many are toll free bridged
            // TODO: actually generate a wrapper class that does this without going through the tests above
            return *(id*)aPtr;
        else if(*aType == _C_PTR || *aType == _C_ARY_B) {
            // TODO: actually generate a wrapper class that does this without going through the tests above
            return [TQPointer box:aPtr withType:aType];
        } else {
            TQLog(@"Type %s cannot be boxed", aType);
            return nil;
        }
    }
    return [boxingClass box:aPtr];
}

+ (id)box:(void *)aPtr
{
    return [[[self alloc] initWithPtr:aPtr] autorelease];
}

+ (void)unbox:(id)aValue to:(void *)aDest usingType:(const char *)aType
{
    aType = [self _skipQualifiers:aType];

    if([aValue isKindOfClass:[NSValue class]]) {
        NSValue *value = aValue;
        const char *valType = [value objCType];
        if(strncmp(valType, aType, strlen(valType)) == 0) {
            [value getValue:aDest];
            return;
        }
    }

    switch(*aType) {
        case _C_ID:
        case _C_CLASS:    *(id*)aDest                  = aValue;                                break;
        case _C_SEL:      *(SEL*)aDest                 = sel_registerName([aValue UTF8String]); break;
        case _C_CHARPTR:  *(const char **)aDest        = [aValue UTF8String];                   break;
        case _C_DBL:      *(double *)aDest             = [aValue doubleValue];                  break;
        case _C_FLT:      *(float *)aDest              = [aValue floatValue];                   break;
        case _C_INT:      *(int *)aDest                = [aValue intValue];                     break;
        case _C_CHR:      *(char *)aDest               = [aValue charValue];                    break;
        case _C_UCHR:     *(unsigned char *)aDest      = [aValue unsignedCharValue];            break;
        case _C_SHT:      *(short *)aDest              = [aValue shortValue];                   break;
        case _C_BOOL:     *(_Bool *)aDest              = [aValue boolValue];                    break;
        case _C_LNG:      *(long *)aDest               = [aValue longValue];                    break;
        case _C_LNG_LNG:  *(long long *)aDest          = [aValue longLongValue];                break;
        case _C_UINT:     *(unsigned int *)aDest       = [aValue unsignedIntValue];             break;
        case _C_USHT:     *(unsigned short *)aDest     = [aValue unsignedShortValue];           break;
        case _C_ULNG:     *(unsigned long *)aDest      = [aValue unsignedLongValue];            break;
        case _C_ULNG_LNG: *(unsigned long long *)aDest = [aValue unsignedLongLongValue];        break;
        case _C_VOID:     TQAssert(NO, @"You cannot unbox a value of type void");               break;

        case _TQ_C_LAMBDA_B: {
            TQAssert(!aValue || [aValue isKindOfClass:objc_getClass("NSBlock")], @"Tried to unbox a non block to a block/function pointer type (%@ -> %s)", aValue, aType);
            if(!aValue)
                *(void **)aDest = NULL;
            else  {
                // If the receiver expects a function pointer we need to give an immortal copy of the block
                // since we cannot know when it should be released (For blocks, it's the receivers responsibility to copy it)
                if(*(aType+1) == _C_PTR)
                    aValue = [aValue copy];
                TQBlockClosure *closure = [[[TQBlockClosure alloc] initWithBlock:aValue type:aType] autorelease];
                *(void **)aDest = closure.pointer;
            }
        } break;

        case _C_STRUCT_B: {
            NSUInteger size;
            TQGetSizeAndAlignment(aType, &size, NULL);

            // If it's a boxed object we just make sure the sizes match and then copy the bits
            if([aValue isKindOfClass:self]) {
                TQBoxedObject *value = aValue;
                TQAssert(value->_size == size, @"Tried to unbox a boxed struct to a type of a different size (%@ -> %s)", aValue, aType);
                memmove(aDest, value->_ptr, size);
            }
            // If it's an array  we unbox based on indices
            else if([aValue isKindOfClass:[NSArray class]] || [aValue isKindOfClass:[NSPointerArray class]]) {
                NSArray *arr = aValue;
                NSUInteger size;
                NSUInteger ofs = 0;
                const char *fieldType = strstr(aType, "=") + 1;
                assert((uintptr_t)fieldType > 1);
                const char *next;
                for(id obj in arr) {
                    next = TQGetSizeAndAlignment(fieldType, &size, NULL);
                    [TQBoxedObject unbox:obj to:(char*)aDest + ofs usingType:fieldType];
                    if(*next == _C_STRUCT_E)
                        break;
                    fieldType = next;
                    ofs += size;
                }
            }
            // If nil, we just give 0 bits
            else if(!aValue) {
                memset(aDest, 0, size);
            }
            // If it's a dictionary we can unbox based on it's keys
            else if([aValue isKindOfClass:[NSDictionary class]] || [aValue isKindOfClass:[NSMapTable class]]) {
                  [NSException raise:@"Unimplemented"
                           format:@"Dictionary unboxing has not been implemented yet."];

            } else
                TQAssert(NO, @"You tried to unbox %@ to a struct(%s), but it can not.", aValue, aType);
        } break;
        case _C_UNION_B: {
            TQAssert(NO, @"Unboxing to a union has not been implemented yet");
        }
        case _C_PTR: {
            if(!aValue)
                *(void **)aDest = NULL;
            else if(TYPE_IS_TOLLFREE(aType))
                *(id *)aDest = aValue;
            else if(![aValue isKindOfClass:[TQPointer class]]) {
                if(*(aType+1) == _C_VOID)
                    *(void **)aDest = aValue;
                else {
                    TQPointer *ptr = [[TQPointer alloc] initWithType:aType+1 count:1];
                    [ptr setObject:aValue atIndexedSubscript:0];
                    *(void **)aDest = ptr->_addr;
                }
            } else
                *(void **)aDest = ((TQPointer *)aValue)->_addr;
            break;
        }
        default:
            TQAssert(NO, @"Tried to unbox unsupported type '%c' in %s!", *aType, aType);
    }
}

- (id)initWithPtr:(void *)aPtr
{
    TQAssert(NO, @"TQBoxedObject is an abstract class. Do not try to instantiate it directly.");
    // Implemented by subclasses
    return nil;
}

- (void)dealloc
{
    if(_isOnHeap)
        free(_ptr);
    [super dealloc];
}

- (void)moveValueToHeap
{
    if(_isOnHeap)
        return;

    void *stackAddr = _ptr;
    _ptr = malloc(_size);
    memmove(_ptr, stackAddr, _size);
    _isOnHeap = YES;
}

- (id)retain
{
    id ret = [super retain];
    [self moveValueToHeap];
    return ret;
}

- (id)copyWithZone:(NSZone *)aZone
{
    TQBoxedObject *ret = [[[self class] alloc] initWithPtr:_ptr];
    [ret moveValueToHeap];
    return ret;
}

#pragma mark -

+ (NSString *)_getFieldName:(const char **)aType
{
    if(*(*aType) != '"')
        return NULL;
    *aType = *aType + 1;
    const char *nameEnd = strstr(*aType, "\"");
    int len = nameEnd - *aType;

    NSString *ret = [[NSString alloc] initWithBytes:*aType length:len encoding:NSUTF8StringEncoding];
    (*aType) += len+1;
    return [ret autorelease];
}

+ (BOOL)typeIsScalar:(const char *)aType
{
    return !(*aType == _C_STRUCT_B || *aType == _C_UNION_B || *aType == _C_ARY_B || *aType == _TQ_C_LAMBDA_B || *aType == _C_PTR);
}

+ (const char *)_findEndOfPair:(const char *)aStr start:(char)aStartChar end:(char)aEndChar
{
    for(int i = 0, depth = 0; i < strlen(aStr); ++i) {
        if(aStr[i] == aStartChar)
            ++depth;
        else if(aStr[i] == aEndChar) {
            if(--depth == 0)
                return aStr+i;
        }
    }
    return NULL;
}

// Skips type qualifiers and alignments neither of which is used at the moment
+ (const char *)_skipQualifiers:(const char *)aType
{
    while(*aType == 'r' || *aType == 'n' || *aType == 'N' || *aType == 'o' || *aType == 'O'
          || *aType == 'R' || *aType == 'V' || isdigit(*aType)) {
        ++aType;
    }
    return aType;
}

+ (NSString *)_classNameForType:(const char *)aType
{
    NSUInteger len;
    if(*aType == _C_STRUCT_B)
        len = [self _findEndOfPair:aType start:_C_STRUCT_B end:_C_STRUCT_E] - aType + 1;
    else if(*aType == _C_UNION_B)
        len = [self _findEndOfPair:aType start:_C_UNION_B end:_C_UNION_E] - aType + 1;
    else if(*aType == _C_ARY_B)
        len = [self _findEndOfPair:aType start:_C_ARY_B end:_C_ARY_E] - aType + 1;
    else if(*aType == _TQ_C_LAMBDA_B)
        len = [self _findEndOfPair:aType start:_TQ_C_LAMBDA_B end:_TQ_C_LAMBDA_E] - aType + 1;
    else if(*aType == _C_PTR) {
        const char *nextType = TQGetSizeAndAlignment(aType, NULL, NULL);
        len = nextType - aType;
    } else
        len = 1;

    len += strlen(TQBoxedObject_PREFIX) + 1;
    char className[len+1];
    snprintf(className, len, "%s%s", TQBoxedObject_PREFIX, aType);

    return [NSString stringWithUTF8String:className];
}

+ (Class)_prepareScalarWrapper:(const char *)aClassName withType:(const char *)aType
{
    NSUInteger size, alignment;
    TQGetSizeAndAlignment(aType, &size, &alignment);

    IMP initImp      = nil;
    switch(*aType) {
        case _C_ID:
        case _C_CLASS:    initImp = (IMP)_box_C_ID_imp;       break;
        case _C_SEL:      initImp = (IMP)_box_C_SEL_imp;      break;
        case _C_VOID:     initImp = (IMP)_box_C_VOID_imp;     break;
        case _C_CHARPTR:  initImp = (IMP)_box_C_CHARPTR_imp;  break;
        case _C_DBL:      initImp = (IMP)_box_C_DBL_imp;      break;
        case _C_FLT:      initImp = (IMP)_box_C_FLT_imp;      break;
        case _C_INT:      initImp = (IMP)_box_C_INT_imp;      break;
        case _C_CHR:      initImp = (IMP)_box_C_CHR_imp;      break;
        case _C_UCHR:     initImp = (IMP)_box_C_UCHR_imp;     break;
        case _C_SHT:      initImp = (IMP)_box_C_SHT_imp;      break;
        case _C_BOOL:     initImp = (IMP)_box_C_BOOL_imp;     break;
        case _C_LNG:      initImp = (IMP)_box_C_LNG_imp;      break;
        case _C_LNG_LNG:  initImp = (IMP)_box_C_LNG_LNG_imp;  break;
        case _C_UINT:     initImp = (IMP)_box_C_UINT_imp;     break;
        case _C_USHT:     initImp = (IMP)_box_C_USHT_imp;     break;
        case _C_ULNG:     initImp = (IMP)_box_C_ULNG_imp;     break;
        case _C_ULNG_LNG: initImp = (IMP)_box_C_ULNG_LNG_imp; break;

        default:
            TQAssert(NO, @"Unsupported scalar type %c!", *aType);
            return nil;
    }

    Class kls;
    kls = objc_allocateClassPair(self, aClassName, 0);
    if(!kls)
        return objc_getClass(aClassName);
    class_addMethod(kls->isa, @selector(box:), initImp, "@:^v");
    objc_registerClassPair(kls);

    return kls;
}

// Handles unions&structs
+ (Class)_prepareAggregateWrapper:(const char *)aClassName withType:(const char *)aType
{
    BOOL isStruct = *aType == _C_STRUCT_B;
    Class kls = objc_allocateClassPair(self, aClassName, 0);
    if(!kls)
        return objc_getClass(aClassName);

    NSUInteger size, alignment;
    TQGetSizeAndAlignment(aType, &size, &alignment);

    // Store the accessors sequentially in order to allow indexed access (necessary for structs without field name information)
    NSMutableArray *fieldGetters = [NSMutableArray array];
    NSMutableArray *fieldSetters = [NSMutableArray array];

    __block id fieldGetter, fieldSetter;
    __block NSUInteger ofs;
    const char *fieldType = strstr(aType, "=")+1;
    assert((uintptr_t)fieldType > 1);

    // Add properties for each field
    ofs = 0;
    TQIterateTypesInEncoding(fieldType, ^(const char *type, NSUInteger size, NSUInteger align, BOOL *stop) {
        NSString *name = [self _getFieldName:&type];

        // This is only to make sure that the type string survives for the lifetime of the class (Since the lifetime of the type param is not defined)
        NSString *nsType = [NSString stringWithUTF8String:type];
        objc_setAssociatedObject(kls, nsType, nsType, OBJC_ASSOCIATION_RETAIN);

        NSUInteger currOfs = ofs;
        if(*type == _C_ARY_B) {
            // For an array we must box a pointer to the address of the array (the location within the struct is a pointer
            // to it's first element, not to the array itself)
            fieldGetter = ^(TQBoxedObject *self) {
                void *tmp = self->_ptr+currOfs;
                return [TQBoxedObject box:&tmp withType:[nsType UTF8String]];
            };
        } else {
            fieldGetter = ^(TQBoxedObject *self) {
                return [TQBoxedObject box:self->_ptr+currOfs withType:[nsType UTF8String]];
            };
        }
        fieldGetter = [[fieldGetter copy] autorelease];
        fieldSetter = [[^(TQBoxedObject *self, id value) {
            [TQBoxedObject unbox:value to:self->_ptr+currOfs usingType:[nsType UTF8String]];
        } copy] autorelease];

        if(name) {
            class_addMethod(kls, sel_registerName([name UTF8String]), BlockImp(fieldGetter), "@:");
            class_addMethod(kls, sel_registerName([[NSString stringWithFormat:@"set%@:", [name capitalizedString]] UTF8String]), BlockImp(fieldSetter), "@:@");
        }
        [fieldGetters addObject:fieldGetter];
        [fieldSetters addObject:fieldSetter];

        // If it's a union, the offset is always 0
        if(isStruct)
            ofs += size;
    });

    IMP subscriptGetterImp = BlockImp(^(id self, NSInteger idx) {
        id (^getter)(id) = [fieldGetters objectAtIndex:idx];
        return getter(self);
    });
    const char *subscrGetterType = [[NSString stringWithFormat:@"@:%s", @encode(NSInteger)] UTF8String];
    class_addMethod(kls, @selector(objectAtIndexedSubscript:), subscriptGetterImp, subscrGetterType);
    IMP subscriptSetterImp = BlockImp(^(id self, id value, NSInteger idx) {
        id (^setter)(id, id) = [fieldSetters objectAtIndex:idx];
        return setter(self, value);
    });
    const char *subscrSetterType = [[NSString stringWithFormat:@"@:@%s", @encode(NSInteger)] UTF8String];
    class_addMethod(kls, @selector(setObject:atIndexedSubscript:), subscriptSetterImp, subscrSetterType);

    IMP initImp = BlockImp(^(TQBoxedObject *self, void *aPtr) {
        self->_ptr  = aPtr;
        self->_size = size;
        return self;
    });
    class_addMethod(kls, @selector(initWithPtr:), initImp, "@:^v");
    objc_registerClassPair(kls);

    return kls;
}

// Handles blocks&function pointers
+ (Class)_prepareLambdaWrapper:(const char *)aClassName withType:(const char *)aType
{
    Class kls = objc_allocateClassPair(self, aClassName, 0);
    if(!kls)
        return objc_getClass(aClassName);

    BOOL isBlock = *(++aType) == _TQ_C_LAMBDA_BLOCK;
    BOOL needsWrapping = NO;
    // If the value is a funptr, the return value or any argument is not an object, then the value needs to be wrapped up
    for(int i = 0; i < strlen(aType)-1; ++i) {
        if(aType[i] != _C_ID) {
            needsWrapping = YES;
            break;
        }
    }

    IMP initImp;
    if(!needsWrapping)
        initImp = (IMP)_box_C_ID_imp;
    const char *argTypes;
    // Figure out the return type
    argTypes = aType+1;
    if(*argTypes == _C_CONST)
        ++argTypes;

    TQFFIType *retType = [TQFFIType typeWithEncoding:argTypes nextType:&argTypes];

    // And now the argument types
    __block NSUInteger numArgs = isBlock;
    __block NSUInteger argSize = 0;
    if(*argTypes != _TQ_C_LAMBDA_E) {
        TQIterateTypesInEncoding(argTypes, ^(const char *argType, NSUInteger size, NSUInteger align, BOOL *stop) {
            ++numArgs;
            argSize += size;
        });
    }

    ffi_cif *cif = (ffi_cif*)malloc(sizeof(ffi_cif));
    ffi_type **args = (ffi_type**)malloc(sizeof(ffi_type*)*numArgs);
    NSMutableArray *argTypeObjects = [NSMutableArray arrayWithCapacity:numArgs];

    int argIdx = 0;
    if(isBlock) {
        args[argIdx++] = &ffi_type_pointer;
        argSize += sizeof(void*);
    }

    TQFFIType *currTypeObj;
    for(int i = isBlock; i < numArgs; ++i) {
        currTypeObj = [TQFFIType typeWithEncoding:argTypes nextType:&argTypes];
        args[argIdx++] = [currTypeObj ffiType];

        [argTypeObjects addObject:currTypeObj];
    }

    if(ffi_prep_cif(cif, FFI_DEFAULT_ABI, numArgs, retType.ffiType, args) != FFI_OK) {
        // TODO: be more graceful
        TQLog(@"unable to wrap block");
        exit(1);
    }

    initImp = BlockImp(^(TQBoxedObject *self, id *aPtr) {
        // Create and return the wrapper block
        struct TQBoxedBlockLiteral blk = {
            &_NSConcreteStackBlock,
            TQ_BLOCK_IS_WRAPPER_BLOCK, 0,
            (void*)&__wrapperBlock_invoke,
            &boxedBlockDescriptor,
            isBlock ? (id)*aPtr : (id)aPtr,
            aType,
            argSize,
            cif
        };
        return [(id)&blk copy];
    });

    class_addMethod(kls, @selector(initWithPtr:), initImp, "@:^v");
    objc_registerClassPair(kls);

    // Hold on to these guys for the life of the class:
    objc_setAssociatedObject(kls, &_TQRetTypeAssocKey, retType, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(kls, &_TQArgTypesAssocKey, argTypeObjects, OBJC_ASSOCIATION_RETAIN);
    NSPointerFunctions *pointerFuns = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsOpaqueMemory|NSPointerFunctionsOpaquePersonality];
    pointerFuns.relinquishFunction = &_freeRelinquishFunction;

    NSPointerArray *ffiResArr = [NSPointerArray pointerArrayWithPointerFunctions:pointerFuns];
    [ffiResArr addPointer:cif];
    [ffiResArr addPointer:args];
    objc_setAssociatedObject(kls, &_TQFFIResourcesAssocKey, ffiResArr, OBJC_ASSOCIATION_RETAIN);

    return kls;
}

- (id)at:(id)key
{
    if([key isKindOfClass:[TQNumber class]] || [key isKindOfClass:[NSNumber class]])
        return [self objectAtIndexedSubscript:[(TQNumber *)key unsignedIntegerValue]];
    else
        [NSException raise:NSInvalidArgumentException format:@"Keyed access for boxed object is not supported"];
    return nil;
        //return [self objectForKeyedSubscript:key];
}
- (id)set:(id)key to:(id)val
{
    if([key isKindOfClass:[TQNumber class]] || [key isKindOfClass:[NSNumber class]])
        [self setObject:val atIndexedSubscript:[(TQNumber *)key unsignedIntegerValue]];
    else
        [NSException raise:NSInvalidArgumentException format:@"Keyed access for boxed object is not supported"];
        //[self setObject:val forKeyedSubscript:key];
    return nil;
}

- (id)objectAtIndexedSubscript:(NSInteger)aIdx
{
    return nil;
}
- (void)setObject:(id)aValue atIndexedSubscript:(NSInteger)aIdx
{
    // Implemented by subclasses
}

+ (void)addFieldNames:(NSArray *)aNames
{
    NSString *sel;
    for(int i = 0; i < [aNames count]; ++i) {
        sel = [aNames objectAtIndex:i];
        class_addMethod(self, NSSelectorFromString(sel), imp_implementationWithBlock(^(id self_) {
            return [self_ objectAtIndexedSubscript:i];
        }), "@@:");
        sel = [NSString stringWithFormat:@"set%@:", [sel capitalizedString]];
        class_addMethod(self, NSSelectorFromString(sel), imp_implementationWithBlock(^(id self_, id val) {
            return [self_ setObject:val atIndexedSubscript:i];
        }), "@@:@");
    }
}
@end

#pragma mark - Block/Function pointer (un)boxing

// Block that takes a variable number of objects and calls the original function pointer using their unboxed values
id __wrapperBlock_invoke(struct TQBoxedBlockLiteral *__blk, ...)
{
    const char *type = __blk->type;
    void *funPtr = __blk->funPtr;
    BOOL isBlock = *(type++) == _C_ID;

    void *ffiRet = alloca(__blk->cif->rtype->size);
    const char *retType = type;

    va_list argList;
    va_start(argList, __blk);

    const char *currType, *nextType;
    currType = TQGetSizeAndAlignment(retType, NULL, NULL);
    void *ffiArgs     = alloca(__blk->argSize);
    void **ffiArgPtrs = (void**)alloca(sizeof(void*) * __blk->cif->nargs);
    if(isBlock) {
        ffiArgPtrs[0] = funPtr;
        funPtr = TQBlockDispatchers[__blk->cif->nargs-1];
    }

    id arg;
    for(int i = isBlock, ofs = 0; i < __blk->cif->nargs; ++i) {
        arg = va_arg(argList, id);
        [TQBoxedObject unbox:arg to:(char*)ffiArgs+ofs usingType:currType];
        ffiArgPtrs[i] = (char*)ffiArgs+ofs;

        ofs += __blk->cif->arg_types[i]->size;
        currType = TQGetSizeAndAlignment(currType, NULL, NULL);
    }
    va_end(argList);
    ffi_call(__blk->cif, FFI_FN(funPtr), ffiRet, ffiArgPtrs);

    if(*retType == _C_ID || TYPE_IS_TOLLFREE(retType))
        return *(id *)ffiRet;
    // retain/autorelease to move the pointer onto the heap
    return [[[TQBoxedObject box:ffiRet withType:retType] retain] autorelease];
}

#pragma mark - Boxed msgSend

extern uintptr_t _TQSelectorCacheLookup(id obj, SEL aSelector);
extern void _TQCacheSelector(id obj, SEL sel);

id tq_boxedMsgSend(id self, SEL selector, ...)
{
    if(!self)
        return nil;

    Method method = (Method)_TQSelectorCacheLookup(self, selector);
    if(method == 0x0) {
        _TQCacheSelector(self, selector);
        method = (Method)_TQSelectorCacheLookup(self, selector);
    }
    TQAssert(method != 0x0, @"Unknown selector %s sent to object %@", sel_getName(selector), self);
    if((uintptr_t)method == 0x1L) {
        TQLog(@"Error: Tried to use tq_boxedMsgSend to call a method that does not require boxing");
        return nil;
    }

    const char *encoding = method_getTypeEncoding(method);
    unsigned int nargs   = method_getNumberOfArguments(method);
    IMP imp              = method_getImplementation(method);

    ffi_type *retType;
    ffi_type *argTypes[nargs];
    void *argValues;      // Stores the actual arguments to pass to ffi_call
    void *argPtrs[nargs]; // Stores a list of pointers to args to pass to ffi_call
    void *retPtr = NULL;

    // Start by loading the passed objects (we store them temporarily in argPtrs to avoid an extra alloca)
    argPtrs[0] = self;
    argPtrs[1] = selector;
    va_list valist;
    va_start(valist, selector);
    for(unsigned int i = 2; i < nargs; ++i) {
        argPtrs[i] = va_arg(valist, id);
    }
    va_end(valist);

    if(TQMethodTypeRequiresBoxing(encoding)) {
        // Allocate enough space for the return value
        NSUInteger retSize;
        const char *argEncoding = TQGetSizeAndAlignment(encoding, &retSize, NULL);
        if(retSize > 0)
            retPtr = alloca(retSize);
        retType = [[TQFFIType typeWithEncoding:[TQBoxedObject _skipQualifiers:encoding]] ffiType];

        // Figure out how much space the unboxed arguments need
        const char *argType = argEncoding;
        NSUInteger totalArgSize, argSize;
        totalArgSize = 0;
        for(unsigned int i = 0; i < nargs; ++i) {
            argType = TQGetSizeAndAlignment(argType, &argSize, NULL);
            totalArgSize += argSize;
        }
        argValues = alloca(totalArgSize);

        // Actually unbox the argument list
        argType = argEncoding;
        unsigned int ofs = 0;
        for(unsigned int i = 0; i < nargs; ++i) {
            // Only unbox non-objects that come after the selector
            if(*(argType = [TQBoxedObject _skipQualifiers:argType]) != _C_ID && i >= 2) {
                [TQBoxedObject unbox:(id)argPtrs[i] to:(char*)argValues+ofs usingType:argType];
                argTypes[i] = [[TQFFIType typeWithEncoding:argType] ffiType];
            } else {
                memcpy((char*)argValues + ofs, &argPtrs[i], sizeof(void*));
                argTypes[i] = &ffi_type_pointer;
            }
            argPtrs[i] = (char*)argValues+ofs;
            argType = TQGetSizeAndAlignment(argType, &argSize, NULL);
            ofs += argSize;
        }
    } else {
        // Everything's a simple pointer
        if(*encoding == _C_ID) {
            retType = &ffi_type_pointer;
            retPtr = alloca(sizeof(void*));
        } else
            retType = &ffi_type_void;

        argValues = alloca(sizeof(void*)*nargs);
        unsigned int ofs;
        for(unsigned int i = 0; i < nargs; ++i) {
            ofs = i*sizeof(id);
            memcpy((char*)argValues + ofs, &argPtrs[i], sizeof(id));
            argPtrs[i]  = (char*)argValues + ofs;
            argTypes[i] = &ffi_type_pointer;
        }
    }

    ffi_cif cif;
    if(ffi_prep_cif(&cif, FFI_DEFAULT_ABI, nargs, retType, argTypes) != FFI_OK) {
        // TODO: be more graceful
        TQLog(@"unable to wrap method call");
        exit(1);
    }
    ffi_call(&cif, FFI_FN(imp), retPtr, argPtrs);

    if(*encoding == _C_ID || TYPE_IS_TOLLFREE(encoding))
        return *(id*)retPtr;
    else if(*encoding == _C_VOID)
        return nil;
    return [[[TQBoxedObject box:retPtr withType:encoding] retain] autorelease];
}

#pragma mark - Scalar boxing IMPs
id _box_C_ID_imp(TQBoxedObject *self, SEL _cmd, id *aPtr)                       { return *aPtr;                                           }
id _box_C_SEL_imp(TQBoxedObject *self, SEL _cmd, SEL *aPtr)                     { return NSStringFromSelector(*aPtr);                     }
id _box_C_VOID_imp(TQBoxedObject *self, SEL _cmd, id *aPtr)                     { return nil;                                             }
id _box_C_DBL_imp(TQBoxedObject *self, SEL _cmd, double *aPtr)                  { return [TQNumber numberWithDouble:*aPtr];               }
id _box_C_FLT_imp(TQBoxedObject *self, SEL _cmd, float *aPtr)                   { return [TQNumber numberWithFloat:*aPtr];                }
id _box_C_INT_imp(TQBoxedObject *self, SEL _cmd, int *aPtr)                     { return [TQNumber numberWithInt:*aPtr];                  }
id _box_C_SHT_imp(TQBoxedObject *self, SEL _cmd, short *aPtr)                   { return [TQNumber numberWithShort:*aPtr];                }
id _box_C_BOOL_imp(TQBoxedObject *self, SEL _cmd, _Bool *aPtr)                  { return *aPtr ? TQValid : nil;                           }
id _box_C_LNG_imp(TQBoxedObject *self, SEL _cmd, long *aPtr)                    { return [TQNumber numberWithLong:*aPtr];                 }
id _box_C_LNG_LNG_imp(TQBoxedObject *self, SEL _cmd, long long *aPtr)           { return [TQNumber numberWithLongLong:*aPtr];             }
id _box_C_UINT_imp(TQBoxedObject *self, SEL _cmd, unsigned int *aPtr)           { return [TQNumber numberWithUnsignedInt:*aPtr];          }
id _box_C_USHT_imp(TQBoxedObject *self, SEL _cmd, unsigned short *aPtr)         { return [TQNumber numberWithUnsignedShort:*aPtr];        }
id _box_C_ULNG_imp(TQBoxedObject *self, SEL _cmd, unsigned long *aPtr)          { return [TQNumber numberWithUnsignedLong:*aPtr];         }
id _box_C_ULNG_LNG_imp(TQBoxedObject *self, SEL _cmd, unsigned long long *aPtr) { return [TQNumber numberWithUnsignedLongLong:*aPtr];     }
id _box_C_CHARPTR_imp(TQBoxedObject *self, SEL _cmd, char **aPtr)               { return *aPtr == NULL ? nil : [TQPointer box:aPtr withType:"^c"];      }
id _box_C_CHR_imp(TQBoxedObject *self, SEL _cmd, char *aPtr)                    { return *aPtr == 0    ? nil : [TQNumber numberWithChar:*aPtr];         }
id _box_C_UCHR_imp(TQBoxedObject *self, SEL _cmd, char *aPtr)                   { return *aPtr == 0    ? nil : [TQNumber numberWithUnsignedChar:*aPtr]; }

#pragma mark -

void _freeRelinquishFunction(const void *item, NSUInteger (*size)(const void *item))
{
    free((void*)item);
}

