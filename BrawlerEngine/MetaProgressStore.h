#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BrawlerMetaProgressDefaultsKey;

@interface MetaProgressStore : NSObject

@property (nonatomic) int version;
@property (nonatomic) int coins;
@property (nonatomic) int hpLevel;
@property (nonatomic) int livesLevel;
@property (nonatomic) int scrapLevel;
@property (nonatomic) int secondWindLevel;

+ (instancetype)defaultsStore;
+ (instancetype)inMemoryStore;
- (instancetype)initWithUserDefaults:(nullable NSUserDefaults *)defaults;

- (void)load;
- (void)save;

@end

NS_ASSUME_NONNULL_END
