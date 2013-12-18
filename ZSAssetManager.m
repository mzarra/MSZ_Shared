/*
 * ZSImageCacheHandler.h
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

#import "ZSAssetManager.h"
#import "ZSURLConnectionDelegate.h"
#import "ZSReachability.h"

#import "NSString+ZSAdditions.h"

#define kCachePath @"imageCache"

#define VERBOSE NO
#define CACHE_TEST NO

#define kGoodSampleThreshold (25 * 1024)

//These need to be in bytes
#define kYellowHighThreshold (50.0f * 1024.0f)
#define kYellowLowThreshold (25.0f * 1024.0f)

typedef enum {
  ZSNetworkStateOptimal = 4,
  ZSNetworkStateAverage = 0,
  ZSNetworkStatePoor = -4
} ZSNetworkState;

@interface ZSAssetManager()

- (NSString*)cachePath;
- (void)downloadImage:(NSURL*)url;
- (NSURL*)resolveLocalURLForRemoteURL:(NSURL*)url;
- (NSOperationQueue*)assetQueue;

@property (nonatomic, assign) NSUInteger totalDownload;
@property (nonatomic, assign) NSInteger cachePopulationIdentifier;
@property (nonatomic, assign) NSInteger currentNetworkState;
@property (nonatomic, assign) NSInteger numberOfItemsDownloaded;

@property (nonatomic, retain) NSMutableArray *pendingCacheItems;
@property (nonatomic, retain) NSMutableDictionary *completionBlocks;

@end

@implementation ZSAssetManager

@synthesize backgroundCaching;
@synthesize pendingCacheItems;
@synthesize totalDownload;
@synthesize cachePopulationIdentifier;
@synthesize currentNetworkState;
@synthesize numberOfItemsDownloaded;
@synthesize completionBlocks;

+ (ZSAssetManager*)sharedAssetManager
{
  static dispatch_once_t onceToken;
  static ZSAssetManager *sharedInstance = nil;
  
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ZSAssetManager alloc] init];
  });
  
  return sharedInstance;
}

- (id)init
{
  self = [super init];
  
  // TODO: Is there a way to avoid object:nil?
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kZSReachabilityChangedNotification object:nil];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(flushMemoryCaches:) name:UIApplicationDidReceiveMemoryWarningNotification object:[UIApplication sharedApplication]];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(enteringBackground:) name:UIApplicationDidEnterBackgroundNotification object:[UIApplication sharedApplication]];
  
  [self performSelector:@selector(loadPersistentCacheLists) withObject:nil afterDelay:1.0];
  [self setCompletionBlocks:[NSMutableDictionary dictionary]];
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  [super dealloc];
}

- (NSOperationQueue*)assetQueue
{
  static NSOperationQueue *assetQueue;
  if (assetQueue) return assetQueue;
  
  @synchronized([UIApplication sharedApplication]) {
    assetQueue = [[NSOperationQueue alloc] init];
    [assetQueue setMaxConcurrentOperationCount:2];
  }
  
  return assetQueue;
}

- (NSString*)cachePath
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *filePath = [paths objectAtIndex:0];
  filePath = [filePath stringByAppendingPathComponent:kCachePath];
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:filePath]) return filePath;
  
  NSError *error = nil;
  ZAssert([fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:&error], @"Failed to create image cache directory: %@\n%@", [error localizedDescription], [error userInfo]);
  
  return filePath;
}

#pragma mark -
#pragma mark Cache Control

- (void)clearStaleCacheItems
{
  DLog(@"clearing stale cache items");
  
  NSTimeInterval time = [NSDate timeIntervalSinceReferenceDate];
  
#ifdef DEBUG
  time -= (5 * 60);
#else
  time -= (24 * 60 * 60);
#endif
  
  NSDate *deleteDate = [NSDate dateWithTimeIntervalSinceReferenceDate:time];
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  NSString *cachePath = [self cachePath];
  
  NSError *error = nil;
  NSArray *filesArray = [fileManager contentsOfDirectoryAtPath:cachePath error:&error];
  ZAssert(!error || filesArray, @"Failed to retrieve contents of directory %@\n%@\n%@", cachePath, [error localizedDescription], [error userInfo]);
  
  [filesArray enumerateObjectsUsingBlock:^(id filename, NSUInteger index, BOOL *stop) {
    NSError *error = nil;
    NSString *filePath = [cachePath stringByAppendingPathComponent:filename];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:filePath isDirectory:&isDirectory]) {
      DLog(@"file no longer exists, skipping: %@", filePath);
      return;
    }
    if (isDirectory) {
      DLog(@"directory being skipped: %@", filePath);
      return;
    }
    
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:filePath error:&error];
    ZAssert(!error || fileAttributes, @"Failed to retrieve attributes of file %@\n%@\n%@", filePath, [error localizedDescription], [error userInfo]);
    
    NSDate *createDate = [fileAttributes fileCreationDate];
    NSDate *modificationDate = [fileAttributes fileModificationDate];
    
    if ([deleteDate earlierDate:createDate] == createDate || [deleteDate earlierDate:modificationDate] == modificationDate) {
      DLog(@"file is too new, skipping: %@", filePath);
      return;
    }
    
    ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to remove file: %@\n%@\n%@", filePath, [error localizedDescription], [error userInfo]);
  }];
}

- (NSURL*)resolveLocalURLForRemoteURL:(NSURL*)url
{
  if (!url) return nil;
  
  NSString *filename = [[url absoluteString] zs_digest];
  NSString *filePath = [[self cachePath] stringByAppendingPathComponent:filename];
  
  return [NSURL fileURLWithPath:filePath];
}

- (NSString*)persistentCacheListFilePath
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *filePath = [paths objectAtIndex:0];
  filePath = [filePath stringByAppendingPathComponent:@"CacheList"];
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:filePath]) return filePath;
  
  NSError *error = nil;
  ZAssert([fileManager createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:&error], @"Failed to create image cache directory: %@\n%@", [error localizedDescription], [error userInfo]);
  return filePath;
}

- (void)loadPersistentCacheLists
{
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  NSError *error = nil;
  NSArray *files = [fileManager contentsOfDirectoryAtPath:filePath error:&error];
  ZAssert(!error || files, @"Error retrieving files %@\n%@", [error localizedDescription], [error userInfo]);
  
  for (NSString *pathComponent in files) {
    NSMutableSet *assetSet = [[NSMutableSet alloc] init];
    NSString *fullPathForFile = [filePath stringByAppendingPathComponent:pathComponent];
    NSArray *cacheItems = [NSArray arrayWithContentsOfFile:fullPathForFile];
    for (NSString *item in cacheItems) {
      [assetSet addObject:[NSURL URLWithString:item]];
    }
    ZAssert([fileManager removeItemAtPath:fullPathForFile error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
    
    DLog(@"reinstating cache list ------------------------------------------ %i", [cacheItems count]);
    
    [self queueAssetsForRetrievalFromURLSet:assetSet];
  }
}

- (void)persistCacheList:(NSSet*)set
{
  NSString *filePath = [self persistentCacheListFilePath];
  filePath = [filePath stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  
  NSMutableArray *array = [[NSMutableArray alloc] init];
  for (NSURL *url in set) {
    [array addObject:[url absoluteString]];
  }
  
  ZAssert([array writeToFile:filePath atomically:NO], @"Failed to write cache list to disk");
}

- (void)calculateBandwidthForDelegate:(ZSURLConnectionDelegate*)delegate
{
  if ([[delegate data] length] < kGoodSampleThreshold) return;
  CGFloat sample = ([[delegate data] length] / [delegate duration]);
  totalDownload += [[delegate data] length];
  ++numberOfItemsDownloaded;
  
  if (sample >= kYellowHighThreshold) {
    currentNetworkState = ++currentNetworkState < ZSNetworkStateOptimal ? currentNetworkState : ZSNetworkStateOptimal;
  } else if (sample <= kYellowLowThreshold) {
    currentNetworkState = --currentNetworkState > ZSNetworkStatePoor ? currentNetworkState : ZSNetworkStatePoor;
  } else if (currentNetworkState > ZSNetworkStateAverage) {
    --currentNetworkState;
  } else if (currentNetworkState > ZSNetworkStatePoor) {
    ++currentNetworkState;
  }
  
  if (currentNetworkState == ZSNetworkStateOptimal) {
    [[self assetQueue] setSuspended:NO];
    [[self assetQueue] setMaxConcurrentOperationCount:4];
    return;
  }
  
  [[self assetQueue] setMaxConcurrentOperationCount:1];
  
  if (currentNetworkState == ZSNetworkStateAverage) {
    [[self assetQueue] setSuspended:NO];
    return;
  }
  
  for (ZSURLConnectionDelegate *nextOperation in [[self assetQueue] operations]) {
    if ([nextOperation isExecuting] || [nextOperation isFinished] || [nextOperation isCancelled]) {
      DLog(@"skipping operation");
      continue;
    }
    if ([nextOperation queuePriority] == NSOperationQueuePriorityVeryHigh) {
      DLog(@"still busy with user requests");
      return;
    }
    [[self assetQueue] setSuspended:YES];
  }
}

- (void)cacheOperationCompleted:(ZSURLConnectionDelegate*)delegate
{
  NSInteger opCount = [[self assetQueue] operationCount];
  NSError *error = nil;
  
  [self calculateBandwidthForDelegate:delegate];
  
  if (opCount > 1) return;
  
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
  
  [[UIApplication sharedApplication] endBackgroundTask:[self cachePopulationIdentifier]];
  
  DLog(@"<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<cache completed>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>");
}

- (void)cacheOperationFailed:(ZSURLConnectionDelegate*)delegate
{
  if (VERBOSE) DLog(@"request failed");
}

#pragma mark -
#pragma mark Notifications

- (void)enteringBackground:(NSNotification*)notification
{
  DLog(@"object %@", [[notification object] class]);
  if ([self allowBackgroundCaching]) return;
  
  [[self assetQueue] cancelAllOperations];
}

- (void)reachabilityChanged:(NSNotification*)notification
{
  NetworkStatus status = [[ZSReachability reachabilityForInternetConnection] currentReachabilityStatus];
  [[self assetQueue] setSuspended:(status == NotReachable)];
  if (CACHE_TEST) DLog(@"Suspended: %@", (status == NotReachable ? @"YES" : @"NO"));
}

#pragma mark -
#pragma mark Internal Methods

- (void)downloadImage:(NSURL*)url
{
  if ([[ZSReachability reachabilityForInternetConnection] currentReachabilityStatus] == NotReachable) {
    if (CACHE_TEST) DLog(@"connection is offline, refusing to download image");
    return;
  } else {
    [[self assetQueue] setSuspended:NO];
    if (CACHE_TEST) DLog(@"activating cache");
  }
  
  [[self assetQueue] setSuspended:NO];
  
  //If it is currently in the cache queue, promote it
  for (ZSURLConnectionDelegate *operation in [[self assetQueue] operations]) {
    if (![[operation myURL] isEqual:url]) continue;
    [operation setQueuePriority:NSOperationQueuePriorityHigh];
    [operation setSuccessSelector:@selector(dataReceived:)];
    [operation setFailureSelector:@selector(requestFailedForDelegate:)];
    return;
  }
  
  NSURL *localURL = [self resolveLocalURLForRemoteURL:url];
  
  ZSURLConnectionDelegate *delegate = [[ZSURLConnectionDelegate alloc] initWithURL:url delegate:self];
  [delegate setFilePath:[localURL path]];
  [delegate setSuccessSelector:@selector(dataReceived:)];
  [delegate setFailureSelector:@selector(requestFailedForDelegate:)];
  [delegate setQueuePriority:NSOperationQueuePriorityNormal];
  
  [[self assetQueue] addOperation:delegate];
}

#pragma mark -
#pragma mark ZSURLConnectionDelegate

- (void)dataReceived:(ZSURLConnectionDelegate*)delegate
{
  if (![[delegate data] length]) {
    if (VERBOSE) DLog(@"%s zero-length image received; ignoring", __PRETTY_FUNCTION__);
    return;
  }
  NSURL *url = [delegate myURL];
  UIImage *image = [self imageForURL:url];

  // Fire off any completion blocks we may have.
  if ([[self completionBlocks] objectForKey:url]) {
    NSMutableArray *blocks = [[self completionBlocks] objectForKey:url];
    for (ZDSImageDeliveryBlock completionBlock in blocks) {
      completionBlock(url, image);
    }
    
    // We don't need you any more. </golum>
    [[self completionBlocks] removeObjectForKey:url];
  }
  
  NSNotification *notification = [NSNotification notificationWithName:kImageDownloadComplete object:url userInfo:nil];
  
  [[NSNotificationQueue defaultQueue] enqueueNotification:notification postingStyle:NSPostWhenIdle coalesceMask:NSNotificationCoalescingOnSender forModes:nil];

  [[NSNotificationCenter defaultCenter] postNotification:notification];
}

- (void)requestFailedForDelegate:(ZSURLConnectionDelegate*)delegate
{
  if (VERBOSE) DLog(@"request failed");
  if (!delegate) return;
}

#pragma mark -
#pragma mark Public Methods

- (void)queueAssetForRetrievalFromURL:(NSURL*)url
{
  if (![url isKindOfClass:[NSURL class]]) {
    DLog(@"non-NSURL in request: %@:%@", [url class], url);
    return;
  }
  
  for (ZSURLConnectionDelegate *delegate in [[self assetQueue] operations]) {
    if ([[delegate myURL] isEqual:url]) return;
  }
  
  NSString *filePath = [[self resolveLocalURLForRemoteURL:url] path];
  if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
    DLog(@"file already in place: %@", filePath);
    return;
  }
  
  ZSURLConnectionDelegate *cacheOperation = [[ZSURLConnectionDelegate alloc] initWithURL:url delegate:self];
  [cacheOperation setFilePath:filePath];
  [cacheOperation setVerbose:VERBOSE];
  [cacheOperation setSuccessSelector:@selector(cacheOperationCompleted:)];
  [cacheOperation setFailureSelector:@selector(cacheOperationFailed:)];
  [cacheOperation setQueuePriority:NSOperationQueuePriorityLow];
  [cacheOperation setThreadPriority:0.0f];
  
  [[self assetQueue] addOperation:cacheOperation];
}

- (void)queueAssetsForRetrievalFromURLSet:(NSSet*)urlSet
{
  DLog(@"loading cache");
  [self persistCacheList:urlSet];
  [self performSelector:@selector(clearStaleCacheItems) withObject:nil afterDelay:1.0];
  
  BOOL newTask = ([[self assetQueue] operationCount] == 0);
  
  [urlSet enumerateObjectsUsingBlock:^(id requestedURL, BOOL *stop) {
    [self queueAssetForRetrievalFromURL:requestedURL];
  }];
  
  if (!newTask) return;
  
  //Do not schedule ourselves on the background when using cellular
  if ([[ZSReachability reachabilityForInternetConnection] currentReachabilityStatus] != ReachableViaWiFi) return;
  
  NSInteger bgIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
    DLog(@"about to exit");
  }];
  [self setCachePopulationIdentifier:bgIdentifier];
}

- (NSURL*)localURLForAssetURL:(NSURL*)url
{
  ZAssert(url, @"nil URL passed again");
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  NSURL *localURL = [self resolveLocalURLForRemoteURL:url];
  
  if ([[NSFileManager defaultManager] fileExistsAtPath:[localURL path]]) {
    if (CACHE_TEST) DLog(@" ******************** HIT cache file %@", [url absoluteString]);
    
    NSError *error = nil;
    NSDictionary *modifiedDict = [NSDictionary dictionaryWithObject:[NSDate date] forKey:NSFileModificationDate];
    ZAssert([fileManager setAttributes:modifiedDict ofItemAtPath:[localURL path] error:&error], @"Error setting modification date on file %@\n%@\n%@", [localURL path], [error localizedDescription], [error userInfo]);
    return localURL;
  }
  
#ifdef DEBUG
  if (CACHE_TEST) DLog(@"missed cache file %@\n%@", [url absoluteString], [localURL path]);
#endif
  
  [self downloadImage:url];
  
  return nil;
}

- (void)fetchImageForURL:(NSURL*)url withCompletionBlock:(ZDSImageDeliveryBlock)completion
{
  UIImage *image = [self imageForURL:url];
  
  if (image) {
    completion(url, image);
  }
  else {
    NSMutableArray *array = [NSMutableArray arrayWithArray:[[self completionBlocks] objectForKey:url]];
    [array addObject:[completion copy]];
    [[self completionBlocks] setObject:array forKey:url];
  }
}

- (UIImage*)imageForURL:(NSURL*)url
{
  ZAssert(url, @"nil URL passed again");
  
  NSURL *localURL = [self localURLForAssetURL:url];
  if (!localURL) return nil;
  
  UIImage *image = [UIImage imageWithData:[NSData dataWithContentsOfMappedFile:[localURL path]]];
  
  return image;
}

- (void)flushCache
{
  [[self assetQueue] setSuspended:YES];
  
  [[self assetQueue] cancelAllOperations];
  
  [[self assetQueue] setSuspended:NO];
}

- (void)clearCaches
{
#ifdef DEBUG
  NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
#endif
  [[self assetQueue] setSuspended:YES];
  
  [[self assetQueue] cancelAllOperations];
  
  DLog(@"operations flushed: %.2f", ([NSDate timeIntervalSinceReferenceDate] - start));
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  NSError *error = nil;
  NSString *tempCachePath = [NSString stringWithFormat:@"%@ %.2f", [self cachePath], [NSDate timeIntervalSinceReferenceDate]];
  ZAssert([fileManager moveItemAtPath:[self cachePath] toPath:tempCachePath error:&error], @"Move failed");
  DLog(@"move directory: %.2f", ([NSDate timeIntervalSinceReferenceDate] - start));
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
  dispatch_async(queue, ^(void) {
    NSError *error = nil;
    ZAssert([fileManager removeItemAtPath:tempCachePath error:&error], @"Crap: %@", error);
    DLog(@"directory removed: %.2f", ([NSDate timeIntervalSinceReferenceDate] - start));
  });
  
  DLog(@"disk flush prepped: %.2f", ([NSDate timeIntervalSinceReferenceDate] - start));
  
  [[self assetQueue] setSuspended:NO];
  
  DLog(@"done: %.2f", ([NSDate timeIntervalSinceReferenceDate] - start));
}

- (void)clearPersistentCacheList
{
  [[self assetQueue] setSuspended:YES];
  
  [[self assetQueue] cancelAllOperations];
  
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;
  
  ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
  
  [[self assetQueue] setSuspended:NO];
}

@end
