/*
 *
 * NSData SHA1 Extension (requires libopenssl / Security.framework)
 *
 * A few convienience methods that clean up strings for display.
 *
 * Created by Jordan Breeding
 * Copyright Zarra Studos LLC 2011. All rights reserved.
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

#import "NSData+ZSAdditions.h"
#import <CommonCrypto/CommonDigest.h>

@implementation NSData (ZSAdditions)

- (NSString*)zs_digest
{
  uint8_t digest[CC_SHA1_DIGEST_LENGTH];
  
  CC_SHA1([self bytes], [self length], digest);
  
  NSMutableString* outputHolder = [[NSMutableString alloc] initWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
  
  for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
    [outputHolder appendFormat:@"%02x", digest[i]];
  }
  
  NSString *output = [outputHolder copy];
  MCRelease(outputHolder);
  
  return [output autorelease];
}

@end

