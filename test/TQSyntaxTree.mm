#include "TQSyntaxTree.h"
#include <iostream>
#include <llvm/LLVMContext.h>
#include <llvm/DerivedTypes.h>
#include <llvm/Constants.h>
#include <llvm/GlobalVariable.h>
#include <llvm/Function.h>
#include <llvm/CallingConv.h>
#include <llvm/BasicBlock.h>
#include <llvm/Instructions.h>
#include <llvm/InlineAsm.h>
#include <llvm/Support/FormattedStream.h>
#include <llvm/Support/MathExtras.h>
#include <llvm/Pass.h>
#include <llvm/PassManager.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/Analysis/Verifier.h>
#include <llvm/Assembly/PrintModulePass.h>
#include <algorithm>

NSString * const kTQSyntaxErrorDomain = @"org.tranquil.syntax";

@implementation TQSyntaxNode
- (BOOL)generateCodeInModule:(llvm::Module *)aModule :(NSError **)aoErr
{
	NSLog(@"Code generation has not been implemented for %@.", [self class]);
	return NO;
}
@end

@implementation TQSyntaxNodeReturn
@synthesize value=_value;
- (id)initWithValue:(TQSyntaxNode *)aValue
{
	if(!(self = [super init]))
		return nil;

	_value = [aValue retain];

	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ret@ %@>", _value];
}
@end

@implementation TQSyntaxNodeVariable
@synthesize name=_name;

- (id)initWithName:(NSString *)aName
{
	if(!(self = [super init]))
		return nil;

	_name = [aName retain];

	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<var@ %@>", _name];
}

- (void)dealloc
{
	[_name release];
	[super dealloc];
}
@end

@implementation TQSyntaxNodeString
@synthesize value=_value;

- (id)initWithCString:(const char *)aStr
{
	if(!(self = [super init]))
		return nil;

	_value = [[NSString alloc] initWithUTF8String:aStr];

	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<str@ \"%@\">", _value];
}

- (void)dealloc
{
	[_value release];
	[super dealloc];
}
@end

@implementation TQSyntaxNodeIdentifier
- (NSString *)description
{
	return [NSString stringWithFormat:@"<ident@ %@>", [self value]];
}

@end

@implementation TQSyntaxNodeNumber
@synthesize value=_value;

- (id)initWithDouble:(double)aDouble
{
	if(!(self = [super init]))
		return nil;

	_value = [[NSNumber alloc] initWithDouble:aDouble];

	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<num@ %f>", _value.doubleValue];
}

- (void)dealloc
{
	[_value release];
	[super dealloc];
}
@end


@implementation TQSyntaxNodeArgument
@synthesize identifier=_identifier, passedNode=_passedNode;

- (id)initWithPassedNode:(TQSyntaxNode *)aNode identifier:(NSString *)aIdentifier
{
	if(!(self = [super init]))
		return nil;

	_passedNode = [aNode retain];
	_identifier = [aIdentifier retain];

	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<arg@ %@: %@>", _identifier, _passedNode];
}

- (void)dealloc
{
	[_identifier release];
	[_passedNode release];
	[super dealloc];
}
@end


@implementation TQSyntaxNodeBlock
@synthesize arguments=_arguments, statements=_statements;

- (id)init
{
	if(!(self = [super init]))
		return nil;

	_arguments = [[NSMutableArray alloc] init];
	_statements = [[NSMutableArray alloc] init];

	return self;
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithString:@"<blk@ {"];
	if(_arguments.count > 0) {
		for(TQSyntaxNodeArgument *arg in _arguments) {
			[out appendFormat:@"%@ ", arg];
		}
		[out appendString:@"|"];
	}
	if(_statements.count > 0) {
		[out appendString:@"\n"];
		for(TQSyntaxNode *stmt in _statements) {
			[out appendFormat:@"\t%@\n", stmt];
		}
	}
	[out appendString:@"}>"];
	return out;
}

- (void)dealloc
{
	[_arguments release];
	[_statements release];
	[super dealloc];
}

- (BOOL)addArgument:(TQSyntaxNodeArgument *)aArgument error:(NSError **)aoError
{
	if(_arguments.count == 0)
		TQAssertSoft(aArgument.identifier == nil,
		             kTQSyntaxErrorDomain, kTQUnexpectedIdentifier, NO,
		             @"First argument of a block can not have an identifier");
	[_arguments addObject:aArgument];

	return YES;
}
@end


@implementation TQSyntaxNodeCall
@synthesize callee=_callee, arguments=_arguments;

- (id)initWithCallee:(TQSyntaxNode *)aCallee
{
	if(!(self = [super init]))
		return nil;

	_callee = [aCallee retain];
	_arguments = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc
{
	[_callee release];
	[_arguments release];
	[super dealloc];
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithString:@"<call@ "];
	if(_callee)
		[out appendFormat:@"%@: ", _callee];

	for(TQSyntaxNodeArgument *arg in _arguments) {
		[out appendFormat:@"%@ ", arg];
	}

	[out appendString:@".>"];
	return out;
}


@end

@implementation TQSyntaxNodeClass
@synthesize name=_name, superClassName=_superClassName, classMethods=_classMethods, instanceMethods=_instanceMethods;

- (id)initWithName:(NSString *)aName superClass:(NSString *)aSuperClass error:(NSError **)aoError
{
	NSString *first = [aName substringToIndex:1];
	TQAssertSoft([first isEqualToString:[first capitalizedString]],
	             kTQSyntaxErrorDomain, kTQInvalidClassName, nil,
	             @"Classes must be capitalized, %@ was not.", aName);
	if(aSuperClass) {
		first = [aSuperClass substringToIndex:1];
		TQAssertSoft([first isEqualToString:[first capitalizedString]],
		             kTQSyntaxErrorDomain, kTQInvalidClassName, nil,
		             @"Classes must be capitalized, %@ was not.", aName);
	}

	if(!(self = [super init]))
		return nil;

	_name = [aName retain];
	_superClassName = [aSuperClass retain];

	_classMethods = [[NSMutableArray alloc] init];
	_instanceMethods = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc
{
	[_name release];
	[_superClassName release];
	[_classMethods release];
	[_instanceMethods release];
	[super dealloc];
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithFormat:@"<cls@ class %@", _name];
	if(_superClassName)
		[out appendFormat:@" < %@", _superClassName];
	[out appendString:@"\n"];

	for(TQSyntaxNodeMethod *meth in _classMethods) {
		[out appendFormat:@"%@\n", meth];
	}
	if(_classMethods.count > 0 && _instanceMethods.count > 0)
		[out appendString:@"\n"];
	for(TQSyntaxNodeMethod *meth in _instanceMethods) {
		[out appendFormat:@"%@\n", meth];
	}

	[out appendString:@"end>"];
	return out;
}

@end

@implementation TQSyntaxNodeMethod
@synthesize type=_type;

- (id)initWithType:(TQMethodType)aType
{
	if(!(self = [super init]))
		return nil;

	_type = aType;

	return self;
}

- (BOOL)addArgument:(TQSyntaxNodeArgument *)aArgument error:(NSError **)aoError
{
	if(self.arguments.count == 0)
		TQAssertSoft(aArgument.identifier != nil,
		             kTQSyntaxErrorDomain, kTQUnexpectedIdentifier, NO,
		             @"No name given for method");
	[self.arguments addObject:aArgument];

	return YES;
}

- (void)dealloc
{
	[super dealloc];
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithString:@"<meth@ "];
	switch(_type) {
		case kTQClassMethod:
			[out appendString:@"+ "];
			break;
		case kTQInstanceMethod:
		default:
			[out appendString:@"- "];
	}
	for(TQSyntaxNodeArgument *arg in self.arguments) {
		[out appendFormat:@"%@ ", arg];
	}
	[out appendString:@"{"];
	if(self.statements.count > 0) {
		[out appendString:@"\n"];
		for(TQSyntaxNode *stmt in self.statements) {
			[out appendFormat:@"\t%@\n", stmt];
		}
	}
	[out appendString:@"}>"];
	return out;
}

@end


@implementation TQSyntaxNodeMessage
@synthesize receiver=_receiver, arguments=_arguments;

- (id)initWithReceiver:(TQSyntaxNode *)aNode
{
	if(!(self = [super init]))
		return nil;
	
	_receiver = [aNode retain];
	_arguments = [[NSMutableArray alloc] init];

	return self;
}

- (void)dealloc
{
	[_receiver release];
	[_arguments release];
	[super dealloc];
}

- (NSString *)description
{
	NSMutableString *out = [NSMutableString stringWithString:@"<msg@ "];
	[out appendFormat:@"%@ ", _receiver];

	for(TQSyntaxNodeArgument *arg in _arguments) {
		[out appendFormat:@"%@ ", arg];
	}

	[out appendString:@".>"];
	return out;
}
@end

@implementation TQSyntaxNodeMemberAccess
@synthesize receiver=_receiver, property=_property;

- (id)initWithReceiver:(TQSyntaxNode *)aReceiver property:(NSString *)aProperty
{
	if(!(self = [super init]))
		return nil;

	_receiver = [aReceiver retain];
	_property = [aProperty retain];

	return self;
}

- (void)dealloc
{
	[_receiver release];
	[_property release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<acc@ %@#%@>", _receiver, _property];
}

@end

@implementation TQSyntaxNodeBinaryOperator
@synthesize type=_type, left=_left, right=_right;

- (id)initWithType:(TQOperatorType)aType left:(TQSyntaxNode *)aLeft right:(TQSyntaxNode *)aRight
{
	if(!(self = [super init]))
		return nil;

	_type = aType;
	_left = [aLeft retain];
	_right = [aRight retain];

	return self;
}

- (void)dealloc
{
	[_left release];
	[_right release];
	[super dealloc];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<op@ %@ %c %@>", _left, _type, _right];
}
@end



@implementation TQSyntaxTree
@end