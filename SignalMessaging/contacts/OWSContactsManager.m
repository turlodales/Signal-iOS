//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "OWSContactsManager.h"
#import "Environment.h"
#import "OWSFormat.h"
#import "OWSProfileManager.h"
#import "ViewControllerUtils.h"
#import <Contacts/Contacts.h>
#import <PromiseKit/AnyPromise.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/NSString+OWS.h>
#import <SignalCoreKit/iOSVersions.h>
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalMessaging/UIFont+OWS.h>
#import <SignalServiceKit/NSNotificationCenter+OWS.h>
#import <SignalServiceKit/OWSError.h>
#import <SignalServiceKit/PhoneNumber.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSNotificationName const OWSContactsManagerSignalAccountsDidChangeNotification
    = @"OWSContactsManagerSignalAccountsDidChangeNotification";
NSNotificationName const OWSContactsManagerContactsDidChangeNotification
    = @"OWSContactsManagerContactsDidChangeNotification";

NSString *const OWSContactsManagerCollection = @"OWSContactsManagerCollection";
NSString *const OWSContactsManagerKeyLastKnownContactPhoneNumbers
    = @"OWSContactsManagerKeyLastKnownContactPhoneNumbers";
NSString *const OWSContactsManagerKeyNextFullIntersectionDate = @"OWSContactsManagerKeyNextFullIntersectionDate2";

@interface OWSContactsManager () <SystemContactsFetcherDelegate>

@property (nonatomic) BOOL isContactsUpdateInFlight;
// This reflects the contents of the device phone book and includes
// contacts that do not correspond to any signal account.
@property (atomic) NSArray<Contact *> *allContacts;
@property (atomic) NSDictionary<NSString *, Contact *> *allContactsMap;
@property (atomic) NSArray<SignalAccount *> *signalAccounts;

@property (nonatomic, readonly) SystemContactsFetcher *systemContactsFetcher;
@property (nonatomic, readonly) AnyLRUCache *cnContactCache;
@property (atomic) BOOL isSetup;

@end

#pragma mark -

@implementation OWSContactsManager

- (id)init
{
    self = [super init];
    if (!self) {
        return self;
    }

    _keyValueStore = [[SDSKeyValueStore alloc] initWithCollection:OWSContactsManagerCollection];

    _allContacts = @[];
    _allContactsMap = @{};
    _signalAccounts = @[];
    _systemContactsFetcher = [SystemContactsFetcher new];
    _systemContactsFetcher.delegate = self;
    _cnContactCache = [[AnyLRUCache alloc] initWithMaxSize:50
                                                nseMaxSize:0
                                shouldEvacuateInBackground:YES];

    OWSSingletonAssert();

    AppReadinessRunNowOrWhenAppWillBecomeReady(^{
        [self setup];
    });

    return self;
}

- (void)setup {
    __block NSMutableArray<SignalAccount *> *signalAccounts;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        NSUInteger signalAccountCount = [SignalAccount anyCountWithTransaction:transaction];
        OWSLogInfo(@"loading %lu signal accounts from cache.", (unsigned long)signalAccountCount);

        signalAccounts = [[NSMutableArray alloc] initWithCapacity:signalAccountCount];

        [SignalAccount anyEnumerateWithTransaction:transaction
                                             block:^(SignalAccount *signalAccount, BOOL *stop) {
                                                 [signalAccounts addObject:signalAccount];
                                             }];
    }];
    [self updateSignalAccounts:signalAccounts shouldSetHasLoadedContacts:NO];
}

#pragma mark - System Contact Fetching

// Request contacts access if you haven't asked recently.
- (void)requestSystemContactsOnce
{
    [self requestSystemContactsOnceWithCompletion:nil];
}

- (void)requestSystemContactsOnceWithCompletion:(void (^_Nullable)(NSError *_Nullable error))completion
{
    [self.systemContactsFetcher requestOnceWithCompletion:completion];
}

- (void)fetchSystemContactsOnceIfAlreadyAuthorized
{
    [self.systemContactsFetcher fetchOnceIfAlreadyAuthorized];
}

- (AnyPromise *)userRequestedSystemContactsRefresh
{
    return [AnyPromise promiseWithResolverBlock:^(PMKResolver resolve) {
        [self.systemContactsFetcher userRequestedRefreshWithCompletion:^(NSError *error){
            if (error) {
                OWSLogError(@"refreshing contacts failed with error: %@", error);
            }
            resolve(error ?: @(1));
        }];
    }];
}

- (BOOL)isSystemContactsAuthorized
{
    return self.systemContactsFetcher.isAuthorized;
}

- (BOOL)isSystemContactsDenied
{
    return self.systemContactsFetcher.isDenied;
}

- (BOOL)systemContactsHaveBeenRequestedAtLeastOnce
{
    return self.systemContactsFetcher.systemContactsHaveBeenRequestedAtLeastOnce;
}

- (BOOL)supportsContactEditing
{
    return self.systemContactsFetcher.supportsContactEditing;
}

#pragma mark - CNContacts

- (nullable CNContact *)cnContactWithId:(nullable NSString *)contactId
{
    if (!contactId) {
        return nil;
    }

    CNContact *_Nullable cnContact = (CNContact *)[self.cnContactCache objectForKey:contactId];
    if (cnContact != nil) {
        return cnContact;
    }
    cnContact = [self.systemContactsFetcher fetchCNContactWithContactId:contactId];
    if (cnContact != nil) {
        [self.cnContactCache setObject:cnContact forKey:contactId];
    }
    return cnContact;
}

- (nullable NSData *)avatarDataForCNContactId:(nullable NSString *)contactId
{
    // Don't bother to cache avatar data.
    CNContact *_Nullable cnContact = [self cnContactWithId:contactId];
    return [Contact avatarDataForCNContact:cnContact];
}

- (nullable UIImage *)avatarImageForCNContactId:(nullable NSString *)contactId
{
    if (contactId == nil) {
        return nil;
    }
    NSData *_Nullable avatarData = [self avatarDataForCNContactId:contactId];
    if (avatarData == nil) {
        return nil;
    }
    if ([avatarData ows_isValidImage]) {
        OWSLogWarn(@"Invalid image.");
        return nil;
    }
    UIImage *_Nullable avatarImage = [UIImage imageWithData:avatarData];
    if (avatarImage == nil) {
        OWSLogWarn(@"Could not load image.");
        return nil;
    }
    return avatarImage;
}

#pragma mark - SystemContactsFetcherDelegate

- (void)systemContactsFetcher:(SystemContactsFetcher *)systemsContactsFetcher
              updatedContacts:(NSArray<Contact *> *)contacts
                isUserRequested:(BOOL)isUserRequested
{
    BOOL shouldClearStaleCache;
    // On iOS 11.2, only clear the contacts cache if the fetch was initiated by the user.
    // iOS 11.2 rarely returns partial fetches and we use the cache to prevent contacts from
    // periodically disappearing from the UI.
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(11, 2) && !SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(11, 3)) {
        shouldClearStaleCache = isUserRequested;
    } else {
        shouldClearStaleCache = YES;
    }
    [self updateWithContacts:contacts
                      didLoad:YES
              isUserRequested:isUserRequested
        shouldClearStaleCache:shouldClearStaleCache];
}

- (void)systemContactsFetcher:(SystemContactsFetcher *)systemContactsFetcher
       hasAuthorizationStatus:(enum ContactStoreAuthorizationStatus)authorizationStatus
{
    if (authorizationStatus == ContactStoreAuthorizationStatusRestricted
        || authorizationStatus == ContactStoreAuthorizationStatusDenied) {
        // Clear the contacts cache if access to the system contacts is revoked.
        [self updateWithContacts:@[] didLoad:NO isUserRequested:NO shouldClearStaleCache:YES];
    }
}

#pragma mark - Intersection

- (NSSet<NSString *> *)phoneNumbersForIntersectionWithContacts:(NSArray<Contact *> *)contacts
{
    OWSAssertDebug(contacts);

    NSMutableSet<NSString *> *phoneNumbers = [NSMutableSet set];

    for (Contact *contact in contacts) {
        [phoneNumbers addObjectsFromArray:contact.e164sForIntersection];
    }
    return [phoneNumbers copy];
}

- (void)intersectContacts:(NSArray<Contact *> *)contacts
          isUserRequested:(BOOL)isUserRequested
               completion:(void (^)(NSError *_Nullable error))completion
{
    OWSAssertDebug(contacts);
    OWSAssertDebug(completion);
    OWSAssertIsOnMainThread();


    dispatch_async(self.intersectionQueue, ^{
        __block BOOL isFullIntersection = YES;
        __block BOOL isRegularlyScheduledRun = NO;
        __block NSSet<NSString *> *allContactPhoneNumbers;
        __block NSSet<NSString *> *phoneNumbersForIntersection;
        __block NSMutableSet<SignalRecipient *> *existingRegisteredRecipients = [NSMutableSet new];
        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
            // Contact updates initiated by the user should always do a full intersection.
            if (!isUserRequested) {
                NSDate *_Nullable nextFullIntersectionDate =
                    [self.keyValueStore getDate:OWSContactsManagerKeyNextFullIntersectionDate transaction:transaction];
                if (nextFullIntersectionDate && [nextFullIntersectionDate isAfterNow]) {
                    isFullIntersection = NO;
                } else {
                    isRegularlyScheduledRun = YES;
                }
            }

            [SignalRecipient anyEnumerateWithTransaction:transaction
                                                   block:^(SignalRecipient *signalRecipient, BOOL *stop) {
                                                       if (signalRecipient.devices.count > 0) {
                                                           [existingRegisteredRecipients addObject:signalRecipient];
                                                       }
                                                   }];

            allContactPhoneNumbers = [self phoneNumbersForIntersectionWithContacts:contacts];
            phoneNumbersForIntersection = allContactPhoneNumbers;

            if (!isFullIntersection) {
                // Do a "delta" intersection instead of a "full" intersection:
                // only intersect new contacts which were not in the last successful
                // "full" intersection.
                NSSet<NSString *> *_Nullable lastKnownContactPhoneNumbers =
                    [self.keyValueStore getObjectForKey:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                            transaction:transaction];
                if (lastKnownContactPhoneNumbers) {
                    // Do a "delta" sync which only intersects phone numbers not included
                    // in the last full intersection.
                    NSMutableSet<NSString *> *newPhoneNumbers = [allContactPhoneNumbers mutableCopy];
                    [newPhoneNumbers minusSet:lastKnownContactPhoneNumbers];
                    phoneNumbersForIntersection = newPhoneNumbers;
                } else {
                    // Without a list of "last known" contact phone numbers, we'll have to do a full intersection.
                    isFullIntersection = YES;
                }
            }
        }];
        OWSAssertDebug(phoneNumbersForIntersection);

        if (phoneNumbersForIntersection.count < 1) {
            OWSLogInfo(@"Skipping intersection; no contacts to intersect.");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(nil);
            });
            return;
        } else if (isFullIntersection) {
            OWSLogInfo(@"Doing full intersection with %zu contacts.", phoneNumbersForIntersection.count);
        } else {
            OWSLogInfo(@"Doing delta intersection with %zu contacts.", phoneNumbersForIntersection.count);
        }

        [self intersectContacts:phoneNumbersForIntersection
            retryDelaySeconds:1.0
            success:^(NSSet<SignalRecipient *> *registeredRecipients) {
                if (isRegularlyScheduledRun) {
                    NSMutableSet<SignalRecipient *> *newSignalRecipients = [registeredRecipients mutableCopy];
                    [newSignalRecipients minusSet:existingRegisteredRecipients];

                    if (newSignalRecipients.count == 0) {
                        OWSLogInfo(@"No new recipients.");
                    } else {
                        __block NSSet<NSString *> *_Nullable lastKnownContactPhoneNumbers;
                        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
                            lastKnownContactPhoneNumbers =
                                [self.keyValueStore getObjectForKey:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                                        transaction:transaction];
                        }];

                        if (lastKnownContactPhoneNumbers != nil && lastKnownContactPhoneNumbers.count > 0) {
                            [OWSNewAccountDiscovery.shared discoveredNewRecipients:newSignalRecipients];
                        } else {
                            OWSLogInfo(@"skipping new recipient notification for first successful contact sync.");
                        }
                    }
                }

                [self markIntersectionAsComplete:allContactPhoneNumbers isFullIntersection:isFullIntersection];

                completion(nil);
            }
            failure:^(NSError *error) {
                completion(error);
            }];
    });
}

- (void)markIntersectionAsComplete:(NSSet<NSString *> *)phoneNumbersForIntersection
                isFullIntersection:(BOOL)isFullIntersection
{
    OWSAssertDebug(phoneNumbersForIntersection.count > 0);

    dispatch_async(self.intersectionQueue, ^{
        DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
            if (isFullIntersection) {
                // replace last known numbers
                [self.keyValueStore setObject:phoneNumbersForIntersection
                                          key:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                  transaction:transaction];

                const NSUInteger contactCount = phoneNumbersForIntersection.count;

                NSDate *nextFullIntersectionDate = [NSDate dateWithTimeIntervalSinceNow:RemoteConfig.cdsSyncInterval];
                OWSLogDebug(@"contactCount: %lu, currentDate: %@, nextFullIntersectionDate: %@",
                    (unsigned long)contactCount,
                    [NSDate new],
                    nextFullIntersectionDate);

                [self.keyValueStore setDate:nextFullIntersectionDate
                                        key:OWSContactsManagerKeyNextFullIntersectionDate
                                transaction:transaction];
            } else {
                NSSet<NSString *> *_Nullable lastKnownContactPhoneNumbers =
                    [self.keyValueStore getObjectForKey:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                            transaction:transaction];

                // If a user has a "flaky" address book, perhaps a network linked directory that
                // goes in and out of existence, we could get thrashing between what the last
                // known set is, causing us to re-intersect contacts many times within the debounce
                // interval. So while we're doing incremental intersections, we *accumulate*,
                // rather than replace the set of recently intersected contacts.
                if ([lastKnownContactPhoneNumbers isKindOfClass:NSSet.class]) {
                    NSSet<NSString *> *_Nullable accumulatedSet =
                        [lastKnownContactPhoneNumbers setByAddingObjectsFromSet:phoneNumbersForIntersection];

                    // replace last known numbers
                    [self.keyValueStore setObject:accumulatedSet
                                              key:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                      transaction:transaction];
                } else {
                    // replace last known numbers
                    [self.keyValueStore setObject:phoneNumbersForIntersection
                                              key:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                      transaction:transaction];
                }
            }
        });
    });
}

- (void)intersectContacts:(NSSet<NSString *> *)phoneNumbers
        retryDelaySeconds:(double)retryDelaySeconds
                  success:(void (^)(NSSet<SignalRecipient *> *))successParameter
                  failure:(void (^)(NSError *))failureParameter
{
    OWSAssertDebug(phoneNumbers.count > 0);
    OWSAssertDebug(retryDelaySeconds > 0);
    OWSAssertDebug(successParameter);
    OWSAssertDebug(failureParameter);

    void (^success)(NSSet<SignalRecipient *> *) = ^(NSSet<SignalRecipient *> *registeredRecipients) {
        OWSLogInfo(@"Successfully intersected contacts.");
        successParameter(registeredRecipients);
    };
    void (^failure)(NSError *) = ^(NSError *error) {
        double delay = retryDelaySeconds;
        BOOL isRateLimitingError = NO;
        BOOL shouldRetry = YES;

        if ([error isKindOfClass:[OWSContactDiscoveryError class]]) {
            OWSContactDiscoveryError *cdsError = (OWSContactDiscoveryError *)error;
            isRateLimitingError = (cdsError.code == OWSContactDiscoveryErrorCodeRateLimit);
            shouldRetry = cdsError.retrySuggested;
            if (cdsError.retryAfterDate) {
                delay = MAX(cdsError.retryAfterDate.timeIntervalSinceNow, delay);
            }
        }

        if (isRateLimitingError) {
            OWSLogError(@"Contact intersection hit rate limit with error: %@", error);
            failureParameter(error);
            return;
        }
        if (!shouldRetry) {
            OWSLogError(@"ContactDiscoveryError suggests not to retry. Aborting without rescheduling.");
            failureParameter(error);
            return;
        }

        OWSLogWarn(@"Failed to intersect contacts with error: %@. Rescheduling", error);

        // Retry with exponential backoff.
        //
        // TODO: Abort if another contact intersection succeeds in the meantime.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self intersectContacts:phoneNumbers
                  retryDelaySeconds:retryDelaySeconds * 2.0
                            success:successParameter
                            failure:failureParameter];
        });
    };
    OWSContactDiscoveryTask *discoveryTask = [[OWSContactDiscoveryTask alloc] initWithPhoneNumbers:phoneNumbers];
    [discoveryTask performAtQoS:QOS_CLASS_USER_INITIATED
                  callbackQueue:dispatch_get_main_queue()
                        success:success
                        failure:failure];
}

- (void)updateWithContacts:(NSArray<Contact *> *)contacts
                   didLoad:(BOOL)didLoad
           isUserRequested:(BOOL)isUserRequested
     shouldClearStaleCache:(BOOL)shouldClearStaleCache
{
    dispatch_async(self.intersectionQueue, ^{
        NSMutableArray<Contact *> *allContacts = [contacts mutableCopy];
        NSMutableDictionary<NSString *, Contact *> *allContactsMap = [NSMutableDictionary new];
        for (Contact *contact in contacts) {
            for (PhoneNumber *phoneNumber in contact.parsedPhoneNumbers) {
                NSString *phoneNumberE164 = phoneNumber.toE164;

                // Ignore any system contact records for the local contact.
                // For the local user we never want to show the avatar /
                // name that you have entered for yourself in your system
                // contacts. Instead, we always want to display your profile
                // name and avatar.
                BOOL isLocalContact = [phoneNumberE164 isEqualToString:TSAccountManager.localNumber];
                if (isLocalContact) {
                    [allContacts removeObject:contact];
                } else if (phoneNumberE164.length > 0) {
                    allContactsMap[phoneNumberE164] = contact;
                }
            }
        }

        NSArray<Contact *> *sortedContacts = [allContacts
            sortedArrayUsingComparator:[Contact comparatorSortingNamesByFirstThenLast:self.shouldSortByGivenName]];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.allContacts = sortedContacts;
            self.allContactsMap = [allContactsMap copy];
            [self.cnContactCache removeAllObjects];

            [[NSNotificationCenter defaultCenter]
                postNotificationNameAsync:OWSContactsManagerContactsDidChangeNotification
                                   object:nil];

            [self intersectContacts:allContacts
                    isUserRequested:isUserRequested
                         completion:^(NSError *_Nullable error) {
                             if (error != nil) {
                                 OWSFailDebug(@"Error: %@", error);
                                 return;
                             }
                             [OWSContactsManager
                                 buildSignalAccountsForContacts:sortedContacts
                                          shouldClearStaleCache:shouldClearStaleCache
                                                     completion:^(NSArray<SignalAccount *> *signalAccounts) {
                                                         [self updateSignalAccounts:signalAccounts
                                                             shouldSetHasLoadedContacts:didLoad];
                                                     }];
                         }];
        });
    });
}

- (void)updateSignalAccounts:(NSArray<SignalAccount *> *)signalAccounts
    shouldSetHasLoadedContacts:(BOOL)shouldSetHasLoadedContacts
{
    OWSAssertIsOnMainThread();

    BOOL hadLoadedContacts = self.hasLoadedContacts;
    if (shouldSetHasLoadedContacts) {
        _hasLoadedContacts = YES;
    }

    if ([signalAccounts isEqual:self.signalAccounts]) {
        OWSLogDebug(@"SignalAccounts unchanged.");
        self.isSetup = YES;

        if (hadLoadedContacts != self.hasLoadedContacts) {
            [[NSNotificationCenter defaultCenter]
                postNotificationNameAsync:OWSContactsManagerSignalAccountsDidChangeNotification
                                   object:nil];
        }

        return;
    }

    NSMutableArray<SignalServiceAddress *> *allAddresses = [NSMutableArray new];
    for (SignalAccount *signalAccount in signalAccounts) {
        [allAddresses addObject:signalAccount.recipientAddress];
    }

    self.signalAccounts = [self sortSignalAccountsWithSneakyTransaction:signalAccounts];

    [self.profileManagerImpl setContactAddresses:allAddresses];

    self.isSetup = YES;

    [[NSNotificationCenter defaultCenter]
        postNotificationNameAsync:OWSContactsManagerSignalAccountsDidChangeNotification
                           object:nil];
}

- (nullable NSString *)cachedContactNameForAddress:(SignalServiceAddress *)address
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address];
    return [self cachedContactNameForAddress:address signalAccount:signalAccount];
}

- (nullable NSString *)cachedContactNameForAddress:(SignalServiceAddress *)address
                                       transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address);
    OWSAssertDebug(transaction);

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address transaction:transaction];
    NSString *_Nullable phoneNumber = nil;
    if (signalAccount == nil) {
        // cachedContactNameForAddress only needs the phone number
        // if signalAccount is nil.
        phoneNumber = [self phoneNumberForAddress:address transaction:transaction];
    }
    return [self cachedContactNameForAddress:address signalAccount:signalAccount phoneNumber:phoneNumber];
}

- (nullable NSString *)cachedContactNameForAddress:(SignalServiceAddress *)address
                                     signalAccount:(nullable SignalAccount *)signalAccount
{
    NSString *_Nullable phoneNumber = nil;
    if (signalAccount == nil) {
        // cachedContactNameForAddress only needs the phone number
        // if signalAccount is nil.
        phoneNumber = [self phoneNumberForAddress:address];
    }
    return [self cachedContactNameForAddress:address signalAccount:signalAccount phoneNumber:phoneNumber];
}

- (nullable NSString *)cachedContactNameForAddress:(SignalServiceAddress *)address
                                     signalAccount:(nullable SignalAccount *)signalAccount
                                       phoneNumber:(nullable NSString *)phoneNumber
{
    OWSAssertDebug(address);

    if (!signalAccount) {
        // search system contacts for no-longer-registered signal users, for which there will be no SignalAccount
        Contact *_Nullable nonSignalContact = self.allContactsMap[phoneNumber];
        if (!nonSignalContact) {
            return nil;
        }
        return nonSignalContact.fullName;
    }

    // Name may be either the nickname or the full name of the contact
    NSString *fullName = signalAccount.contactPreferredDisplayName;
    if (fullName.length == 0) {
        return nil;
    }

    NSString *multipleAccountLabelText = signalAccount.multipleAccountLabelText;
    if (multipleAccountLabelText.length == 0) {
        return fullName;
    }

    return [NSString stringWithFormat:@"%@ (%@)", fullName, multipleAccountLabelText];
}

- (nullable NSPersonNameComponents *)cachedContactNameComponentsForAddress:(SignalServiceAddress *)address
                                                               transaction:(SDSAnyReadTransaction *)transaction
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address transaction:transaction];
    NSString *_Nullable phoneNumber = nil;
    if (signalAccount == nil) {
        // We only need the phone number if signalAccount is nil.
        phoneNumber = [self phoneNumberForAddress:address transaction:transaction];
    }

    return [self cachedContactNameComponentsForSignalAccount:signalAccount phoneNumber:phoneNumber];
}

- (nullable NSPersonNameComponents *)cachedContactNameComponentsForAddress:(SignalServiceAddress *)address
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address];
    NSString *_Nullable phoneNumber = nil;
    if (signalAccount == nil) {
        // We only need the phone number if signalAccount is nil.
        phoneNumber = [self phoneNumberForAddress:address];
    }

    return [self cachedContactNameComponentsForSignalAccount:signalAccount phoneNumber:phoneNumber];
}

- (nullable NSPersonNameComponents *)cachedContactNameComponentsForSignalAccount:(nullable SignalAccount *)signalAccount
                                                                     phoneNumber:(nullable NSString *)phoneNumber
{
    if (!signalAccount) {
        // search system contacts for no-longer-registered signal users, for which there will be no SignalAccount
        Contact *_Nullable nonSignalContact = self.allContactsMap[phoneNumber];
        if (!nonSignalContact) {
            return nil;
        }
        NSPersonNameComponents *nameComponents = [NSPersonNameComponents new];
        nameComponents.givenName = nonSignalContact.firstName;
        nameComponents.familyName = nonSignalContact.lastName;
        nameComponents.nickname = nonSignalContact.nickname;
        return nameComponents;
    }

    return signalAccount.contactPersonNameComponents;
}

- (nullable NSString *)phoneNumberForAddress:(SignalServiceAddress *)address
{
    if (address.phoneNumber != nil) {
        return address.phoneNumber;
    }

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address];
    return signalAccount.recipientPhoneNumber;
}

- (nullable NSString *)phoneNumberForAddress:(SignalServiceAddress *)address
                                 transaction:(SDSAnyReadTransaction *)transaction
{
    if (address.phoneNumber != nil) {
        return [address.phoneNumber filterStringForDisplay];
    }

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address transaction:transaction];
    return [signalAccount.recipientPhoneNumber filterStringForDisplay];
}

#pragma mark - View Helpers

- (BOOL)phoneNumber:(PhoneNumber *)phoneNumber1 matchesNumber:(PhoneNumber *)phoneNumber2
{
    return [phoneNumber1.toE164 isEqualToString:phoneNumber2.toE164];
}

#pragma mark - Whisper User Management

- (BOOL)isSystemContactWithPhoneNumber:(NSString *)phoneNumber
{
    OWSAssertDebug(phoneNumber.length > 0);

    return self.allContactsMap[phoneNumber] != nil;
}

- (BOOL)isSystemContactWithAddress:(SignalServiceAddress *)address
{
    NSString *phoneNumber = address.phoneNumber;
    if (phoneNumber.length == 0) {
        return NO;
    }
    return [self isSystemContactWithPhoneNumber:phoneNumber];
}

- (BOOL)isSystemContactWithSignalAccount:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    return [self hasSignalAccountForAddress:address];
}

- (BOOL)isSystemContactWithSignalAccount:(SignalServiceAddress *)address
                             transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address.isValid);

    return [self hasSignalAccountForAddress:address transaction:transaction];
}

- (BOOL)hasNameInSystemContactsForAddress:(SignalServiceAddress *)address
{
    return [self cachedContactNameForAddress:address].length > 0;
}

- (BOOL)hasNameInSystemContactsForAddress:(SignalServiceAddress *)address
                              transaction:(SDSAnyReadTransaction *)transaction
{
    return [self cachedContactNameForAddress:address transaction:transaction].length > 0;
}

- (NSString *)displayNameForThread:(TSThread *)thread transaction:(SDSAnyReadTransaction *)transaction
{
    if (thread.isNoteToSelf) {
        return MessageStrings.noteToSelf;
    } else if ([thread isKindOfClass:TSContactThread.class]) {
        TSContactThread *contactThread = (TSContactThread *)thread;
        return [self displayNameForAddress:contactThread.contactAddress transaction:transaction];
    } else if ([thread isKindOfClass:TSGroupThread.class]) {
        TSGroupThread *groupThread = (TSGroupThread *)thread;
        return groupThread.groupNameOrDefault;
    } else {
        OWSFailDebug(@"unexpected thread: %@", thread);
        return @"";
    }
}

- (NSString *)displayNameForThreadWithSneakyTransaction:(TSThread *)thread
{
    if (thread.isNoteToSelf) {
        return MessageStrings.noteToSelf;
    } else if ([thread isKindOfClass:TSContactThread.class]) {
        TSContactThread *contactThread = (TSContactThread *)thread;
        __block NSString *name;
        [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
            name = [self displayNameForAddress:contactThread.contactAddress transaction:transaction];
        }];
        return name;
    } else if ([thread isKindOfClass:TSGroupThread.class]) {
        TSGroupThread *groupThread = (TSGroupThread *)thread;
        return groupThread.groupNameOrDefault;
    } else {
        OWSFailDebug(@"unexpected thread: %@", thread);
        return @"";
    }
}

- (NSString *)unknownContactName
{
    return NSLocalizedString(
        @"UNKNOWN_CONTACT_NAME", @"Displayed if for some reason we can't determine a contacts phone number *or* name");
}

- (nullable NSString *)nameFromSystemContactsForAddress:(SignalServiceAddress *)address
{
    return [self cachedContactNameForAddress:address];
}

- (nullable NSString *)nameFromSystemContactsForAddress:(SignalServiceAddress *)address
                                            transaction:(SDSAnyReadTransaction *)transaction
{
    return [self cachedContactNameForAddress:address transaction:transaction];
}

- (NSString *)displayNameForAddress:(SignalServiceAddress *)address transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address.isValid);

    // Prefer a saved name from system contacts, if available.
    //
    // We don't need to filterStringForDisplay(); this value is filtered within phoneNumberForAddress,
    // Contact or SignalAccount.
    NSString *_Nullable savedContactName = [self cachedContactNameForAddress:address transaction:transaction];
    if (savedContactName.length > 0) {
        return savedContactName;
    }

    // We don't need to filterStringForDisplay(); this value is filtered within OWSUserProfile.
    NSString *_Nullable profileName = [self.profileManager fullNameForAddress:address transaction:transaction];
    // Include the profile name, if set.
    if (profileName.length > 0) {
        return profileName;
    }

    // We don't need to filterStringForDisplay(); this value is filtered within phoneNumberForAddress.
    NSString *_Nullable phoneNumber = [self phoneNumberForAddress:address transaction:transaction];
    if (phoneNumber.length > 0) {
        phoneNumber = [PhoneNumber bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber:phoneNumber];
        if (phoneNumber.length > 0) {
            return phoneNumber;
        }
    }

    // We don't need to filterStringForDisplay(); usernames are strictly filtered.
    NSString *_Nullable username = [self.profileManagerImpl usernameForAddress:address transaction:transaction];
    if (username.length > 0) {
        username = [CommonFormats formatUsername:username];
        return username;
    }

    [self.bulkProfileFetch fetchProfileWithAddress:address];

    return self.unknownUserLabel;
}

- (NSString *)displayNameForAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    __block NSString *displayName;

    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        displayName = [self displayNameForAddress:address transaction:transaction];
    }];

    return displayName;
}

- (NSString *)unknownUserLabel
{
    return NSLocalizedString(@"UNKNOWN_USER", @"Label indicating an unknown user.");
}

- (NSString *_Nonnull)displayNameForSignalAccount:(SignalAccount *)signalAccount
{
    OWSAssertDebug(signalAccount);

    return [self displayNameForAddress:signalAccount.recipientAddress];
}

- (NSString *)shortDisplayNameForAddress:(SignalServiceAddress *)address
                             transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address.isValid);

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address transaction:transaction];
    if (signalAccount != nil) {
        NSString *_Nullable nickname = signalAccount.contactNicknameIfAvailable;
        if (nickname.length > 0) {
            return nickname;
        }
    }

    NSPersonNameComponents *_Nullable nameComponents = [self nameComponentsForAddress:address transaction:transaction];
    if (!nameComponents) {
        return [self displayNameForAddress:address transaction:transaction];
    }

    static NSPersonNameComponentsFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSPersonNameComponentsFormatter new];
        formatter.style = NSPersonNameComponentsFormatterStyleShort;
    });

    return [formatter stringFromPersonNameComponents:nameComponents];
}

- (nullable NSPersonNameComponents *)nameComponentsForAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    NSPersonNameComponents *_Nullable savedContactNameComponents = [self cachedContactNameComponentsForAddress:address];
    if (savedContactNameComponents) {
        return savedContactNameComponents;
    }

    __block NSPersonNameComponents *_Nullable profileNameComponents;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        profileNameComponents = [self.profileManagerImpl nameComponentsForAddress:address transaction:transaction];
    }];
    return profileNameComponents;
}

- (nullable NSPersonNameComponents *)nameComponentsForAddress:(SignalServiceAddress *)address
                                                  transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address.isValid);

    NSPersonNameComponents *_Nullable savedContactNameComponents =
        [self cachedContactNameComponentsForAddress:address transaction:transaction];
    if (savedContactNameComponents) {
        return savedContactNameComponents;
    }

    return [self.profileManagerImpl nameComponentsForAddress:address transaction:transaction];
}

- (nullable SignalAccount *)fetchSignalAccountForAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address);

    __block SignalAccount *_Nullable result;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        result = [self.modelReadCaches.signalAccountReadCache getSignalAccountWithAddress:address
                                                                              transaction:transaction];
    }];
    return result;
}

- (nullable SignalAccount *)fetchSignalAccountForAddress:(SignalServiceAddress *)address
                                             transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(address);
    OWSAssertDebug(transaction);

    return [self.modelReadCaches.signalAccountReadCache getSignalAccountWithAddress:address transaction:transaction];
}

- (SignalAccount *)fetchOrBuildSignalAccountForAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address);

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address];
    return (signalAccount ?: [[SignalAccount alloc] initWithSignalServiceAddress:address]);
}

- (BOOL)hasSignalAccountForAddress:(SignalServiceAddress *)address
{
    return [self fetchSignalAccountForAddress:address] != nil;
}

- (BOOL)hasSignalAccountForAddress:(SignalServiceAddress *)address transaction:(SDSAnyReadTransaction *)transaction
{
    return [self fetchSignalAccountForAddress:address transaction:transaction] != nil;
}

- (nullable NSData *)profileImageDataForAddressWithSneakyTransaction:(nullable SignalServiceAddress *)address
{
    if (address == nil) {
        OWSFailDebug(@"address was unexpectedly nil");
        return nil;
    }

    __block NSData *_Nullable data;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        data = [self.profileManager profileAvatarDataForAddress:address transaction:transaction];
    }];
    return data;
}

- (BOOL)shouldSortByGivenName
{
    return [[CNContactsUserDefaults sharedDefaults] sortOrder] == CNContactSortOrderGivenName;
}

- (NSString *)comparableNameForAddress:(SignalServiceAddress *)address transaction:(SDSAnyReadTransaction *)transaction
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForAddress:address transaction:transaction];
    if (!signalAccount) {
        signalAccount = [[SignalAccount alloc] initWithSignalServiceAddress:address];
    }

    return [self comparableNameForSignalAccount:signalAccount transaction:transaction];
}

- (nullable NSString *)comparableNameForContact:(nullable Contact *)contact
{
    if (contact == nil) {
        return nil;
    }

    if (self.shouldSortByGivenName) {
        return contact.comparableNameFirstLast;
    }

    return contact.comparableNameLastFirst;
}

- (NSString *)comparableNameForSignalAccount:(SignalAccount *)signalAccount
{
    NSString *_Nullable name = [self comparableNameForContact:signalAccount.contact];

    if (name.length > 0) {
        return name;
    }

    NSString *_Nullable phoneNumber = signalAccount.recipientPhoneNumber;
    if (phoneNumber != nil) {
        Contact *_Nullable contact = self.allContactsMap[phoneNumber];
        NSString *_Nullable comparableContactName = [self comparableNameForContact:contact];
        if (comparableContactName.length > 0) {
            return comparableContactName;
        }
    }

    __block NSPersonNameComponents *_Nullable nameComponents;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        nameComponents = [self nameComponentsForAddress:signalAccount.recipientAddress transaction:transaction];
    }];

    if (nameComponents != nil && nameComponents.givenName.length > 0 && nameComponents.familyName.length > 0) {
        NSString *leftName = self.shouldSortByGivenName ? nameComponents.givenName : nameComponents.familyName;
        NSString *rightName = self.shouldSortByGivenName ? nameComponents.familyName : nameComponents.givenName;
        return [NSString stringWithFormat:@"%@\t%@", leftName, rightName];
    }

    // Fall back to non-contact display name.
    return [self displayNameForSignalAccount:signalAccount];
}

- (NSString *)comparableNameForSignalAccount:(SignalAccount *)signalAccount
                                 transaction:(SDSAnyReadTransaction *)transaction
{
    NSString *_Nullable name = [self comparableNameForContact:signalAccount.contact];

    if (name.length > 0) {
        return name;
    }

    NSString *_Nullable phoneNumber = signalAccount.recipientPhoneNumber;
    if (phoneNumber != nil) {
        Contact *_Nullable contact = self.allContactsMap[phoneNumber];
        NSString *_Nullable comparableContactName = [self comparableNameForContact:contact];
        if (comparableContactName.length > 0) {
            return comparableContactName;
        }
    }

    NSPersonNameComponents *_Nullable nameComponents = [self nameComponentsForAddress:signalAccount.recipientAddress
                                                                          transaction:transaction];

    if (nameComponents != nil && nameComponents.givenName.length > 0 && nameComponents.familyName.length > 0) {
        NSString *leftName = self.shouldSortByGivenName ? nameComponents.givenName : nameComponents.familyName;
        NSString *rightName = self.shouldSortByGivenName ? nameComponents.familyName : nameComponents.givenName;
        return [NSString stringWithFormat:@"%@\t%@", leftName, rightName];
    }

    // Fall back to non-contact display name.
    return [self displayNameForAddress:signalAccount.recipientAddress transaction:transaction];
}

- (BOOL)isKnownRegisteredUserWithSneakyTransaction:(SignalServiceAddress *)address
{
    __block BOOL result;
    [self.databaseStorage readWithBlock:^(
        SDSAnyReadTransaction *transaction) { result = [self isKnownRegisteredUser:address transaction:transaction]; }];
    return result;
}

- (BOOL)isKnownRegisteredUser:(SignalServiceAddress *)address transaction:(SDSAnyReadTransaction *)transaction
{
    return [SignalRecipient isRegisteredRecipient:address transaction:transaction];
}

@end

NS_ASSUME_NONNULL_END
