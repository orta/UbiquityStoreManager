//
//  UbiquityStoreManager.m
//  UbiquityStoreManager
//
//  Created by Aleksey Novicov on 3/27/12.
//  Copyright (c) 2012 Yodel Code LLC. All rights reserved.
//

#import "UbiquityStoreManager.h"

#if TARGET_OS_IPHONE
#define OS_Alert UIAlertView
#else
#define OS_Alert NSAlert
#endif

NSString * const RefetchAllDatabaseDataNotificationKey	= @"RefetchAllDatabaseData";
NSString * const RefreshAllViewsNotificationKey			= @"RefreshAllViews";

NSString *LocalUUIDKey			= @"LocalUUIDKey";
NSString *iCloudUUIDKey			= @"iCloudUUIDKey";
NSString *iCloudEnabledKey		= @"iCloudEnabledKey";
NSString *DatabaseDirectoryName	= @"Database.nosync";
NSString *DataDirectoryName		= @"Data";

@interface UbiquityStoreManager () {
    NSDictionary *additionalStoreOptions__;
    NSString *containerIdentifier__;
	NSManagedObjectModel *model__;
	NSPersistentStoreCoordinator *persistentStoreCoordinator__;
	NSPersistentStore *persistentStore__;
	NSURL *localStoreURL__;
	OS_Alert *moveDataAlert;
	OS_Alert *switchToiCloudAlert;
	OS_Alert *switchToLocalAlert;
	dispatch_queue_t persistentStorageQueue;
}

@property (nonatomic) NSString *localUUID;
@property (nonatomic) NSString *iCloudUUID;

- (NSString *)freshUUID;
- (void)registerForNotifications;
- (void)removeNotifications;
- (void)migrate:(BOOL)migrate andUseCloudStorageWithUUID:(NSString *)uuid completionBlock:(void (^)(BOOL usingiCloud))completionBlock;
- (void)checkiCloudStatus;
@end


@implementation UbiquityStoreManager

@synthesize delegate;
@synthesize isReady = _isReady;
@synthesize hardResetEnabled = _hardResetEnabled;

- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model localStoreURL:(NSURL *)storeURL
             containerIdentifier:(NSString *)containerIdentifier additionalStoreOptions:(NSDictionary *)additionalStoreOptions {
	self = [super init];
	if (self) {
        additionalStoreOptions__ = additionalStoreOptions;
        containerIdentifier__ = containerIdentifier;
		model__ = model;
		localStoreURL__ = storeURL;
		persistentStorageQueue = dispatch_queue_create([@"PersistentStorageQueue" UTF8String], DISPATCH_QUEUE_SERIAL);
		
		// Start iCloud connection
		[self updateLocalCopyOfiCloudUUID];
		
		[self checkiCloudStatus];
		[self registerForNotifications];
	}
	
	return self;
}

- (void)dealloc {
	[self removeNotifications];
	dispatch_release(persistentStorageQueue);
}

#pragma mark - File Handling

- (NSURL *)iCloudStoreURLForUUID:(NSString *)uuid {
	NSFileManager *fileManager	= [NSFileManager defaultManager];
	NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
	NSString *databaseContent	= [[cloudURL path] stringByAppendingPathComponent:DatabaseDirectoryName];
	NSString *storePath			= [databaseContent stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.sqlite", uuid]];
	
	return [NSURL fileURLWithPath:storePath];
}

- (void)deleteStoreForUUID:(NSString *) uuid {
	// TODO:
}

- (void)deleteStoreDirectory {
	NSFileManager *fileManager	= [NSFileManager defaultManager];
	NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
	NSString *databaseContent	= [[cloudURL path] stringByAppendingPathComponent:DatabaseDirectoryName];
	
	if ([fileManager fileExistsAtPath:databaseContent]) {
		NSError *error = nil;
		[fileManager removeItemAtPath:databaseContent error:&error];
		
		if (error)
			NSLog(@"Error deleting old store: %@", error);
	}
}

- (void)createStoreDirectoryIfNecessary {
	NSFileManager *fileManager	= [NSFileManager defaultManager];
	NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
	NSString *databaseContent	= [[cloudURL path] stringByAppendingPathComponent:DatabaseDirectoryName];
	
	if (![fileManager fileExistsAtPath:databaseContent]) {
		NSError *error = nil;
		[fileManager createDirectoryAtPath:databaseContent withIntermediateDirectories:YES attributes:nil error:&error];
		
		if (error) NSLog(@"Error creating database directory: %@", error);
	}
}

- (NSURL *)transactionLogsURL {
	NSFileManager *fileManager		= [NSFileManager defaultManager];
	NSURL *cloudURL					= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
	NSString* coreDataCloudContent	= [[cloudURL path] stringByAppendingPathComponent:DataDirectoryName];
	
	return [NSURL fileURLWithPath:coreDataCloudContent];
}

- (void)deleteTransactionLogs {
		NSFileManager *fileManager	= [NSFileManager defaultManager];
		[fileManager removeItemAtPath:[[self transactionLogsURL] path] error:nil];
}

- (NSURL *)transactionLogsURLForUUID:(NSString *)uuid {
	return [[self transactionLogsURL] URLByAppendingPathComponent:uuid isDirectory:YES];
}

- (void)deleteTransactionLogsForUUID:(NSString *)uuid {
	if (uuid) {
		NSFileManager *fileManager	= [NSFileManager defaultManager];
		NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
		
		// Can only continue if iCloud is available
		if (cloudURL) {
			NSString *transactionLogsForUUID = [[self transactionLogsURLForUUID:uuid] path];
			[fileManager removeItemAtPath:transactionLogsForUUID error:nil];
		}
	}
}

#pragma mark - Message Strings

// Subclass UbiquityStoreManager and override these methods if you want to customize these messages

- (NSString *)moveDataToiCloudTitle {
	return @"Move Data to iCloud";
}

- (NSString *)moveDataToiCloudMessage {
	return @"Your data is about to be moved to iCloud. If you prefer to start using iCloud with data from a different device, tap Cancel and enable iCloud from that other device.";
}

- (NSString *)switchDataToiCloudTitle {
	return  @"iCloud Data";
}

- (NSString *)switchDataToiCloudMessage {
	return @"Would you like to switch to using data from iCloud?";
}

- (NSString *)tryLaterTitle {
	return @"iCloud Not Available";
}

- (NSString *)tryLaterMessage {
	return @"iCloud is not currently available. Please try again later.";
}


- (NSString *)switchToLocalDataTitle {
	return @"Stop Using iCloud";
}

- (NSString *)switchToLocalDataMessage {
	return @"If you stop using iCloud you will switch to using local data on this device only. Your local data is completely separate from iCloud. Any changes you make will not be be synchronized with iCloud.";
}

#pragma mark - UIAlertView

- (void)alertView:(OS_Alert *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
	if (alertView == moveDataAlert) {
		if (buttonIndex == 1) {
			// Move the data from the local store to the iCloud store
			[self setupCloudStorageWithUUID:[self freshUUID]];
		}
		else {
			[self didSwitchToiCloud:NO];
		}
	}
	
	if (alertView == switchToiCloudAlert) {
		if (buttonIndex == 1) {
			// Switch to using data from iCloud
			[self useCloudStorage];
		}
		else {
			[self didSwitchToiCloud:NO];
		}
	}
	
	if (alertView == switchToLocalAlert) {
		if (buttonIndex == 1) {
			// Switch to using data from iCloud
			[self useLocalStorage];
		}
		else {
			[self didSwitchToiCloud:YES];
		}
	}
}

- (void)moveDataToiCloudAlert {
#if TARGET_OS_IPHONE
	moveDataAlert = [[UIAlertView alloc] initWithTitle: [self moveDataToiCloudTitle]
											   message: [self moveDataToiCloudMessage]
											  delegate: self
									 cancelButtonTitle: @"Cancel"
									 otherButtonTitles: @"Move Data", nil];
	[moveDataAlert show];	
#else
    moveDataAlert = [NSAlert alertWithMessageText:[self moveDataToiCloudTitle]
                                    defaultButton:@"Move Data"
                                  alternateButton:@"Cancel"
                                      otherButton:nil
                        informativeTextWithFormat:[self moveDataToiCloudMessage]];
    NSInteger button = [moveDataAlert runModal];
    [self alertView:moveDataAlert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
}

- (void)switchToiCloudDataAlert {
#if TARGET_OS_IPHONE
	switchToiCloudAlert = [[UIAlertView alloc] initWithTitle: [self switchDataToiCloudTitle]
													 message: [self switchDataToiCloudMessage]
													delegate: self
										   cancelButtonTitle: @"Cancel"
										   otherButtonTitles: @"Use iCloud", nil];
	[switchToiCloudAlert show];
#else
    switchToiCloudAlert = [NSAlert alertWithMessageText:[self switchDataToiCloudTitle]
                                    defaultButton:@"Use iCloud"
                                  alternateButton:@"Cancel"
                                      otherButton:nil
                        informativeTextWithFormat:[self switchDataToiCloudMessage]];
    NSInteger button = [switchToiCloudAlert runModal];
    [self alertView:switchToiCloudAlert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
}

- (void)tryLaterAlert {
#if TARGET_OS_IPHONE
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle: [self tryLaterTitle]
													message: [self tryLaterMessage]
												   delegate: nil
										  cancelButtonTitle: @"Done"
										  otherButtonTitles: nil];
	[alert show];
#else
    NSAlert *alert = [NSAlert alertWithMessageText:[self tryLaterTitle]
                                          defaultButton:@"Cancel"
                                        alternateButton:nil
                                            otherButton:nil
                              informativeTextWithFormat:[self tryLaterMessage]];
    [alert runModal];
#endif
}

- (void)switchToLocalDataAlert {
#if TARGET_OS_IPHONE
	switchToLocalAlert = [[UIAlertView alloc] initWithTitle: [self switchToLocalDataTitle]
													message: [self switchToLocalDataMessage]
												   delegate: self
										  cancelButtonTitle: @"Cancel"
										  otherButtonTitles: @"Continue", nil];
	[switchToLocalAlert show];	
#else
    switchToLocalAlert = [NSAlert alertWithMessageText:[self switchToLocalDataTitle]
                                          defaultButton:@"Continue"
                                        alternateButton:@"Cancel"
                                            otherButton:nil
                              informativeTextWithFormat:[self switchToLocalDataMessage]];
    NSInteger button = [switchToLocalAlert runModal];
    [self alertView:switchToLocalAlert didDismissWithButtonIndex:button == NSAlertDefaultReturn? 1: 0];
#endif
}

#pragma mark - Test Methods

- (void)hardResetCloudStorage {
	if (_hardResetEnabled) {
		[self migrate:NO andUseCloudStorageWithUUID:nil completionBlock:^(BOOL usingiCloud) {
			[self deleteStoreDirectory];
			[self deleteTransactionLogs];
			
			// Setting iCloudUUID to nil will propagate to all other devices,
			// and automatically force them to switch over to their local stores
			
			self.iCloudUUID = nil;	
			self.localUUID = nil;
			self.iCloudEnabled = NO;
		}];
	}
}

- (NSArray *)fileList {
	NSArray *fileList = nil;

	NSFileManager *fileManager	= [NSFileManager defaultManager];
	NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
	
	if (cloudURL)
		fileList = [fileManager subpathsAtPath:[cloudURL path]];
	
	return fileList;
}

#pragma mark - Persistent Store Management

- (void)clearPersistentStore {
	if (persistentStore__) {
		NSError *error = nil;
		[persistentStoreCoordinator__ removePersistentStore:persistentStore__ error:&error];
		persistentStore__ = nil;
		
		if (error)
			NSLog(@"Error removing persistent store: %@", error);
		else 
			NSLog(@"Existing persistent store removed");
	}
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator {
	
    if (persistentStoreCoordinator__ == nil) {
		persistentStoreCoordinator__ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model__];
		
		NSString *uuid = (self.iCloudEnabled) ? self.localUUID : nil;
		[self migrate:NO andUseCloudStorageWithUUID:uuid completionBlock:nil];
    }
    return persistentStoreCoordinator__;
}

- (void)migrateToiCloud:(BOOL)migrate persistentStoreCoordinator:(NSPersistentStoreCoordinator *)psc with:(NSString *)uuid {
	NSMutableDictionary *options;

	NSAssert([[psc persistentStores] count] == 0, @"There were more persistent stores than expected");

	[self createStoreDirectoryIfNecessary];
	
	NSError *error = nil;
	NSURL *transactionLogsURL = [self transactionLogsURLForUUID:uuid];
	
	options = [NSMutableDictionary dictionaryWithObjectsAndKeys:
			   uuid, NSPersistentStoreUbiquitousContentNameKey,
			   transactionLogsURL, NSPersistentStoreUbiquitousContentURLKey,
			   [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
			   [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption,
			   nil];
    [options addEntriesFromDictionary:additionalStoreOptions__];
	
	[psc lock];
	
	if (migrate) {
		// Clear old registered notifcations. This was required to address an exception that occurs when using
		// a persistent store on iCloud setup by another device (Object's persistent store is not reachable
		// from this NSManagedObjectContext's coordinator)
		[[NSNotificationCenter defaultCenter] removeObserver: self 
														name: NSPersistentStoreDidImportUbiquitousContentChangesNotification
													  object: psc];

		// Add the store to migrate
		NSPersistentStore * migratedStore = [psc addPersistentStoreWithType: NSSQLiteStoreType
															  configuration: nil 
																		URL: localStoreURL__
																	options: additionalStoreOptions__
																	  error: &error];

		if (error) NSLog(@"Prepping migrated store error: %@", error);

		error = nil;
		persistentStore__ = [psc migratePersistentStore: migratedStore 
												  toURL: [self iCloudStoreURLForUUID:uuid]
												options: options
											   withType: NSSQLiteStoreType
												  error: &error];

		[[NSNotificationCenter defaultCenter]addObserver: self 
												selector: @selector(mergeChanges:) 
													name: NSPersistentStoreDidImportUbiquitousContentChangesNotification 
												  object: psc];
	}
	else {
		persistentStore__ = [psc addPersistentStoreWithType: NSSQLiteStoreType
											  configuration: nil
														URL: [self iCloudStoreURLForUUID:uuid]
													options: options
													  error: &error];
	}
	[psc unlock];
	
	if (error) NSLog(@"Persistent store error: %@", error);
	
	NSAssert([[psc persistentStores] count] == 1, @"Not the expected number of persistent stores");
}

- (void)migrate:(BOOL)migrate andUseCloudStorageWithUUID:(NSString *)uuid completionBlock:(void (^)(BOOL usingiCloud))completionBlock {
	NSLog(@"Setting up store with %@", uuid);
	BOOL willUseiCloud = (uuid != nil);
	
	// TODO: Check for use case where user checks out of one iCloud account, and logs into another!
	
	// TODO: Test deletion from Settings App -> Manage Data -> Delete Data (nuke option)
	
    NSPersistentStoreCoordinator* psc = persistentStoreCoordinator__;
	
	// Do this asynchronously since if this is the first time this particular device is syncing with preexisting
	// iCloud content it may take a long long time to download
    dispatch_async(persistentStorageQueue, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
		NSMutableDictionary *options;
		
		// Clear previous persistentStore
		[self clearPersistentStore];
		
        NSURL *cloudURL					= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];
        NSString* coreDataCloudContent	= [[cloudURL path] stringByAppendingPathComponent:DataDirectoryName];
		
		BOOL usingiCloud = ([coreDataCloudContent length] != 0) && willUseiCloud;
		
		if (usingiCloud) {
			// iCloud is available
			[self migrateToiCloud:migrate persistentStoreCoordinator:psc with:uuid];
		}
		else {
			// iCloud is not available
			options = [NSMutableDictionary dictionaryWithObjectsAndKeys:
					   [NSNumber numberWithBool:YES], NSMigratePersistentStoresAutomaticallyOption,
					   [NSNumber numberWithBool:YES], NSInferMappingModelAutomaticallyOption,
					   nil];
            [options addEntriesFromDictionary:additionalStoreOptions__];
			
			[psc lock];
			
			persistentStore__ = [psc addPersistentStoreWithType: NSSQLiteStoreType
												  configuration: nil
															URL: localStoreURL__ 
														options: options 
														  error: nil];
			
			[psc unlock];
		}

		// Inform UI on the main thread we finally added the store and then post a custom notification
		// to make your views do whatever they need to such as tell their NSFetchedResultsController to
		// performFetch again now there is a real store.
		
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			_isReady = YES;
			
			NSString *usingiCloudString = (usingiCloud) ? @" using iCloud!" : @"!";
            NSLog(@"Asynchronously added persistent store%@", usingiCloudString);
			
			if(completionBlock) {
				completionBlock(usingiCloud);
			}

            [[NSNotificationCenter defaultCenter] postNotificationName:RefetchAllDatabaseDataNotificationKey object:self userInfo:nil];
			[self didSwitchToiCloud:willUseiCloud];
        });
    });
}

- (void)useCloudStorage {
    if (persistentStoreCoordinator__ == nil)
		persistentStoreCoordinator__ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model__];
	
	[self migrate:NO andUseCloudStorageWithUUID:self.iCloudUUID completionBlock:^(BOOL usingiCloud) {
		if (usingiCloud) {
			self.localUUID = self.iCloudUUID;
			self.iCloudEnabled = YES;
		}
	}];
}

- (void)useLocalStorage {
    if (persistentStoreCoordinator__ == nil)
		persistentStoreCoordinator__ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model__];
	
	[self migrate:NO andUseCloudStorageWithUUID:nil completionBlock:^(BOOL usingiCloud) {
		self.localUUID = nil;
		self.iCloudEnabled = NO;
	}];
}

- (void)setupCloudStorageWithUUID:(NSString *)uuid {
	NSLog(@"Setting up iCloud data with new UUID = %@", uuid);

	[self migrate:YES andUseCloudStorageWithUUID:uuid completionBlock:^(BOOL usingiCloud) {
		if (usingiCloud) {
			self.localUUID		= uuid;
			self.iCloudUUID		= uuid;
			self.iCloudEnabled	= YES;
		}
	}];
}

- (void)replaceiCloudStoreWithUUID:(NSString *)uuid {
    if (persistentStoreCoordinator__ == nil)
		persistentStoreCoordinator__ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model__];
	
	[self migrate:NO andUseCloudStorageWithUUID:uuid completionBlock:^(BOOL usingiCloud) {
		if (usingiCloud) {
			self.localUUID		= uuid;
			self.iCloudEnabled	= YES;
		}
		else {
			if (_hardResetEnabled) {
				// Hard reset has occurred. Delete database and transaction logs
				[self deleteStoreDirectory];
				[self deleteTransactionLogs];
			}
			
			self.localUUID		= nil;
			self.iCloudEnabled	= NO;
		}
	}];
}

- (NSURL *)currentStoreURL {
	if (self.iCloudEnabled)
		return [self iCloudStoreURLForUUID:self.iCloudUUID];
	else
		return localStoreURL__;
}

#pragma mark - Top Level Methods

- (void)checkiCloudStatus {
	if (self.iCloudEnabled) {
		NSFileManager *fileManager	= [NSFileManager defaultManager];
		NSURL *cloudURL				= [fileManager URLForUbiquityContainerIdentifier:containerIdentifier__];

		// If we have only one file/directory (Documents directory), then iCloud data has been deleted by user
		if ((cloudURL == nil) || [[self fileList] count] < 2)
			[self useLocalStorage];
	}
}

- (void)useiCloudStore:(BOOL)willUseiCloud {
	// To provide the option of using iCloud immediately upon first running of an app,
	// make sure a persistentStoreCoordinator exists.
	
    if (persistentStoreCoordinator__ == nil)
		persistentStoreCoordinator__ = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel: model__];
	
	if (willUseiCloud) {
		if (!self.iCloudEnabled) {
			NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
			
			// If an iCloud store already exists, ask the user if they want to switch over to iCloud
			if (cloud) {
				if (self.iCloudUUID) {
                    if ([localStoreURL__ checkResourceIsReachableAndReturnError:nil])
                        [self switchToiCloudDataAlert];
                    else
                        [self useCloudStorage];
				}
				else {
                    if ([localStoreURL__ checkResourceIsReachableAndReturnError:nil])
                        [self moveDataToiCloudAlert];
                    else
                        [self setupCloudStorageWithUUID:[self freshUUID]];
				}
			}
			else {
				[self tryLaterAlert];
			}
		}
	}
	else {
		if (self.iCloudEnabled) {
            if ([localStoreURL__ checkResourceIsReachableAndReturnError:nil])
                [self switchToLocalDataAlert];
            else
                [self useLocalStorage];
		}
	}
}

- (void)didSwitchToiCloud:(BOOL)didSwitch {
	if ([delegate respondsToSelector:@selector(ubiquityStoreManager:didSwitchToiCloud:)]) {
		[delegate ubiquityStoreManager:self didSwitchToiCloud:didSwitch];
	}
}

#pragma mark - Properties

- (BOOL)iCloudEnabled {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	return [local boolForKey:iCloudEnabledKey];
}

- (void)setICloudEnabled:(BOOL)enabled {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	[local setBool:enabled forKey:iCloudEnabledKey];
}

- (NSString *)freshUUID {
    CFUUIDRef uuidRef			= CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef uuidStringRef	= CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
	
    CFRelease(uuidRef);
	
    return (__bridge NSString *)uuidStringRef;
}

- (void)setLocalUUID:(NSString *)uuid {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	[local setObject:uuid forKey:LocalUUIDKey];
	[local synchronize];
}

- (NSString *)localUUID {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	return [local objectForKey:LocalUUIDKey];
}

- (void)setICloudUUID:(NSString *)uuid {
	NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
	[cloud setObject:uuid forKey:iCloudUUIDKey];
	[cloud synchronize];

	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	[local setObject:uuid forKey:iCloudUUIDKey];
	[local synchronize];
}

- (NSString *)iCloudUUID {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	return [local objectForKey:iCloudUUIDKey];
}

- (void)updateLocalCopyOfiCloudUUID {
	NSUserDefaults *local = [NSUserDefaults standardUserDefaults];
	NSUbiquitousKeyValueStore *cloud = [NSUbiquitousKeyValueStore defaultStore];
	[local setObject:[cloud objectForKey:iCloudUUIDKey] forKey:iCloudUUIDKey];
	[local synchronize];
}

#pragma mark - KeyValueStore Notification

- (void)keyValueStoreChanged:(NSNotification *)note {
	NSLog(@"KeyValueStore changed");
	
	NSDictionary* changedKeys = [note.userInfo objectForKey:NSUbiquitousKeyValueStoreChangedKeysKey];
	for (NSString *key in changedKeys) {
		if ([key isEqualToString:iCloudUUIDKey]) {
			
			// Latest change wins
			[self updateLocalCopyOfiCloudUUID];
			[self replaceiCloudStoreWithUUID:self.iCloudUUID];
		}
	}
	NSLog(@"KeyValueStore change completed");
}

#pragma mark - Notifications

- (void)mergeChanges:(NSNotification *)note {
	NSLog(@"NSPersistentStoreDidImportUbiquitousContentChangesNotification received");
	
	dispatch_async(persistentStorageQueue, ^{
		NSManagedObjectContext *moc = [self.delegate managedObjectContextForUbiquityStoreManager:self];
		[moc performBlockAndWait:^{
			[moc mergeChangesFromContextDidSaveNotification:note]; 
		}];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			NSNotification* refreshNotification = [NSNotification notificationWithName: RefreshAllViewsNotificationKey
																				object: self
																			  userInfo: [note userInfo]];
			
			[[NSNotificationCenter defaultCenter] postNotification:refreshNotification];
		});
	});
}


- (void)registerForNotifications {
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(keyValueStoreChanged:)
												 name: NSUbiquitousKeyValueStoreDidChangeExternallyNotification
											   object: nil];

	[[NSNotificationCenter defaultCenter]addObserver: self 
											selector: @selector(mergeChanges:) 
												name: NSPersistentStoreDidImportUbiquitousContentChangesNotification 
											  object: [self persistentStoreCoordinator]];
	
}

- (void)removeNotifications {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
