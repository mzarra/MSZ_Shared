//
//  UIImage+ZSAssetManagerAdditions.h
//  iPad12
//
//  Created by Patrick Hughes on 8/8/12.
//  Copyright (c) 2012 Empirical Development LLC. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIImageView (ZSAssetManagerAdditions)

- (void)setImageWithURL:(NSURL *)url;
- (void)setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)placeholderImage;

@end
