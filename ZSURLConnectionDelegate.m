/*
 * ZSURLConnectionDelegate.m
 *
 * Created by Marcus S. Zarra
 * Copyright Zarra Studos LLC 2010. All rights reserved.
 *
 * Implementation of an image cache that stores downloaded images
 * based on a URL key.  The cache is not persistent (OS makes no
 * guarantees) and is not backed-up when the device is sync'd.
 *
 *  Permission is hereby granted, free of charge, to any person
 *  obtaining a copy of this software and associated documentation
 *  files (the "Software"), to deal in the Software without
 *  restriction, including without limitation the rights to use,
 *  copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the
 *  Software is furnished to do so, subject to the following
 *  conditions:
 *
 *  The above copyright notice and this permission notice shall be
 *  included in all copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 *  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 *  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 *  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 *  OTHER DEALINGS IN THE SOFTWARE.
 *
 */

#import "ZSURLConnectionDelegate.h"
#import "ZSImageCacheHandler.h"

@implementation ZSURLConnectionDelegate

static NSInteger activityCount;

+ (void)incrementNetworkActivity:(id)sender;
{
  @synchronized ([UIApplication sharedApplication]) {
    ++activityCount;
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
  }
}

+ (void)decrementNetworkActivity:(id)sender;
{
  @synchronized ([UIApplication sharedApplication]) {
    --activityCount;
    if (activityCount <= 0) {
      [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    }
  }
}

- (id)initWithURL:(NSURL*)aURL delegate:(id)aDelegate;
{
  if (![super init]) return nil;
  
  delegate = [aDelegate retain];
  finished = NO;
  executing = NO;
  [self setMyURL:aURL];
  retryCount = 0;
  
  return self;
}

- (void)dealloc
{
  connection = nil;
  object = nil;
  delegate = nil;
  [myURL release], myURL = nil;
  [data release], data = nil;
  [super dealloc];
}

- (BOOL)isConcurrent
{
  return YES;
}

- (void)start
{
  if (![NSThread isMainThread]) {
    [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
    return;
  }
  
  [ZSURLConnectionDelegate incrementNetworkActivity:self];
  [self willChangeValueForKey:@"isExecuting"];
  executing = NO;
  [self didChangeValueForKey:@"isExecuting"];
  NSURLRequest *request = [NSURLRequest requestWithURL:[self myURL]];
  
  NSURLConnection *myconn = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
  [self setConnection:myconn];
  [myconn scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  [myconn start];
  [myconn release];  
}

- (void)finish
{
  [ZSURLConnectionDelegate decrementNetworkActivity:self];
  [self willChangeValueForKey:@"isExecuting"];
  executing = NO;
  [self didChangeValueForKey:@"isExecuting"];
  
  [self willChangeValueForKey:@"isFinished"];
  finished = YES;
  [self didChangeValueForKey:@"isFinished"];
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
  if ([[self delegate] respondsToSelector:[self successSelector]]) {
    [[self delegate] performSelector:[self successSelector] withObject:self];
  }
  [self setDelegate:nil];
  [self finish];
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSHTTPURLResponse*)resp
{
  [self setResponse:resp];
  data = [[NSMutableData alloc] init];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)newData
{
  [data appendData:newData];
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
  ALog(@"Failure %@\nURL: %@", [error localizedDescription], [self myURL]);
  if ([[self delegate] respondsToSelector:[self failureSelector]]) {
    [[self delegate] performSelector:[self failureSelector] withObject:self];
  }
  [self setDelegate:nil];
  [self finish];
}

@synthesize isExecuting = executing;
@synthesize isFinished = finished;
@synthesize connection;
@synthesize thumbnail;
@synthesize retryCount;
@synthesize myURL;
@synthesize object;
@synthesize data;
@synthesize delegate;
@synthesize successSelector;
@synthesize failureSelector;
@synthesize response;
@synthesize parseSelector;

@end
