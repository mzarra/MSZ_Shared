//
//  ZDSStreamJSONParser.m
//
//  Created by Marcus Zarra on 10/28/11.
//  Copyright (c) 2011 Cocoa Is My Girlfriend. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.

#import "ZDSStreamJSONParser.h"

@implementation ZDSStreamJSONParser

static NSDateFormatter *dateFormatter;

@synthesize skipDictionaryCount;
@synthesize parent;
@synthesize currentKey;
@synthesize currentObject;
@synthesize moc;
@synthesize childParser;
//Mon Oct 31 21:43:37 +0000 2011
+ (void)initialize
{
  dateFormatter = [[NSDateFormatter alloc] init];
  [dateFormatter setDateFormat:@"EEE MMM dd HH:mm:ss ZZZ YYYY"];
}

- (id)initWithManagedObjectContext:(NSManagedObjectContext*)aMOC;
{
  if (!(self = [super init])) return nil;
  
  moc = aMOC;
  
  return self;
}

- (void)dealloc
{
  MCRelease(currentKey);
  MCRelease(childParser);
  
  [super dealloc];
}

#pragma mark -
#pragma mark YAJLParserDelegate

- (void)parserDidStartDictionary:(YAJLParser*)parser
{
  NSEntityDescription *entity = nil;
  NSDictionary *relationships = nil;
  NSRelationshipDescription *relationship = nil;
  NSString *destinationObjectName = nil;

  entity = [[self currentObject] entity];
  relationships = [entity relationshipsByName];
  relationship = [relationships objectForKey:[self currentKey]];

  if (!relationship) {
    DLog(@"Unknown relationship in the stream: %@; skipping", [self currentKey]);
    [self setSkipDictionaryCount:([self skipDictionaryCount] + 1)];
    return;
  }
  
  destinationObjectName = [[relationship destinationEntity] name];
  id destinationObject = [NSEntityDescription insertNewObjectForEntityForName:destinationObjectName 
                                                       inManagedObjectContext:[self moc]];
  
  if ([relationship isToMany]) {
    NSMutableSet *children = [[self currentObject] mutableSetValueForKey:[self currentKey]];
    [children addObject:destinationObject];
  } else {
    [[self currentObject] setValue:destinationObject forKey:[self currentKey]];
  }
  
  ZDSStreamJSONParser *aChildParser = nil;
  aChildParser = [[ZDSStreamJSONParser alloc] initWithManagedObjectContext:[self moc]];
  [aChildParser setParent:self];
  [aChildParser setCurrentObject:destinationObject];
  [parser setDelegate:aChildParser];
  [self setChildParser:aChildParser];
  MCRelease(aChildParser);
}

- (void)parserDidEndDictionary:(YAJLParser*)parser
{
  if ([self skipDictionaryCount] > 0) {
    [self setSkipDictionaryCount:([self skipDictionaryCount] - 1)];
    return;
  }
  [parser setDelegate:[self parent]];
}

- (void)parserDidStartArray:(YAJLParser*)parser {}

- (void)parserDidEndArray:(YAJLParser*)parser {}

- (void)parser:(YAJLParser*)parser didMapKey:(NSString*)key
{
  if (![self currentObject]) {
    [self setCurrentKey:key];
    return;
  }
  
  NSDictionary *userInfo = [[[self currentObject] entity] userInfo];
  if (!userInfo) {
    [self setCurrentKey:key];
    return;
  }
  
  NSString *resolvedKey = [userInfo valueForKey:[self currentKey]];
  if (!resolvedKey) {
    [self setCurrentKey:key];
    return;
  }
  
  [self setCurrentKey:key];
}

- (void)parser:(YAJLParser*)parser didAdd:(id)value;
{
  ZAssert([self currentObject], @"Add value without object: %@\n%@", [self currentKey], value);
  
  NSEntityDescription *entity = [[self currentObject] entity];
  NSDictionary *properties = [entity propertiesByName];
  id property = [properties valueForKey:[self currentKey]];
  
  if (!property) { // Fall back to KVC
    SEL selector = NSSelectorFromString([self currentKey]);
    if (![[self currentObject] respondsToSelector:selector]) {
      return;
    }
    
    [[self currentObject] setValue:value forKey:[self currentKey]];
    return;
  }
  
  if ([property isKindOfClass:[NSRelationshipDescription class]]) {
    NSString *methodName = [NSString stringWithFormat:@"add%@:", [[self currentKey] capitalizedString]];
    SEL addSelector = NSSelectorFromString(methodName);
    ZAssert([[self currentObject] respondsToSelector:addSelector], @"Failed to resolve method %@", methodName);
    [[self currentObject] performSelector:addSelector withObject:value];
    return;
  }
  
  switch ([property attributeType]) {
    case NSStringAttributeType:
      if ([value isKindOfClass:[NSString class]]) {
        [[self currentObject] setValue:value forKey:[self currentKey]];
        return;
      } else if ([value isKindOfClass:[NSNumber class]]) {
        [[self currentObject] setValue:[value stringValue] forKey:[self currentKey]];
        return;
      } else if ([value isKindOfClass:[NSNull class]]) {
        [[self currentObject] setValue:nil forKey:[self currentKey]];
        return;
      }
      ALog(@"unparsable data class %@ to string against class %@", 
           [value class], [[[self currentObject] entity] name]);
      return;
    case NSDateAttributeType:
      ZAssert([value isKindOfClass:[NSString class]], 
              @"unparsable data class %@ to number against class %@", 
              [value class], [[[self currentObject] entity] name]);
      if ([value length] == 0) return;
      [[self currentObject] setValue:[dateFormatter dateFromString:value] 
                              forKey:[self currentKey]];
      return;
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType:
    case NSDoubleAttributeType:
    case NSFloatAttributeType:
    case NSBooleanAttributeType:
      if ([value isKindOfClass:[NSNumber class]]) {
        [[self currentObject] setValue:value forKey:[self currentKey]];
        return;
      } else if ([value isKindOfClass:[NSString class]]) {
        
      } else {
        ALog(@"unparsable data class %@ to number against class %@", 
             [value class], [[[self currentObject] entity] name]);
        return;
      }
    case NSBinaryDataAttributeType:
      // TODO: Decode base 64
      return;
    case NSTransformableAttributeType:
    case NSObjectIDAttributeType:
    case NSDecimalAttributeType:
    case NSUndefinedAttributeType:
    default:
      ALog(@"Unknown type %i against class %@", [property attributeType], [[[self currentObject] entity] name]);
  }
}

@end
