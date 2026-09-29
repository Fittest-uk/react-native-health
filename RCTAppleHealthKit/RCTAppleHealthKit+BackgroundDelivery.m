//
//  RCTAppleHealthKit+BackgroundDelivery.m
//
//  HealthKit background delivery that reaches JS on the New Architecture.
//
//  The original path (initializeBackgroundObservers:, called from AppDelegate
//  with an RCTBridge) cannot work bridgeless: there is no bridge to hand it,
//  and its events go out through a hand-built RCTCallableJSModules bound to
//  that missing bridge. It also calls the observer's completion handler the
//  moment it emits, so iOS may suspend the app before JS has synced anything,
//  and it maps SleepAnalysis onto the workout type.
//
//  Here JS registers the observers itself (JS boots on a HealthKit background
//  launch well inside the ~30s window) and events go out through this module's
//  own emitter. Each wake hands JS an id; the completion handler is held until
//  JS calls completeBackgroundDelivery(id) after its upload, with a timeout so
//  HealthKit never sees a wake left open.
//

#import "RCTAppleHealthKit+BackgroundDelivery.h"

static const NSTimeInterval kDeliveryTimeoutSeconds = 25.0;

@implementation RCTAppleHealthKit (BackgroundDelivery)

+ (NSMutableDictionary<NSString *, HKObserverQueryCompletionHandler> *)bg_pendingCompletions {
    static NSMutableDictionary *pending = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ pending = [NSMutableDictionary new]; });
    return pending;
}

+ (NSMutableSet<NSString *> *)bg_registeredTypes {
    static NSMutableSet *registered = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ registered = [NSMutableSet new]; });
    return registered;
}

+ (nullable HKSampleType *)bg_sampleTypeFromName:(NSString *)name {
    if ([name isEqualToString:@"Workout"]) return [HKObjectType workoutType];
    if ([name isEqualToString:@"SleepAnalysis"]) return [HKObjectType categoryTypeForIdentifier:HKCategoryTypeIdentifierSleepAnalysis];
    if ([name isEqualToString:@"HeartRateVariabilitySDNN"]) return [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierHeartRateVariabilitySDNN];
    if ([name isEqualToString:@"RestingHeartRate"]) return [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierRestingHeartRate];
    if ([name isEqualToString:@"RespiratoryRate"]) return [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierRespiratoryRate];
    if ([name isEqualToString:@"Vo2Max"]) return [HKObjectType quantityTypeForIdentifier:HKQuantityTypeIdentifierVO2Max];
    return nil;
}

- (void)bg_completeDelivery:(NSString *)deliveryId {
    HKObserverQueryCompletionHandler handler = nil;
    NSMutableDictionary *pending = [RCTAppleHealthKit bg_pendingCompletions];
    @synchronized (pending) {
        handler = pending[deliveryId];
        [pending removeObjectForKey:deliveryId];
    }
    if (handler) handler();
}

- (void)bg_registerDelivery:(NSArray<NSString *> *)types callback:(RCTResponseSenderBlock)callback {
    if (![HKHealthStore isHealthDataAvailable]) {
        callback(@[RCTMakeError(@"HealthKit data is not available", nil, nil)]);
        return;
    }
    NSMutableArray<NSString *> *registeredNow = [NSMutableArray new];
    NSMutableSet *registered = [RCTAppleHealthKit bg_registeredTypes];

    for (NSString *name in types) {
        HKSampleType *sampleType = [RCTAppleHealthKit bg_sampleTypeFromName:name];
        if (!sampleType) continue;
        // One observer per type per process: JS may call this on every boot
        // and every foreground, but duplicate observers would each wake JS.
        @synchronized (registered) {
            if ([registered containsObject:name]) continue;
            [registered addObject:name];
        }

        NSString *newEvent = [NSString stringWithFormat:@"healthKit:%@:new", name];
        NSString *failureEvent = [NSString stringWithFormat:@"healthKit:%@:failure", name];
        __weak RCTAppleHealthKit *weakSelf = self;

        HKObserverQuery *query = [[HKObserverQuery alloc] initWithSampleType:sampleType
                                                                   predicate:nil
                                                               updateHandler:^(HKObserverQuery *q, HKObserverQueryCompletionHandler completionHandler, NSError *error) {
            RCTAppleHealthKit *strongSelf = weakSelf;
            if (error || !strongSelf || !strongSelf.hasListeners) {
                NSLog(@"[HealthKitBg] %@ wake not delivered (error=%@, listeners=%d)", name, error.localizedDescription, strongSelf.hasListeners);
                if (error && strongSelf.hasListeners) {
                    [strongSelf sendEventWithName:failureEvent body:@{@"error": error.localizedDescription ?: @""}];
                }
                completionHandler();
                return;
            }
            NSString *deliveryId = [[NSUUID UUID] UUIDString];
            NSMutableDictionary *pending = [RCTAppleHealthKit bg_pendingCompletions];
            @synchronized (pending) { pending[deliveryId] = [completionHandler copy]; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeliveryTimeoutSeconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf bg_completeDelivery:deliveryId];
            });
            NSLog(@"[HealthKitBg] %@ wake -> JS (%@)", name, deliveryId);
            [strongSelf sendEventWithName:newEvent body:@{@"id": deliveryId, @"type": name}];
        }];
        [self.healthStore executeQuery:query];

        [self.healthStore enableBackgroundDeliveryForType:sampleType
                                                frequency:HKUpdateFrequencyImmediate
                                           withCompletion:^(BOOL success, NSError *error) {
            NSLog(@"[HealthKitBg] enableBackgroundDelivery %@ success=%d error=%@", name, success, error.localizedDescription);
        }];
        [registeredNow addObject:name];
    }
    callback(@[[NSNull null], registeredNow]);
}

@end
