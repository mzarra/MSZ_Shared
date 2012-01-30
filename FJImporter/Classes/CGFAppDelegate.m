
//
//  CGFAppDelegate.m
//  FJImporter
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

#import "CGFAppDelegate.h"

#import "CGFUsernameViewController.h"

@implementation CGFAppDelegate

@synthesize window;
@synthesize managedObjectContext;
@synthesize navController;

- (void)dealloc
{
  [window release];
  [managedObjectContext release];
  
  [super dealloc];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  [self setWindow:[[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease]];
  
  CGFUsernameViewController *controller = [[CGFUsernameViewController alloc] initWithNibName:@"CGFUsernameView" bundle:nil];
  [controller setManagedObjectContext:[self managedObjectContext]];
  
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
  [self setNavController:nav];
  MCRelease(controller);
  MCRelease(nav);
  
  [[self window] addSubview:[[self navController] view]];
  
  [[self window] makeKeyAndVisible];
  
  return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
  [self saveContext];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
  [self saveContext];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
  [self saveContext];
}

- (void)saveContext
{
  NSError *error = nil;
  
  if (![self managedObjectContext]) return;
  if (![[self managedObjectContext] hasChanges]) return;
  
  ZAssert([[self managedObjectContext] save:&error], @"Unresolved error %@, %@", error, [error userInfo]);
}

#pragma mark - Core Data stack

- (NSManagedObjectContext *)managedObjectContext
{
  if (managedObjectContext) return managedObjectContext;
  
  NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"FJImporter" withExtension:@"momd"];
  NSManagedObjectModel *mom = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
  
  NSURL *storeURL = [[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:@"FJImporter.sqlite"];
  
  NSError *error = nil;
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:mom];
  MCRelease(mom);
  
  ZAssert([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:nil error:&error], @"Unresolved error %@, %@", error, [error userInfo]);
  
  managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  [managedObjectContext setPersistentStoreCoordinator:psc];
  MCRelease(psc);
  
  return managedObjectContext;
}

@end
