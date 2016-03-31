//
//  MSZContextWatcher.swift
//
//  Copyright 2016 Marcus S. Zarra All rights reserved.
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

import Foundation
import CoreData

protocol MSZContextWatcherDelegate {

  func contextUpdated(impact: [String:[NSManagedObject]])

}

class MSZContextWatcher: NSObject {
  let persistentStoreCoordinator: NSPersistentStoreCoordinator
  var delegate: MSZContextWatcherDelegate?
  var masterPredicate: NSPredicate?

  init(context: NSManagedObjectContext) {
    guard let psc = context.persistentStoreCoordinator else {
      fatalError("No PSC in context")
    }
    persistentStoreCoordinator = psc

    super.init()
    
    let center = NSNotificationCenter.defaultCenter()
    center.addObserver(self, selector: "contextUpdated:",
      name: NSManagedObjectContextDidSaveNotification, object: nil)
  }

  deinit {
    let center = NSNotificationCenter.defaultCenter()
    center.removeObserver(self)
    delegate = nil
  }

  func addEntityToWatch(desc: NSEntityDescription, predicate: NSPredicate) {
    guard let name = desc.name else { fatalError("bad desc") }
    let entityPredicate = NSPredicate(format: "entity.name == %@", name)

    var array = [entityPredicate, predicate]
    let final = NSCompoundPredicate(andPredicateWithSubpredicates: array)

    if masterPredicate == nil {
      masterPredicate = final
      return
    }

    array = [masterPredicate!, final]

    masterPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: array)
  }

  func contextUpdated(notification: NSNotification) {
    guard let predicate = masterPredicate else {
      fatalError("Master Predicate is not set")
    }
    guard let iContext = notification.object as? NSManagedObjectContext else {
      fatalError("Unexpected object in notification")
    }
    guard let iCoordinator = iContext.persistentStoreCoordinator else {
      fatalError("Incoming context has no PSC")
    }
    if iCoordinator != persistentStoreCoordinator { return }

    let info = notification.userInfo

    var results = [String:[NSManagedObject]]()
    var totalCount = 0
    
    if let insert = info?[NSInsertedObjectsKey] as? Set<NSManagedObject> {
      let filter = insert.filter{ return predicate.evaluateWithObject($0) }
      totalCount += filter.count
      results[NSInsertedObjectsKey] = filter
    }

    if let update = info?[NSUpdatedObjectsKey] as? Set<NSManagedObject> {
      let filter = update.filter{ return predicate.evaluateWithObject($0) }
      totalCount += filter.count
      results[NSUpdatedObjectsKey] = filter
    }

    if let delete = info?[NSDeletedObjectsKey] as? Set<NSManagedObject> {
      let filter = delete.filter{ return predicate.evaluateWithObject($0) }
      totalCount += filter.count
      results[NSDeletedObjectsKey] = filter
    }

    if totalCount == 0 { return }

    delegate?.contextUpdated(results)
  }
}