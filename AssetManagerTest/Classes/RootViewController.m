//
//  RootViewController.m
//  AssetManagerTest
//
//  Created by Marcus S. Zarra on 3/17/11.
//  Copyright 2011 Zarra Studios LLC. All rights reserved.
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

#import "RootViewController.h"

@interface RootViewController()

@property (nonatomic, retain) NSArray *xmlItems;

@end

@implementation RootViewController

@synthesize xmlItems;
@synthesize assetManager;

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageDownloadComplete:) name:kImageDownloadComplete object:[self assetManager]];
}

- (void)populateWithXMLItems:(NSArray*)items
{
  [self setXmlItems:items];
  [[self tableView] reloadData];
}

- (void)imageDownloadComplete:(NSNotification *)notification
{
  [[self tableView] reloadData];
}

#pragma mark -
#pragma mark UITableViewDatasource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return [[self xmlItems] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
  if (cell == nil) {
    cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier] autorelease];
    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
  }
  
  GDataXMLElement *item = [[self xmlItems] objectAtIndex:[indexPath row]];
  GDataXMLElement *title = [[item elementsForName:@"title"] lastObject];
  if (!title) {
    [[cell textLabel] setText:@"Untitled"];
  } else {
    [[cell textLabel] setText:[title stringValue]];
  }
  
  GDataXMLElement *mediaThumbnail = [[item elementsForName:@"media:thumbnail"] lastObject];
  ZAssert(mediaThumbnail, @"Failed to find media thumbnail: %@", item);
  
  NSString *thumbnailURLString = [[mediaThumbnail attributeForName:@"url"] stringValue];
  NSURL *thumbnailURL = [NSURL URLWithString:thumbnailURLString];
  [[cell imageView] setImage:[assetManager imageForURL:thumbnailURL]];
  
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

#pragma mark -
#pragma mark Memory management
- (void)dealloc
{
  [xmlItems release];
  [assetManager release];
  [super dealloc];
}
@end