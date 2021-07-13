//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public class SpamChallengeResolver: NSObject, SpamChallengeSchedulingDelegate {

    // Post-initial load, all work should be done on this queue
    var workQueue: DispatchQueue { Self.workQueue }
    private static let workQueue = DispatchQueue(
        label: "org.signal.SpamChallengeResolver",
        target: .sharedUtility)

    private var challenges: [SpamChallenge]? {
        didSet {
            let oldValueHasCaptcha = oldValue?.contains { $0 is CaptchaChallenge } ?? false
            let newValueHasCaptcha = challenges?.contains { $0 is CaptchaChallenge } ?? false
            if oldValueHasCaptcha, !newValueHasCaptcha {
                retryPausedMessages()
            }
        }
    }
    private var nextAttemptTimer: Timer? {
        didSet {
            guard oldValue !== nextAttemptTimer else { return }
            oldValue?.invalidate()
            nextAttemptTimer.map { RunLoop.main.add($0, forMode: .default) }
        }
    }

    @objc override init() {
        super.init()
        SwiftSingletons.register(self)

        AppReadiness.runNowOrWhenAppWillBecomeReady {
            self.loadChallengesFromDatabase()
            Logger.info("Loaded \(self.challenges?.count ?? -1) unresolved challenges")
        }
    }

    // MARK: - Private

    private func recheckChallenges() {
        assertOnQueue(workQueue)

        consolidateChallenges()
        saveChallenges()
        scheduleNextUpdate()
        resolveChallenges()
    }

    // Perform any clean up work to consolidate any challenges
    private func consolidateChallenges() {
        assertOnQueue(workQueue)

        let countBefore = challenges?.count ?? 0

        challenges = challenges?
            .filter { ![.complete, .failed].contains($0.state) }
            .filter { $0.expirationDate.isAfterNow }

        if let countAfter = challenges?.count, countBefore != countAfter {
            Logger.info("Removed \(countBefore - countAfter) complete, failed, or expired challenges")
        }
    }

    private func scheduleNextUpdate() {
        assertOnQueue(workQueue)

        guard let deferral = challenges?
                .map({ $0.nextActionableDate })
                .min() else { return }
        guard deferral.isAfterNow else { return }
        guard deferral != nextAttemptTimer?.fireDate else { return }

        Logger.verbose("Deferred challenges will be re-checked in \(deferral.timeIntervalSinceNow)")
        nextAttemptTimer = Timer(
            timeInterval: deferral.timeIntervalSinceNow,
            repeats: false) { [weak self] _ in

            Logger.verbose("Deferral timer fired!")
            guard let self = self else { return }

            self.workQueue.async {
                self.nextAttemptTimer = nil
                self.recheckChallenges()
            }
        }
    }

    private func resolveChallenges() {
        assertOnQueue(workQueue)

        challenges?.forEach { challenge in
            if challenge.state.isActionable {
                challenge.resolveChallenge()
            }
        }
    }

    private func retryPausedMessages() {
        databaseStorage.asyncWrite { writeTx in
            let pendingInteractionIds = InteractionFinder.pendingInteractionIds(transaction: writeTx)
            Logger.info("retrying paused messages: \(pendingInteractionIds)")

            pendingInteractionIds
                .compactMap { TSOutgoingMessage.anyFetchOutgoingMessage(uniqueId: $0, transaction: writeTx) }
                .forEach { self.messageSenderJobQueue.add(message: $0.asPreparer, transaction: writeTx) }
        }
    }
}

// MARK: - Push challenges

extension SpamChallengeResolver {
    @objc
    static public var NeedsCaptchaNotification: Notification.Name { .init("NeedsCaptchaNotification") }

    @objc
    public func handleIncomingPushChallengeToken(_ token: String) {
        guard AppReadiness.isAppReady else {
            owsFailDebug("App not ready")
            return
        }

        workQueue.async {
            Logger.info("Did receive push token")

            let awaitingToken = self.challenges?
                .compactMap { $0 as? PushChallenge }
                .filter { $0.token == nil }
                .min { $0.creationDate < $1.creationDate }

            // If there's an existing push challenge without a token, fulfill that first
            // Otherwise, create a new one
            if let existingChallenge = awaitingToken {
                Logger.info("Populating token for in-progress challenge")
                existingChallenge.token = token
            } else {
                Logger.info("Creating new push challenge")

                let challenge = PushChallenge(tokenIn: token)
                challenge.schedulingDelegate = self
                self.challenges?.append(challenge)
                self.recheckChallenges()
            }
        }
    }

    @objc
    public func handleIncomingCaptchaChallengeToken(_ token: String) {
        guard AppReadiness.isAppReady else {
            owsFailDebug("App not ready")
            return
        }

        workQueue.async {
            Logger.info("Did receive captcha token")

            let awaitingToken = self.challenges?
                .compactMap { $0 as? CaptchaChallenge }
                .filter { $0.captchaToken == nil }
                .min { $0.creationDate < $1.creationDate }

            awaitingToken?.captchaToken = token
        }
    }
}

// MARK: - Server challenges

private struct ServerChallengePayload: Decodable {
    let token: String
    let options: [Options]

    enum Options: String, Decodable {
        case recaptcha
        case pushChallenge
        case unrecognized

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            self = Options(rawValue: string) ?? .unrecognized
        }
    }
}

extension SpamChallengeResolver {

    @objc
    public func handleServerChallengeBody(
        _ body: Data,
        retryAfter: Date,
        silentRecoveryCompletionHandler: ((Bool) -> Void)? = nil
    ) {
        guard AppReadiness.isAppReady else { return owsFailDebug("App not ready") }
        guard let payload = try? JSONDecoder().decode(ServerChallengePayload.self, from: body) else {
            return owsFailDebug("Invalid server spam request response body: \(body)")
        }

        Logger.info("Received incoming spam challenge: \(payload.options.map { $0.rawValue })")

        workQueue.async {
            // If we already have a pending captcha challenge, we should wait for that to resolve
            // If we were given a silent recovery closure, reply with a failure
            guard self.challenges?.contains(where: { $0 is CaptchaChallenge }) == false else {
                Logger.info("Captcha challenge already in progress")
                silentRecoveryCompletionHandler?(false)
                return
            }

            if payload.options.contains(.pushChallenge), let completion = silentRecoveryCompletionHandler {
                Logger.info("Requesting push for silent recovery")
                let challenge = PushChallenge(expiry: Date(timeIntervalSinceNow: 10))
                challenge.schedulingDelegate = self
                challenge.completionHandler = { didSucceed in
                    Logger.info("Silent recovery \(didSucceed ? "did" : "did not") succeed")
                    if !didSucceed {
                        self.handleServerChallengeBody(body, retryAfter: retryAfter)
                    }
                    completion(didSucceed)
                }
                self.challenges?.append(challenge)
                self.recheckChallenges()

            } else if payload.options.contains(.recaptcha) {
                Logger.info("Registering captcha challenge")

                let challenge = CaptchaChallenge(tokenIn: payload.token, expiry: retryAfter)
                challenge.schedulingDelegate = self
                self.challenges?.append(challenge)
                self.recheckChallenges()
                silentRecoveryCompletionHandler?(false)
            }
        }
    }
}

// MARK: - Storage

extension SpamChallengeResolver {
    static private let outstandingChallengesKey = "OutstandingChallengesArray"
    static private let keyValueStore = SDSKeyValueStore(collection: "SpamChallengeResolver")
    private var outstandingChallengesKey: String { Self.outstandingChallengesKey }
    private var keyValueStore: SDSKeyValueStore { Self.keyValueStore }

    private func loadChallengesFromDatabase() {
        guard challenges == nil else {
            owsFailDebug("")
            return
        }

        do {
            challenges = try SDSDatabaseStorage.shared.read { readTx in
                try keyValueStore.getCodableValue(
                    forKey: outstandingChallengesKey,
                    transaction: readTx)
            } ?? []
        } catch {
            owsFailDebug("Failed to fetch saved challenges")
            challenges = []
        }

        workQueue.async { self.recheckChallenges() }
    }

    private func saveChallenges() {
        assertOnQueue(workQueue)

        do {
            try SDSDatabaseStorage.shared.write { writeTx in
                try keyValueStore.setCodable(
                    challenges,
                    key: outstandingChallengesKey,
                    transaction: writeTx)
            }
        } catch {
            owsFailDebug("Failed to save outstanding challenges")
        }
    }
}

// MARK: - <SpamChallengeSchedulingDelegate>

extension SpamChallengeResolver {
    func spamChallenge(_ challenge: SpamChallenge,
                       stateDidChangeFrom priorState: SpamChallenge.State) {
        if challenge.state != .inProgress, challenge.state != priorState {
            workQueue.async { self.recheckChallenges() }
        }
    }
}
