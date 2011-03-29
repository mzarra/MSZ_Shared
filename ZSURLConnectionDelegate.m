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

#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

static NSInteger activityCount;

void incrementNetworkActivity(id sender)
{
  if ([[UIApplication sharedApplication] isStatusBarHidden]) return;
  
  @synchronized ([UIApplication sharedApplication]) {
    ++activityCount;
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
  }
}

void decrementNetworkActivity(id sender)
{
  if ([[UIApplication sharedApplication] isStatusBarHidden]) return;
  
  @synchronized ([UIApplication sharedApplication]) {
    --activityCount;
    if (activityCount <= 0) {
      [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
      activityCount = 0;
    }
  }
}

@implementation ZSURLConnectionDelegate

@synthesize verbose;
@synthesize done;

@synthesize data;

@synthesize object;
@synthesize filePath;
@synthesize myURL;
@synthesize response;

@synthesize successSelector;
@synthesize failureSelector;

@synthesize delegate;
@synthesize connection;
@synthesize startTime;
@synthesize duration;

static dispatch_queue_t writeQueue;
static dispatch_queue_t pngQueue;

- (id)initWithURL:(NSURL*)aURL delegate:(id)aDelegate;
{
  ZAssert(aURL, @"incoming url is nil");
  if (![super init]) return nil;
  
  delegate = [aDelegate retain];
  [self setMyURL:aURL];
  
  if (writeQueue == NULL) {
    writeQueue = dispatch_queue_create("cache write queue", NULL);
  }
  
  if (pngQueue == NULL) {
    pngQueue = dispatch_queue_create("png generation queue", NULL);
  }
  
  return self;
}

- (void)dealloc
{
  if ([self isVerbose]) DLog(@"fired");
  connection = nil;
  object = nil;
  
  MCRelease(delegate);
  MCRelease(filePath);
  MCRelease(myURL);
  MCRelease(data);
  MCRelease(response);

  [super dealloc];
}

- (void)main
{
  if ([self isCancelled]) return;
  
  incrementNetworkActivity(self);
  NSURLRequest *request = [NSURLRequest requestWithURL:[self myURL]];
  
  [self setConnection:[NSURLConnection connectionWithRequest:request delegate:self]];
  
  CFRunLoopRun();
  
  decrementNetworkActivity(self);
}

- (void)finish
{
  CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
  DLog(@"finished for %@", [self myURL]);
  if ([self isCancelled]) {
    [[self connection] cancel];
    [self finish];
    return;
  }
  
  [self setDuration:([NSDate timeIntervalSinceReferenceDate] - [self startTime])];
   
  if (![self filePath]) {
    if ([[self delegate] respondsToSelector:[self successSelector]]) {
      [[self delegate] performSelectorOnMainThread:[self successSelector] withObject:self waitUntilDone:YES];
    }
    [self finish];
    return;
  }
  
  NSData *localizedData = [self data];
  NSString *localizedFilepath = [self filePath];
  
  dispatch_sync(writeQueue, ^{
    NSError *error = nil;
    ZAssert([localizedData writeToFile:localizedFilepath atomically:NO], @"Failed to write to %@\n%@\n%@", localizedFilepath, [error localizedDescription], [error userInfo]);
    
    if (![[self delegate] respondsToSelector:[self successSelector]]) return;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
      [[self delegate] performSelector:[self successSelector] withObject:self];
    });
  });
  
  [self finish];
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSHTTPURLResponse*)resp
{
  if ([self isCancelled]) {
    [[self connection] cancel];
    [self finish];
    return;
  }
  if ([self isVerbose]) DLog(@"fired");
  [self setResponse:resp];
  MCRelease(data);
  data = [[NSMutableData alloc] init];
  [self setStartTime:[NSDate timeIntervalSinceReferenceDate]];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)newData
{
  if ([self isCancelled]) {
    [[self connection] cancel];
    [self finish];
    return;
  }
  if ([self isVerbose]) DLog(@"fired");
  [data appendData:newData];
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
  if ([self isCancelled]) {
    [[self connection] cancel];
    [self finish];
    return;
  }
  DLog(@"Failure %@\nURL: %@", [error localizedDescription], [self myURL]);
  if ([[self delegate] respondsToSelector:[self failureSelector]]) {
    [[self delegate] performSelectorOnMainThread:[self failureSelector] withObject:self waitUntilDone:YES];
  }
  [self setDelegate:nil];
  [self finish];
}

@end
