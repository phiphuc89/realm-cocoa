////////////////////////////////////////////////////////////////////////////
//
// Copyright 2017 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import <XCTest/XCTest.h>

#import "RLMSyncTestCase.h"

#import "RLMTestUtils.h"

#define APPLY_PERMISSION(ma_permission, ma_user) \
    APPLY_PERMISSION_WITH_MESSAGE(ma_permission, ma_user, @"Setting a permission should work")

#define APPLY_PERMISSION_WITH_MESSAGE(ma_permission, ma_user, ma_message) {                                            \
    XCTestExpectation *ex = [self expectationWithDescription:ma_message];                                              \
    [ma_user applyPermission:ma_permission callback:^(NSError *err) {                                                  \
        XCTAssertNil(err, @"Received an error when applying permission: %@", err);                                     \
        [ex fulfill];                                                                                                  \
    }];                                                                                                                \
    [self waitForExpectationsWithTimeout:10.0 handler:nil];                                                            \
}                                                                                                                      \

static NSURL *makeTestGlobalURL(NSString *name) {
    return [[NSURL alloc] initWithString:[NSString stringWithFormat:@"realm://localhost:9080/%@", name]];
}

@interface ObjectWithPermissions : RLMObject
@property (nonatomic) int value;
@property (nonatomic) RLMArray<RLMPermission *><RLMPermission> *permissions;
@end
@implementation ObjectWithPermissions
@end

@interface LinkToObjectWithPermissions : RLMObject
@property (nonatomic) int value;
@property (nonatomic) ObjectWithPermissions *link;
@property (nonatomic) RLMArray<RLMPermission *><RLMPermission> *permissions;
@end
@implementation LinkToObjectWithPermissions
@end

@interface RLMPermissionsAPITests : RLMSyncTestCase
@property (nonatomic, strong) NSString *currentUsernameBase;

@property (nonatomic, strong) RLMSyncUser *userA;
@property (nonatomic, strong) RLMSyncUser *userB;
@property (nonatomic, strong) RLMSyncUser *userC;

@property (nonatomic, strong) void (^errorBlock)(NSError *);
@end

@implementation RLMPermissionsAPITests

- (void)setUp {
    [super setUp];
    NSString *accountNameBase = [[NSUUID UUID] UUIDString];
    self.currentUsernameBase = accountNameBase;
    NSString *userNameA = [accountNameBase stringByAppendingString:@"a"];
    self.userA = [self logInUserForCredentials:[RLMSyncTestCase basicCredentialsWithName:userNameA register:YES]
                                        server:[RLMSyncTestCase authServerURL]];

    NSString *userNameB = [accountNameBase stringByAppendingString:@"b"];
    self.userB = [self logInUserForCredentials:[RLMSyncTestCase basicCredentialsWithName:userNameB register:YES]
                                        server:[RLMSyncTestCase authServerURL]];

    NSString *userNameC = [accountNameBase stringByAppendingString:@"c"];
    self.userC = [self logInUserForCredentials:[RLMSyncTestCase basicCredentialsWithName:userNameC register:YES]
                                        server:[RLMSyncTestCase authServerURL]];

    RLMSyncManager.sharedManager.errorHandler = ^(NSError *error, __unused RLMSyncSession *session) {
        if (self.errorBlock) {
            self.errorBlock(error);
            self.errorBlock = nil;
        } else {
            XCTFail(@"Error handler should not be called unless explicitly expected. Error: %@", error);
        }
    };
}

- (void)tearDown {
    self.currentUsernameBase = nil;
    [self.userA logOut];
    [self.userB logOut];
    [self.userC logOut];
    RLMSyncManager.sharedManager.errorHandler = nil;
    [super tearDown];
}

#pragma mark - Helper methods

- (NSError *)subscribeToRealm:(RLMRealm *)realm type:(Class)cls where:(NSString *)pred {
    __block NSError *error;
    XCTestExpectation *ex = [self expectationWithDescription:@"Should be able to successfully complete a query"];
    [realm subscribeToObjects:cls where:pred callback:^(__unused RLMResults *results, NSError *err) {
        error = err;
        [ex fulfill];
    }];
    [self waitForExpectations:@[ex] timeout:20.0];
    return error;
}

- (NSURL *)createRealmWithName:(SEL)sel permissions:(void (^)(RLMRealm *realm))block {
    // Create a new Realm with an admin user
    RLMSyncUser *admin = [self createAdminUserForURL:[RLMSyncTestCase authServerURL]
                                            username:[[NSUUID UUID] UUIDString]];

    NSURL *url = makeTestGlobalURL(NSStringFromSelector(sel));
    RLMRealm *adminRealm = [self openRealmForURL:url user:admin];
    [self addSyncObjectsToRealm:adminRealm descriptions:@[@"child-1", @"child-2", @"child-3"]];
    CHECK_COUNT(3, SyncObject, adminRealm);
    [self waitForUploadsForUser:admin realm:adminRealm error:nil];
    [self waitForDownloadsForUser:admin realm:adminRealm error:nil];

    // FIXME: we currently need to add a subscription to get the permissions types sent to us
    [adminRealm refresh];
    CHECK_COUNT(0, SyncObject, adminRealm);
    [self subscribeToRealm:adminRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(3, SyncObject, adminRealm);

    // Set up permissions on the Realm
    [adminRealm transactionWithBlock:^{ block(adminRealm); }];

    // FIXME: we currently need to also add the old realm-level permissions
    RLMSyncPermission *p = [[RLMSyncPermission alloc] initWithRealmPath:[url path]
                                                               identity:self.userA.identity
                                                            accessLevel:RLMSyncAccessLevelRead];
    APPLY_PERMISSION(p, admin);
    p = [[RLMSyncPermission alloc] initWithRealmPath:[url path] identity:self.userB.identity
                                         accessLevel:RLMSyncAccessLevelRead];
    APPLY_PERMISSION(p, admin);
    p = [[RLMSyncPermission alloc] initWithRealmPath:[url path] identity:self.userC.identity
                                         accessLevel:RLMSyncAccessLevelRead];
    APPLY_PERMISSION(p, admin);
    [self waitForUploadsForUser:admin realm:adminRealm error:nil];

    return url;
}

- (void)waitForSync:(RLMRealm *)realm user:(RLMSyncUser *)user {
    [self waitForUploadsForUser:user realm:realm error:nil];
    [self waitForDownloadsForUser:user realm:realm error:nil];
    [realm refresh];
}

#pragma mark - Permissions

static RLMPermissionRole *getRole(RLMRealm *realm, NSString *roleName) {
    return [RLMPermissionRole createOrUpdateInRealm:realm withValue:@{@"name": roleName}];
}

static void addUserToRole(RLMRealm *realm, NSString *roleName, NSString *user) {
    [getRole(realm, roleName).users addObject:[RLMPermissionUser userInRealm:realm withIdentity:user]];
}

static void createPermissions(RLMArray *permissions) {
    [permissions removeAllObjects];
    [permissions addObject:@{@"role": getRole(permissions.realm, @"reader"), @"canRead": @YES, @"cnaQuery": @YES}];
    [permissions addObject:@{@"role": getRole(permissions.realm, @"writer"), @"canWrite": @YES}];
    [permissions addObject:@{@"role": getRole(permissions.realm, @"admin"), @"canSetPermissions": @YES}];
}

- (void)testRealmReadAccess {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMRealmPermission objectInRealm:realm].permissions);
        addUserToRole(realm, @"reader", self.userA.identity);
    }];

    // userA should now be able to open the Realm and see objects
    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    [self subscribeToRealm:userARealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(3, SyncObject, userARealm);
    XCTAssertTrue([userARealm privilegesForRealm].read);

    // userA should not be able to create new objects
    [self addSyncObjectsToRealm:userARealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(6, SyncObject, userARealm);

    [self waitForSync:userARealm user:self.userA];
    CHECK_COUNT(3, SyncObject, userARealm);

    // userB should not be able to read any objects
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    [self subscribeToRealm:userBRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(0, SyncObject, userBRealm);
    XCTAssertFalse([userBRealm privilegesForRealm].read);
}

- (void)testRealmWriteAccess {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMRealmPermission objectInRealm:realm].permissions);

        addUserToRole(realm, @"reader", self.userA.identity);
        addUserToRole(realm, @"writer", self.userA.identity);

        addUserToRole(realm, @"reader", self.userB.identity);
    }];

    // userA should be able to add objects
    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    [self subscribeToRealm:userARealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(3, SyncObject, userARealm);

    [self addSyncObjectsToRealm:userARealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(6, SyncObject, userARealm);

    [self waitForSync:userARealm user:self.userA];
    CHECK_COUNT(6, SyncObject, userARealm);
    XCTAssertTrue([userARealm privilegesForRealm].update);

    // userB's insertions should be reverted
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    [self subscribeToRealm:userBRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(6, SyncObject, userBRealm);

    [self addSyncObjectsToRealm:userBRealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(9, SyncObject, userBRealm);
    [self waitForSync:userBRealm user:self.userB];
    CHECK_COUNT(6, SyncObject, userBRealm);
    XCTAssertFalse([userBRealm privilegesForRealm].update);
}

- (void)testRealmManagePermissions {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMRealmPermission objectInRealm:realm].permissions);

        addUserToRole(realm, @"reader", self.userA.identity);
        addUserToRole(realm, @"writer", self.userA.identity);
        addUserToRole(realm, @"admin", self.userA.identity);

        addUserToRole(realm, @"reader", self.userB.identity);
        addUserToRole(realm, @"writer", self.userB.identity);

        addUserToRole(realm, @"reader", self.userC.identity);
    }];

    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    RLMRealm *userCRealm = [self openRealmForURL:url user:self.userC];

    // userC should initially not be able to write to the Realm
    [self subscribeToRealm:userCRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    XCTAssertFalse([userCRealm privilegesForRealm].update);
    [self addSyncObjectsToRealm:userCRealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    [self waitForSync:userCRealm user:self.userC];
    CHECK_COUNT(3, SyncObject, userCRealm);

    // userB should not be able to grant write permissions to userC
    [userBRealm transactionWithBlock:^{
        addUserToRole(userBRealm, @"writer", self.userC.identity);
    }];
    [self waitForSync:userBRealm user:self.userB];
    [self waitForSync:userCRealm user:self.userC];
    XCTAssertFalse([userCRealm privilegesForRealm].update);
    [self addSyncObjectsToRealm:userCRealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    [self waitForSync:userCRealm user:self.userC];
    CHECK_COUNT(3, SyncObject, userCRealm);

    // userA should be able to grant write permissions to userC
    [userARealm transactionWithBlock:^{
        addUserToRole(userARealm, @"writer", self.userC.identity);
    }];
    [self waitForSync:userARealm user:self.userA];
    [self waitForSync:userCRealm user:self.userC];
    XCTAssertTrue([userCRealm privilegesForRealm].update);
    [self addSyncObjectsToRealm:userCRealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    [self waitForSync:userCRealm user:self.userC];
    CHECK_COUNT(6, SyncObject, userCRealm);
}

- (void)testRealmModifySchema {
    // awkward to test due to that reverts will normally crash
}

- (void)testClassRead {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMClassPermission objectInRealm:realm forClass:SyncObject.class].permissions);
        addUserToRole(realm, @"reader", self.userA.identity);
    }];

    // userA should now be able to open the Realm and see objects
    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    [self subscribeToRealm:userARealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    XCTAssertTrue([userARealm privilegesForRealm].read);
    XCTAssertTrue([userARealm privilegesForClass:SyncObject.class].read);
    XCTAssertTrue([userARealm privilegesForObject:[SyncObject allObjectsInRealm:userARealm].firstObject].read);
    CHECK_COUNT(3, SyncObject, userARealm);

    // userA should not be able to create new objects
    XCTAssertTrue([userARealm privilegesForRealm].update);
    XCTAssertFalse([userARealm privilegesForClass:SyncObject.class].create);
    XCTAssertFalse([userARealm privilegesForClass:SyncObject.class].update);
    [self addSyncObjectsToRealm:userARealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(6, SyncObject, userARealm);

    [self waitForSync:userARealm user:self.userA];
    CHECK_COUNT(3, SyncObject, userARealm);

    // userB should not be able to read any objects
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    [self subscribeToRealm:userBRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    XCTAssertFalse([userBRealm privilegesForRealm].read);
    XCTAssertFalse([userARealm privilegesForClass:SyncObject.class].read);
    CHECK_COUNT(0, SyncObject, userBRealm);
}

- (void)testClassUpdate {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMClassPermission objectInRealm:realm forClass:SyncObject.class].permissions);

        addUserToRole(realm, @"reader", self.userA.identity);
        addUserToRole(realm, @"writer", self.userA.identity);

        addUserToRole(realm, @"reader", self.userB.identity);
    }];

    // userA should be able to mutate objects
    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    [self subscribeToRealm:userARealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    SyncObject *objA = [SyncObject allObjectsInRealm:userARealm].firstObject;

    [userARealm transactionWithBlock:^{
        objA.stringProp = @"new value";
    }];
    [self waitForSync:userARealm user:self.userA];
    XCTAssertEqualObjects(objA.stringProp, @"new value");

    // userB's mutations should be reverted
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    [self subscribeToRealm:userBRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    SyncObject *objB = [SyncObject allObjectsInRealm:userBRealm].firstObject;

    [userBRealm transactionWithBlock:^{
        objB.stringProp = @"new value 2";
    }];
    XCTAssertEqualObjects(objB.stringProp, @"new value 2");
    [self waitForSync:userBRealm user:self.userB];
    XCTAssertEqualObjects(objB.stringProp, @"new value");
}

- (void)testClassCreate {
    NSURL *url = [self createRealmWithName:_cmd permissions:^(RLMRealm *realm) {
        createPermissions([RLMClassPermission objectInRealm:realm forClass:SyncObject.class].permissions);

        addUserToRole(realm, @"reader", self.userA.identity);
        addUserToRole(realm, @"writer", self.userA.identity);

        addUserToRole(realm, @"reader", self.userB.identity);
    }];

    // userA should be able to add objects
    RLMRealm *userARealm = [self openRealmForURL:url user:self.userA];
    [self subscribeToRealm:userARealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(3, SyncObject, userARealm);

    [self addSyncObjectsToRealm:userARealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(6, SyncObject, userARealm);

    [self waitForSync:userARealm user:self.userA];
    CHECK_COUNT(6, SyncObject, userARealm);
    XCTAssertTrue([userARealm privilegesForRealm].update);

    // userB's insertions should be reverted
    RLMRealm *userBRealm = [self openRealmForURL:url user:self.userB];
    [self subscribeToRealm:userBRealm type:[SyncObject class] where:@"TRUEPREDICATE"];
    CHECK_COUNT(6, SyncObject, userBRealm);

    [self addSyncObjectsToRealm:userBRealm descriptions:@[@"child-4", @"child-5", @"child-6"]];
    CHECK_COUNT(9, SyncObject, userBRealm);
    [self waitForSync:userBRealm user:self.userB];
    CHECK_COUNT(6, SyncObject, userBRealm);
    XCTAssertFalse([userBRealm privilegesForRealm].update);
}

- (void)testClassSetPermissions {

}

- (void)testObjectRead {

}

- (void)testObjectTransitiveRead {

}

- (void)testObjectUpdate {

}

- (void)testObjectDelete {

}

- (void)testObjectSetPermissions {

}

@end
