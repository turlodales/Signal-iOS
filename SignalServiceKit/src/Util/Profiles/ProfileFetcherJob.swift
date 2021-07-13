//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalMetadataKit

@objc
public enum ProfileFetchError: Int, Error {
    case missing
    case throttled
    case notMainApp
    case cantRequestVersionedProfile
    case rateLimit
    case unauthorized
}

// MARK: -

extension ProfileFetchError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missing:
            return "ProfileFetchError.missing"
        case .throttled:
            return "ProfileFetchError.throttled"
        case .notMainApp:
            return "ProfileFetchError.notMainApp"
        case .cantRequestVersionedProfile:
            return "ProfileFetchError.cantRequestVersionedProfile"
        case .rateLimit:
            return "ProfileFetchError.rateLimit"
        case .unauthorized:
            return "ProfileFetchError.unauthorized"
        }
    }
}

// MARK: -

@objc
public enum ProfileFetchType: UInt {
    // .default fetches honor FeatureFlag.versionedProfileFetches
    case `default`
    case unversioned
    case versioned
}

// MARK: -

@objc
public class ProfileFetchOptions: NSObject {
    fileprivate let mainAppOnly: Bool
    fileprivate let ignoreThrottling: Bool
    // TODO: Do we ever want to fetch but not update our local profile store?
    fileprivate let fetchType: ProfileFetchType

    fileprivate init(mainAppOnly: Bool = true,
                     ignoreThrottling: Bool = false,
                     fetchType: ProfileFetchType = .default) {
        self.mainAppOnly = mainAppOnly
        self.ignoreThrottling = ignoreThrottling || DebugFlags.aggressiveProfileFetching.get()
        self.fetchType = fetchType
    }
}

// MARK: -

private enum ProfileRequestSubject {
    case address(address: SignalServiceAddress)
    case username(username: String)
}

extension ProfileRequestSubject: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(hashTypeConstant)
        switch self {
        case .address(let address):
            hasher.combine(address)
        case .username(let username):
            hasher.combine(username)
        }
    }

    var hashTypeConstant: String {
        switch self {
        case .address:
            return "address"
        case .username:
            return "username"
        }
    }
}

// MARK: -

extension ProfileRequestSubject: CustomStringConvertible {
    public var description: String {
        switch self {
        case .address(let address):
            return "[address:\(address)]"
        case .username:
            // TODO: Could we redact username for logging?
            return "[username]"
        }
    }
}

// MARK: -

@objc
public class ProfileFetcherJob: NSObject {

    private static let queueCluster = GCDQueueCluster(label: "org.signal.profileFetcherJob",
                                                      concurrency: 5)

    // This property is only accessed on the serial queue.
    private static var fetchDateMap = [ProfileRequestSubject: Date]()

    private let subject: ProfileRequestSubject
    private let options: ProfileFetchOptions

    private var backgroundTask: OWSBackgroundTask?

    private static let unfairLock = UnfairLock()

    @objc
    public class func fetchProfilePromiseObjc(address: SignalServiceAddress,
                                              mainAppOnly: Bool,
                                              ignoreThrottling: Bool) -> AnyPromise {
        return AnyPromise(fetchProfilePromise(address: address,
                                              mainAppOnly: mainAppOnly,
                                              ignoreThrottling: ignoreThrottling))
    }

    public class func fetchProfilePromise(address: SignalServiceAddress,
                                          mainAppOnly: Bool = true,
                                          ignoreThrottling: Bool = false,
                                          fetchType: ProfileFetchType = .default) -> Promise<FetchedProfile> {
        let subject = ProfileRequestSubject.address(address: address)
        let options = ProfileFetchOptions(mainAppOnly: mainAppOnly,
                                          ignoreThrottling: ignoreThrottling,
                                          fetchType: fetchType)
        return ProfileFetcherJob(subject: subject, options: options).runAsPromise()
    }

    @objc
    public class func fetchProfile(address: SignalServiceAddress, ignoreThrottling: Bool) {
        let subject = ProfileRequestSubject.address(address: address)
        let options = ProfileFetchOptions(ignoreThrottling: ignoreThrottling)
        firstly {
            ProfileFetcherJob(subject: subject, options: options).runAsPromise()
        }.catch { error in
            if error.isNetworkFailureOrTimeout {
                Logger.warn("Error: \(error)")
            } else {
                switch error {
                case ProfileFetchError.missing:
                    Logger.warn("Error: \(error)")
                case ProfileFetchError.unauthorized:
                    if self.tsAccountManager.isRegisteredAndReady {
                        owsFailDebug("Error: \(error)")
                    } else {
                        Logger.warn("Error: \(error)")
                    }
                default:
                    owsFailDebug("Error: \(error)")
                }
            }
        }
    }

    @objc
    public class func fetchProfile(username: String,
                                   success: @escaping (_ address: SignalServiceAddress) -> Void,
                                   notFound: @escaping () -> Void,
                                   failure: @escaping (_ error: Error?) -> Void) {
        let subject = ProfileRequestSubject.username(username: username)
        let options = ProfileFetchOptions(ignoreThrottling: true)
        firstly {
            ProfileFetcherJob(subject: subject, options: options).runAsPromise()
        }.done { fetchedProfile in
            success(fetchedProfile.profile.address)
        }.catch { error in
            switch error {
            case ProfileFetchError.missing:
                notFound()
            default:
                failure(error)
            }
        }
    }

    private init(subject: ProfileRequestSubject,
                 options: ProfileFetchOptions) {
        self.subject = subject
        self.options = options
    }

    // MARK: -

    private func runAsPromise() -> Promise<FetchedProfile> {
        return DispatchQueue.main.async(.promise) {
            self.addBackgroundTask()
        }.then(on: Self.queueCluster.next()) { _ in
            self.requestProfile()
        }.then(on: Self.queueCluster.next()) { fetchedProfile in
            firstly {
                self.updateProfile(fetchedProfile: fetchedProfile)
            }.map(on: Self.queueCluster.next()) { _ in
                return fetchedProfile
            }
        }
    }

    private func requestProfile() -> Promise<FetchedProfile> {

        guard !options.mainAppOnly || CurrentAppContext().isMainApp else {
            // We usually only refresh profiles in the MainApp to decrease the
            // chance of missed SN notifications in the AppExtension for our users
            // who choose not to verify contacts.
            return Promise(error: ProfileFetchError.notMainApp)
        }

        // Check throttling _before_ possible retries.
        if !options.ignoreThrottling {
            if let lastDate = lastFetchDate(for: subject) {
                let lastTimeInterval = fabs(lastDate.timeIntervalSinceNow)
                // Don't check a profile more often than every N seconds.
                //
                // Throttle less in debug to make it easier to test problems
                // with our fetching logic.
                guard lastTimeInterval > Self.throttledProfileFetchFrequency else {
                    return Promise(error: ProfileFetchError.throttled)
                }
            }
        }

        recordLastFetchDate(for: subject)

        return requestProfileWithRetries()
    }

    private static var throttledProfileFetchFrequency: TimeInterval {
        kMinuteInterval * 2.0
    }

    private func requestProfileWithRetries(retryCount: Int = 0) -> Promise<FetchedProfile> {
        let subject = self.subject

        let (promise, resolver) = Promise<FetchedProfile>.pending()
        firstly {
            requestProfileAttempt()
        }.done(on: Self.queueCluster.next()) { fetchedProfile in
            resolver.fulfill(fetchedProfile)
        }.catch(on: Self.queueCluster.next()) { error in
            if error.httpStatusCode == 401 {
                return resolver.reject(ProfileFetchError.unauthorized)
            }
            if error.httpStatusCode == 404 {
                return resolver.reject(ProfileFetchError.missing)
            }
            if error.httpStatusCode == 413 {
                return resolver.reject(ProfileFetchError.rateLimit)
            }

            switch error {
            case ProfileFetchError.throttled, ProfileFetchError.notMainApp:
                // These errors should only be thrown at a higher level.
                owsFailDebug("Unexpected error: \(error)")
                resolver.reject(error)
                return
            case SignalServiceProfile.ValidationError.invalidIdentityKey:
                // There will be invalid identity keys on staging that can be safely ignored.
                // This should not be retried.
                if FeatureFlags.isUsingProductionService {
                    owsFailDebug("skipping updateProfile retry. Invalid profile for: \(subject) error: \(error)")
                } else {
                    Logger.warn("skipping updateProfile retry. Invalid profile for: \(subject) error: \(error)")
                }
                resolver.reject(error)
                return
            case let error as SignalServiceProfile.ValidationError:
                // This should not be retried.
                owsFailDebug("skipping updateProfile retry. Invalid profile for: \(subject) error: \(error)")
                resolver.reject(error)
                return
            default:
                let maxRetries = 3
                guard retryCount < maxRetries else {
                    Logger.warn("failed to get profile with error: \(error)")
                    resolver.reject(error)
                    return
                }

                firstly {
                    self.requestProfileWithRetries(retryCount: retryCount + 1)
                }.done(on: Self.queueCluster.next()) { fetchedProfile in
                    resolver.fulfill(fetchedProfile)
                }.catch(on: Self.queueCluster.next()) { error in
                    resolver.reject(error)
                }
            }
        }
        return promise
    }

    private func requestProfileAttempt() -> Promise<FetchedProfile> {
        switch subject {
        case .address(let address):
            return requestProfileAttempt(address: address)
        case .username(let username):
            return requestProfileAttempt(username: username)
        }
    }

    private func requestProfileAttempt(username: String) -> Promise<FetchedProfile> {
        Logger.info("username")

        guard options.fetchType != .versioned else {
            return Promise(error: ProfileFetchError.cantRequestVersionedProfile)
        }

        let request = OWSRequestFactory.getProfileRequest(withUsername: username)
        return firstly {
            return networkManager.makePromise(request: request)
        }.map(on: Self.queueCluster.next()) {
            let profile = try SignalServiceProfile(address: nil, responseObject: $1)
            let profileKey = self.profileKey(forProfile: profile,
                                             versionedProfileRequest: nil)
            return FetchedProfile(profile: profile,
                                  versionedProfileRequest: nil,
                                  profileKey: profileKey)
        }
    }

    private var shouldUseVersionedFetchForUuids: Bool {
        switch options.fetchType {
        case .default:
            return true
        case .versioned:
            return true
        case .unversioned:
            return false
        }
    }

    private func requestProfileAttempt(address: SignalServiceAddress) -> Promise<FetchedProfile> {
        Logger.verbose("address: \(address)")

        let shouldUseVersionedFetch = (shouldUseVersionedFetchForUuids
                                        && address.uuid != nil)

        let udAccess: OWSUDAccess?
        if address.isLocalAddress {
            // Don't use UD for "self" profile fetches.
            udAccess = nil
        } else {
            udAccess = udManager.udAccess(forAddress: address, requireSyncAccess: false)
        }

        let canFailoverUDAuth = true
        var currentVersionedProfileRequest: VersionedProfileRequest?
        let requestMaker = RequestMaker(label: "Profile Fetch",
                                        requestFactoryBlock: { (udAccessKeyForRequest) -> TSRequest? in
                                            // Clear out any existing request.
                                            currentVersionedProfileRequest = nil

                                            if shouldUseVersionedFetch {
                                                do {
                                                    let request = try self.versionedProfiles.versionedProfileRequest(address: address, udAccessKey: udAccessKeyForRequest)
                                                    currentVersionedProfileRequest = request
                                                    return request.request
                                                } catch {
                                                    owsFailDebug("Error: \(error)")
                                                    return nil
                                                }
                                            } else {
                                                Logger.info("Unversioned profile fetch.")
                                                return OWSRequestFactory.getUnversionedProfileRequest(address: address, udAccessKey: udAccessKeyForRequest)
                                            }
                                        }, udAuthFailureBlock: {
                                            // Do nothing
                                        }, websocketFailureBlock: {
                                            // Do nothing
                                        }, address: address,
                                        udAccess: udAccess,
                                        canFailoverUDAuth: canFailoverUDAuth)

        return firstly {
            return requestMaker.makeRequest()
        }.map(on: Self.queueCluster.next()) { (result: RequestMakerResult) -> FetchedProfile in
            let profile = try SignalServiceProfile(address: address, responseObject: result.responseObject)
            let profileKey = self.profileKey(forProfile: profile,
                                             versionedProfileRequest: currentVersionedProfileRequest)
            return FetchedProfile(profile: profile,
                                  versionedProfileRequest: currentVersionedProfileRequest,
                                  profileKey: profileKey)
        }
    }

    private func updateProfile(fetchedProfile: FetchedProfile) -> Promise<Void> {
        // Before we update the profile, try to download and decrypt
        // the avatar data, if necessary.

        let profileAddress = fetchedProfile.profile.address
        guard let profileKey = fetchedProfile.profileKey else {
            // If we don't have a profile key for this user, don't bother
            // downloading their avatar - we can't decrypt it.
            return updateProfile(fetchedProfile: fetchedProfile,
                                 profileKey: nil,
                                 optionalAvatarData: nil)
        }

        guard let avatarUrlPath = fetchedProfile.profile.avatarUrlPath else {
            // If profile has no avatar, we don't need to download the avatar.
            return updateProfile(fetchedProfile: fetchedProfile,
                                 profileKey: profileKey,
                                 optionalAvatarData: nil)
        }

        let hasExistingAvatarData = databaseStorage.read { (transaction: SDSAnyReadTransaction) -> Bool in
            guard let oldAvatarURLPath = self.profileManager.profileAvatarURLPath(for: profileAddress,
                                                                                  transaction: transaction),
                  oldAvatarURLPath == avatarUrlPath else {
                return false
            }
            return self.profileManager.hasProfileAvatarData(profileAddress, transaction: transaction)
        }
        if hasExistingAvatarData {
            Logger.verbose("Skipping avatar data download; already downloaded.")
            return updateProfile(fetchedProfile: fetchedProfile,
                                 profileKey: profileKey,
                                 optionalAvatarData: nil)
        }

        return firstly { () -> AnyPromise in
            profileManager.downloadAndDecryptProfileAvatar(forProfileAddress: profileAddress,
                                                           avatarUrlPath: avatarUrlPath,
                                                           profileKey: profileKey)
        }.map(on: Self.queueCluster.next()) { (result: Any?) throws -> Data in
            guard let avatarData = result as? Data else {
                Logger.verbose("Unexpected result: \(String(describing: result))")
                throw OWSAssertionError("Unexpected result.")
            }
            return avatarData
        }.then(on: Self.queueCluster.next()) { (avatarData: Data) -> Promise<Void> in
            self.updateProfile(fetchedProfile: fetchedProfile,
                               profileKey: profileKey,
                               optionalAvatarData: avatarData)
        }.recover(on: Self.queueCluster.next()) { (error: Error) -> Promise<Void> in
            if error.isNetworkFailureOrTimeout {
                Logger.warn("Error: \(error)")

                if profileAddress.isLocalAddress {
                    // Fetches and local profile updates can conflict.
                    // To avoid these conflicts we treat "partial"
                    // profile fetches (where we download the profile
                    // but not the associated avatar) as failures.
                    throw error.asUnretryableError
                }
            } else {
                // This should be very rare. It might reflect:
                //
                // * A race around rotating profile keys which would cause a
                //   decryption error.
                // * An incomplete profile update (profile updated but
                //   avatar not uploaded afterward). This might be due to
                //   a race with an update that is in flight.
                //   We should eventually recover since profile updates are
                //   durable.
                Logger.warn("Error: \(error)")
            }
            // We made a best effort to download the avatar
            // before updating the profile.
            return self.updateProfile(fetchedProfile: fetchedProfile,
                                      profileKey: profileKey,
                                      optionalAvatarData: nil)
        }
    }

    private func profileKey(forProfile profile: SignalServiceProfile,
                            versionedProfileRequest: VersionedProfileRequest?) -> OWSAES256Key? {
        if let profileKey = versionedProfileRequest?.profileKey {
            if DebugFlags.internalLogging {
                Logger.info("Using profileKey used in versioned profile request.")
            }
            return profileKey
        }
        let profileAddress = profile.address
        if let profileKey = (databaseStorage.read { transaction in
            self.profileManager.profileKey(for: profileAddress,
                                           transaction: transaction)
        }) {
            if DebugFlags.internalLogging {
                Logger.info("Using profileKey from database.")
            }
            return profileKey
        }
        return nil
    }

    // TODO: This method can cause many database writes.
    //       Perhaps we can use a single transaction?
    private func updateProfile(fetchedProfile: FetchedProfile,
                               profileKey: OWSAES256Key?,
                               optionalAvatarData: Data?) -> Promise<Void> {
        let profile = fetchedProfile.profile
        let address = profile.address

        var givenName: String?
        var familyName: String?
        var bio: String?
        var bioEmoji: String?
        var paymentAddress: TSPaymentAddress?
        if let decryptedProfile = fetchedProfile.decryptedProfile {
            givenName = decryptedProfile.givenName?.nilIfEmpty
            familyName = decryptedProfile.familyName?.nilIfEmpty
            bio = decryptedProfile.bio?.nilIfEmpty
            bioEmoji = decryptedProfile.bioEmoji?.nilIfEmpty
            paymentAddress = decryptedProfile.paymentAddress
        }
        let username = profile.username

        if DebugFlags.internalLogging {
            let isVersionedProfile = fetchedProfile.versionedProfileRequest != nil
            let profileKeyDescription = profileKey?.keyData.hexadecimalString ?? "None"
            let hasAvatar = profile.avatarUrlPath != nil
            let hasProfileNameEncrypted = profile.profileNameEncrypted != nil
            let hasGivenName = givenName?.count ?? 0 > 0
            let hasFamilyName = familyName?.count ?? 0 > 0
            let hasBio = bio?.count ?? 0 > 0
            let hasBioEmoji = bioEmoji?.count ?? 0 > 0
            let hasUsername = username?.count ?? 0 > 0
            let hasPaymentAddress = paymentAddress != nil

            Logger.info("address: \(address), " +
                            "isVersionedProfile: \(isVersionedProfile), " +
                            "hasAvatar: \(hasAvatar), " +
                            "hasProfileNameEncrypted: \(hasProfileNameEncrypted), " +
                            "hasGivenName: \(hasGivenName), " +
                            "hasFamilyName: \(hasFamilyName), " +
                            "hasBio: \(hasBio), " +
                            "hasBioEmoji: \(hasBioEmoji), " +
                            "hasUsername: \(hasUsername), " +
                            "hasPaymentAddress: \(hasPaymentAddress), " +
                            "profileKey: \(profileKeyDescription)")
        }

        if let profileRequest = fetchedProfile.versionedProfileRequest {
            self.versionedProfiles.didFetchProfile(profile: profile, profileRequest: profileRequest)
        }

        profileManager.updateProfile(for: address,
                                     givenName: givenName,
                                     familyName: familyName,
                                     bio: bio,
                                     bioEmoji: bioEmoji,
                                     username: profile.username,
                                     isUuidCapable: true,
                                     avatarUrlPath: profile.avatarUrlPath,
                                     optionalDecryptedAvatarData: optionalAvatarData,
                                     lastFetch: Date(),
                                     userProfileWriter: .profileFetch)

        updateUnidentifiedAccess(address: address,
                                 verifier: profile.unidentifiedAccessVerifier,
                                 hasUnrestrictedAccess: profile.hasUnrestrictedUnidentifiedAccess)

        if address.isLocalAddress,
           DebugFlags.groupsV2memberStatusIndicators {
            Logger.info("supportsGroupsV2: \(profile.supportsGroupsV2)")
        }

        return databaseStorage.write(.promise) { transaction in
            GroupManager.setUserCapabilities(address: address,
                                             hasGroupsV2Capability: profile.supportsGroupsV2,
                                             hasGroupsV2MigrationCapability: profile.supportsGroupsV2Migration,
                                             transaction: transaction)

            self.verifyIdentityUpToDate(address: address,
                                        latestIdentityKey: profile.identityKey,
                                        transaction: transaction)

            self.payments.setArePaymentsEnabled(for: address,
                                                hasPaymentsEnabled: paymentAddress != nil,
                                                transaction: transaction)
        }
    }

    private func updateUnidentifiedAccess(address: SignalServiceAddress, verifier: Data?, hasUnrestrictedAccess: Bool) {
        guard let verifier = verifier else {
            // If there is no verifier, at least one of this user's devices
            // do not support UD.
            udManager.setUnidentifiedAccessMode(.disabled, address: address)
            return
        }

        if hasUnrestrictedAccess {
            udManager.setUnidentifiedAccessMode(.unrestricted, address: address)
            return
        }

        guard let udAccessKey = udManager.udAccessKey(forAddress: address) else {
            udManager.setUnidentifiedAccessMode(.disabled, address: address)
            return
        }

        let dataToVerify = Data(count: 32)
        guard let expectedVerifier = Cryptography.computeSHA256HMAC(dataToVerify, key: udAccessKey.keyData) else {
            owsFailDebug("could not compute verification")
            udManager.setUnidentifiedAccessMode(.disabled, address: address)
            return
        }

        guard expectedVerifier.ows_constantTimeIsEqual(to: verifier) else {
            Logger.verbose("verifier mismatch, new profile key?")
            udManager.setUnidentifiedAccessMode(.disabled, address: address)
            return
        }

        udManager.setUnidentifiedAccessMode(.enabled, address: address)
    }

    private func verifyIdentityUpToDate(address: SignalServiceAddress,
                                        latestIdentityKey: Data,
                                        transaction: SDSAnyWriteTransaction) {
        if self.identityManager.saveRemoteIdentity(latestIdentityKey, address: address, transaction: transaction) {
            Logger.info("updated identity key with fetched profile for recipient: \(address)")
            self.sessionStore.archiveAllSessions(for: address, transaction: transaction)
        } else {
            // no change in identity.
        }
    }

    private func lastFetchDate(for subject: ProfileRequestSubject) -> Date? {
        Self.unfairLock.withLock {
            ProfileFetcherJob.fetchDateMap[subject]
        }
    }

    private func recordLastFetchDate(for subject: ProfileRequestSubject) {
        Self.unfairLock.withLock {
            ProfileFetcherJob.fetchDateMap[subject] = Date()
        }
    }

    private func addBackgroundTask() {
        backgroundTask = OWSBackgroundTask(label: "\(#function)", completionBlock: { [weak self] status in
            AssertIsOnMainThread()

            guard status == .expired else {
                return
            }
            guard let _ = self else {
                return
            }
            Logger.error("background task time ran out before profile fetch completed.")
        })
    }
}

// MARK: -

public struct DecryptedProfile: Dependencies {
    public let givenName: String?
    public let familyName: String?
    public let bio: String?
    public let bioEmoji: String?
    public let paymentAddressData: Data?
    public let publicIdentityKey: Data
}

// MARK: -

public struct FetchedProfile {
    let profile: SignalServiceProfile
    let versionedProfileRequest: VersionedProfileRequest?
    let profileKey: OWSAES256Key?
    public let decryptedProfile: DecryptedProfile?

    init(profile: SignalServiceProfile,
         versionedProfileRequest: VersionedProfileRequest?,
         profileKey: OWSAES256Key?) {
        self.profile = profile
        self.versionedProfileRequest = versionedProfileRequest
        self.profileKey = profileKey
        self.decryptedProfile = Self.decrypt(profile: profile,
                                             versionedProfileRequest: versionedProfileRequest,
                                             profileKey: profileKey)
    }

    private static func decrypt(profile: SignalServiceProfile,
                                versionedProfileRequest: VersionedProfileRequest?,
                                profileKey: OWSAES256Key?) -> DecryptedProfile? {
        guard let profileKey = profileKey else {
            return nil
        }
        var givenName: String?
        var familyName: String?
        var bio: String?
        var bioEmoji: String?
        var paymentAddressData: Data?
        if let profileNameEncrypted = profile.profileNameEncrypted,
           let profileNameComponents = OWSUserProfile.decrypt(profileNameData: profileNameEncrypted,
                                                              profileKey: profileKey,
                                                              address: profile.address) {
            givenName = profileNameComponents.givenName?.ows_stripped()
            familyName = profileNameComponents.familyName?.ows_stripped()
        }
        if let bioEncrypted = profile.bioEncrypted {
            bio = OWSUserProfile.decrypt(profileStringData: bioEncrypted,
                                         profileKey: profileKey)
        }
        if let bioEmojiEncrypted = profile.bioEmojiEncrypted {
            bioEmoji = OWSUserProfile.decrypt(profileStringData: bioEmojiEncrypted,
                                              profileKey: profileKey)
        }
        if let paymentAddressEncrypted = profile.paymentAddressEncrypted {
            paymentAddressData = OWSUserProfile.decrypt(profileData: paymentAddressEncrypted,
                                                        profileKey: profileKey)
        }
        let publicIdentityKey = profile.identityKey
        return DecryptedProfile(givenName: givenName,
                                familyName: familyName,
                                bio: bio,
                                bioEmoji: bioEmoji,
                                paymentAddressData: paymentAddressData,
                                publicIdentityKey: publicIdentityKey)
    }
}

// MARK: -

public extension DecryptedProfile {

    var paymentAddress: TSPaymentAddress? {
        guard payments.arePaymentsEnabled else {
            return nil
        }
        guard let paymentAddressDataWithLength = paymentAddressData else {
            return nil
        }

        do {
            let byteParser = ByteParser(data: paymentAddressDataWithLength, littleEndian: true)
            let length = byteParser.nextUInt32()
            guard length > 0 else {
                return nil
            }
            guard let paymentAddressDataWithoutLength = byteParser.readBytes(UInt(length)) else {
                owsFailDebug("Invalid payment address.")
                return nil
            }
            let proto = try SSKProtoPaymentAddress(serializedData: paymentAddressDataWithoutLength)
            let paymentAddress = try TSPaymentAddress.fromProto(proto, publicIdentityKey: publicIdentityKey)
            return paymentAddress
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }
}

// MARK: -

// A simple mechanism for distributing workload across multiple serial queues.
// Allows concurrency while avoiding thread explosion.
//
// TODO: Move this to DispatchQueue+OWS.swift if we adopt it elsewhere.
public class GCDQueueCluster {
    private static let unfairLock = UnfairLock()

    private let queues: [DispatchQueue]

    private let counter = AtomicUInt(0)

    public required init(label: String, concurrency: UInt) {
        if concurrency < 1 {
            owsFailDebug("Invalid concurrency.")
        }
        let concurrency = max(1, concurrency)
        var queues = [DispatchQueue]()
        for index in 0..<concurrency {
            queues.append(DispatchQueue(label: label + ".\(index)"))
        }
        self.queues = queues
    }

    public func next() -> DispatchQueue {
        Self.unfairLock.withLock {
            let index = Int(counter.increment() % UInt(queues.count))
            return queues[index]
        }
    }
}
