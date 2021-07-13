//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB

@objc
public class GRDBDatabaseStorageAdapter: NSObject {

    // 256 bit key + 128 bit salt
    public static let kSQLCipherKeySpecLength: UInt = 48

    @objc
    public enum DirectoryMode: Int {
        case primary
        case hotswap

        var folderName: String {
            switch self {
            case .primary: return "grdb"
            case .hotswap: return "grdb-hotswap"
            }
        }
    }

    @objc
    public static func databaseDirUrl(baseDir: URL, directoryMode: DirectoryMode = .primary) -> URL {
        return baseDir.appendingPathComponent(directoryMode.folderName, isDirectory: true)
    }

    public static func databaseFileUrl(baseDir: URL, directoryMode: DirectoryMode = .primary) -> URL {
        let databaseDir = databaseDirUrl(baseDir: baseDir, directoryMode: directoryMode)
        OWSFileSystem.ensureDirectoryExists(databaseDir.path)
        return databaseDir.appendingPathComponent("signal.sqlite", isDirectory: false)
    }

    public static func databaseWalUrl(baseDir: URL, directoryMode: DirectoryMode = .primary) -> URL {
        let databaseDir = databaseDirUrl(baseDir: baseDir, directoryMode: directoryMode)
        OWSFileSystem.ensureDirectoryExists(databaseDir.path)
        return databaseDir.appendingPathComponent("signal.sqlite-wal", isDirectory: false)
    }

    private let databaseUrl: URL

    private let storage: GRDBStorage

    public var pool: DatabasePool {
        return storage.pool
    }

    init(baseDir: URL, directoryMode: DirectoryMode = .primary) {
        databaseUrl = GRDBDatabaseStorageAdapter.databaseFileUrl(baseDir: baseDir, directoryMode: directoryMode)

        do {
            // Crash if keychain is inaccessible.
            try GRDBDatabaseStorageAdapter.ensureDatabaseKeySpecExists(baseDir: baseDir)
        } catch {
            owsFail("\(error.grdbErrorForLogging)")
        }

        do {
            // Crash if storage can't be initialized.
            storage = try GRDBStorage(dbURL: databaseUrl, keyspec: GRDBDatabaseStorageAdapter.keyspec)
        } catch {
            owsFail("\(error.grdbErrorForLogging)")
        }

        super.init()

        AppReadiness.runNowOrWhenAppWillBecomeReady { [weak self] in
            // This adapter may have been discarded after running
            // schema migrations.            
            guard let self = self else { return }

            BenchEventStart(title: "GRDB Setup", eventId: "GRDB Setup")
            defer { BenchEventComplete(eventId: "GRDB Setup") }
            do {
                try self.setup()
            } catch {
                owsFail("unable to setup database: \(error)")
            }
        }
    }

    public func add(function: DatabaseFunction) {
        pool.add(function: function)
    }

    static let tables: [SDSTableMetadata] = [
        // Models
        TSThread.table,
        TSInteraction.table,
        StickerPack.table,
        InstalledSticker.table,
        KnownStickerPack.table,
        TSAttachment.table,
        SSKJobRecord.table,
        OWSMessageContentJob.table,
        OWSRecipientIdentity.table,
        ExperienceUpgrade.table,
        OWSDisappearingMessagesConfiguration.table,
        SignalRecipient.table,
        SignalAccount.table,
        OWSUserProfile.table,
        OWSDevice.table,
        TestModel.table,
        OWSReaction.table,
        IncomingGroupsV2MessageJob.table,
        TSMention.table,
        TSPaymentModel.table,
        TSPaymentRequestModel.table,
        TSGroupMember.table
        // NOTE: We don't include OWSMessageDecryptJob,
        // since we should never use it with GRDB.
    ]

    static let swiftTables: [TableRecord.Type] = [
        ThreadAssociatedData.self,
        PendingReadReceiptRecord.self,
        PendingViewedReceiptRecord.self,
        MediaGalleryRecord.self
    ]

    // MARK: - DatabaseChangeObserver

    @objc
    public private(set) var databaseChangeObserver: DatabaseChangeObserver?

    @objc
    public func setupDatabaseChangeObserver() throws {
        owsAssertDebug(self.databaseChangeObserver == nil)

        // DatabaseChangeObserver is a general purpose observer, whose delegates
        // are notified when things change, but are not given any specific details
        // about the changes.
        let databaseChangeObserver = try DatabaseChangeObserver(pool: pool,
                                                                  checkpointingQueue: storage.checkpointingQueue)
        self.databaseChangeObserver = databaseChangeObserver

        try pool.write { db in
            db.add(transactionObserver: databaseChangeObserver, extent: Database.TransactionObservationExtent.observerLifetime)
        }
    }

    // NOTE: This should only be used in exceptional circumstances,
    // e.g. after reloading the database due to a device transfer.
    func publishUpdatesImmediately() {
        databaseChangeObserver?.publishUpdatesImmediately()
    }

    func testing_tearDownDatabaseChangeObserver() {
        // DatabaseChangeObserver is a general purpose observer, whose delegates
        // are notified when things change, but are not given any specific details
        // about the changes.
        self.databaseChangeObserver = nil
    }

    func setup() throws {
        MediaGalleryManager.setup(storage: self)
        try setupDatabaseChangeObserver()
    }

    // MARK: -

    private static let keyServiceName: String = "GRDBKeyChainService"
    private static let keyName: String = "GRDBDatabaseCipherKeySpec"
    public static var keyspec: GRDBKeySpecSource {
        return GRDBKeySpecSource(keyServiceName: keyServiceName, keyName: keyName)
    }

    @objc
    public static var isKeyAccessible: Bool {
        do {
            return try keyspec.fetchString().count > 0
        } catch {
            owsFailDebug("Key not accessible: \(error)")
            return false
        }
    }

    /// Fetches the GRDB key data from the keychain.
    /// - Note: Will fatally assert if not running in a debug or test build.
    /// - Returns: The key data, if available.
    @objc
    public static var debugOnly_keyData: Data? {
        owsAssert(OWSIsTestableBuild())
        return try? keyspec.fetchData()
    }

    @objc
    public static func ensureDatabaseKeySpecExists(baseDir: URL) throws {

        do {
            _ = try keyspec.fetchString()
            // Key exists and is valid.
            return
        } catch {
            Logger.warn("Key not accessible: \(error)")
        }

        // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        // the keychain will be inaccessible after device restart until
        // device is unlocked for the first time.  If the app receives
        // a push notification, we won't be able to access the keychain to
        // process that notification, so we should just terminate by throwing
        // an uncaught exception.
        var errorDescription = "CipherKeySpec inaccessible. New install, migration or no unlock since device restart?"
        if CurrentAppContext().isMainApp {
            let applicationState = CurrentAppContext().reportedApplicationState
            errorDescription += ", ApplicationState: \(NSStringForUIApplicationState(applicationState))"
        }
        Logger.error(errorDescription)
        Logger.flush()

        if CurrentAppContext().isMainApp {
            if CurrentAppContext().isInBackground() {
                // Rather than crash here, we should have already detected the situation earlier
                // and exited gracefully (in the app delegate) using isDatabasePasswordAccessible.
                // This is a last ditch effort to avoid blowing away the user's database.
                throw OWSAssertionError(errorDescription)
            }
        } else {
            throw OWSAssertionError("CipherKeySpec inaccessible; not main app.")
        }

        // At this point, either:
        //
        // * This is a new install so there's no existing password to retrieve.
        // * The keychain has become corrupt.
        let databaseUrl = GRDBDatabaseStorageAdapter.databaseFileUrl(baseDir: baseDir)
        let doesDBExist = FileManager.default.fileExists(atPath: databaseUrl.path)
        if doesDBExist {
            owsFail("Could not load database metadata")
        }

        keyspec.generateAndStore()
    }

    @objc
    public static func resetAllStorage(baseDir: URL) {
        Logger.info("")

        // This might be redundant but in the spirit of thoroughness...

        GRDBDatabaseStorageAdapter.removeAllFiles(baseDir: baseDir)

        deleteDBKeys()

        if CurrentAppContext().isMainApp {
            TSAttachmentStream.deleteAttachmentsFromDisk()
        }

        // TODO: Delete Profiles on Disk?
    }

    private static func deleteDBKeys() {
        do {
            try keyspec.clear()
        } catch {
            owsFailDebug("Could not clear keychain: \(error)")
        }
    }

    static func prepareDatabase(db: Database, keyspec: GRDBKeySpecSource, name: String? = nil) throws {
        let prefix: String
        if let name = name, !name.isEmpty {
            prefix = name + "."
        } else {
            prefix = ""
        }

        let keyspec = try keyspec.fetchString()
        try db.execute(sql: "PRAGMA \(prefix)key = \"\(keyspec)\"")
        try db.execute(sql: "PRAGMA \(prefix)cipher_plaintext_header_size = 32")
    }
}

// MARK: -

extension GRDBDatabaseStorageAdapter: SDSDatabaseStorageAdapter {

    #if TESTABLE_BUILD
    // TODO: We could eventually eliminate all nested transactions.
    private static let detectNestedTransactions = false

    // In debug builds, we can detect transactions opened within transaction.
    // These checks can also be used to detect unexpected "sneaky" transactions.
    @ThreadBacked(key: "canOpenTransaction", defaultValue: true)
    public static var canOpenTransaction: Bool
    #endif

    // TODO writeThrows flavors
    public func readThrows(block: (GRDBReadTransaction) throws -> Void) throws {

        #if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        return try pool.read { database in
            try autoreleasepool {
                try block(GRDBReadTransaction(database: database))
            }
        }
    }

    @discardableResult
    public func read<T>(block: (GRDBReadTransaction) throws -> T) throws -> T {

        #if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        return try pool.read { database in
            try autoreleasepool {
                try block(GRDBReadTransaction(database: database))
            }
        }
    }

    @discardableResult
    public func write<T>(block: (GRDBWriteTransaction) throws -> T) throws -> T {

        var value: T!
        var thrown: Error?
        try write { (transaction) in
            do {
                value = try block(transaction)
            } catch {
                thrown = error
            }
        }
        if let error = thrown {
            throw error.grdbErrorForLogging
        }
        return value
    }

    @objc
    public func read(block: (GRDBReadTransaction) -> Void) throws {

        #if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        try pool.read { database in
            autoreleasepool {
                block(GRDBReadTransaction(database: database))
            }
        }
    }

    @objc
    public func write(block: (GRDBWriteTransaction) -> Void) throws {

        #if TESTABLE_BUILD
        owsAssertDebug(Self.canOpenTransaction)
        // Check for nested tractions.
        if Self.detectNestedTransactions {
            // Check for nested tractions.
            Self.canOpenTransaction = false
        }
        defer {
            if Self.detectNestedTransactions {
                Self.canOpenTransaction = true
            }
        }
        #endif

        var syncCompletions: [GRDBWriteTransaction.CompletionBlock] = []
        var asyncCompletions: [GRDBWriteTransaction.AsyncCompletion] = []

        try pool.write { database in
            autoreleasepool {
                let transaction = GRDBWriteTransaction(database: database)
                block(transaction)
                transaction.finalizeTransaction()

                syncCompletions = transaction.syncCompletions
                asyncCompletions = transaction.asyncCompletions
            }
        }

        // Perform all completions _after_ the write transaction completes.
        for block in syncCompletions {
            block()
        }

        for asyncCompletion in asyncCompletions {
            asyncCompletion.queue.async(execute: asyncCompletion.block)
        }
    }
}

// MARK: -

func filterForDBQueryLog(_ input: String) -> String {
    var result = input
    while let matchRange = result.range(of: "x'[0-9a-f\n]*'", options: .regularExpression) {
        let charCount = result.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
        let byteCount = Int64(charCount) / 2
        let formattedByteCount = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .memory)
        result = result.replacingCharacters(in: matchRange, with: "x'<\(formattedByteCount)>'")
    }
    return result
}

private func dbQueryLog(_ value: String) {
    guard SDSDatabaseStorage.shouldLogDBQueries else {
        return
    }
    Logger.info(filterForDBQueryLog(value))
}

// MARK: -

private struct GRDBStorage {

    let pool: DatabasePool

    // TODO: Can we eliminate this?
    let checkpointingQueue: DatabaseQueue?

    private let dbURL: URL
    private let poolConfiguration: Configuration
    private let checkpointingQueueConfiguration: Configuration

    fileprivate static let maxBusyTimeoutMs = 50

    init(dbURL: URL, keyspec: GRDBKeySpecSource) throws {
        self.dbURL = dbURL

        poolConfiguration = Self.buildConfiguration(keyspec: keyspec,
                                                    isForCheckpointingQueue: false)
        checkpointingQueueConfiguration = Self.buildConfiguration(keyspec: keyspec,
                                                                  isForCheckpointingQueue: true)

        pool = try DatabasePool(path: dbURL.path, configuration: poolConfiguration)
        Logger.debug("dbURL: \(dbURL)")

        let shouldCheckpoint = CurrentAppContext().isMainApp
        if shouldCheckpoint {
            checkpointingQueue = try DatabaseQueue(path: dbURL.path,
                                                   configuration: checkpointingQueueConfiguration)
        } else {
            checkpointingQueue = nil
        }

        OWSFileSystem.protectFileOrFolder(atPath: dbURL.path)
    }

    private static func buildConfiguration(keyspec: GRDBKeySpecSource,
                                           isForCheckpointingQueue: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = false
        configuration.foreignKeysEnabled = true // Default is already true
        configuration.trace = { logString in
            dbQueryLog(logString)
        }
        // Useful when your app opens multiple databases
        configuration.label = (isForCheckpointingQueue
                                ? "GRDB Checkpointing"
                                : "GRDB Storage")
        configuration.maximumReaderCount = 10   // The default is 5
        configuration.busyMode = .callback({ (retryCount: Int) -> Bool in
            // sleep N milliseconds
            let millis = 25
            usleep(useconds_t(millis * 1000))
            Logger.verbose("retryCount: \(retryCount)")
            let accumulatedWaitMs = millis * (retryCount + 1)
            if accumulatedWaitMs > 0, (accumulatedWaitMs % 250) == 0 {
                Logger.warn("Database busy for \(accumulatedWaitMs)ms")
            }

            if isForCheckpointingQueue {
                // The checkpointing queue should time out.
                if accumulatedWaitMs > GRDBStorage.maxBusyTimeoutMs {
                    Logger.warn("Aborting busy retry.")
                    return false
                }
                return true
            } else {
                return true
            }
        })
        configuration.prepareDatabase = { db in
            try GRDBDatabaseStorageAdapter.prepareDatabase(db: db, keyspec: keyspec)
        }
        configuration.defaultTransactionKind = .immediate
        configuration.allowsUnsafeTransactions = true
        return configuration
    }
}

// MARK: -

public struct GRDBKeySpecSource {

    private var kSQLCipherKeySpecLength: UInt {
        GRDBDatabaseStorageAdapter.kSQLCipherKeySpecLength
    }

    let keyServiceName: String
    let keyName: String

    func fetchString() throws -> String {
        // Use a raw key spec, where the 96 hexadecimal digits are provided
        // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
        // using explicit BLOB syntax, e.g.:
        //
        // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
        let data = try fetchData()

        guard data.count == kSQLCipherKeySpecLength else {
            owsFail("unexpected keyspec length")
        }

        let passphrase = "x'\(data.hexadecimalString)'"
        return passphrase
    }

    public func fetchData() throws -> Data {
        return try CurrentAppContext().keychainStorage().data(forService: keyServiceName, key: keyName)
    }

    func clear() throws {
        Logger.info("")

        try CurrentAppContext().keychainStorage().remove(service: keyServiceName, key: keyName)
    }

    func generateAndStore() {
        Logger.info("")

        do {
            let keyData = Randomness.generateRandomBytes(Int32(kSQLCipherKeySpecLength))
            try store(data: keyData)
        } catch {
            owsFail("Could not generate key for GRDB: \(error)")
        }
    }

    public func store(data: Data) throws {
        guard data.count == kSQLCipherKeySpecLength else {
            owsFail("unexpected keyspec length")
        }
        try CurrentAppContext().keychainStorage().set(data: data, service: keyServiceName, key: keyName)
    }
}

// MARK: -

extension GRDBDatabaseStorageAdapter {
    public var databaseFilePath: String {
        return databaseUrl.path
    }

    public var databaseWALFilePath: String {
        return databaseUrl.path + "-wal"
    }

    public var databaseSHMFilePath: String {
        return databaseUrl.path + "-shm"
    }

    static func removeAllFiles(baseDir: URL) {
        let databaseUrl = GRDBDatabaseStorageAdapter.databaseFileUrl(baseDir: baseDir)
        OWSFileSystem.deleteFileIfExists(databaseUrl.path)
        OWSFileSystem.deleteFileIfExists(databaseUrl.path + "-wal")
        OWSFileSystem.deleteFileIfExists(databaseUrl.path + "-shm")
    }
}

// MARK: - Reporting

extension GRDBDatabaseStorageAdapter {
    var databaseFileSize: UInt64 {
        guard let fileSize = OWSFileSystem.fileSize(ofPath: databaseFilePath) else {
            owsFailDebug("Could not determine file size.")
            return 0
        }
        return fileSize.uint64Value
    }

    var databaseWALFileSize: UInt64 {
        guard let fileSize = OWSFileSystem.fileSize(ofPath: databaseWALFilePath) else {
            owsFailDebug("Could not determine file size.")
            return 0
        }
        return fileSize.uint64Value
    }

    var databaseSHMFileSize: UInt64 {
        guard let fileSize = OWSFileSystem.fileSize(ofPath: databaseSHMFilePath) else {
            owsFailDebug("Could not determine file size.")
            return 0
        }
        return fileSize.uint64Value
    }
}

// MARK: - Checkpoints

public struct GrdbTruncationResult {
    let walSizePages: Int32
    let pagesCheckpointed: Int32
}

extension GRDBDatabaseStorageAdapter {
    @objc
    public func syncTruncatingCheckpoint() throws {
        guard let checkpointingQueue = storage.checkpointingQueue else {
            return
        }

        Logger.info("running truncating checkpoint.")

        SDSDatabaseStorage.shared.logFileSizes()

        let result = try GRDBDatabaseStorageAdapter.checkpoint(checkpointingQueue: checkpointingQueue,
                                                               mode: .truncate)

        Logger.info("walSizePages: \(result.walSizePages), pagesCheckpointed: \(result.pagesCheckpointed)")

        SDSDatabaseStorage.shared.logFileSizes()
    }

    public static func checkpoint(checkpointingQueue: DatabaseQueue,
                                  mode: Database.CheckpointMode) throws -> GrdbTruncationResult {

        var walSizePages: Int32 = 0
        var pagesCheckpointed: Int32 = 0
        try Bench(title: "Slow checkpoint: \(mode)", logIfLongerThan: 0.01, logInProduction: true) {
            #if TESTABLE_BUILD
            let startTime = CACurrentMediaTime()
            #endif
            try checkpointingQueue.inDatabase { db in
                #if TESTABLE_BUILD
                let startElapsedSeconds: TimeInterval = CACurrentMediaTime() - startTime
                let slowStartSeconds: TimeInterval = TimeInterval(GRDBStorage.maxBusyTimeoutMs) / 1000
                if startElapsedSeconds > slowStartSeconds * 2 {
                    // maxBusyTimeoutMs isn't a hard limit, but slow starts should be very rare.
                    let formattedTime = String(format: "%0.2fms", startElapsedSeconds * 1000)
                    owsFailDebug("Slow checkpoint start: \(formattedTime)")
                }
                #endif

                let code = sqlite3_wal_checkpoint_v2(db.sqliteConnection, nil, mode.rawValue, &walSizePages, &pagesCheckpointed)
                switch code {
                case SQLITE_OK:
                    if mode != .passive {
                        Logger.info("Checkpoint succeeded: \(mode).")
                    }
                    break
                case SQLITE_BUSY:
                    // Busy is not an error.
                    Logger.info("Checkpoint \(mode) failed due to busy.")
                    break
                default:
                    throw OWSAssertionError("checkpoint sql error with code: \(code)")
                }
            }
        }
        return GrdbTruncationResult(walSizePages: walSizePages, pagesCheckpointed: pagesCheckpointed)
    }
}

// MARK: -

public extension Error {
    var grdbErrorForLogging: Error {
        // If not a GRDB error, return unmodified.
        guard let grdbError = self as? GRDB.DatabaseError else {
            return self
        }
        // DatabaseError.description includes the arguments.
        Logger.verbose("grdbError: \(grdbError))")
        // DatabaseError.description does not include the extendedResultCode.
        Logger.verbose("resultCode: \(grdbError.resultCode), extendedResultCode: \(grdbError.extendedResultCode), message: \(String(describing: grdbError.message)), sql: \(String(describing: grdbError.sql))")
        let error = GRDB.DatabaseError(resultCode: grdbError.extendedResultCode,
                                       message: grdbError.message,
                                       sql: nil,
                                       arguments: nil)
        return error
    }
}
