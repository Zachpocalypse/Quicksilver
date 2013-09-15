//
// QSCatalogEntry.m
// Quicksilver
//
// Created by Alcor on 2/8/05.
// Copyright 2005 Blacktree. All rights reserved.
//

#import "QSCatalogEntry.h"
#import "QSRegistry.h"
#import "QSLibrarian.h"
#import "QSResourceManager.h"
#import "QSObjectSource.h"
#import "QSNotifications.h"
#import "QSApp.h"
#import "QSTaskController.h"
#import "QSObject_PropertyList.h"
#import "QSTask.h"
#import <QSFoundation/QSFoundation.h>

@interface NSObject (QSCatalogSourceInformal)
- (void)enableEntry:(QSCatalogEntry *)entry;
- (void)disableEntry:(QSCatalogEntry *)entry;
@end

#define kUseNSArchiveForIndexes NO;

@interface QSCatalogEntry () {
    NSString *_name;
    NSArray *_contents;
    QSObjectSource *_source;

	__block NSDate *indexDate;

	id parent;
	NSMutableArray *children;
    dispatch_queue_t scanQueue;
	NSMutableDictionary *info;
	NSBundle *bundle;
}

@property (getter=isScanning) BOOL scanning;
@property (retain) NSArray *contents;

@end

@implementation QSCatalogEntry

+ (BOOL)accessInstanceVariablesDirectly {return YES;}

+ (QSCatalogEntry *)entriesWithArray:(NSArray *)array { return nil; }

// KVO
+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key {
    NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey:key];

    if ([key isEqualToString:@"deepObjectCount"]) {
        NSSet *affectingKeys = [NSSet setWithObjects:@"contents", @"enabled",nil];
        keyPaths = [keyPaths setByAddingObjectsFromSet:affectingKeys];
    } else if ([key isEqualToString:@"currentEntry"]) {
        keyPaths = [keyPaths setByAddingObject:@"selection"];
    } else if ([key isEqualToString:@"self"] ) {
        keyPaths = [keyPaths setByAddingObject:@"count"];
    }
    return keyPaths;
}

+ (QSCatalogEntry *)entryWithDictionary:(NSDictionary *)dict {
	return [[QSCatalogEntry alloc] initWithDictionary:dict];
}

- (NSString *)description {
	return [NSString stringWithFormat:@"[%@] ", self.name];
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _name = nil;
    indexDate = nil;
    parent = nil;
    children = nil;
    _contents = nil;
    info = nil;

    return self;
}

- (QSCatalogEntry *)initWithDictionary:(NSDictionary *)dict {
    self = [self init];
	if (!self) return nil;

    info = [dict mutableCopy];

    NSArray *childDicts = [dict objectForKey:kItemChildren];
    if (childDicts) {
        NSMutableArray *newChildren = [NSMutableArray array];
        for(NSDictionary *child in childDicts) {
            [newChildren addObject:[QSCatalogEntry entryWithDictionary:child]];
        }
        children = newChildren;
    }
    // create a serial dispatch queue to make scan processes serial for each catalog entry
    scanQueue = dispatch_queue_create([[NSString stringWithFormat:@"QSCatalogEntry scanQueue: %@",[dict objectForKey:kItemID]] UTF8String], NULL);
    dispatch_queue_set_specific(scanQueue, kQueueCatalogEntry, (__bridge void *)self, NULL);

	return self;
}

#warning doesn't look used, and doesn't *actually* update enabled...
- (void)enable {
	if ([self.source respondsToSelector:@selector(enableEntry:)])
		[self.source enableEntry:self];
}

- (void)dealloc {
	if ([self.source respondsToSelector:@selector(disableEntry:)])
		[self.source disableEntry:self];
    }
}

- (NSDictionary *)dictionaryRepresentation {
	if (children)
		[info setObject:[children valueForKey:@"dictionaryRepresentation"] forKey:kItemChildren];
	return info;
}

- (QSCatalogEntry *)childWithID:(NSString *)theID {
	for (QSCatalogEntry *child in children) {
		if ([child.identifier isEqualToString:theID])
			return child;
	}
	return nil;
}

- (QSCatalogEntry *)childWithPath:(NSString *)path {
	if (![path length])
		return self;
	QSCatalogEntry *object = self;
	for(NSString *s in [path pathComponents]) {
		object = [object childWithID:s];
	}
	return object;
}

- (BOOL)isSuppressed {
#ifdef DEBUG
	return NO;
#endif
	NSString *path = [info objectForKey:@"requiresPath"];
	if (path && ![[NSFileManager defaultManager] fileExistsAtPath:[path stringByResolvingWildcardsInPath]])
		return YES;
	if ([[info objectForKey:@"requiresSettingsPath"] boolValue]) {
		path = [[info objectForKey:@"settings"] objectForKey:kItemPath];
		if (path && ![[NSFileManager defaultManager] fileExistsAtPath:[path stringByResolvingWildcardsInPath]])
			return YES;
	}
	NSString *requiredBundle = [info objectForKey:@"requiresBundle"];
	if (requiredBundle && ![[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:requiredBundle])
		return YES;
	return NO;
}

- (NSDate *)lastScanDate {
    if ([[self type] isEqualToString:@"Group"]) {
        // It's a group entry. Loop through the child catalog entries to find the one with the latest scan date
        NSDate *latestScan = nil;
        for (QSCatalogEntry *child in [self children]) {
            NSDate *childScanDate = [child lastScanDate];
            if (childScanDate && (childScanDate > latestScan || latestScan == nil)) {
                latestScan = childScanDate;
            }
        }
        return latestScan;
    }
	return [[[NSFileManager defaultManager] attributesOfItemAtPath:[self indexLocation] error:nil] objectForKey:NSFileModificationDate];
}

#warning should rename...
- (BOOL)deletable {
	if (self.isPreset) return NO;

	return ![[info objectForKey:@"permanent"] boolValue];
}

- (BOOL)isEditable {
    if ([self.source respondsToSelector:@selector(usesGlobalSettings)]
        && [self.source performSelector:@selector(usesGlobalSettings)]) {
        return YES;
    }

    return !self.isPreset;
}

- (NSString *)type {
	NSString *theID = NSStringFromClass([self.source class]);
	NSString *title = [[NSBundle bundleForClass:[self.source class]] safeLocalizedStringForKey:theID value:theID table:@"QSObjectSource.name"];
	if ([title isEqualToString:theID])
		return [[NSBundle mainBundle] safeLocalizedStringForKey:theID value:theID table:@"QSObjectSource.name"];
	else
		return title;
}

- (BOOL)isCatalog { return self == [[QSLibrarian sharedInstance] catalog]; }
- (BOOL)isPreset { return [self.identifier hasPrefix:@"QSPreset"]; }
- (BOOL)isSeparator { return [self.identifier hasPrefix:@"QSSeparator"]; }
- (BOOL)isGroup { return [[info objectForKey:kItemSource] isEqualToString:@"QSGroupObjectSource"]; }
- (BOOL)isLeaf { return !self.isGroup; }

- (NSInteger)state {
	BOOL enabled = self.isEnabled;
	if (!enabled) return 0;
	if (self.isGroup) {
		for(QSCatalogEntry *child in [self deepChildrenWithGroups:NO leaves:YES disabled:YES]) {
			if (!child.isEnabled) return -1*enabled;
		}
	}
	return enabled;
}

- (NSInteger)hasEnabledChildren {
	if (self.isGroup) {
		BOOL hasEnabledChildren = NO;
		for (QSCatalogEntry *child in children)
			hasEnabledChildren |= child.isEnabled;
		return hasEnabledChildren;
	} else
		return YES;
}

- (BOOL)shouldIndex {
	return self.isEnabled;
}

- (BOOL)isEnabled {
	if (!self.isPreset)
		return [[info objectForKey:kItemEnabled] boolValue];

    NSNumber *value;
    if (value = [[QSLibrarian sharedInstance] presetIsEnabled:self])
        return [value boolValue];
    else if (value = [info objectForKey:kItemEnabled])
        return [value boolValue];

#warning this is just a little silly...
    return YES;
}

- (void)setEnabled:(BOOL)enabled {
	if (self.isPreset)
		[[QSLibrarian sharedInstance] setPreset:self isEnabled:enabled];
	else
		[info setObject:@(enabled) forKey:kItemEnabled];
	if (enabled && ![[self contents] count]) {
        [self scanForced:YES];
    }

    [QSLib writeCatalog:self];
}

- (void)setDeepEnabled:(BOOL)enabled {
	self.enabled = YES;
	if (self.isGroup) {
		NSArray *deepChildren = [self deepChildrenWithGroups:YES leaves:YES disabled:YES];
		for(QSCatalogEntry *child in deepChildren)
			child.enabled = enabled;
	}
}

- (void)pruneInvalidChildren {
	NSMutableArray *children2 = [children copy];
	for (QSCatalogEntry *child in children2) {
		if (child.isSeparator) break; //Stop when at end of presets
		if (![[NSUserDefaults standardUserDefaults] boolForKey:@"Show All Catalog Entries"] && child.isSuppressed) {

#ifdef DEBUG
			if (DEBUG_CATALOG) NSLog(@"Suppressing Preset:%@", child.identifier);
#endif

			[children removeObject:child];
		} else if (child.isGroup) {
			[child pruneInvalidChildren];
			if (![(NSArray *)[child children] count]) // Remove empty groups
				[children removeObject:child];
		}
	}
}

- (NSArray *)leafIDs {
	if (!self.isEnabled) return nil;

	if (self.isGroup) {
		NSMutableArray *childObjects = [NSMutableArray arrayWithCapacity:1];
		for(QSCatalogEntry *child in children) {
			[childObjects addObjectsFromArray:[child leafIDs]];
		}
		return childObjects;
    }

    return [NSArray arrayWithObject:self.identifier];
}

- (NSArray *)leafEntries {
	return [self deepChildrenWithGroups:NO leaves:YES disabled:NO];
}

- (NSMutableDictionary *)info {
	return info;
}

- (NSArray *)deepChildrenWithGroups:(BOOL)groups leaves:(BOOL)leaves disabled:(BOOL)disabled {
	if (!(disabled || self.isEnabled)) return nil;

	if (self.isGroup) {
		NSMutableArray *childObjects = [NSMutableArray arrayWithCapacity:1];
		if (groups)
			[childObjects addObject:self];

		for (QSCatalogEntry *child in children) {
			[childObjects addObjectsFromArray:[child deepChildrenWithGroups:groups leaves:leaves disabled:disabled]];
		}
		return childObjects;
	}

    if (leaves) {
		return [NSArray arrayWithObject:self];
	}

	return nil;
}

- (NSString *)identifier {
	NSString *ID = [info objectForKey:kItemID];
	if (!ID && [info isKindOfClass:[NSMutableDictionary class]]) {
		[(NSMutableDictionary *)info setObject:[NSString uniqueString] forKey:kItemID];
		return [info objectForKey:kItemID];
	} else
		return ID;
}

- (NSIndexPath *)catalogIndexPath {
	NSArray *anc = [self ancestors];
	NSUInteger i;
	NSUInteger index;
	NSIndexPath *p = nil;
	for (i = 0; i < ([anc count] - 1); i++) {
		index = [[[anc objectAtIndex:i] children] indexOfObject:[anc objectAtIndex:i+1]];
		p = (p) ? [p indexPathByAddingIndex:index] : [NSIndexPath indexPathWithIndex:index];
	}
	return p;
}

- (NSIndexPath *)catalogSetIndexPath {
	NSArray *anc = [self ancestors];
	NSUInteger i;
	NSUInteger index;
	NSIndexPath *p = nil;
	for (i = 1; i < ([anc count] - 1); i++) {
		index = [[[anc objectAtIndex:i] children] indexOfObject:[anc objectAtIndex:i+1]];
		p = (p) ? [p indexPathByAddingIndex:index] : [NSIndexPath indexPathWithIndex:index];
	}
	return p;
}

- (NSArray *)ancestors {
	id catalog = [[QSLibrarian sharedInstance] catalog];
	NSArray *groups = [catalog deepChildrenWithGroups:YES leaves:NO disabled:YES];
	NSMutableArray *entryChain = [NSMutableArray arrayWithCapacity:0];
	id thisItem = self;
	NSUInteger i;
	[entryChain addObject:self];
	id theGroup = nil;
	while(thisItem != catalog) {
		for (i = 0; i < [groups count]; i++) {
			theGroup = [groups objectAtIndex:i];
			if ([[theGroup children] containsObject:thisItem]) {
				[entryChain insertObject:theGroup atIndex:0];
				thisItem = theGroup;
				break;
			} else if (i == [groups count] - 1) {
				NSLog(@"couldn't find parent of %@", thisItem);
				return nil;
			}
		}
	}
	return entryChain;
}

- (NSComparisonResult) compare:(QSCatalogEntry *)other {
    if (other.name != nil) {
        return [self.name compare:other.name];
    }
    // othername is nil, so make the receiver higher in the list
    return NSOrderedAscending;
}

- (NSString *)name {
    @synchronized (self) {
        if (self.isSeparator) return @"";
        if (!_name)
            _name = [info objectForKey:kItemName];
        if (!_name) {
            NSString *ID = self.identifier;
            _name = [bundle ? bundle : [NSBundle mainBundle] safeLocalizedStringForKey:ID value:ID table:@"QSCatalogPreset.name"];
            if (_name)
                [self setValue:_name forKey:@"name"];
        }
        return _name;
    }
}

- (void)setName:(NSString *)newName {
    @synchronized (self) {
        [info setObject:newName forKey:kItemName];
        _name = newName;
    }
}

- (id)imageAndText { return self; }

- (void)setImageAndText:(id)object { self.name = object; }

- (NSImage *)image { return self.icon; }

- (NSString *)text { return self.name; }

- (NSImage *)icon {
	NSImage *image = [QSResourceManager imageNamed:[info objectForKey:kItemIcon]];
	if (!image)
        image = image = [self.source iconForEntry:info];

    if (!image)
        image = [QSResourceManager imageNamed:@"Catalog"];

	return image;
}

- (NSString *)getCount {
	NSInteger num;
	if((num = [self count]))
		return [NSString stringWithFormat:@"%ld", (long)num];
	else
		return nil;
}

- (NSUInteger)count {
	return [self deepObjectCount];
}

- (NSUInteger)deepObjectCount {
	NSArray *leaves = [self deepChildrenWithGroups:NO leaves:YES disabled:NO];
	NSUInteger i, count = 0;
	for (i = 0; i < [leaves count]; i++)
		count += [(NSArray *)[[leaves objectAtIndex:i] enabledContents] count];
	return count;
}

- (NSString *)indexLocation {
	return [[[pIndexLocation stringByStandardizingPath] stringByAppendingPathComponent:self.identifier] stringByAppendingPathExtension:@"qsindex"];
}

- (BOOL)loadIndex {
	if (self.isEnabled) {
		NSString *indexPath = self.indexLocation;
		NSMutableArray *dictionaryArray = nil;
		@try {
			dictionaryArray = [QSObject objectsWithDictionaryArray:[NSMutableArray arrayWithContentsOfFile:indexPath]];
        }
        @catch (NSException *e) {
            NSLog(@"Error loading index of %@: %@", self.name , e);
        }

        if (!dictionaryArray)
            return NO;

        [self setContents:dictionaryArray];
        [[NSNotificationCenter defaultCenter] postNotificationName:QSCatalogEntryIndexed object:self];
        [[QSLibrarian sharedInstance] recalculateTypeArraysForItem:self];
	}
	return YES;
}

- (void)saveIndex {
    QSGCDQueueSync(scanQueue, ^{
#ifdef DEBUG
        if (DEBUG_CATALOG) NSLog(@"saving index for %@", self);
#endif

        [self setIndexDate:[NSDate date]];

        @try {
            NSArray *writeArray = [self.contents arrayByPerformingSelector:@selector(dictionaryRepresentation)];
            [writeArray writeToFile:self.indexLocation atomically:YES];
        }
        @catch (NSException *exception) {
            NSLog(@"Exception whilst saving catalog entry %@\ncontents: %@\nException: %@", self.name, self.contents, exception);
        }
    });
}


- (void)invalidateIndex:(NSNotification *)notif {
#ifdef DEBUG
	if (VERBOSE)
		NSLog(@"Catalog Entry Invalidated: %@ (%@) %@", self, [notif object] , [notif name]);
#endif
	[self scanForced:YES];
}

- (BOOL)indexIsValid {
    __block BOOL isValid = YES;
    QSGCDQueueSync(scanQueue,^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *indexPath = self.indexLocation;
        if (![manager fileExistsAtPath:self.indexLocation isDirectory:nil]) {
            isValid = NO;
        }
        if (isValid) {
            if (!indexDate)
                [self setIndexDate:[[manager attributesOfItemAtPath:indexPath error:NULL] fileModificationDate]];
            NSNumber *modInterval = [info objectForKey:kItemModificationDate];
            if (modInterval) {
                NSDate *specDate = [NSDate dateWithTimeIntervalSinceReferenceDate:[modInterval doubleValue]];
                if ([specDate compare:indexDate] == NSOrderedDescending) {
                    isValid = NO; //Catalog Specification is more recent than index
                }
            }
        }
        if (isValid) {
            isValid = [self.source indexIsValidFromDate:indexDate forEntry:info];
        }
    });
    return isValid;
}

- (QSObjectSource *)source {
    if (!_source) {
        _source = [QSReg sourceNamed:[info objectForKey:kItemSource]];
#ifdef DEBUG
        if (!_source && VERBOSE)
            NSLog(@"Source not found: %@ for Entry: %@", [info objectForKey:kItemSource], self.identifier);
#endif
    }
	return _source;
}

- (NSArray *)scannedObjects {
    NSArray *itemContents = nil;
    @autoreleasepool {
        @try {
            itemContents = [self.source objectsForEntry:info];
        }
        @catch (NSException *exception) {
            NSLog(@"An error ocurred while scanning \"%@\": %@", self.name, exception);
            [exception printStackTrace];
        }
    }
    return itemContents;
}

- (BOOL)canBeIndexed {
    if (![self.source respondsToSelector:@selector(entryCanBeIndexed:)])
        return YES;

	return [self.source entryCanBeIndexed:[self info]];
}

- (NSArray *)scanAndCache {
    if (self.isScanning) {
#ifdef DEBUG
		if (VERBOSE) NSLog(@"%@ is already being scanned", self.name);
#endif
		return nil;
	} else {
        __block NSArray *itemContents = nil;
        // Use a serial queue to do the grunt of the scan work. Ensures that no more than one thread can scan at any one time.
        QSGCDQueueSync(scanQueue, ^{
            self.scanning = YES;
            [self willChangeValueForKey:@"self"];
            NSString *ID = self.identifier;
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc postNotificationName:QSCatalogEntryIsIndexing object:self];
            itemContents = [self scannedObjects];
            if (itemContents && ID) {
                self.contents = itemContents;
                if (self.canBeIndexed) {
                    [self saveIndex];
                }
            } else if (ID) {
                self.contents = nil;
            }
            [self didChangeValueForKey:@"self"];
            [nc postNotificationName:QSCatalogEntryIndexed object:self];
            self.scanning = NO;
        });
        return itemContents;
    }
}

- (void)scanForced:(BOOL)force {
    if (self.isSeparator || !self.isEnabled) return;

    if (self.isGroup) {
        @autoreleasepool {
            for(QSCatalogEntry * child in children) {
                [child scanForced:force];
            }
        }
        return;
    }
    [[[QSLibrarian sharedInstance] scanTask] setStatus:[NSString stringWithFormat:NSLocalizedString(@"Checking: %@", @"Catalog task checking (%@ => source name)"), self.name]];
    BOOL valid = [self indexIsValid];
    if (valid && !force) {
#ifdef DEBUG
        if (DEBUG_CATALOG) NSLog(@"\tIndex is valid for source: %@", self.name);
#endif
        return;
    }

#ifdef DEBUG
    if (DEBUG_CATALOG)
        NSLog(@"Scanning source: %@%@", self.name , (force?@" (forced) ":@""));
#endif

    [[[QSLibrarian sharedInstance] scanTask] setStatus:[NSString stringWithFormat:NSLocalizedString(@"Scanning: %@", @"Catalog task scanning (%@ => source name)"), self.name]];
    [self scanAndCache];
    return;
}

- (NSMutableArray *)children { return children; }
- (NSMutableArray *)getChildren {
	if (!children)
		children = [[NSMutableArray alloc] init];
	return children;
}

- (void)setChildren:(NSArray *)newChildren {
	if(newChildren != children){
		children = [newChildren mutableCopy];
	}
}

- (NSArray *)contents {
    @synchronized (self) {
        return [self contentsScanIfNeeded:NO];
    }
}

- (void)setContents:(NSArray *)newContents {
    @synchronized (self) {
        _contents = [newContents copy];
    }
}

- (NSArray *)contentsScanIfNeeded:(BOOL)canScan {
    @synchronized (self) {
        if (!self.isEnabled) return nil;

        if (self.isGroup) {
            NSMutableSet *childObjects = [NSMutableSet setWithCapacity:1];

            for (QSCatalogEntry *child in children) {
                [childObjects addObjectsFromArray:[child contentsScanIfNeeded:canScan]];
            }
            return [childObjects allObjects];
        }

        if (!_contents && canScan)
            return [self scanAndCache];

        return _contents;
    }
}

- (NSArray *)enabledContents
{
    NSIndexSet *enabled = [[self contents] indexesOfObjectsWithOptions:NSEnumerationConcurrent passingTest:^BOOL(QSObject *obj, NSUInteger idx, BOOL *stop) {
        return ![QSLib itemIsOmitted:obj];
    }];
    return [[self contents] objectsAtIndexes:enabled];
}

- (QSCatalogEntry *)uniqueCopy {
	NSMutableDictionary *newDictionary = [info mutableCopy];
	if (self.isPreset) {
		[newDictionary setObject:@(self.isEnabled) forKey:kItemEnabled];
		[newDictionary setObject:self.name forKey:kItemName];
	}
	[newDictionary setObject:[NSString uniqueString] forKey:kItemID];

	QSCatalogEntry *newEntry = [[QSCatalogEntry alloc] initWithDictionary:newDictionary];
	if ([self children])
		[newEntry setChildren:[[self children] valueForKey:@"uniqueCopy"]];

	return newEntry;
}

- (NSDate *)indexDate { return indexDate;  }
- (void)setIndexDate:(NSDate *)anIndexDate {
	//	NSLog(@"date %@ ->%@", indexDate, anIndexDate);
	indexDate = anIndexDate;
}

@end
