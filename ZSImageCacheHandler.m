/*
 * ZSImageCacheHandler.h
 *
 * Version: 2.0
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

#import "ZSImageCacheHandler.h"
#import "ZSURLConnectionDelegate.h"

#import "Reachability.h"

#import "TEDImageCacheMO.h"

#define kCachePath @"imageCache"

#define VERBOSE NO
#define CACHE_TEST NO

#define kGoodSampleThreshold (25 * 1024)

//These need to be in bytes
#define kYellowHighThreshold (50.0f * 1024.0f)
#define kYellowLowThreshold (25.0f * 1024.0f)

@interface ZSImageCacheHandler()

- (NSString*)cachePath;

- (void)downloadImage:(NSURL*)url unique:(id)object;

- (NSURL*)resolveLocalURLForRemoteURL:(NSURL*)url;
- (void)postCacheStatusNotification;
@end

@implementation ZSImageCacheHandler

@synthesize rollingSize;
@synthesize currentNetworkState;
@synthesize totalDownload;
@synthesize numberOfItemsDownloaded;

@synthesize numberOfItemsAddedToCacheQueue;
@synthesize imageReferenceCache;
@synthesize imageCache;
@synthesize assetsQueuedToCacheArray;
@synthesize cachePopulationQueue;
@synthesize operationQueue;
@synthesize managedObjectContext;
@synthesize useCount;
@synthesize cachePopulationIdentifier;
@synthesize storedCacheRequestsArray;

+ (id)defaultManagerForContext:(NSManagedObjectContext*)moc;
{
  static NSMutableDictionary *managerDictionary;
  @synchronized (self) {
    if (!managerDictionary) {
      managerDictionary = [[NSMutableDictionary alloc] init];
    }
  }
  NSString *hashCode = [NSString stringWithFormat:@"%i", [[moc persistentStoreCoordinator] hash]];
  id manager = [managerDictionary objectForKey:hashCode];
  if (manager) return manager;
  @synchronized (self) {
    manager = [[self alloc] initWithManagedObjectContext:moc];
    [managerDictionary setValue:manager forKey:hashCode];
    [manager release];
  }
  return manager;
}

- (id)initWithManagedObjectContext:(NSManagedObjectContext*)moc
{
  if (!(self = [super init])) return nil;
  operationQueue = [[NSOperationQueue alloc] init];
  [operationQueue setMaxConcurrentOperationCount:1];
  
  managedObjectContext = [moc retain];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  NSEntityDescription *entity = [NSEntityDescription entityForName:@"ImageCache" inManagedObjectContext:moc];
  ZAssert(entity, @"Failed to find ImageCache entity in context.");
  [request setEntity:entity];
  [request setReturnsObjectsAsFaults:NO];
  
  NSError *error = nil;
  [moc executeFetchRequest:request error:&error];
  MCRelease(request);
  ZAssert(!error, @"Failed to warm up the image cache: %@\n%@", [error localizedDescription], [error userInfo]);
 
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityChanged:) name:kReachabilityChangedNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(flushMemoryCaches:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
  
  if ([NSThread isMainThread]) {
    [self performSelector:@selector(loadPersistentCacheLists) withObject:nil afterDelay:1.0];
    [self performSelector:@selector(clearStaleCacheItems) withObject:nil afterDelay:1.0];
  }
  
  return self;
}

- (void)dealloc
{
  ZAssert(useCount == 0, @"manager deallocated while still in use by %d clients", useCount);
  
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  MCRelease(cachePopulationQueue);
  MCRelease(operationQueue);
  MCRelease(managedObjectContext);
  
  MCRelease(storedCacheRequestsArray);
  MCRelease(assetsQueuedToCacheArray);
  MCRelease(imageReferenceCache);
  MCRelease(imageCache);
  
  [super dealloc];
}

- (NSOperationQueue*)cachePopulationQueue
{
  if (cachePopulationQueue) return cachePopulationQueue;
  
  cachePopulationQueue = [[NSOperationQueue alloc] init];
  [cachePopulationQueue setMaxConcurrentOperationCount:2];
  
  return cachePopulationQueue;
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
#pragma mark NSDiscardableContent

- (void)discardContentIfPossible
{
  if (![self useCount]) {
    if (VERBOSE) DLog(@"memory warning received, current downloads %u", [[[self operationQueue] operations] count]);
    if (VERBOSE) DLog(@"memory warning received, current caching %u", [[[self cachePopulationQueue] operations] count]);
  }
}

- (BOOL)beginContentAccess 
{
  [self setUseCount:[self useCount] + 1];
  return YES;
}

- (void)endContentAccess 
{
  [self setUseCount:[self useCount] - 1];
  ZAssert(useCount>=0, @"object has been over-discarded");
}

- (BOOL)isContentDiscarded 
{
  return (useCount != 0);
}

#pragma mark -
#pragma mark Cache Control

- (void)clearStaleCacheItems
{
  if (VERBOSE) DLog(@"clearing stale cache items");
  NSCalendar *calendar = [NSCalendar currentCalendar];
  NSDateComponents *dateComponents = [[NSDateComponents alloc] init];
  [dateComponents setDay:-3];
  
  NSDate *deleteDate = [calendar dateByAddingComponents:dateComponents toDate:[NSDate date] options:0];
  
  NSManagedObjectContext *moc = [self managedObjectContext];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  [request setEntity:[TEDImageCacheMO entityInManagedObjectContext:moc]];
  [request setPredicate:[NSPredicate predicateWithFormat:@"lastAccessed <= %@", deleteDate]];
  
  NSError *error = nil;
  NSArray *itemsToDelete = [moc executeFetchRequest:request error:&error];
  MCRelease(request);
  ZAssert(!error || itemsToDelete, @"Error fetching cache items: %@\n%@", [error localizedDescription], [error userInfo]);
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  for (TEDImageCacheMO *cacheItem in itemsToDelete) {
    NSString *filePath = [cacheItem imagePath];
    [moc deleteObject:cacheItem];
    if (![fileManager fileExistsAtPath:filePath]) continue;
    ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
  }
  if (VERBOSE) DLog(@"items removed: %i", [itemsToDelete count]);
  [dateComponents release];
}

- (TEDImageCacheMO*)imageCacheObjectForURLString:(NSString*)urlString
{
  ZAssert(urlString, @"URL is nil");
  
  TEDImageCacheMO *imageCacheObject = [[self imageReferenceCache] objectForKey:urlString];
  
  if (imageCacheObject) return imageCacheObject;
  
  NSManagedObjectContext *moc = [self managedObjectContext];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  [request setEntity:[NSEntityDescription entityForName:@"ImageCache" inManagedObjectContext:moc]];
  [request setPredicate:[NSPredicate predicateWithFormat:@"sourceURL == %@", urlString]];
  
  NSError *error = nil;
  NSArray *tempArray = [moc executeFetchRequest:request error:&error];
  imageCacheObject = [tempArray lastObject];
  MCRelease(request);
  ZAssert(!error || imageCacheObject, @"Error fetching cache: %@", error);
  
  if (imageCacheObject) {
    return imageCacheObject;
  } else {
    if (CACHE_TEST) DLog(@"cache missed for url %@", urlString);
  }
  
  if (CACHE_TEST) DLog(@"creating imageCacheObject");
  imageCacheObject = [NSEntityDescription insertNewObjectForEntityForName:@"ImageCache" inManagedObjectContext:moc];
  [imageCacheObject setValue:urlString forKey:@"sourceURL"];
  [imageCacheObject setValue:[NSDate date] forKey:@"lastAccessed"];
  
  NSString *filename = [[NSProcessInfo processInfo] globallyUniqueString];
  NSString *filePath = [[self cachePath] stringByAppendingPathComponent:filename];
  [imageCacheObject setValue:filePath forKey:@"imagePath"];
  if (CACHE_TEST) DLog(@"build ICO with path %@\n%@", filePath, urlString);
  
  if (![self imageReferenceCache]) {
    NSCache *cache = [[NSCache alloc] init];
    [self setImageReferenceCache:cache];
    MCRelease(cache);
  }
  
  [[self imageReferenceCache] setObject:imageCacheObject forKey:urlString];
  
  return imageCacheObject;
}

- (NSURL*)resolveLocalURLForRemoteURL:(NSURL*)url
{
  if (!url) return nil;
  
  TEDImageCacheMO *imageCacheObject = [self imageCacheObjectForURLString:[url absoluteString]];
  
  NSString *path = [imageCacheObject valueForKey:@"imagePath"];
  
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    if (CACHE_TEST) DLog(@"missing cache file %@", [url absoluteString]);
    return [NSURL fileURLWithPath:path];
  }
  
  return nil;
}

- (BOOL)internalQueueAssetForRetrievalFromCacheObject:(TEDImageCacheMO*)imageCacheObject
{
  
  NSURL *url = [NSURL URLWithString:[imageCacheObject sourceURL]];
  if (!url) return NO;
  
  ++numberOfItemsAddedToCacheQueue;
  ZSURLConnectionDelegate *cacheOperation = [[ZSURLConnectionDelegate alloc] initWithURL:url delegate:self];
  [cacheOperation setFilePath:[imageCacheObject imagePath]];
  [cacheOperation setVerbose:VERBOSE];
  [cacheOperation setSuccessSelector:@selector(cacheOperationCompleted:)];
  [cacheOperation setFailureSelector:@selector(cacheOperationFailed:)];
  [cacheOperation setQueuePriority:NSOperationQueuePriorityLow];
  [cacheOperation setThreadPriority:0.0f];
  
  [[self cachePopulationQueue] addOperation:cacheOperation];
  MCRelease(cacheOperation);
  return YES;
}

- (void)internalQueueAssetForRetrievalFromURLString:(NSString*)urlString
{
  TEDImageCacheMO *imageCacheObject = [self imageCacheObjectForURLString:urlString];
  [self internalQueueAssetForRetrievalFromCacheObject:imageCacheObject];
}

- (void)reachabilityChanged:(NSNotification*)notification
{
  if (CACHE_TEST) DLog(@"Suspended: %d", ![Reachability isReachable]);
  [[self cachePopulationQueue] setSuspended:(![Reachability isReachable])];
}

- (void)flushMemoryCaches:(NSNotification*)notification
{
  [[self imageReferenceCache] removeAllObjects];
  [[self imageCache] removeAllObjects];
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

- (void)clearPersistentCacheList
{
  [[self operationQueue] setSuspended:YES];
  [[self cachePopulationQueue] setSuspended:YES];
  
  [[self operationQueue] cancelAllOperations];
  [[self cachePopulationQueue] cancelAllOperations];
  
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;
  
  ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
  
  [[self operationQueue] setSuspended:NO];
  [[self cachePopulationQueue] setSuspended:NO];
}

- (void)loadPersistentCacheLists
{
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  NSError *error = nil;
  NSArray *files = [fileManager contentsOfDirectoryAtPath:filePath error:&error];
  ZAssert(!error || files, @"Error retrieving files %@\n%@", [error localizedDescription], [error userInfo]);
  
  for (NSString *pathComponent in files) {
    NSString *fullPathForFile = [filePath stringByAppendingPathComponent:pathComponent];
    NSArray *cacheItems = [NSArray arrayWithContentsOfFile:fullPathForFile];
    ZAssert([fileManager removeItemAtPath:fullPathForFile error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
    if (!cacheItems) continue;
    
    if (VERBOSE) DLog(@"reinstating cache list ------------------------------------------ %i", [cacheItems count]);
    
    [self queueAssetsForRetrievalFromURLSet:[NSSet setWithArray:cacheItems]];
  }
}

- (void)persistentCacheList:(NSSet*)set
{
  NSString *filePath = [self persistentCacheListFilePath];
  filePath = [filePath stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
  NSArray *array = [set allObjects];
  
  ZAssert([array writeToFile:filePath atomically:NO], @"Failed to write cache list to disk");
}

- (void)queueAssetsForRetrievalFromURLSet:(NSSet*)urlSet
{
  if (![urlSet count]) return;
  ZAssert([NSThread isMainThread], @"Called on a background thread; bad juju. No cookie for you.");
  
  [self persistentCacheList:urlSet];
  
  BOOL newTask = ([[self cachePopulationQueue] operationCount] == 0);
  
  NSManagedObjectContext *moc = [self managedObjectContext];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  [request setEntity:[NSEntityDescription entityForName:@"ImageCache" inManagedObjectContext:moc]];
  [request setPredicate:[NSPredicate predicateWithFormat:@"sourceURL in %@", urlSet]];
  
  NSError *error = nil;
  NSArray *imageCacheArray = [moc executeFetchRequest:request error:&error];
  MCRelease(request);
  ZAssert(!error || imageCacheArray, @"Failed to load image cache: %@\n%@", [error localizedDescription], [error userInfo]);
  
  NSString *cachePathRoot = [self cachePath];
  
  NSDictionary *imageCacheDictionary = [NSDictionary dictionaryWithObjects:imageCacheArray forKeys:[imageCacheArray valueForKey:@"sourceURL"]];
  
  [urlSet enumerateObjectsUsingBlock:^(id urlString, BOOL *stop) {
    TEDImageCacheMO *imageCacheObject = [imageCacheDictionary valueForKey:urlString];
    
    NSString *path = nil;
    if (!imageCacheObject) {
      imageCacheObject = [TEDImageCacheMO insertInManagedObjectContext:moc];
      [imageCacheObject setSourceURL:urlString];
      [imageCacheObject setLastAccessed:[NSDate date]];
      path = [cachePathRoot stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
      [imageCacheObject setImagePath:path];
    } else {
      path = [imageCacheObject imagePath];
      if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return;
      }
    }
    
    if (![self internalQueueAssetForRetrievalFromCacheObject:imageCacheObject]) {
      if (VERBOSE) DLog(@"bad url %@", urlString);
      [[self managedObjectContext] deleteObject:imageCacheObject];
    }
  }];
  [self postCacheStatusNotification];  
  if ([[self cachePopulationQueue] operationCount] == 0) {

    return;
  }
  
  if (!newTask) return;
  
  //Do not schedule ourselves on the background when using cellular
  if (![Reachability isReachableViaWiFi]) return;
  
  NSInteger bgIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
    if (VERBOSE) DLog(@"about to exit");
    NSError *error = nil;
    ZAssert([[self managedObjectContext] save:&error], @"Error saving context on backgrounding %@\n%@", [error localizedDescription], [error userInfo]);
  }];
  [self setCachePopulationIdentifier:bgIdentifier];
}

- (void)queueAssetForRetrievalFromURL:(NSURL*)url
{
  ZAssert([NSThread isMainThread], @"Called on a background thread; bad juju. No cookie for you.");
  
  NSURL *localURL = [self resolveLocalURLForRemoteURL:url];
  if (localURL) return; //Already loaded
  
  [[[self operationQueue] operations] enumerateObjectsUsingBlock:^(id operation, NSUInteger index, BOOL *stop) {
    if ([[operation myURL] isEqual:url]) return;
  }];
  
  [self internalQueueAssetForRetrievalFromURLString:[url absoluteString]];
}

- (void)flushCache
{
  [[self operationQueue] setSuspended:YES];
  [[self cachePopulationQueue] setSuspended:YES];
  
  [[self operationQueue] cancelAllOperations];
  [[self cachePopulationQueue] cancelAllOperations];
  
  [[self operationQueue] setSuspended:NO];
  [[self cachePopulationQueue] setSuspended:NO];
}

- (void)clearCaches
{
  [[self operationQueue] setSuspended:YES];
  [[self cachePopulationQueue] setSuspended:YES];
  
  [[self operationQueue] cancelAllOperations];
  [[self cachePopulationQueue] cancelAllOperations];
  
  NSManagedObjectContext *moc = [self managedObjectContext];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  [request setEntity:[NSEntityDescription entityForName:@"ImageCache" inManagedObjectContext:moc]];
  
  NSError *error = nil;
  NSArray *imageCacheArray = [moc executeFetchRequest:request error:&error];
  MCRelease(request);
  ZAssert(!error || imageCacheArray, @"Error fetching cache: %@", error);
  
  for (TEDImageCacheMO *imageCacheObject in imageCacheArray) {
    [moc deleteObject:imageCacheObject];
  }
  
  [[self imageReferenceCache] removeAllObjects];
  [[self imageCache] removeAllObjects];
  
  NSFileManager *fileManager = [NSFileManager defaultManager];
  error = nil;
  [fileManager removeItemAtPath:[self cachePath] error:&error];
  ZAssert(!error, @"error removing image cache directory: %@", error);
  
  [[self operationQueue] setSuspended:NO];
  [[self cachePopulationQueue] setSuspended:NO];
}

- (void)calculateBandwidthForDelegate:(ZSURLConnectionDelegate*)delegate
{
  if ([[delegate data] length] < kGoodSampleThreshold) return;
  CGFloat sample = ([[delegate data] length] / [delegate duration]);
  totalDownload += [[delegate data] length];
  ++numberOfItemsDownloaded;
  
  if (sample >= kYellowHighThreshold) {
    currentNetworkState = ++currentNetworkState < kNetworkOptimal ? currentNetworkState : kNetworkOptimal;
  } else if (sample <= kYellowLowThreshold) {
    currentNetworkState = --currentNetworkState > kNetworkPoor ? currentNetworkState : kNetworkPoor;
  } else if (currentNetworkState > kNetworkAverage) {
    --currentNetworkState;
  } else if (currentNetworkState > kNetworkPoor) {
    ++currentNetworkState;
  }
  if (CACHE_TEST) {
    NSString *averageString = nil;
    NSString *sampleString = nil;
    CGFloat average = (totalDownload / numberOfItemsDownloaded);
    CGFloat kbps = average / 1024;
    if (kbps > 1024) {
      averageString = [NSString stringWithFormat:@"%.2f MBps", (kbps / 1024)];
    } else {
      averageString = [NSString stringWithFormat:@"%.2f KBps", kbps];
    }
    if (sample < 1024) {
      sampleString = [NSString stringWithFormat:@"%.2f Bps", sample];
    } else if (sample < (1024 * 1024)) {
      sampleString = [NSString stringWithFormat:@"%.2f KBps", (sample / 1024)];
    } else {
      sampleString = [NSString stringWithFormat:@"%.2f MBps", (sample / 1024 / 1024)];
    }
    
    switch (currentNetworkState) {
      case kNetworkOptimal:
        DLog(@"Optimal Network at %i AVG: %@ CUR: %@", currentNetworkState, averageString, sampleString);
        break;
      case kNetworkPoor:
        DLog(@"Poor Network at %i AVG: %@ CUR: %@", currentNetworkState, averageString, sampleString);
        break;
      default:
        DLog(@"Average Network at %i AVG: %@ CUR: %@", currentNetworkState, averageString, sampleString);
        break;
    }
  }
}

- (void)postCacheStatusNotification
{
  NSInteger opCount = [[self cachePopulationQueue] operationCount];

  NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
  [userInfo setValue:[NSNumber numberWithInteger:opCount] forKey:kRemainingCacheItems];
  [userInfo setValue:[NSNumber numberWithInteger:[self numberOfItemsAddedToCacheQueue]] forKey:kTotalRequestedCacheItems];
  
  switch ([self currentNetworkState]) {
    case kNetworkOptimal:
      [userInfo setValue:[NSNumber numberWithInteger:kNetworkOptimal] forKey:kCurrentNetworkState];
      break;
    case kNetworkPoor:
      [userInfo setValue:[NSNumber numberWithInteger:kNetworkPoor] forKey:kCurrentNetworkState];
      break;
    default:
      [userInfo setValue:[NSNumber numberWithInteger:kNetworkAverage] forKey:kCurrentNetworkState];
      break;
  }
  CGFloat overallAverageSpeed = ([self totalDownload] / [self numberOfItemsDownloaded]);
  [userInfo setValue:[NSNumber numberWithFloat:overallAverageSpeed] forKey:kLastSampledDownloadSpeed];
  
  [[NSNotificationCenter defaultCenter] postNotificationName:kCurrentCacheState object:self userInfo:userInfo];
  
  MCRelease(userInfo);
}

- (void)cacheOperationCompleted:(ZSURLConnectionDelegate*)delegate
{
  NSInteger opCount = [[self cachePopulationQueue] operationCount];
  NSError *error = nil;
  
  [self calculateBandwidthForDelegate:delegate];
  
  if (opCount % 50 == 0) {
    if (CACHE_TEST) DLog(@"saving.......................................");
    ZAssert([[self managedObjectContext] save:&error], @"Failed to save: %@\n%@", [error localizedDescription], [error userInfo]);
  }
  
  if (opCount % 10 == 0) {
    [self postCacheStatusNotification];
  }
  
  if (opCount > 1) return;
  
  if (VERBOSE) DLog(@"<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<cache completed>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>");
  ZAssert([[self managedObjectContext] save:&error], @"Failed to save: %@\n%@", [error localizedDescription], [error userInfo]);
  
  NSString *filePath = [self persistentCacheListFilePath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  
  ZAssert([fileManager removeItemAtPath:filePath error:&error], @"Failed to delete file: %@\n%@", [error localizedDescription], [error userInfo]);
  
  [[UIApplication sharedApplication] endBackgroundTask:[self cachePopulationIdentifier]];
  [self postCacheStatusNotification];
}

- (void)cacheOperationFailed:(ZSURLConnectionDelegate*)delegate
{
  if (VERBOSE) DLog(@"%@:%s request failed", [self class], _cmd);
}

- (void)downloadImage:(NSURL*)url unique:(NSManagedObject*)object
{
  if (![Reachability isReachable]) {
    if (CACHE_TEST) DLog(@"connection is offline, refusing to download image");
    return;
  } else {
    [[self cachePopulationQueue] setSuspended:NO];
    if (CACHE_TEST) DLog(@"activating cache");
  }
  
  //Check the request queue
  [[[self operationQueue] operations] enumerateObjectsUsingBlock:^(id operation, NSUInteger index, BOOL *stop) {
    if ([[operation myURL] isEqual:url]) return;
  }];
  
  //If it is currently in the cache queue, promote it
  for (ZSURLConnectionDelegate *operation in [[self cachePopulationQueue] operations]) {
    if (![[operation myURL] isEqual:url]) continue;
    [operation setMyURL:url]; //MSZ: Force it to be the same pointer
    [operation setQueuePriority:NSOperationQueuePriorityHigh];
    [operation setSuccessSelector:@selector(dataReceived:)];
    [operation setFailureSelector:@selector(requestFailedForDelegate:)];
    return;
  }
  
  ZSURLConnectionDelegate *delegate = [[ZSURLConnectionDelegate alloc] initWithURL:url delegate:self];
  [delegate setFilePath:[object valueForKey:@"imagePath"]];
  [delegate setSuccessSelector:@selector(dataReceived:)];
  [delegate setFailureSelector:@selector(requestFailedForDelegate:)];
  [delegate setObject:object];
  [delegate setQueuePriority:NSOperationQueuePriorityNormal];
  [delegate setThreadPriority:0.0f];
  
  [[self operationQueue] addOperation:delegate];
  
  MCRelease(delegate);
}

- (UIImage*)imageForURL:(NSURL*)url
{
  ZAssert(url, @"nil URL passed again");
  
  NSURL *localURL = [self localURLForAssetURL:url];
  if (!localURL) return nil;
  
  if (!imageCache) {
    imageCache = [[NSCache alloc] init];
  }
  NSString *URLString = [localURL absoluteString];
  
  UIImage *image = [imageCache objectForKey:URLString];
  
  if (!image) {
    if (CACHE_TEST) DLog(@"retrieving from disk %@", URLString);
    NSData *mappedFile = [NSData dataWithContentsOfMappedFile:[localURL path]];
    image = [UIImage imageWithData:mappedFile];
    if (image) {
      [imageCache setObject:image forKey:URLString];      
    }
  } else {
    if (CACHE_TEST) DLog(@"Retrieved from memory: %@", URLString);
  }
  
  return image;
}

- (NSURL*)localURLForAssetURL:(NSURL*)url
{
  ZAssert(url, @"nil URL passed again");
  
  TEDImageCacheMO *imageCacheObject = [self imageCacheObjectForURLString:[url absoluteString]];
  NSString *path = [imageCacheObject valueForKey:@"imagePath"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    if (CACHE_TEST) DLog(@" ******************** HIT cache file %@", [url absoluteString]);
    [imageCacheObject setLastAccessed:[NSDate date]];
    return [NSURL fileURLWithPath:path];
  }
  
#ifdef DEBUG
  if (CACHE_TEST) DLog(@"missed cache file %@\n%@", [url absoluteString], path);
#endif
  
  [self downloadImage:url unique:imageCacheObject];
  
  return nil;
}

- (void)dataReceived:(ZSURLConnectionDelegate*)delegate
{
  if (![[delegate data] length]) {
    if (VERBOSE) DLog(@"%s zero-length image received; ignoring", __PRETTY_FUNCTION__);
    return;
  }
  
  [self calculateBandwidthForDelegate:delegate];
  
  if (VERBOSE) DLog(@"image received %@", [delegate myURL]);
  
  NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
  [userInfo setObject:self forKey:kAssetManager];
  NSNotification *notification = [NSNotification notificationWithName:kImageDownloadComplete object:[delegate myURL] userInfo:userInfo];
  [[NSNotificationCenter defaultCenter] postNotification:notification];
}

- (void)requestFailedForDelegate:(ZSURLConnectionDelegate*)delegate
{
  if (VERBOSE) DLog(@"%@:%s request failed", [self class], _cmd);
  if (!delegate) return;
}

@end
