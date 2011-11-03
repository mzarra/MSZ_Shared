//
//  CGFUsernameViewController.m
//  FJImporter
//
//  Created by Marcus Zarra on 11/3/11.
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

#import "CGFUsernameViewController.h"
#import "CGFURLDelegateOperation.h"
#import "CGFTimelineViewController.h"

#define urlBase @"https://api.twitter.com/1/statuses/user_timeline.json?screen_name=%@"

@interface CGFUsernameViewController()

@property (nonatomic, retain) NSOperationQueue *queue;

@end

@implementation CGFUsernameViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  [self setTitle:@"Enter Username"];
  
  if (![self queue]) {
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [self setQueue:queue];
    MCRelease(queue);
  }
}

- (IBAction)loadTimeline:(id)sender
{
  NSString *username = [[self usernameTextField] text];
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:urlBase, username]];
  
  CGFURLDelegateOperation *op = [[CGFURLDelegateOperation alloc] initWithRequestURL:url andContext:[self managedObjectContext]];
  [[self queue] addOperation:op];
  MCRelease(op);
  
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"User"];
  [request setPredicate:[NSPredicate predicateWithFormat:@"name == %@", username]];
  
  NSError *error = nil;
  NSManagedObject *user = [[[self managedObjectContext] executeFetchRequest:request error:&error] lastObject];
  ZAssert(!error || user, @"Error fetching user: %@", error);
  
  if (!user) {
    user = [NSEntityDescription insertNewObjectForEntityForName:@"User" inManagedObjectContext:[self managedObjectContext]];
    [user setValue:username forKey:@"name"];
  }
  
  CGFTimelineViewController *controller = [[CGFTimelineViewController alloc] initWithStyle:UITableViewStylePlain];
  [controller setUser:user];
  [controller setManagedObjectContext:[self managedObjectContext]];
  [[self navigationController] pushViewController:controller animated:YES];
  MCRelease(controller);
}

@synthesize queue;
@synthesize usernameTextField;
@synthesize managedObjectContext;

@end
