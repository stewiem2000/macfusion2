//
//  MFServerFS.m
//  MacFusion2
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//      http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "MFServerFS.h"
#import "MFConstants.h"
#import "MFPluginController.h"
#import "MFError.h"
#import "MFLogging.h"
#import "MFPreferences.h"
#import "MGUtilities.h"
#import <AppKit/AppKit.h>
#import "NSString+CarbonFSRefCreation.h"

#import <sys/xattr.h>

#define FS_DIR_PATH @"~/Library/Application Support/Macfusion/Filesystems"

@interface MFServerFS (PrivateAPI)
- (MFServerFS *)initWithPlugin:(MFServerPlugin *)p;
- (MFServerFS *)initWithParameters:(NSDictionary*)params plugin:(MFServerPlugin*)p;

- (NSMutableDictionary *)fullParametersWithDictionary:(NSDictionary *)fsParams;
- (void)registerGeneralNotifications;
- (NSMutableDictionary *)initializedStatusInfo;
- (void)writeOutData;
- (NSString *)getNewUUID;
- (BOOL)validateParameters:(NSDictionary*)params error:(NSError**)error;
- (NSError *)genericError;
- (void)setError:(NSError*)error;
- (NSTimer *)newTimeoutTimer;
- (void)addFileSystemToFinderSidebar;
- (void)removeFileSystemFromFinderSidebar;
@end

@implementation MFServerFS

+ (MFServerFS *)newFilesystemWithPlugin:(MFServerPlugin *)plugin {
	if (plugin) {
		Class FSClass = [plugin subclassForClass:self];
		return [[FSClass alloc] initWithPlugin:plugin];
	}
	
	return nil;
}

+ (MFServerFS *)loadFilesystemAtPath:(NSString *)path error:(NSError **)error {
	MFServerFS *fs;
	NSMutableDictionary *fsParameters = [NSMutableDictionary dictionaryWithContentsOfFile:path];
	if (!fsParameters) {
		NSDictionary* errorDict = [NSDictionary dictionaryWithObjectsAndKeys:
								   @"Could not read dictionary data for filesystem", NSLocalizedDescriptionKey,
								   [NSString stringWithFormat:@"File at path %@", path], NSLocalizedRecoverySuggestionErrorKey, 
								   nil];
		if (error) {
			*error = [NSError errorWithDomain:kMFErrorDomain code:kMFErrorCodeDataCannotBeRead userInfo:errorDict];	
		}
		return nil;
	}
	
	[fsParameters setObject:path forKey:kMFFSFilePathParameter];
	[fsParameters setObject:[NSNumber numberWithBool:YES] forKey:kMFFSPersistentParameter];
	
	NSString *pluginID = [fsParameters objectForKey:kMFFSTypeParameter];
	if (!pluginID) {
		NSDictionary *errorDict = [NSDictionary dictionaryWithObjectsAndKeys:
								   @"Could not read plugin id key for filesystem", NSLocalizedDescriptionKey,
								   [NSString stringWithFormat:@"File at path %@", path], NSLocalizedRecoverySuggestionErrorKey,
								   nil];
		if (error) {
			*error = [NSError errorWithDomain:kMFErrorDomain code:kMFErrorCodeMissingParameter userInfo:errorDict];	
		}
		return nil;
	}
	
	MFServerPlugin *plugin = [[MFPluginController sharedController] pluginWithID:pluginID];
	if (plugin) {
		Class FSClass = [plugin subclassForClass:self];
		fs = [[FSClass alloc] initWithParameters:fsParameters plugin:plugin];
		NSError *validationError;
		BOOL ok = [fs validateParametersWithError:&validationError];
		if (ok) {
			return fs;
		} else {
			if (error) {
				*error = validationError;	
			}
			return nil;
		}
	} else {
		if (error) {
			NSDictionary *errorDict = [NSDictionary dictionaryWithObjectsAndKeys:
									   @"Invalid plugin ID given", NSLocalizedDescriptionKey,
									   [NSString stringWithFormat:@"File at path %@", path], NSLocalizedRecoverySuggestionErrorKey,
									   nil];
			*error = [NSError errorWithDomain:kMFErrorDomain code:kMFErrorCodeInvalidParameterValue userInfo:errorDict];	
		}
		return nil;
	}
}


+ (MFServerFS *)filesystemFromURL:(NSURL *)url plugin:(MFServerPlugin *)p error:(NSError **)error {
	NSMutableDictionary* params = [[[p delegate] parameterDictionaryForURL:url error:error] mutableCopy];
	if (!params) {
		if (error) {
			*error = [MFError errorWithErrorCode:kMFErrorCodeMountFaliure description:@"Plugin failed to parse URL"];	
		}
		return nil;
	}
	[params setValue:[NSNumber numberWithBool:NO] forKey:kMFFSPersistentParameter];
	[params setValue:p.ID forKey:kMFFSTypeParameter];
	[params setValue:[NSString stringWithFormat:@"%@", url] forKey:kMFFSDescriptionParameter];
	
	Class FSClass = [p subclassForClass:self];
	MFServerFS* fs = [[FSClass alloc] initWithParameters:params plugin:p];
	NSError *validationError;
	BOOL ok = [fs validateParametersWithError:&validationError];
	if (!ok) {
		if (error) {
			*error = validationError;	
		}
		return nil;
	} else {
		return fs;
	}
}

- (MFServerFS *)initWithParameters:(NSDictionary *)params plugin:(MFServerPlugin *)p {
	if (self = [super init]) {
		[self setPlugin:p];
		delegate = [p delegate];
		parameters = [self fullParametersWithDictionary:params];
		statusInfo = [self initializedStatusInfo];
		_pauseTimeout = NO;
		if (![parameters objectForKey:kMFFSUUIDParameter]) {
			[parameters setObject:[self getNewUUID] forKey:kMFFSUUIDParameter];
		}
		
		[self registerGeneralNotifications];
	}
	
	return self;
}
		 
- (MFServerFS *)initWithPlugin:(MFServerPlugin *)p {
	NSAssert(p, @"Plugin null in MFServerFS initWithPlugin");
	NSDictionary *newFSParameters = [NSDictionary dictionaryWithObjectsAndKeys:
									 p.ID, kMFFSTypeParameter,
									 [NSNumber numberWithBool:YES], kMFFSPersistentParameter,
									 nil];
									 
	return [self initWithParameters:newFSParameters plugin:p];
}


- (void)registerGeneralNotifications {
	[self addObserver:self 
		   forKeyPath:KMFStatusDict
			  options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
			  context:nil];
	[self addObserver:self
		   forKeyPath:kMFParameterDict
			  options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
			  context:nil];
	[self addObserver:self
		   forKeyPath:kMFSTStatusKey
			  options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
			  context:nil];
}

- (NSMutableDictionary *)initializedStatusInfo {
	NSMutableDictionary *initialStatusInfo = [NSMutableDictionary dictionaryWithCapacity:5];
	// Initialize the important keys in the status dictionary
	[initialStatusInfo setObject:kMFStatusFSUnmounted forKey:kMFSTStatusKey];
	[initialStatusInfo setObject:[NSMutableString stringWithString:@""] forKey:kMFSTOutputKey];
	return initialStatusInfo;
}

- (NSString *)getNewUUID {
	CFUUIDRef uuidObject = CFUUIDCreate(NULL);
    CFStringRef uuidCFString = CFUUIDCreateString(NULL, uuidObject);
    CFRelease(uuidObject);
	return (__bridge_transfer NSString *)(uuidCFString);
}


- (NSDictionary *)defaultParameterDictionary {
	NSMutableDictionary *defaultParameterDictionary = [NSMutableDictionary dictionary];
	NSDictionary *delegateDict = [delegate defaultParameterDictionary];
	
	[defaultParameterDictionary addEntriesFromDictionary:delegateDict];
	[defaultParameterDictionary setObject:[NSNumber numberWithBool:NO] forKey:kMFFSNegativeVNodeCacheParameter];
	[defaultParameterDictionary setObject:[NSNumber numberWithBool:NO] forKey:kMFFSNoAppleDoubleParameter];
	[defaultParameterDictionary setObject:[NSNumber numberWithBool:NO] forKey:kMFFSShowInFinderSidebar];
	
	return [defaultParameterDictionary copy];
}

# pragma mark Parameter processing
- (NSMutableDictionary *)fullParametersWithDictionary:(NSDictionary *)fsParams {
	NSDictionary *defaultParams = [self defaultParameterDictionary];
	NSMutableDictionary *params = [fsParams mutableCopy];
	if (!params) {
		params = [NSMutableDictionary dictionary];
	}
	
	for(NSString *parameterKey in [defaultParams allKeys]) {
		if ([fsParams objectForKey:parameterKey]) {
		} else {
			[params setObject:[defaultParams objectForKey:parameterKey] forKey:parameterKey];
		}
		
	}
	
	return params;
}

# pragma mark Initialization

# pragma mark Task Creation methods
- (NSDictionary *)taskEnvironment {
	if ([delegate respondsToSelector:@selector(taskEnvironmentForParameters:)]) {
		return [delegate taskEnvironmentForParameters:[self parametersWithImpliedValues]];
	} else {
		return [[NSProcessInfo processInfo] environment];
	}
}

- (NSArray *)taskArguments
{
	NSArray *delegateArgs;
	NSMutableArray *taskArguments = [NSMutableArray array];
	
	// MFLogS(self, @"Parameters are %@, implied parameters are %@", parameters, [self parametersWithImpliedValues]);
	if ([delegate respondsToSelector:@selector(taskArgumentsForParameters:)]) {
		delegateArgs = [delegate taskArgumentsForParameters:[self parametersWithImpliedValues]];
		if (!delegateArgs || [delegateArgs count] == 0) {
			MFLogS(self, @"Delegate returned nil arguments or empty array!");
			return nil;
		} else {
			[taskArguments addObjectsFromArray:delegateArgs];
			NSString *advancedArgumentsString = [self.parameters objectForKey:kMFFSAdvancedOptionsParameter];
			NSArray *advancedArguments = [advancedArgumentsString componentsSeparatedByString:@" "];
			[taskArguments addObjectsFromArray:advancedArguments];
			
			if ([[self.parameters objectForKey:kMFFSNoAppleDoubleParameter] boolValue]) {
				[taskArguments addObject:@"-onoappledouble"];
			}
			
			if ([[self.parameters objectForKey:kMFFSNegativeVNodeCacheParameter] boolValue]) {
				[taskArguments addObject:@"-onegative_vncache"];
			}
			
			return taskArguments;
		}
	} else {
		MFLogS(self, @"Could not get task arguments for delegate!");
		return nil;
	}
}

- (void)setupIOForTask:(NSTask *)t {
	NSPipe *outputPipe = [[NSPipe alloc] init];
	NSPipe *inputPipe = [[NSPipe alloc] init];
	[t setStandardError:outputPipe];
	[t setStandardOutput:outputPipe];
	[t setStandardInput:inputPipe];
}

- (void)registerNotificationsForTask:(NSTask *)t {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(handleDataOnPipe:) name:NSFileHandleDataAvailableNotification object:[[t standardOutput] fileHandleForReading]];
	[nc addObserver:self selector:@selector(handleTaskDidTerminate:) name:NSTaskDidTerminateNotification object:t];
}

- (NSTask *)taskForLaunch {
	NSTask *t = [[NSTask alloc] init];
	
	// Pull together all the tasks parameters
	NSDictionary *env = [self taskEnvironment];
	[t setEnvironment:env];
	NSArray *args = [self taskArguments];
	[t setArguments:args];
	NSString *launchPath = [delegate executablePath];
	if (launchPath) {
		[t setLaunchPath:launchPath];
	} else {
		MFLogS(self, @"Delegate returned nil executable path");
		return nil;
	}
	
	// MFLogS(self, @"Executing task with path %@ env %@ args %@", [t launchPath], [t environment], [t arguments]);
	[self setupIOForTask:t];
	[self registerNotificationsForTask:t];
	return t;
}


# pragma mark Mounting mechanics
- (BOOL)setupMountPoint {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *mountPath = [[[self mountPath] stringByExpandingTildeInPath] stringByStandardizingPath];
	BOOL pathExists, isDir, returnValue;
	NSString *errorDescription;
	
	NSAssert(mountPath, @"Attempted to filesystem with nil mountPath.");
		
	pathExists = [fm fileExistsAtPath:mountPath isDirectory:&isDir];
	if (pathExists && isDir == YES) {
		// directory already exists 
		BOOL empty = ([[fm contentsOfDirectoryAtPath:mountPath error:nil] count] == 0);
		BOOL writeable = [fm isWritableFileAtPath:mountPath];
		if (!empty) {
			errorDescription = @"Mount path directory in use.";
			returnValue = NO;
		} else if (!writeable) {
			errorDescription = @"Mount path directory not writeable.";
			returnValue = NO;
		} else {
			returnValue = YES;
		}
	} else if (pathExists && !isDir) {
		errorDescription = @"Mount path is a file, not a directory.";
		returnValue = NO;
	} else {
		if ([fm createDirectoryAtPath:mountPath withIntermediateDirectories:YES attributes:nil error:nil]) {
			returnValue = YES;
		} else {
			errorDescription = @"Mount path could not be created.";
			returnValue = NO;
		}
	}
	
	if (returnValue == NO) {
		NSError *error = [MFError errorWithErrorCode:kMFErrorCodeMountFaliure description:errorDescription];
		[statusInfo setObject:error forKey:kMFSTErrorKey];
		return NO;
	} else {
		return YES;
	}
}

- (void)removeMountPoint {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *mountPath = [[[self mountPath] stringByExpandingTildeInPath] stringByStandardizingPath];
	BOOL pathExists, isDir;
	
	removexattr([mountPath cStringUsingEncoding:NSUTF8StringEncoding],[@"org.mgorbach.macfusion.xattr.uuid" cStringUsingEncoding:NSUTF8StringEncoding],0);
	
	pathExists = [fm fileExistsAtPath:mountPath isDirectory:&isDir];
	if (pathExists && isDir && ([[fm contentsOfDirectoryAtPath:mountPath error:nil] count] == 0)) {
		[fm removeItemAtPath:mountPath error:nil];
	}
}

- (void)mount {
	if ([self.status  isEqual: kMFStatusFSMounted]) {
		return;
	}
	
	[super mount];

	MFLogS(self, @"Mounting");
	self.pauseTimeout = NO;
	self.status = kMFStatusFSWaiting;
	if ([self setupMountPoint] == YES) {
		_task = [self taskForLaunch];
		[[[_task standardOutput] fileHandleForReading] waitForDataInBackgroundAndNotify];
		[_timer invalidate];
		_timer = [self newTimeoutTimer];
		[_task launch];

		// Check if it's desired to add the filesystem to the sidebar
		if ([[self.parameters objectForKey:kMFFSShowInFinderSidebar] boolValue]) {
			[self addFileSystemToFinderSidebar];
		}
		MFLogS(self, @"Task launched OK");
	} else {
		MFLogS(self, @"Mount point could not be created");
		self.status = kMFStatusFSFailed;
	}
}

- (void)unmount {
	[super unmount];

	MFLogS(self, @"Unmounting");
	NSString* path = [[[self mountPath] stringByExpandingTildeInPath] stringByStandardizingPath];
	NSString *taskPath = @"/usr/sbin/diskutil";
	NSMutableArray *taskArguments = [NSMutableArray array];
	NSTask* unmountTask = [[NSTask alloc] init];

	[taskArguments addObject:@"unmount"];
	[taskArguments addObject:path];
	
	[unmountTask setLaunchPath:taskPath];
	[unmountTask setArguments:taskArguments];
	[unmountTask launch];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleTaskDidTerminate:) name:NSTaskDidTerminateNotification object:unmountTask];
	
	/*
	[t waitUntilExit];
	if ([t terminationStatus] != 0)
	{
		MFLogS(self, @"Unmount failed. Unmount terminated with %d",
		[t terminationStatus]);
	}
	 */
}

- (void)addFileSystemToFinderSidebar {
	// Create a reference to the shared favorite's file list
	LSSharedFileListRef favoritesFileList = LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);

	CFURLRef itemURL = (__bridge CFURLRef)[NSURL fileURLWithPath:[[self mountPath] stringByExpandingTildeInPath]];
	CFStringRef itemName=(__bridge CFStringRef)[self name];
	IconRef itemIcon=NULL;
	LSSharedFileListItemRef item=NULL;
	FSRef fileReference;
	SInt16 label;

	[[self mountPath] getFSRef:&fileReference createFileIfNecessary:NO];

	if (favoritesFileList) {
		// Insert an item to the list
		if (GetIconRefFromFileInfo(&fileReference, 0, NULL, kFSCatInfoNone, NULL, kIconServicesUpdateIfNeededFlag, &itemIcon, &label) == noErr){
			MFLogS(self, @"Icon reference cerated successfully: %@", [self iconPath]);
		}

		item=LSSharedFileListInsertItemURL(favoritesFileList, kLSSharedFileListItemLast, itemName, itemIcon, itemURL, NULL, NULL);
		if (item){
			CFRelease(item);
		}
		if (itemIcon) {
			ReleaseIconRef(itemIcon);
		}
	} else {
		return;
	}

	CFRelease(favoritesFileList);
}

- (void)removeFileSystemFromFinderSidebar {
	LSSharedFileListRef favoritesFileList=LSSharedFileListCreate(NULL, kLSSharedFileListFavoriteItems, NULL);
	UInt32 seed;
	CFArrayRef favoritesFileListItems=LSSharedFileListCopySnapshot(favoritesFileList, &seed);
	LSSharedFileListItemRef itemReference;
	CFStringRef	itemName;

	// go through the list of favorites searching for the current item
	for (id item in (__bridge NSArray *)favoritesFileListItems ) {
		itemReference=(__bridge LSSharedFileListItemRef)item;
		itemName=LSSharedFileListItemCopyDisplayName(itemReference);

		if (itemName) {
			//When found proceed to delete it
			if ([(__bridge NSString *)itemName isEqualToString:[self name]]) {
				MFLogS(self, @"Deleting an item named %@", (__bridge NSString *)itemName);
				LSSharedFileListItemRemove(favoritesFileList, itemReference);
			}
			CFRelease(itemName);
		}
	}

	CFRelease(favoritesFileList);
	CFRelease(favoritesFileListItems);
}

# pragma mark Validation
- (NSError *)validateAndSetParameters:(NSDictionary *)params {
	NSError* error;
	if ([self validateParameters:params error:&error]) {
		[self willChangeValueForKey:kMFParameterDict];
		parameters = [params mutableCopy];
		[self didChangeValueForKey:kMFParameterDict];
	} else {
		return error;
	}
	
	return nil;
}

- (BOOL)validateParameters:(NSDictionary*)params error:(NSError **)error
{
	NSDictionary* impliedParams = [self fillParametersWithImpliedValues:params];
	BOOL ok = [delegate validateParameters:impliedParams error:error];
	if (!ok) { 
		// Delegate didn't validate
		// MFLogS(self, @"Delegate didn't validate %@", impliedParams);
		return NO;
	} else {
		// MFLogS(self, @"Delegate did validate %@", impliedParams);
		// Continue validation for general macfusion keys
		if (![impliedParams objectForKey:kMFFSVolumeNameParameter]) {
			if (error) {
				*error = [MFError parameterMissingErrorWithParameterName:kMFFSVolumeNameParameter];	
			}
			return NO;
		}
		if (![impliedParams objectForKey:kMFFSMountPathParameter]) {
			if (error) {
				*error = [MFError parameterMissingErrorWithParameterName:kMFFSMountPathParameter];	
			}
			return NO;
		}
		if (![impliedParams objectForKey:kMFFSUUIDParameter]) {
			if (error) {
				*error = [MFError parameterMissingErrorWithParameterName:kMFFSUUIDParameter];	
			}
			return NO;
		}
	}
	
	return YES;
}

- (BOOL)validateParametersWithError:(NSError **)error {
	return [self validateParameters:parameters error:error];
}

# pragma mark Notification handlers
- (void)handleMountNotification {
	self.status = kMFStatusFSMounted;
	[_timer invalidate];
}

- (void)handleTaskDidTerminate:(NSTask *)task {
	if ([self.status  isEqual: kMFStatusFSMounted]) {
		// We are terminating after a mount has been successful
		// This may not quite be normal (may be for example a bad net connection)
		// But we'll set status to unmounted anyway
		self.status = kMFStatusFSUnmounted;
	} else if ([self.status  isEqual: kMFStatusFSWaiting]) {
		// We terminated while trying to mount
		NSDictionary* dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
									self.uuid, kMFErrorFilesystemKey,
									@"Mount process has terminated unexpectedly.", NSLocalizedDescriptionKey,
									nil];
		[self setError:[MFError errorWithDomain:kMFErrorDomain code:kMFErrorCodeMountFaliure userInfo:dictionary]];
		self.status = kMFStatusFSFailed;
	}
}

- (void)appendToOutput:(NSString *)newOutput {
	NSMutableString *output = [statusInfo objectForKey:kMFSTOutputKey];
	[output appendString:newOutput];
}

- (void)handleDataOnPipe:(NSNotification *)note {
	NSData *pipeData = [[note object] availableData];
	if ([pipeData length] == 0) {
		// pipe is now closed
		return;
	} else {
		NSString *recentOutput = [[NSString alloc] initWithData:pipeData encoding:NSUTF8StringEncoding];
		[self appendToOutput:recentOutput];
		[[note object] waitForDataInBackgroundAndNotify];
		MFLogS(self, recentOutput);
	}
}

- (void)handleUnmountNotification {
	self.status = kMFStatusFSUnmounted;
	[_timer invalidate];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
					  ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
	//MFLogS(self, @"Observes notification keypath %@ object %@, change %@",
	//	   keyPath, object, change);
	
	// Since mount points and side-bar items are created when the user press
	// the 'mount' button, they must be removed on the following circumstances:
	// - requested unmount
	// - failure while mounting the FS
	//
	// remember that the visibility in the sidebar is optional hence the check
	if ([keyPath isEqualToString:kMFSTStatusKey ] && object == self && [[change objectForKey:NSKeyValueChangeNewKey] isEqualToString:kMFStatusFSUnmounted]) {
		if ([[self.parameters objectForKey:kMFFSShowInFinderSidebar] boolValue]) {
			[self removeFileSystemFromFinderSidebar];
		}
		[self removeMountPoint];
	}
	
	if ([keyPath isEqualToString:kMFSTStatusKey ] && object == self && [[change objectForKey:NSKeyValueChangeNewKey] isEqualToString:kMFStatusFSFailed]) {
		if ([[self.parameters objectForKey:kMFFSShowInFinderSidebar] boolValue]) {
			[self removeFileSystemFromFinderSidebar];
		}
		[self removeMountPoint];
	}
	
	if ([keyPath isEqualToString:kMFParameterDict]) {
		[self writeOutData];
	}
}

- (NSTimer *)newTimeoutTimer {
	return [NSTimer scheduledTimerWithTimeInterval:[[[MFPreferences sharedPreferences] getValueForPreference:kMFPrefsTimeout] doubleValue] target:self selector:@selector(handleMountTimeout:) userInfo:nil repeats:NO];
}

- (void)handleMountTimeout:(NSTimer *)theTimer {
	if (_pauseTimeout) {
		// MFLogS(self, @"Timeout paused");
		_timer = [self newTimeoutTimer];
		return;
	}
		
	if (![self isUnmounted] && ![self isMounted]) {
		if (![self isFailedToMount]) {
			MFLogS(self, @"Mount time out detected. Killing task %@ pid %d",
				   _task, [_task processIdentifier]);
			kill([_task processIdentifier], SIGKILL);
			NSDictionary *dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
										self.uuid, kMFErrorFilesystemKey,
										@"Mount has timed out.", NSLocalizedDescriptionKey,
										nil];
			[self setError:[MFError errorWithDomain:kMFErrorDomain code:kMFErrorCodeMountFaliure userInfo:dictionary]];
			self.status = kMFStatusFSFailed;
		}
	}
}

# pragma mark Write out
- (void)writeOutData {
	if ([self isPersistent]) {
		NSString *expandedDirPath = [@"~/Library/Application Support/Macfusion/Filesystems" stringByExpandingTildeInPath];
		
		BOOL isDir;
		if (![[NSFileManager defaultManager] fileExistsAtPath:expandedDirPath isDirectory:&isDir] || !isDir)  {
			NSError *error = nil;
			BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:expandedDirPath withIntermediateDirectories:YES attributes:nil error:&error];
			if (!ok) {
				MFLogS(self, @"Failed to create directory save filesystem %@",[error localizedDescription]);
			}
		}
		
		NSString *fullPath = [self valueForParameterNamed:kMFFSFilePathParameter]; 
		if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
			BOOL deleteOK = [[NSFileManager defaultManager] removeItemAtPath:fullPath error:NULL];
			if (!deleteOK) {
				MFLogS(self, @"Failed to delete old file during save");
			}
		}
		
		BOOL writeOK = [parameters writeToFile:fullPath atomically:NO];
		if (!writeOK) {
			MFLogS(self, @"Failed to write out dictionary to file %@", fullPath);
		}
	}
}

- (NSError *)genericError {
	NSDictionary* dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
								self.uuid, kMFErrorFilesystemKey,
								@"Mount has failed.", NSLocalizedDescriptionKey,
								nil];
	return [MFError errorWithDomain:kMFErrorDomain code:kMFErrorCodeMountFaliure userInfo:dictionary];
}


#pragma mark Accessors and Setters
- (void)setStatus:(NSString *)newStatus {
	if (newStatus && ![newStatus isEqualToString:self.status]) {
		// Hack this a bit so that we can set an error on faliure
		// Do this only if an error hasn't already been set
		[statusInfo setObject:newStatus forKey:kMFSTStatusKey];
			
		if([newStatus isEqualToString:kMFStatusFSFailed]) {
			NSError *error = nil;
			// Ask the delegate for the error
			if ([delegate respondsToSelector:@selector(errorForParameters:output:)] && (error = [delegate errorForParameters:[self parametersWithImpliedValues] output:[statusInfo objectForKey:kMFSTOutputKey]]) && error) {
				[self setError:error];
			} else if (![self error]) {
				// Use a generic error
				[self setError:[self genericError]];
			}
		}
	}
}

- (void)setError:(NSError *)error {
	if (error) {
		[statusInfo setObject:error forKey:kMFSTErrorKey];
	}
}

- (BOOL)pauseTimeout {
	return _pauseTimeout;
}

- (void)setPauseTimeout:(BOOL)p {
	_pauseTimeout = p;
	[_timer invalidate];
	_timer = [self newTimeoutTimer];
}

@synthesize plugin=_plugin;
@end
