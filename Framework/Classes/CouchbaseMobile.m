//
//  CouchbaseMobile.m
//  Couchbase Mobile
//
//  Created by J Chris Anderson on 3/2/11.
//  Copyright 2011 Couchbase, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

#import "CouchbaseMobile.h"

#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <CommonCrypto/CommonDigest.h>
#include <Security/SecRandom.h>
#include <UIKit/UIApplication.h>

// Erlang entry point
void erl_start(int, char**);

static NSString* const kInternalCouchStartedNotification = @"couchStarted";
static NSString* const kInternalRestartCouchNotification = @"CouchDBRequestRestart";

#define kAdminUserName @"cbmi-local-admin"
#define kAdminPasswordPref @"CouchbaseMobileAdmin"


static const NSTimeInterval kWaitTimeout = 30.0;    // How long to wait for CouchDB to start


@interface CouchbaseMobile ()
@property (readwrite, retain) NSURL* serverURL;
@property (readwrite, retain) NSError* error;
- (BOOL)createDir:(NSString*)dirName;
- (BOOL)createFile:(NSString*)path contents: (NSString*)contents;
- (BOOL)installItemNamed:(NSString*)name
                 fromDir:(NSString*)fromDir
                   toDir:(NSString*)toDir
                 replace:(BOOL)replace;
- (BOOL)installTemplateNamed:(NSString*)name
                     fromDir:(NSString*)fromDir
                       toDir:(NSString*)toDir;
- (BOOL)deleteFile:(NSString*)filename fromDir: (NSString*)fromDir;
- (BOOL) setupAdminAccount;
@end


@implementation CouchbaseMobile


+ (CouchbaseMobile*) startCouchbase: (id<CouchbaseDelegate>)delegate {
    static CouchbaseMobile* sCouchbase;
    NSAssert(!sCouchbase, @"+startCouchbase has already been called");

    sCouchbase = [[self alloc] init];
    sCouchbase.delegate = delegate;
    if (![sCouchbase start]) {
        [sCouchbase release];
        sCouchbase = nil;
    }
    return sCouchbase;
}


- (id) initWithBundlePath: (NSString*)bundlePath {
    NSParameterAssert(bundlePath);
    self = [super init];
    if (self) {
        _bundlePath = [bundlePath copy];

        // rootDirectory defaults to ~/Library/Application Support/CouchbaseMobile.
        // However, it used to be hardcoded to ~/Documents, so for backward compatibility
        // (to keep apps from losing their data) we'll preserve that if we find a telltale
        // ~/Documents/couchdb/ dir.

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask,
                                                             YES);
        NSString* documentsDir = [paths objectAtIndex:0];
        BOOL isDir;
        if ([[NSFileManager defaultManager]
                     fileExistsAtPath: [documentsDir stringByAppendingPathComponent: @"couchdb"]
                          isDirectory: &isDir] && isDir) {
            _rootDirectory = [documentsDir copy];
            NSLog(@"Couchbase: Found db files in ~/Documents, so using that as rootDirectory");
        } else {
            paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
            _rootDirectory = [[[paths objectAtIndex:0]
                                stringByAppendingPathComponent: @"CouchbaseMobile"] copy];
        }
    }
    return self;
}


- (id)init {
    NSString* bundlePath = [[NSBundle mainBundle] pathForResource:@"CouchbaseResources" ofType:nil];
    NSAssert(bundlePath, @"Couldn't find CouchbaseResources bundle in app's Resources directory");
    _autoRestart = YES;
    return [self initWithBundlePath: bundlePath];
}


- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_rootDirectory release];
    [_bundlePath release];
    [_iniFilePath release];
    [_serverURL release];
    [_error release];
    [super dealloc];
}


@synthesize delegate = _delegate, iniFilePath = _iniFilePath, serverURL = _serverURL, error = _error, autoRestart = _autoRestart, logLevel = _logLevel;

- (NSString*) rootDirectory {
    return _rootDirectory;
}

- (void) setRootDirectory:(NSString *)rootDirectory {
    NSParameterAssert([rootDirectory hasPrefix: @"/"]);
    NSAssert(!_started, @"Cannot set rootDirectory after starting server");
    if (rootDirectory != _rootDirectory) {
        [_rootDirectory release];
        _rootDirectory = [rootDirectory copy];
    }
}

- (NSString*) logDirectory {
    return [_rootDirectory stringByAppendingPathComponent:@"log"];
}

- (NSString*) databaseDirectory {
    return [_rootDirectory stringByAppendingPathComponent:@"couchdb"];
}

- (NSString*) localIniFilePath {
    return [_rootDirectory stringByAppendingPathComponent:@"couchdb_local.ini"];
}


- (BOOL) installDefaultDatabase: (NSString*)databasePath {
    NSString* dbDir = self.databaseDirectory;
    return [self createDir: dbDir] &&
            [self installItemNamed: databasePath fromDir:nil toDir: dbDir replace: NO];
}


#pragma mark STARTING COUCHDB:

- (BOOL)start
{
    if (_started)
        return YES;

    _timeStarted = CFAbsoluteTimeGetCurrent();
    if (_logLevel >= 2) {
        NSLog(@"Couchbase: Starting CouchDB, using runtime files at: %@ (built %s, %s)",
              _bundlePath, __DATE__, __TIME__);
        NSLog(@"Couchbase: Storing data in %@", _rootDirectory);
    }

    if(![self createDir: self.logDirectory]
           || ![self createDir: self.databaseDirectory]
           || ![self setupAdminAccount]
           || ![self deleteFile:@"couch.uri" fromDir:_rootDirectory])
    {
        return NO;
    }

    // Customize & install default_ios.ini:
    if (![self installTemplateNamed: @"default_ios.ini"
                            fromDir: _bundlePath
                              toDir: _rootDirectory])
        return NO;
    
    // Redirect stdout somewhere. Otherwise Erlang will lock up in iOS 5.1+ when it calls printf. (CBMI-72)
    NSString* stdoutFile = [self.logDirectory stringByAppendingPathComponent: @"stdout.txt"];
    NSLog(@"Couchbase: Redirecting stdout to %@", stdoutFile);
    freopen([stdoutFile UTF8String], "w+", stdout);

    _started = YES;
    [self performSelector: @selector(startupTimeout) withObject: nil afterDelay: kWaitTimeout];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(couchStarted:)
                                                 name:kInternalCouchStartedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(maybeRestart)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    [self performSelectorInBackground: @selector(erlangThread) withObject: nil];
    return YES;
}

- (BOOL)isServerRunning {
    int port = [_serverURL.port intValue];
    if (!port)
        return NO;
    struct sockaddr_in addr = {sizeof(struct sockaddr_in), AF_INET, htons(port), {0}};
    int sockfd = socket(AF_INET,SOCK_STREAM, 0);
    int result = connect(sockfd,(struct sockaddr*) &addr, sizeof(addr));
    int connect_errno = errno;
    close(sockfd);
    if (_logLevel >= 2 && result != 0)
        NSLog(@"Couchbase: Server not responding (errno=%i)", connect_errno);
    return result == 0;
}

- (void) maybeRestart {
    if (_autoRestart && _serverURL && ![self isServerRunning])
        [self restart];
}

- (void) restart {
    _timeStarted = CFAbsoluteTimeGetCurrent();
    [[NSNotificationCenter defaultCenter]
     postNotificationName:kInternalRestartCouchNotification object:nil];
}


#pragma mark LAUNCHING ERLANG:

// Body of the pthread that runs Erlang (and CouchDB)
- (void)erlangThread {
	const char* erlang_args[21] = {"beam", "--", "-noinput",
        "-kernel", "error_logger", NULL /*kernel log*/,
        "-sasl", "errlog_type", NULL /*log level*/,
        "-sasl", "sasl_error_logger", NULL /*log type*/,
		"-eval", "R = application:start(couch), io:format(\"~w~n\",[R]).",
		"-root", NULL, "-couch_ini", NULL, NULL, NULL, NULL};
    int erlang_argc;
    {
        // Log level. 0 is silent, 1-2 shows errors, 3 shows progress.
        // (The difference between 1 and 2 is that 2 shows CouchDB [info] logs; see below
        erlang_args[5] = _logLevel > 0 ? "tty" : "silent";
        erlang_args[8] = _logLevel >= 3 ? "progress" : "error";
        erlang_args[11] = _logLevel > 0 ? "tty" : "false";

        // Alloc some paths to pass in as args to erl_start:
        NSAutoreleasePool* pool = [NSAutoreleasePool new];
        char* erl_root = strdup([[_bundlePath stringByAppendingPathComponent:@"erlang"]
                                            fileSystemRepresentation]);
        erlang_args[15] = erl_root;
        // Yes, there are up to four layers of .ini files: Default, iOS, app, local.
        erlang_args[17] = strdup([[_bundlePath stringByAppendingPathComponent:@"default.ini"]
                                            fileSystemRepresentation]);
        erlang_args[18] = strdup([[_rootDirectory stringByAppendingPathComponent:
                                            @"default_ios.ini"] fileSystemRepresentation]);
        erlang_argc = 19;
        if (_iniFilePath)
            erlang_args[erlang_argc++] = strdup([_iniFilePath fileSystemRepresentation]);
        erlang_args[erlang_argc++] = strdup([self.localIniFilePath fileSystemRepresentation]);

        // Set some environment variables for Erlang:
        char erl_bin[1024];
        char erl_inetrc[1024];
        sprintf(erl_bin, "%s/erts-5.7.5/bin", erl_root);
        sprintf(erl_inetrc, "%s/erl_inetrc", erl_root);

        setenv("ROOTDIR", erl_root, 1);
        setenv("BINDIR", erl_bin, 1);
        setenv("ERL_INETRC", erl_inetrc, 1);

        [pool drain];
    }

	erl_start(erlang_argc, (char**)erlang_args);     // This never returns (unless Erlang exits)
}


#pragma mark WAITING FOR COUCHDB TO START:

- (void)couchStarted:(NSNotification*)n
{
    // Runs on the Erlang thread, so do as little as possible and return
    [self performSelectorOnMainThread:@selector(notifyCouchStarted:)
                           withObject:n.userInfo
                        waitUntilDone:NO];
}


- (void)notifyCouchStarted:(NSDictionary*)info {
    // Runs on the main thread after the notification that the server has started
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(startupTimeout)
                                               object:nil];
    NSString* urlStr = [info objectForKey:@"uri"];
    NSURL* serverURL = urlStr ? [NSURL URLWithString:urlStr] : nil;
    NSError* error = nil;
    if (serverURL) {
        if (_logLevel >= 2)
            NSLog(@"Couchbase: CouchDB is up and running after %.3f sec at <%@>",
                  (CFAbsoluteTimeGetCurrent() - _timeStarted), serverURL);
    } else {
        NSLog(@"Couchbase: Error: CouchDB returned invalid server URL");
        error = [NSError errorWithDomain:@"Couchbase" code:1 userInfo:nil]; //TODO: Real error
    }

    self.error = error;
    self.serverURL = serverURL; // Will trigger KVO notification

    if (_serverURL)
        [_delegate couchbaseMobile:self didStart:_serverURL];
    else
        [_delegate couchbaseMobile:self failedToStart:_error];
}


- (void)startupTimeout {
    NSLog(@"Couchbase: Error: No startup notification from server engine");
    self.error = [NSError errorWithDomain:@"Couchbase" code:2 userInfo:nil]; //TODO: Real error
    [_delegate couchbaseMobile:self failedToStart:_error];
}


#pragma mark - ADMIN ACCOUNT:


- (NSString*) hexOfBytes:(const uint8_t*)bytes length:(size_t)length {
    char out[2*length+1];
    char *dst = &out[0];
    for( size_t i=0; i<length; i+=1 )
        dst += sprintf(dst,"%02x", bytes[i]);
    return [[[NSString alloc] initWithBytes: out length: 2*length encoding: NSASCIIStringEncoding]
            autorelease];

}


- (NSString*)randomStringOfLength: (size_t)length {
    size_t byteCount = length/2;
    uint8_t bytes[byteCount];
    SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes);
    return [self hexOfBytes: bytes length: byteCount];
}


- (NSString*) hashPassword: (NSString*)password withSalt: (NSString*)salt {
    // Compute the SHA-1 digest of the password concatenated with the salt:
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    NSData* d = [[password stringByAppendingString: salt] dataUsingEncoding: NSUTF8StringEncoding];
    CC_SHA1(d.bytes, d.length, digest);
    return [self hexOfBytes: digest length: sizeof(digest)];
}


- (BOOL) setupAdminAccount {
    NSString* path = self.localIniFilePath;
    NSString* contents = [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil];
    if (contents) {
        NSRange r = [contents rangeOfString: @"\n[admins]\n" kAdminUserName " = "];
        if (r.length > 0)
            return YES;  // already contains an admin section
    } else {
        contents = @"";
    }

    NSString* password = [self randomStringOfLength: 32];
    NSString* salt = [self randomStringOfLength: 32];
    NSString* hashedPassword = [self hashPassword: password withSalt: salt];

    contents = [contents stringByAppendingFormat: @"\n\n[admins]\n%@ = -hashed-%@,%@\n",
                kAdminUserName, hashedPassword, salt];

    NSError* error = nil;
    if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error: &error]) {
        NSLog(@"Couchbase: Error writing file '%@': %@", path, error);
        self.error = error;
        return NO;
    }

    NSUserDefaults* dflts = [NSUserDefaults standardUserDefaults];
    [dflts setObject: password forKey: kAdminPasswordPref];
    [dflts synchronize]; // make sure the password is saved, else it'll be lost

    return YES;
}


- (NSURLCredential*) adminCredential {
    NSString* password = [[NSUserDefaults standardUserDefaults] stringForKey: kAdminPasswordPref];
    if (!password)
        return nil;
    return [NSURLCredential
            credentialWithUser: kAdminUserName
            password: password
            persistence: NSURLCredentialPersistenceForSession];
}


#pragma mark UTILITIES:

- (BOOL)createDir:(NSString*)dirName {
	BOOL isDir=YES;
	NSFileManager *fm= [NSFileManager defaultManager];
	if(![fm fileExistsAtPath:dirName isDirectory:&isDir]) {
        NSError* createError = nil;
		if([fm createDirectoryAtPath:dirName withIntermediateDirectories:YES
                          attributes:nil error:&createError]) {
            if (_logLevel >= 2)
                NSLog(@"Couchbase: Created dir %@", dirName);
        } else {
			NSLog(@"Couchbase: Error creating dir '%@': %@", dirName, createError);
            self.error = createError;
            return NO;
        }
    } else if (!isDir) {
        NSLog(@"Couchbase: Error creating dir '%@': already exists as file", dirName);
        return NO;
    }
    return YES;
}

- (BOOL)createFile:(NSString*)path contents: (NSString*)contents {
    BOOL isDir;
	if(![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
        NSError* error = nil;
        if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error: &error]) {
			NSLog(@"Couchbase: Error creating file '%@': %@", path, error);
            self.error = error;
            return NO;
        }
    } else if (isDir) {
        NSLog(@"Couchbase: Error creating file '%@': already exists as dir", path);
        return NO;
    }
    return YES;
}

// Copies the item if the destination does not exist; _or_ if it's outdated (if 'replace' is true)
- (BOOL)installItemNamed:(NSString*)name
                 fromDir:(NSString*)fromDir
                   toDir:(NSString*)toDir
                 replace:(BOOL)replace
{
	NSString *source = fromDir ? [fromDir stringByAppendingPathComponent: name] : name;
	NSString *target = [toDir stringByAppendingPathComponent: [name lastPathComponent]];

    NSError* error;
	NSFileManager *fm= [NSFileManager defaultManager];
    NSDate* targetModDate = [[fm attributesOfItemAtPath: target error:NULL] fileModificationDate];
    if (targetModDate) {
        if (!replace)
            return YES;     // Told not to overwrite, so return immediately

        NSDate* sourceModDate = [[fm attributesOfItemAtPath: source error:&error]
                                        fileModificationDate];
        if (!sourceModDate) {
            NSLog(@"Couchbase: Unable to read %@: %@", source, error);
            self.error = error;
            return NO;
        }
        if ([targetModDate compare: sourceModDate] >= 0)
            return YES;     // target exists and is at least as new as the source

        // Need to delete target first, or -copyItemAtPath will fail
        if (![fm removeItemAtPath: target error: &error]) {
            NSLog(@"Couchbase: Error installing to %@: %@", target, error);
            self.error = error;
            return NO;
        }
    }

    // OK, do the copy:
    if ([fm copyItemAtPath: source toPath: target error: &error]) {
        if (_logLevel >= 2)
            NSLog(@"Couchbase: Installed %@ into %@", [name lastPathComponent], target);
        return YES;
    } else {
        NSLog(@"Couchbase: Error installing to %@: %@", target, error);
        self.error = error;
        return NO;
    }
}

- (BOOL)deleteFile:(NSString*)filename fromDir: (NSString*)fromDir {
    NSString* path = [fromDir stringByAppendingPathComponent: filename];
	NSFileManager *fm= [NSFileManager defaultManager];
	if([fm fileExistsAtPath:path]) {
        NSError* removeError = nil;
		if (![fm removeItemAtPath:path error:&removeError]) {
            NSLog(@"Couchbase: Error deleting %@: %@", path, removeError);
            self.error = removeError;
            return NO;
        }
	}
    return YES;
}

- (BOOL)installTemplateNamed:(NSString*)name
                     fromDir:(NSString*)fromDir
                       toDir:(NSString*)toDir
{
	NSString *source = fromDir ? [fromDir stringByAppendingPathComponent: name] : name;
	NSString *target = [toDir stringByAppendingPathComponent: [name lastPathComponent]];

    // Get the template contents:
    NSError* error;
    NSMutableString* contents = [NSMutableString stringWithContentsOfFile: source
                                                                 encoding:NSUTF8StringEncoding
                                                                    error: &error];
    if (!contents) {
        NSLog(@"Couchbase: Error installing %@: %@", source, error);
        self.error = error;
        return NO;
    }

    [contents replaceOccurrencesOfString: @"$LOGLEVEL"
                              withString: (_logLevel >= 2 ? @"info" : @"none")
                                 options: 0
                                   range: NSMakeRange(0, contents.length)];
    [contents replaceOccurrencesOfString: @"$APPDIR"
                              withString: [[NSBundle mainBundle] bundlePath]
                              options: 0
                                range: NSMakeRange(0, contents.length)];
    [contents replaceOccurrencesOfString: @"$BUNDLEDIR"
                              withString: _bundlePath
                                 options: 0
                                   range: NSMakeRange(0, contents.length)];
    [contents replaceOccurrencesOfString: @"$INSTALLDIR"
                              withString: _rootDirectory
                                 options: 0
                                   range: NSMakeRange(0, contents.length)];
    NSData* newData = [contents dataUsingEncoding: NSUTF8StringEncoding];

    // Read the destination file:
    NSData* oldData = [NSData dataWithContentsOfFile: target options: 0 error: nil];
    if (oldData && [oldData isEqualToData: newData])
        return YES;   // No need to copy

    if ([newData writeToFile: target options: NSDataWritingFileProtectionNone error: &error]) {
        if (_logLevel >= 2)
            NSLog(@"Couchbase: Installed customized %@ into %@", [name lastPathComponent], target);
        return YES;
    } else {
        NSLog(@"Couchbase: Error installing to %@: %@", target, error);
        self.error = error;
        return NO;
    }
}


@end
