#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "LGButtonOpticsShaderSource.h"
#import "LGCAClosedProfileShaderSource.h"
#include <cstring>
int main(int argc,const char *argv[]) {
 @autoreleasepool {
  if(argc!=3)return 2;
  NSString *path=[NSString stringWithUTF8String:argv[1]];
  NSString *body=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"kShaderSrc\\s*=\\s*R\"MSL\\((.*?)\\)MSL\";" options:NSRegularExpressionDotMatchesLineSeparators error:nil];
  NSArray<NSTextCheckingResult *> *matches=[re matchesInString:body options:0 range:NSMakeRange(0,body.length)];
  if(matches.count!=1)return 1;
  NSString *raw=[body substringWithRange:[matches[0] rangeAtIndex:1]];
  NSString *formula=[NSString stringWithUTF8String:kLGButtonOpticsFormulaMSL];
  NSString *actual=[@"#define LG_BUTTON_OPTICS_COMPILED 1\n" stringByAppendingString:
   [raw stringByReplacingOccurrencesOfString:@"//__LG_BUTTON_OPTICS_FORMULA__" withString:formula]];
  NSData *data=[actual dataUsingEncoding:NSUTF8StringEncoding];
  BOOL equal=data.length==strlen(kLGCAClosedBaselineMSL) && memcmp(data.bytes,kLGCAClosedBaselineMSL,data.length)==0;
  BOOL prefix=strlen(kLGCAClosedProfileMSL)>data.length && memcmp(data.bytes,kLGCAClosedProfileMSL,data.length)==0;
  NSString *out=[NSString stringWithUTF8String:argv[2]];
  BOOL saved=[data writeToFile:out options:NSDataWritingAtomic error:nil];
  printf("%s actual original C-preprocessor DSL stringify + original runtime source construction exact bytes=%lu / new profile exact-prefix=%d\n",equal&&prefix&&saved?"PASS":"FAIL",(unsigned long)data.length,prefix);
  return equal&&prefix&&saved?0:1;
 }
}
