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

#import "ZSImageCacheHandler.h"
#import "ZSURLConnectionDelegate.h"
#import "PGAImageCacheMO.h"

@interface ZSImageCacheHandler ()

- (NSString*)cachePath;

- (void)downloadImage:(NSURL*)url unique:(id)object;

@property (nonatomic, retain) NSMutableDictionary *currentRequests;
@property (nonatomic, retain) NSMutableDictionary *imageCache;
@property (nonatomic, retain) NSOperationQueue *operationQueue;
@property (nonatomic, retain) NSManagedObjectContext *managedObjectContext;

@end

@implementation ZSImageCacheHandler

- (id)initWithManagedObjectContext:(NSManagedObjectContext*)moc
{
  imageCache = [[NSMutableDictionary alloc] init];
  currentRequests = [[NSMutableDictionary alloc] init];
  operationQueue = [[NSOperationQueue alloc] init];
  [operationQueue setMaxConcurrentOperationCount:1];
  
  managedObjectContext = [moc retain];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];

  return self;
}

- (void)dealloc
{
  [currentRequests release], currentRequests = nil;
  [operationQueue release], operationQueue = nil;
  [imageCache release], imageCache = nil;
  [managedObjectContext release], managedObjectContext = nil;
  [super dealloc];
}

- (void)didReceiveMemoryWarning:(NSNotification*)notification
{
  DLog(@"memory warning received, current downloads %u", [[currentRequests allValues] count]);
  [[self imageCache] removeAllObjects];
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

- (void)downloadImage:(NSURL*)url unique:(PGAImageCacheMO*)object
{
  ZSURLConnectionDelegate *delegate = [[self currentRequests] objectForKey:[object objectID]];
  if (delegate) return;
  
  delegate = [[ZSURLConnectionDelegate alloc] initWithURL:url delegate:self];
  [delegate setSuccessSelector:@selector(dataReceived:)];
  [delegate setFailureSelector:@selector(requestFailedForDelegate:)];
  [delegate setObject:object];
  
  [[self operationQueue] addOperation:delegate];
  
  [[self currentRequests] setObject:delegate forKey:[object objectID]];
  [delegate release], delegate = nil;
}

- (UIImage*)imageForURL:(NSString*)url
{
  if (!url || ![url length]) return nil;
  
  NSManagedObjectContext *moc = [self managedObjectContext];
  
  NSFetchRequest *request = [[NSFetchRequest alloc] init];
  [request setEntity:[NSEntityDescription entityForName:@"ImageCache" inManagedObjectContext:moc]];
  [request setPredicate:[NSPredicate predicateWithFormat:@"sourceURL == %@", url]];
  
  NSError *error = nil;
  PGAImageCacheMO *imageCacheObject = [[moc executeFetchRequest:request error:&error] lastObject];
  [request release], request = nil;
  ZAssert(error == nil, @"Error fetching cache: %@", error);
  
  if (imageCacheObject) {
    NSString *path = [imageCacheObject imagePath];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image) {
      [imageCacheObject setLastAccessed:[NSDate date]];
      return image;
    }
  } else {
    imageCacheObject = [NSEntityDescription insertNewObjectForEntityForName:@"ImageCache" inManagedObjectContext:moc];
    [imageCacheObject setSourceURL:url];
    [imageCacheObject setLastAccessed:[NSDate date]];
  }
  
  NSURL *sourceURL = [NSURL URLWithString:url];
  ZAssert(sourceURL != nil, @"Failed to build sourceURL: %@", url);
  [self downloadImage:sourceURL unique:imageCacheObject];
  return nil;
}

- (NSString*)URLForPlayer:(NSString*)playerID withSize:(CGSize)size
{
  ZAssert(playerID, @"PlayerID is nil");
  
  NSString *sizeString = [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
  
  NSString *urlString = [[self headshotBaseURLString] stringByReplacingOccurrencesOfString:@"[res]" withString:sizeString];
  urlString = [urlString stringByReplacingOccurrencesOfString:@"[playerid]" withString:playerID];
  
  return urlString;
}

- (void)dataReceived:(ZSURLConnectionDelegate*)delegate
{
  if (![[delegate data] length]) {
    DLog(@"%s zero-length image received; ignoring", __PRETTY_FUNCTION__);
    return;
  }
  
  UIImage *image = [UIImage imageWithData:[delegate data]];
  NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
  [userInfo setObject:[delegate object] forKey:kImageItemDownloadedKey];
  if (!image) {
    DLog(@"%@:%s image retrieval failed", [self class], _cmd);
    return;
  }
  
  [userInfo setObject:image forKey:kImageItem];
  
  NSString *filePath = [[delegate object] imagePath];
  if (!filePath) {
    NSString *filename = [[NSProcessInfo processInfo] globallyUniqueString];
    filePath = [[self cachePath] stringByAppendingPathComponent:filename];
    [[delegate object] setImagePath:filePath];
  }
  
  [[self imageCache] setObject:image forKey:filePath];
  [[delegate data] writeToFile:filePath atomically:YES];
  
  NSNotification *notification = [NSNotification notificationWithName:kImageDownloadComplete object:self userInfo:userInfo];
  [[NSNotificationCenter defaultCenter] postNotification:notification];
  
  [[self currentRequests] removeObjectForKey:[[delegate object] objectID]];
}

- (void)requestFailedForDelegate:(ZSURLConnectionDelegate*)delegate
{
  DLog(@"%@:%s request failed", [self class], _cmd);
  if (!delegate) return;
  [[self currentRequests] removeObjectForKey:[[delegate object] objectID]];
}

@synthesize currentRequests;
@synthesize operationQueue;
@synthesize imageCache;
@synthesize managedObjectContext;
@synthesize headshotBaseURLString;

@end
