//
//  RCTAppleHealthKit+BackgroundDelivery.h
//  HealthKit background delivery registered from JS (works bridgeless).
//

#import "RCTAppleHealthKit.h"

@interface RCTAppleHealthKit (BackgroundDelivery)

- (void)bg_registerDelivery:(NSArray<NSString *> *)types callback:(RCTResponseSenderBlock)callback;
- (void)bg_completeDelivery:(NSString *)deliveryId;

@end
