//
//  UIImage+ZSAssetManagerAdditions.m
//  iPad12
//
//  Created by Patrick Hughes on 8/8/12.
//  Copyright (c) 2012 Empirical Development LLC. All rights reserved.
//

#import "UIImageView+ZSAssetManagerAdditions.h"
#import "ZSAssetManager.h"
#import <objc/runtime.h>
#import "ZSShared.h"

static char const * const assetManagerImageURLKey = "assetManagerImageURLKey";

@implementation UIImageView (ZSAssetManagerAdditions)

- (void)setImageWithURL:(NSURL *)url
{
  objc_setAssociatedObject(self, assetManagerImageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  self.image = nil;
  
  if (!url) {
    DLog(@"nil url passed");
    return;
  }
  
  __weak UIImageView *blockSelf = self;
  [[ZSAssetManager sharedAssetManager] fetchImageForURL:url withCompletionBlock:^(NSURL *fetchedUrl, UIImage *image) {

    NSURL *currentURL = (NSURL*) objc_getAssociatedObject(self, assetManagerImageURLKey);

    if ([currentURL isEqual:fetchedUrl]) {
      blockSelf.image = image;
    }
  }];
}

- (void)setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholderImage
{
  // Request the image from the asset manager.
  [self setImageWithURL:url];
  
  // If the asset manager has it, don't set the placeholder.
  if (!self.image) {
    self.image = placeholderImage;
  }
}

@end
