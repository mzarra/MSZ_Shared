//
//  CGFTimelineViewController.m
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

#import "CGFTimelineViewController.h"

@interface CGFTimelineViewController() <NSFetchedResultsControllerDelegate>

@property (nonatomic, retain) NSFetchedResultsController *fetchController;

@end

@implementation CGFTimelineViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  [self setTitle:[[self user] valueForKey:@"name"]];
    
  if ([self fetchController]) return;
  
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Tweet"];
  [request setPredicate:[NSPredicate predicateWithFormat:@"ANY timeline == %@", [self user]]];
  
  NSSortDescriptor *sort = [[[NSSortDescriptor alloc] initWithKey:@"createdAt" ascending:NO] autorelease];
  [request setSortDescriptors:[NSArray arrayWithObject:sort]];
  
  NSFetchedResultsController *controller = [[NSFetchedResultsController alloc] initWithFetchRequest:request managedObjectContext:[self managedObjectContext] sectionNameKeyPath:nil cacheName:[[self user] valueForKey:@"name"]];
  [controller setDelegate:self];
  
  NSError *error = nil;
  ZAssert([controller performFetch:&error], @"Error fetching tweets: %@", error);
  
  [self setFetchController:controller];
  MCRelease(controller);
}

#pragma mark - Table view data source

- (void)configureCell:(id)cell atIndexPath:(NSIndexPath*)indexPath
{
  NSManagedObject *tweet = [[self fetchController] objectAtIndexPath:indexPath];
  
  [[cell textLabel] setText:[tweet valueForKey:@"text"]];
  [[cell detailTextLabel] setText:[tweet valueForKeyPath:@"author.name"]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return [[[[self fetchController] sections] objectAtIndex:section] numberOfObjects];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  id cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
  
  if (!cell) {
    cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier] autorelease];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
  }
  
  [self configureCell:cell atIndexPath:indexPath];
  
  return cell;
}

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller 
{
  [[self tableView] beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type newIndexPath:(NSIndexPath *)newIndexPath 
{
  switch(type) {
    case NSFetchedResultsChangeInsert:
      [[self tableView] insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
      break;
    case NSFetchedResultsChangeDelete:
      [[self tableView] deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
      break;
    case NSFetchedResultsChangeUpdate:
      [self configureCell:[[self tableView] cellForRowAtIndexPath:indexPath] atIndexPath:indexPath];
      break;
    case NSFetchedResultsChangeMove:
      [[self tableView] deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
      [[self tableView] insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
      break;
  }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller 
{
  [[self tableView] endUpdates];
}

@synthesize user;
@synthesize managedObjectContext;
@synthesize fetchController;

@end
