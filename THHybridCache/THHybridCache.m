//
//  THHybridCache.m
//  THHybridCache
//
//  Created by Thomas Heß on 20.9.12.
//  Copyright (c) 2012 Thomas Heß. All rights reserved.
//

#import "THHybridCache.h"

#if !__has_feature(objc_arc)
#error THHybridCache must be built with ARC.
// You can turn on ARC for only THHybridCache files by adding -fobjc-arc to the build phase for each of its files.
#endif

#if (defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && (! defined(__IPHONE_6_0) || __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_6_0))
#define TH_DEPLOYMENT_TARGET_PRE_IOS6(...) \
if ([[[UIDevice currentDevice] systemVersion] integerValue] >= 6) \
{ \
__VA_ARGS__ \
}
#else
#define TH_DEPLOYMENT_TARGET_PRE_IOS6(...)
#endif

#ifdef DEBUG
#   define THLog(fmt, ...) NSLog((@"%s " fmt), __PRETTY_FUNCTION__, ##__VA_ARGS__);
#else
#   define THLog(...)
#endif

#define THWeakObject(o) __weak __typeof__((__typeof__(o))o)
#define THWeakSelf THWeakObject(self)

@implementation THHybridCache
{
    NSCache* memoryCache;
	NSMutableDictionary* cacheDictionary;
    dispatch_queue_t cacheDictionaryAccessQueue;
    dispatch_queue_t diskWriteQueue;
}

@synthesize memoryCacheSize = _memoryCacheSize;
@synthesize timeout = _timeout;
@synthesize jpgQuality = _jpgQuality;

+ (THHybridCache*)sharedCache
{
    static THHybridCache* shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[THHybridCache alloc] init];
    });
    return shared;
}

#define DEFAULT_MEMORY_SIZE 100
#define DEFAULT_TIMEOUT 86400
#define DEFAULT_JPG_QUALITY 0.8

- (id)init
{
    self = [super init];
    if (self)
    {
        // set defaults
        _memoryCacheSize = DEFAULT_MEMORY_SIZE;
        _timeout = DEFAULT_TIMEOUT;
        _jpgQuality = DEFAULT_JPG_QUALITY;
        
        // init memory cache
        memoryCache = [[NSCache alloc] init];
        memoryCache.countLimit = _memoryCacheSize;
        // TODO: work with cost limit
        
        // init cache dictionary
        NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:[THHybridCache dictionaryCachePath]];
        if ([dict isKindOfClass:[NSDictionary class]])
			cacheDictionary = [dict mutableCopy];
        else
            cacheDictionary = [NSMutableDictionary dictionaryWithCapacity:100];
        
        // create queues
        cacheDictionaryAccessQueue = dispatch_queue_create("name.thomashess.THHybridCache.cacheDictionaryAccess",
                                                     DISPATCH_QUEUE_CONCURRENT);
        diskWriteQueue = dispatch_queue_create("name.thomashess.THHybridCache.diskWrites", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(diskWriteQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    }
    return self;
}

- (void)dealloc
{
    TH_DEPLOYMENT_TARGET_PRE_IOS6(
        dispatch_release(cacheDictionaryAccessQueue);
        dispatch_release(diskWriteQueue);
    )
}

#pragma mark - Properties

- (void)setMemoryCacheSize:(NSUInteger)memoryCacheSize
{
    if (self.memoryCacheSize == memoryCacheSize) return;
    _memoryCacheSize = memoryCacheSize;
    memoryCache.countLimit = _memoryCacheSize;
}

- (void)setJpgQuality:(CGFloat)jpgQuality
{
    jpgQuality = MAX(0, MIN(1, jpgQuality));
    if (self.jpgQuality == jpgQuality) return;
    _jpgQuality = jpgQuality;
}

#pragma mark - Paths

+ (NSString*)cachePath
{
    static NSString* THHybridCachePath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        THHybridCachePath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]
                                          stringByAppendingPathComponent:@"THHybridCache"];
        NSError* error = nil;
        if (! [[NSFileManager defaultManager] createDirectoryAtPath:THHybridCachePath
                                        withIntermediateDirectories:YES attributes:nil error:&error])
            THLog(@"Failed to create directory %@: %@", THHybridCachePath, error.localizedDescription);
    });
	return THHybridCachePath;
}

+ (NSString*)cachePathForKey:(NSString*)key
{
    NSParameterAssert(key);
    return [[THHybridCache cachePath] stringByAppendingPathComponent:key];
}

+ (NSString*)dictionaryCachePath
{
    static NSString* THHybridCacheDictPath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        THHybridCacheDictPath = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject]
                                              stringByAppendingPathComponent:@"THHybridCache.plist"];
    });
	return THHybridCacheDictPath;
}

#pragma mark - Public Methods

- (BOOL)hasCacheForKey:(NSString*)key onlyInMemory:(BOOL)onlyInMemory
{
    NSParameterAssert(key);
    
    __block BOOL hasCache = NO;
    dispatch_sync(cacheDictionaryAccessQueue, ^{
        hasCache = ([cacheDictionary objectForKey:key] != nil);
    });
    
    if (! hasCache) return NO;
    
    if (onlyInMemory)
    {
        hasCache = ([memoryCache objectForKey:key] != nil);
        
        if (! hasCache
            && ! [[NSFileManager defaultManager] fileExistsAtPath:[THHybridCache cachePathForKey:key]])
        {
            dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
                [cacheDictionary removeObjectForKey:key];
                [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil waitUntilDone:NO];
            });
        }
        
        return hasCache;
    }
    
    hasCache = [[NSFileManager defaultManager] fileExistsAtPath:[THHybridCache cachePathForKey:key]];
    
    if (! hasCache)
        dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
            [cacheDictionary removeObjectForKey:key];
            [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil waitUntilDone:NO];
        });
    
    return hasCache;
}

- (UIImage*)imageForKey:(NSString*)key onlyFromMemory:(BOOL)onlyFromMemory;
{
    NSParameterAssert(key);
    
    @autoreleasepool
    {
        UIImage* img = [memoryCache objectForKey:key];
        
        if (! img && ! onlyFromMemory)
            img = [UIImage imageWithContentsOfFile:[THHybridCache cachePathForKey:key]];
        
        if (img) {
            [self setTimeoutIntervalForKey:key];
            [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil waitUntilDone:NO];
        }
        
        return img;
    }
}

- (void)cacheImage:(UIImage*)img forKey:(NSString*)key inMemory:(BOOL)inMemory
            onDisk:(BOOL)onDisk hasTransparency:(BOOL)hasTransparency
{
    NSParameterAssert(img && key);

    if ([self hasCacheForKey:key onlyInMemory:inMemory])
    {
        [self setTimeoutIntervalForKey:key];
        [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil waitUntilDone:NO];
        return;
    }
    
    if (inMemory)
    {
        [memoryCache setObject:img forKey:key];
        [self setTimeoutIntervalForKey:key];
        [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil waitUntilDone:NO];
    }
    
    if (! onDisk) return;
    
    THWeakSelf wself = self;
    dispatch_async(diskWriteQueue, ^{
        
        __block BOOL success = NO;
        void (^saveToDisk)() =
        [^{
            @autoreleasepool {
                success = (hasTransparency ?
                           [UIImagePNGRepresentation(img) writeToFile:[THHybridCache cachePathForKey:key]
                                                           atomically:YES] :
                           [UIImageJPEGRepresentation(img, self.jpgQuality) writeToFile:[THHybridCache cachePathForKey:key]
                                                                             atomically:YES]);
            }
        } copy];
        
        saveToDisk();
        
        if (success) {
            if (! inMemory) {
                [wself setTimeoutIntervalForKey:key];
                [wself performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil
                                     waitUntilDone:NO];
            }
            return;
        }
        
        // maybe out of disk space? try cleaning first
        [wself cleanCacheCompletion:^{
            
            saveToDisk();
            
            if (! success) {
                THLog(@"Failed to save %@ to %@", img, [THHybridCache cachePathForKey:key]);
                if (! inMemory)
                    dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
                        [cacheDictionary removeObjectForKey:key];
                        [self performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil
                                            waitUntilDone:NO];
                    });
                return;
            }
            
            if (! inMemory) {
                [wself setTimeoutIntervalForKey:key];
                [wself performSelectorOnMainThread:@selector(cacheDictionaryChanged) withObject:nil
                                     waitUntilDone:NO];
            }
        }];
    });
}

- (void)removeCacheForKey:(NSString*)key
{
    NSParameterAssert(key);
    
    if (! [self hasCacheForKey:key onlyInMemory:NO]) return;

    THWeakSelf wself = self;
    dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
        
        [cacheDictionary removeObjectForKey:key];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [wself cacheDictionaryChanged];
            [memoryCache removeObjectForKey:key];
            [wself removeFileForKey:key completion:NULL];
        });
    });
}

- (void)cleanCache
{
    [self cleanCacheCompletion:NULL];
}

- (void)cleanCacheCompletion:(void(^)())completionBlock
{
    NSMutableArray *removeList = [NSMutableArray array];
    
    dispatch_sync(cacheDictionaryAccessQueue, ^{
        [cacheDictionary enumerateKeysAndObjectsUsingBlock:^(id key, NSDate* date, BOOL *stop) {
            if ([[[NSDate date] earlierDate:date] isEqualToDate:date])
                [removeList addObject:key];
        }];
    });
    
    if ([removeList count] == 0) {
        if (completionBlock) completionBlock();
        return;
    }
    
    THWeakSelf wself = self;
    dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
        
        [cacheDictionary removeObjectsForKeys:removeList];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [wself cacheDictionaryChanged];
            [removeList enumerateObjectsWithOptions:NSEnumerationConcurrent
                                         usingBlock:^(NSString* key, NSUInteger idx, BOOL *stop)
             {
                 [memoryCache removeObjectForKey:key];
                 [wself removeFileForKey:key completion:(completionBlock && key == [removeList lastObject] ?
                                                         completionBlock : NULL)];
             }];
        });
    });
}

- (void)clearCache
{
    __block NSArray* allKeys = nil;
    dispatch_sync(cacheDictionaryAccessQueue, ^{
        allKeys = [cacheDictionary allKeys];
    });
    [allKeys enumerateObjectsWithOptions:NSEnumerationConcurrent
                              usingBlock:^(NSString* key, NSUInteger idx, BOOL *stop) {
                                  [self removeCacheForKey:key];
                              }];
}

#pragma mark - Cache Dictionary Saving

#define DICTIONARY_SAVE_DELAY 0.3

- (void)cacheDictionaryChanged
{
    // coalesce save requests
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCacheDictionary)
                                               object:nil];
	[self performSelector:@selector(saveCacheDictionary) withObject:nil afterDelay:DICTIONARY_SAVE_DELAY];
}

- (void)saveCacheDictionary
{
    TH_DEPLOYMENT_TARGET_PRE_IOS6(
        dispatch_retain(cacheDictionaryAccessQueue);
    )
    dispatch_async(diskWriteQueue, ^{
        dispatch_sync(cacheDictionaryAccessQueue, ^{
            @autoreleasepool {
                if (! [cacheDictionary writeToFile:[THHybridCache dictionaryCachePath]
                                        atomically:YES])
                    THLog(@"Failed to save cache dictionary");
            }
        });
        TH_DEPLOYMENT_TARGET_PRE_IOS6(
            dispatch_release(cacheDictionaryAccessQueue);
        )
    });
}

#pragma mark - Util

- (void)setTimeoutIntervalForKey:(NSString*)key
{
    NSParameterAssert(key);
    dispatch_barrier_async(cacheDictionaryAccessQueue, ^{
        cacheDictionary[key] = [NSDate dateWithTimeIntervalSinceNow:self.timeout];
    });
}

- (void)removeFileForKey:(NSString*)key completion:(void(^)())completionBlock
{
    NSParameterAssert(key);
    dispatch_async(diskWriteQueue, ^{
        
        [[NSFileManager defaultManager] removeItemAtPath:[THHybridCache cachePathForKey:key] error:nil];
        
        if (completionBlock) completionBlock();
    });
}

@end
