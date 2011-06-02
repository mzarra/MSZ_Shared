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

@interface ZSURLConnectionDelegate ()
@property (readwrite, retain) NSString *inProgressFilePath;
@property (readwrite, retain) NSFileHandle *inProgressFileHandle;
@property (readwrite) NSInteger HTTPStatus;
@property (readwrite, retain) NSURLRequest *request;
@property (readwrite, assign) dispatch_group_t dispatchFileWriteGroup;
@end

@implementation ZSURLConnectionDelegate

@synthesize verbose;
@synthesize done;

@synthesize data;

@synthesize object;
@synthesize filePath;
@synthesize myURL;
@synthesize response;
@synthesize HTTPStatus;
@synthesize request;
@synthesize dispatchFileWriteGroup;

@synthesize successSelector;
@synthesize failureSelector;

@synthesize delegate;
@synthesize connection;
@synthesize startTime;
@synthesize duration;

@synthesize inProgressFilePath;
@synthesize inProgressFileHandle;

@synthesize acceptSelfSignedCertificates;
@synthesize acceptSelfSignedCertificatesFromHosts;

@synthesize userInfo;

static dispatch_queue_t writeQueue;
static dispatch_queue_t pngQueue;

#pragma mark -
#pragma mark Initializers
- (id)initWithRequest:(NSURLRequest *)newRequest delegate:(id)aDelegate;
{
  if (!(self = [super init])) return nil;
  
  request = [newRequest retain];
  delegate = [aDelegate retain];
  [self setMyURL:[newRequest URL]];

  if (writeQueue == NULL) {
    writeQueue = dispatch_queue_create("cache write queue", NULL);
  }
  
  if (pngQueue == NULL) {
    pngQueue = dispatch_queue_create("png generation queue", NULL);
  }
  
  if (dispatchFileWriteGroup == NULL) {
    dispatchFileWriteGroup = dispatch_group_create();
  }
  
  return self;
}

- (id)initWithURL:(NSURL*)aURL delegate:(id)aDelegate;
{
  ZAssert(aURL, @"incoming url is nil");
  return [self initWithRequest:[NSURLRequest requestWithURL:aURL] delegate:aDelegate];
}

#pragma mark -
#pragma mark Convenience factory methods
+ (id)operationWithRequest:(NSURLRequest *)newRequest delegate:(id)aDelegate
{
  return [[[ZSURLConnectionDelegate alloc] initWithRequest:newRequest delegate:aDelegate] autorelease];
}

+ (id)operationWithURL:(NSURL *)aURL delegate:(id)aDelegate
{
  return [[[ZSURLConnectionDelegate alloc] initWithURL:aURL delegate:aDelegate] autorelease];
}

#pragma mark -
#pragma mark Memory management
- (void)dealloc
{
  if ([self isVerbose]) DLog(@"fired");
  connection = nil;
  object = nil;
  
  if (![self filePath]) {
    // If no filePath was set, don't litter the temp dir with orphaned downloaded files.
    [[NSFileManager defaultManager] removeItemAtPath:[self inProgressFilePath] error:nil];
  }
  MCRelease(delegate);
  MCRelease(filePath);
  MCRelease(myURL);
  MCRelease(data);
  MCRelease(request);
  MCRelease(response);
  MCRelease(userInfo);

  dispatch_release([self dispatchFileWriteGroup]);

  MCRelease(inProgressFilePath);
  MCRelease(inProgressFileHandle);
  
  [super dealloc];
}

#pragma mark -
#pragma mark Accessors
- (void)setAcceptSelfSignedCertificates:(BOOL)flag
{
  acceptSelfSignedCertificates = flag;
  if (flag) {
    // Setting the flag to YES implies trusting self-signed certs from everyone.
    [acceptSelfSignedCertificatesFromHosts release];
    acceptSelfSignedCertificatesFromHosts = nil;
  }
}

- (void)setAcceptSelfSignedCertificatesFromHosts:(NSArray *)hosts
{
  [acceptSelfSignedCertificatesFromHosts release];
  acceptSelfSignedCertificatesFromHosts = [hosts copy];
  // Set the flag to NO to turn off accept-from-all behavior, limiting access to only the host list.
  [self setAcceptSelfSignedCertificates:NO];
}

#pragma mark -
#pragma mark Entry point
- (void)main
{
  if ([self isCancelled]) return;
  
  incrementNetworkActivity(self);
  
  [self setConnection:[NSURLConnection connectionWithRequest:[self request] delegate:self]];
  
  CFRunLoopRun();
  
  decrementNetworkActivity(self);
}

- (void)finish
{
  CFRunLoopStop(CFRunLoopGetCurrent());
}

#pragma mark -
#pragma mark NSURLConnection delegate methods
- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
  dispatch_group_wait([self dispatchFileWriteGroup], DISPATCH_TIME_FOREVER);
  
  [[self inProgressFileHandle] closeFile];
  
  DLog(@"finished for %@", [self myURL]);
  if ([self isCancelled]) {
    [[self connection] cancel];
    [self finish];
    return;
  }
  
  [self setDuration:([NSDate timeIntervalSinceReferenceDate] - [self startTime])];
   
  // Even if filePath was set, the delegate might try to look at the data blob.
  data = [[NSData alloc] initWithContentsOfMappedFile:[self inProgressFilePath]];
  if ([[self delegate] respondsToSelector:[self successSelector]]) {
    [[self delegate] performSelectorOnMainThread:[self successSelector] withObject:self waitUntilDone:YES];
  }
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
  [self setHTTPStatus:[resp statusCode]];
  
  if ([self filePath]) {
    [self setInProgressFilePath:[self filePath]];
  } else {
    [self setInProgressFilePath:[[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", abs([[[self myURL] absoluteString] hash])]] retain]];
  }
  [[NSFileManager defaultManager] removeItemAtPath:[self inProgressFilePath] error:nil];
  [[NSFileManager defaultManager] createFileAtPath:[self inProgressFilePath] contents:nil attributes:nil];
  [self setInProgressFileHandle:[NSFileHandle fileHandleForWritingAtPath:[self inProgressFilePath]]];
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
  dispatch_group_async([self dispatchFileWriteGroup], writeQueue, ^{
    [[self inProgressFileHandle] writeData:newData];
  });
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
  [[self inProgressFileHandle] closeFile];
  
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

- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace {
    if (([self acceptSelfSignedCertificates]) || ([[self acceptSelfSignedCertificatesFromHosts] count] > 0)) {
        return [[protectionSpace authenticationMethod] isEqualToString:NSURLAuthenticationMethodServerTrust];
    } else {
        return NO;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
  if (([self acceptSelfSignedCertificates]) || ([[self acceptSelfSignedCertificatesFromHosts] containsObject:[[challenge protectionSpace] host]])) {
    if ([[[challenge protectionSpace] authenticationMethod] isEqualToString:NSURLAuthenticationMethodServerTrust]) {
      [[challenge sender] useCredential:[NSURLCredential credentialForTrust:[[challenge protectionSpace] serverTrust]] forAuthenticationChallenge:challenge];
    } else {
      [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
    }
  }
}

@end
