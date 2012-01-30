//
//  CGFTimelineViewController.h
//  FJImporter
//
//  Created by Marcus Zarra on 11/3/11.
//  Copyright (c) 2011 Cocoa Is My Girlfriend. All rights reserved.
//

@interface CGFTimelineViewController : UITableViewController

@property (nonatomic, retain) NSManagedObject *user;
@property (nonatomic, assign) NSManagedObjectContext *managedObjectContext;

@end
