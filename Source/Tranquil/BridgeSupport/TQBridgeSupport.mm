#import "TQBridgeSupport.h"
#import "../Tranquil.h"
#import "../Runtime/NSString+TQAdditions.h"
#import "bs.h"
#import <objc/runtime.h>

using namespace llvm;

static void _parserCallback(bs_parser_t *parser, const char *path, bs_element_type_t type,
                            void *value, void *context)
{
    TQBridgeSupport *bs = (id)context;
    switch(type) {
        case BS_ELEMENT_STRUCT: {
            bs_element_struct_t *strct = (bs_element_struct_t*)value;
            //printf("struct: %s { ", strct->name);
            //for(int i = 0; i < strct->fields_count; ++i) {
                //printf("%s => %s, ", strct->fields[i].name, strct->fields[i].type);
            //}
            //printf("}\n");
        } break;
        case BS_ELEMENT_CFTYPE: {
            // Bridged types treated as objects, unbridged as opaque pointers
            bs_element_cftype_t *cf = (bs_element_cftype_t*)value;
            //printf("cftyp: %s type: %s bridged? %s\n", cf->name, cf->type, cf->tollfree);
        } break;
        case BS_ELEMENT_OPAQUE: {
            bs_element_opaque_t *opaq = (bs_element_opaque_t*)value;
            //printf("opaq: %s type: %s\n", opaq->name, opaq->type);

        } break;
        case BS_ELEMENT_CONSTANT: {
            bs_element_constant_t *cnst = (bs_element_constant_t*)value;
            NSString *name = [NSString stringWithUTF8String:cnst->name];
            [bs->_literalConstants setObject:[TQBridgedConstant constantWithName:name
                                                                            type:[NSString stringWithUTF8String:cnst->type]]
                                      forKey:[name stringByCapitalizingFirstLetter]];
        } break;
        case BS_ELEMENT_STRING_CONSTANT: {
            bs_element_string_constant_t *str = (bs_element_string_constant_t*)value;
            [bs->_literalConstants setObject:[TQNodeString nodeWithString:[NSMutableString stringWithUTF8String:str->value]]
                                      forKey:[[NSString stringWithUTF8String:str->name] stringByCapitalizingFirstLetter]];
        } break;
        case BS_ELEMENT_ENUM: {
            bs_element_enum_t *enm = (bs_element_enum_t*)value;
            if(enm->ignore)
                return;
            [bs->_literalConstants setObject:[TQNodeNumber nodeWithDouble:atof(enm->value)]
                                      forKey:[[NSString stringWithUTF8String:enm->name] stringByCapitalizingFirstLetter]];
            //printf("enum: %s = %s. Suggest: %s\n", enm->name, enm->value, enm->suggestion);
        } break;
        case BS_ELEMENT_FUNCTION: {
            bs_element_function_t *fun = (bs_element_function_t*)value;

            NSMutableArray *args = [NSMutableArray arrayWithCapacity:fun->args_count];
            for(int i = 0; i < fun->args_count; ++i) {
                [args addObject:[NSString stringWithUTF8String:fun->args[i].type]];
            }
            TQBridgedFunction *funObj = [TQBridgedFunction functionWithName:[NSString stringWithUTF8String:fun->name]
                                                                 returnType:[NSString stringWithUTF8String:fun->retval ? fun->retval->type : "v"]
                                                              argumentTypes:args];
            [bs->_functions setObject:funObj
                               forKey:[funObj.name stringByCapitalizingFirstLetter]];

        } break;
        case BS_ELEMENT_FUNCTION_ALIAS: {
            bs_element_function_alias_t *alias = (bs_element_function_alias_t*)value;
            [bs->_functions setObject:[bs->_functions objectForKey:[[NSString stringWithUTF8String:alias->original]  stringByCapitalizingFirstLetter]]
                               forKey:[[NSString stringWithUTF8String:alias->name] stringByCapitalizingFirstLetter]];

        } break;
        case BS_ELEMENT_CLASS: {
            bs_element_class_t *kls = (bs_element_class_t*)value;
            //printf("Class: %s\n", kls->name);
        } break;
        case BS_ELEMENT_INFORMAL_PROTOCOL_METHOD:
            // Protocols are not a thing in Tranquil and probably won't be
        break;
        default:
            NSLog(@"Unknown BridgeSupport object");
    }
}

@implementation TQBridgeSupport

- (id)init
{
    if(!(self = [super init]))
        return nil;

    _functions        = [[NSMutableDictionary alloc] init];
    _literalConstants = [[NSMutableDictionary alloc] init];
    _constants        = [[NSMutableDictionary alloc] init];
    _parser           = bs_parser_new();

    return self;
}

- (void)dealloc
{
    [_functions release];
    [_constants release];
    [_literalConstants release];
    bs_parser_free(_parser);

    [super dealloc];
}

- (id)loadFramework:(NSString *)aFrameworkPath
{
    char bsPath[1024];
    const char *frameworkPath = [aFrameworkPath fileSystemRepresentation];
    bool found = bs_find_path(frameworkPath, bsPath, 1024);
    if(!found)
        return nil;
    char *error = nil;
    bool parsed = bs_parser_parse(_parser, bsPath, frameworkPath, BS_PARSE_OPTIONS_LOAD_DYLIBS, 
                                  &_parserCallback, (void*)self, &error);
    if(!parsed) {
        if(error)
            NSLog(@"BridgeSupport error: %s", error);
        return NO;
    }

    return TQValid;
}

- (TQNode *)entityNamed:(NSString *)aName
{
    id ret = [self functionNamed:aName];
    if(ret)
        return ret;
    return [self constantNamed:aName];
}

- (TQBridgedFunction *)functionNamed:(NSString *)aName
{
    return [_functions objectForKey:aName];
}

- (TQBridgedConstant *)constantNamed:(NSString *)aName
{
    id literal = [_literalConstants objectForKey:aName];
    if(literal)
        return literal;
    return [_constants objectForKey:aName];
}

+ (llvm::Type *)llvmTypeFromEncoding:(const char *)aEncoding inProgram:(TQProgram *)aProgram
{
    switch(*aEncoding) {
        case _C_ID:
        case _C_CLASS:
        case _C_SEL:
        case _C_PTR:
        case _C_CHARPTR:
        case _MR_C_LAMBDA_B:
            return aProgram.llInt8PtrTy;
        case _C_DBL:
            return aProgram.llDoubleTy;
        case _C_FLT:
            return aProgram.llFloatTy;
        case _C_INT:
            return aProgram.llIntTy;
        case _C_SHT:
            return aProgram.llInt16Ty;
        case _C_CHR:
            return aProgram.llInt8Ty;
        case _C_BOOL:
            return aProgram.llInt8Ty;
        case _C_LNG:
            return aProgram.llInt64Ty;
        case _C_LNG_LNG:
            return aProgram.llInt64Ty;
        case _C_UINT:
            return aProgram.llIntTy;
        case _C_USHT:
            return aProgram.llInt16Ty;
        case _C_ULNG:
            return aProgram.llInt64Ty;
        case _C_ULNG_LNG:
            return aProgram.llInt64Ty;
        case _C_VOID:
            return aProgram.llVoidTy;
        case _C_STRUCT_B: {
            const char *field = strstr(aEncoding, "=") + 1;
            assert((uintptr_t)field > 1);
            std::vector<Type*> fields;
            while(*field != _C_STRUCT_E) {
                fields.push_back([self llvmTypeFromEncoding:field inProgram:aProgram]);
                field = NSGetSizeAndAlignment(field, NULL, NULL);
            }
            return StructType::get(aProgram.llModule->getContext(), fields);
        }
        case _C_UNION_B:
            NSLog(@"unions -> llvm not yet supported");
            exit(1);
        break;
        default:
            [NSException raise:NSGenericException
                        format:@"Unsupported type %c!", *aEncoding];
            return NULL;
    }
}

@end

@implementation TQBridgedConstant
@synthesize name=_name, type=_type;

+ (TQBridgedConstant *)constantWithName:(NSString *)aName type:(NSString *)aType;
{
    TQBridgedConstant *cnst = (TQBridgedConstant *)[self node];
    cnst->_name = [aName retain];
    cnst->_type = [aType retain];

    return cnst;
}

- (void)dealloc
{
    [_name release];
    [_type release];
    [super dealloc];
}

- (Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
    if(_global)
        return aBlock.builder->CreateLoad(_global);

    // With constants we just want to unbox them once and then keep that object around
    Module *mod = aProgram.llModule;
    Function *rootFunction = aProgram.root.function;
    IRBuilder<> rootBuilder(&rootFunction->getEntryBlock(), rootFunction->getEntryBlock().begin());
    Value *constant = mod->getOrInsertGlobal([_name UTF8String], [TQBridgeSupport llvmTypeFromEncoding:[_type UTF8String] inProgram:aProgram]);
    constant = rootBuilder.CreateBitCast(constant, aProgram.llInt8PtrTy);
    Value *boxed = rootBuilder.CreateCall2(aProgram.TQBoxValue, constant, [aProgram getGlobalStringPtr:_type withBuilder:&rootBuilder]);
    _global = new GlobalVariable(*mod, aProgram.llInt8PtrTy, false, GlobalVariable::InternalLinkage,
                                 ConstantPointerNull::get(aProgram.llInt8PtrTy), [[@"TQBridgedConst_" stringByAppendingString:_name] UTF8String]);
    rootBuilder.CreateStore(boxed, _global);
    return aBlock.builder->CreateLoad(_global);
}
@end

@implementation TQBridgedFunction
@synthesize name=_name, returnType=_returnType, argumentTypes=_argumentTypes;

+ (TQBridgedFunction *)functionWithName:(NSString *)aName returnType:(NSString *)aReturn argumentTypes:(NSArray *)aArgumentTypes
{
    TQBridgedFunction *fun = (TQBridgedFunction *)[self node];
    fun->_name             = [aName retain];
    fun->_returnType       = [aReturn retain];
    fun->_argumentTypes    = [aArgumentTypes retain];

    return fun;
}

- (void)dealloc
{
    [_name release];
    [_returnType release];
    [_argumentTypes release];
    [super dealloc];
}

- (NSUInteger)argumentCount
{
    return [_argumentTypes count];
}
//- (llvm::Function *)_generateCopyHelperInProgram:(TQProgram *)aProgram
//{
    //return NULL;
//}
//- (llvm::Function *)_generateDisposeHelperInProgram:(TQProgram *)aProgram
//{
    //return NULL;
//}

// Compiles a a wrapper block for the function
// The reason we don't use TQBoxedObject is that when the function is known at compile time
// we can generate a far more efficient wrapper that doesn't rely on libffi
- (llvm::Function *)_generateInvokeInProgram:(TQProgram *)aProgram error:(NSError **)aoErr
{
    if(_function)
        return _function;

    llvm::PointerType *int8PtrTy = aProgram.llInt8PtrTy;

    // Build the invoke function
    std::vector<Type *> paramObjTypes(_argumentTypes.count+1, int8PtrTy);
    FunctionType* wrapperFunType = FunctionType::get(int8PtrTy, paramObjTypes, false);

    Module *mod = aProgram.llModule;

    const char *wrapperFunctionName = [[NSString stringWithFormat:@"__tq_wrapper_%@", _name] UTF8String];

    _function = Function::Create(wrapperFunType, GlobalValue::ExternalLinkage, wrapperFunctionName, mod);

    BasicBlock *entryBlock    = BasicBlock::Create(mod->getContext(), "entry", _function, 0);
    IRBuilder<> *entryBuilder = new IRBuilder<>(entryBlock);

    BasicBlock *callBlock    = BasicBlock::Create(mod->getContext(), "call", _function);
    IRBuilder<> *callBuilder = new IRBuilder<>(callBlock);

    BasicBlock *errBlock    = BasicBlock::Create(mod->getContext(), "invalidArgError", _function);
    IRBuilder<> *errBuilder = new IRBuilder<>(errBlock);



    // Load the block pointer argument (must do this before captures, which must be done before arguments in case a default value references a capture)
    llvm::Function::arg_iterator argumentIterator = _function->arg_begin();
    // Ignore the block pointer
    ++argumentIterator;


    // Load the arguments
    Value *sentinel = entryBuilder->CreateLoad(mod->getOrInsertGlobal("TQSentinel", aProgram.llInt8PtrTy));

    NSString *argTypeEncoding;
    Type *argType;
    std::vector<Type *> argTypes;
    std::vector<Value *> args;
    NSUInteger typeSize;
    BasicBlock  *currBlock, *nextBlock;
    IRBuilder<> *currBuilder, *nextBuilder;
    currBlock   = entryBlock;
    currBuilder = entryBuilder;

    Type *retType = [TQBridgeSupport llvmTypeFromEncoding:[_returnType UTF8String] inProgram:aProgram];    
    AllocaInst *resultAlloca;
    // If it's a void return we don't allocate a return buffer
    if(![_returnType hasPrefix:@"v"])
        resultAlloca = entryBuilder->CreateAlloca(retType);

    NSGetSizeAndAlignment([_returnType UTF8String], &typeSize, NULL);
    // Return doesn't fit in a register so we must pass an alloca before the function arguments
    // TODO: Make this cross platform
    BOOL returningOnStack = TQStructSizeRequiresStret(typeSize);
    if(returningOnStack) {
        argTypes.push_back(PointerType::getUnqual(retType));
        args.push_back(resultAlloca);
        retType = aProgram.llVoidTy;
    }

    for(int i = 0; i < [_argumentTypes count]; ++i)
    {
        argTypeEncoding = [_argumentTypes objectAtIndex:i];
        //NSGetSizeAndAlignment([argTypeEncoding UTF8String], &typeSize, NULL);
        argType = [TQBridgeSupport llvmTypeFromEncoding:[argTypeEncoding UTF8String] inProgram:aProgram];
        argTypes.push_back(argType);

        IRBuilder<> startBuilder(&_function->getEntryBlock(), _function->getEntryBlock().begin());
        Value *unboxedArgAlloca = startBuilder.CreateAlloca(argType, NULL, [[NSString stringWithFormat:@"arg%d", i] UTF8String]);

        // If the value is a sentinel we've not been passed enough arguments => jump to error
        Value *notPassedCond = currBuilder->CreateICmpEQ(argumentIterator, sentinel);

        // Create the block for the next argument check (or set it to the call block)
        if(i == [_argumentTypes count]-1) {
            nextBlock = callBlock;
            nextBuilder = callBuilder;
        } else {
            nextBlock = BasicBlock::Create(mod->getContext(), [[NSString stringWithFormat:@"check%d", i] UTF8String], _function, callBlock);
            nextBuilder = new IRBuilder<>(nextBlock);
        }

        currBuilder->CreateCondBr(notPassedCond, errBlock, nextBlock);

        nextBuilder->CreateCall3(aProgram.TQUnboxObject,
                                 argumentIterator,
                                 [aProgram getGlobalStringPtr:argTypeEncoding withBuilder:nextBuilder],
                                 nextBuilder->CreateBitCast(unboxedArgAlloca, aProgram.llInt8PtrTy));
        args.push_back(nextBuilder->CreateLoad(unboxedArgAlloca));

        ++argumentIterator;
        currBlock   = nextBlock;
        currBuilder = nextBuilder;
    }

    // Populate the error block
    // TODO: Come up with a global error reporting mechanism and make this crash
    [aProgram insertLogUsingBuilder:errBuilder withStr:[@"Invalid number of arguments passed to " stringByAppendingString:_name]];
    errBuilder->CreateRet(ConstantPointerNull::get(int8PtrTy));

    // Populate call block
    FunctionType *funType = FunctionType::get(retType, argTypes, false);
    Function *function = aProgram.llModule->getFunction([_name UTF8String]);
    if(!function) {
        function = Function::Create(funType, GlobalValue::ExternalLinkage, [_name UTF8String], aProgram.llModule);
        function->setCallingConv(CallingConv::C);
    }

    Value *callResult = callBuilder->CreateCall(function, args);
    if([_returnType hasPrefix:@"v"])
        callBuilder->CreateRet(ConstantPointerNull::get(aProgram.llInt8PtrTy));
    else {
        if(!returningOnStack)
            callBuilder->CreateStore(callResult, resultAlloca);
        Value *boxed = callBuilder->CreateCall2(aProgram.TQBoxValue,
                                                callBuilder->CreateBitCast(resultAlloca, int8PtrTy),
                                                [aProgram getGlobalStringPtr:_returnType withBuilder:callBuilder]);
        Value *moveToHeapSel = callBuilder->CreateLoad(mod->getOrInsertGlobal("TQMoveToHeapSel", aProgram.llInt8PtrTy));
        callBuilder->CreateCall2(aProgram.objc_msgSend, boxed, moveToHeapSel);
        callBuilder->CreateRet(boxed);
    }

    return _function;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<bridged function@ %@>", _name];
}
@end
