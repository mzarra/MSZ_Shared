//
//  CGFURLDelegateOperation.m
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

#import "CGFURLDelegateOperation.h"
#import "ZDSStreamJSONParser.h"

#import "YAJLParser.h"

@interface CGFInternalParser : NSObject <YAJLParserDelegate>

@property (nonatomic, retain) ZDSStreamJSONParser *child;
@property (nonatomic, retain) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, retain) NSManagedObject *currentTweet;
@property (nonatomic, retain) NSManagedObject *user;

@property (nonatomic, assign) YAJLParser *parser;

@end

@implementation CGFURLDelegateOperation

@synthesize requestURL;
@synthesize parser;
@synthesize managedObjectContext;
@synthesize response;
@synthesize user;

- (id)initWithRequestURL:(NSURL*)aURL andContext:(NSManagedObjectContext*)aContext;
{
  if (!(self = [super init])) return nil;
  
  requestURL = [aURL retain];
  managedObjectContext = aContext;

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  managedObjectContext = nil;
  
  MCRelease(response);
  MCRelease(requestURL);
  MCRelease(parser);
  
  [super dealloc];
}

- (void)main
{
  NSInteger yajlOptions = YAJLParserOptionsAllowComments;
  YAJLParser *aParser = [[YAJLParser alloc] initWithParserOptions:yajlOptions];
  
  NSManagedObjectContext *internalMOC = [[NSManagedObjectContext alloc] init];
  [internalMOC setParentContext:[self managedObjectContext]];
  
  CGFInternalParser *internalParser = [[CGFInternalParser alloc] init];
  [internalParser setManagedObjectContext:internalMOC];
  [internalParser setParser:aParser];
  [internalParser setUser:[self user]];
  
  [aParser setDelegate:internalParser];
  [self setParser:aParser];
  MCRelease(aParser);
  
  NSURLRequest *request = [NSURLRequest requestWithURL:[self requestURL]];
  [NSURLConnection connectionWithRequest:request delegate:self];
  
  CFRunLoopRun();
  
  NSError *error = nil;
  ZAssert([internalMOC save:&error], @"Error saving %@\n%@", [error localizedDescription], [error userInfo]);
  MCRelease(internalMOC);
}

#pragma mark -
#pragma mark NSURLConnectionDelegate methods

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSHTTPURLResponse*)resp
{
  [self setResponse:resp];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)newData
{
  YAJLParserStatus status = [[self parser] parse:newData];
  if (status == YAJLParserStatusInsufficientData) return;
  if (status == YAJLParserStatusOK) return;
  
  NSError *error = [[self parser] parserError];
  ALog(@"Data parsing has failed: %@", error);
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
  CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
  ALog(@"Failure %@\n%@", [error localizedDescription], [error userInfo]);
  CFRunLoopStop(CFRunLoopGetCurrent());
}

@end

@implementation CGFInternalParser

#pragma mark YAJLParserDelegate

- (void)dealloc
{
  [self setChild:nil];
  [self setManagedObjectContext:nil];
  [self setCurrentTweet:nil];
  [self setUser:nil];
  
  [super dealloc];
}

- (void)merge
{
  if (![self currentTweet]) return;
    
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Tweet"];
  [request setPredicate:[NSPredicate predicateWithFormat:@"identifer == %@", [[self currentTweet] valueForKey:@"identifier"]]];
  
  NSError *error = nil;
  NSArray *tweets = [[self managedObjectContext] executeFetchRequest:request error:&error];
  ZAssert(!error || tweets, @"Error fetching: %@", error);
  
  if ([tweets count] == 1) {
    [[[self user] mutableSetValueForKey:@"timeline"] addObject:[self currentTweet]];
    [[self managedObjectContext] performBlock:^{
      NSError *error = nil;
      ZAssert([[self managedObjectContext] save:&error], @"Failed to save: %@", error);
    }];
    return;
  }
  
  NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id mo, NSDictionary *bindings) {
    if ([mo isTemporaryID]) return NO;
    return YES;
  }];
  
  NSManagedObject *masterTweet = [[tweets filteredArrayUsingPredicate:predicate] lastObject];
  if (!masterTweet) {
    masterTweet = [self currentTweet];
  }
  
  for (NSManagedObject *tweet in tweets) {
    if (tweet == masterTweet) continue;
    [[self managedObjectContext] deleteObject:tweet];
  }
  
  [[[self user] mutableSetValueForKey:@"timeline"] addObject:masterTweet];
  
  [[self managedObjectContext] performBlock:^{
    NSError *error = nil;
    ZAssert([[self managedObjectContext] save:&error], @"Failed to save: %@", error);
  }];
}

- (void)parserDidStartDictionary:(YAJLParser*)parser
{
  [self merge];

  NSManagedObject *tweet = [NSEntityDescription insertNewObjectForEntityForName:@"Tweet" inManagedObjectContext:[self managedObjectContext]];
  ZDSStreamJSONParser *streamParser = [[ZDSStreamJSONParser alloc] initWithManagedObjectContext:[self managedObjectContext]];
  [streamParser setCurrentObject:tweet];
  [streamParser setParent:self];
  [self setChild:streamParser];
  [parser setDelegate:streamParser];
  [self setCurrentTweet:tweet];
  MCRelease(streamParser);
}

- (void)parserDidEndDictionary:(YAJLParser*)parser
{
  ALog(@"Should not fire");
}

- (void)parserDidStartArray:(YAJLParser*)parser
{
}

- (void)parserDidEndArray:(YAJLParser*)parser
{
}

- (void)parser:(YAJLParser*)parser didMapKey:(NSString*)key
{
  ALog(@"Should not fire");
}

- (void)parser:(YAJLParser*)parser didAdd:(id)value
{
  ALog(@"Should not fire");
}

@synthesize user;
@synthesize parser;
@synthesize managedObjectContext;
@synthesize currentTweet;
@synthesize child;

@end
