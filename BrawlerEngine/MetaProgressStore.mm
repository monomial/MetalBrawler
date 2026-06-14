#import "MetaProgressStore.h"

NSString * const BrawlerMetaProgressDefaultsKey = @"brawler.meta.v1";

static const int kMetaProgressVersion = 1;

@implementation MetaProgressStore {
    NSUserDefaults *_defaults;
    NSMutableDictionary *_memorySnapshot;
}

+ (instancetype)defaultsStore {
    MetaProgressStore *store = [[MetaProgressStore alloc] initWithUserDefaults:NSUserDefaults.standardUserDefaults];
    [store load];
    return store;
}

+ (instancetype)inMemoryStore {
    MetaProgressStore *store = [[MetaProgressStore alloc] initWithUserDefaults:nil];
    [store load];
    return store;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    _defaults = defaults;
    _memorySnapshot = [NSMutableDictionary dictionary];
    _version = kMetaProgressVersion;
    return self;
}

- (NSDictionary *)_snapshot {
    if (_defaults) {
        NSDictionary *dict = [_defaults dictionaryForKey:BrawlerMetaProgressDefaultsKey];
        return [dict isKindOfClass:NSDictionary.class] ? dict : @{};
    }
    return _memorySnapshot ?: @{};
}

- (void)load {
    NSDictionary *dict = [self _snapshot];
    _version = [dict[@"version"] intValue];
    if (_version <= 0) _version = kMetaProgressVersion;
    _coins = MAX(0, [dict[@"coins"] intValue]);
    _hpLevel = MAX(0, MIN(4, [dict[@"hpLevel"] intValue]));
    _livesLevel = MAX(0, MIN(2, [dict[@"livesLevel"] intValue]));
    _scrapLevel = MAX(0, MIN(3, [dict[@"scrapLevel"] intValue]));
    _secondWindLevel = MAX(0, MIN(1, [dict[@"secondWindLevel"] intValue]));
}

- (void)save {
    NSDictionary *dict = @{
        @"version": @(kMetaProgressVersion),
        @"coins": @(MAX(0, _coins)),
        @"hpLevel": @(MAX(0, MIN(4, _hpLevel))),
        @"livesLevel": @(MAX(0, MIN(2, _livesLevel))),
        @"scrapLevel": @(MAX(0, MIN(3, _scrapLevel))),
        @"secondWindLevel": @(MAX(0, MIN(1, _secondWindLevel))),
    };
    if (_defaults) {
        [_defaults setObject:dict forKey:BrawlerMetaProgressDefaultsKey];
        [_defaults synchronize];
    } else {
        _memorySnapshot = [dict mutableCopy];
    }
    [self load];
}

@end
