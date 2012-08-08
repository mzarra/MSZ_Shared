//
//  UIImage+ZSAssetManagerAdditions.m
//  iPad12
//
//  Created by Patrick Hughes on 8/8/12.
//  Copyright (c) 2012 Empirical Development LLC. All rights reserved.
//

#import "UIImageView+ZSAssetManagerAdditions.h"
#import "ZSAssetManager.h"

@implementation UIImageView (ZSAssetManagerAdditions)

- (void)setImageWithURL:(NSURL *)url
{
  [[ZSAssetManager sharedAssetManager] fetchImageForURL:url withCompletionBlock:^(NSURL *fetchedUrl, UIImage *image) {
    if ([url isEqual:fetchedUrl]) {
      self.image = image;
    }
  }];
}

- (void)setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholderImage
{
  self.image = placeholderImage;
  [self setImageWithURL:url];
}

@end
