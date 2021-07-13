//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// Represents a _playable_ audio attachment.
public class AudioAttachment: NSObject {
    public enum State {
        case attachmentStream(attachmentStream: TSAttachmentStream, audioDurationSeconds: TimeInterval)
        case attachmentPointer(attachmentPointer: TSAttachmentPointer)
    }
    public let state: State

    public var attachment: TSAttachment {
        switch state {
        case .attachmentStream(let attachmentStream, _):
            return attachmentStream
        case .attachmentPointer(let attachmentPointer):
            return attachmentPointer
        }
    }

    public var attachmentStream: TSAttachmentStream? {
        switch state {
        case .attachmentStream(let attachmentStream, _):
            return attachmentStream
        case .attachmentPointer:
            return nil
        }
    }

    public var attachmentPointer: TSAttachmentPointer? {
        switch state {
        case .attachmentStream:
            return nil
        case .attachmentPointer(let attachmentPointer):
            return attachmentPointer
        }
    }

    public let owningMessage: TSMessage?

    public var durationSeconds: TimeInterval {
        switch state {
        case .attachmentStream(_, let audioDurationSeconds):
            return audioDurationSeconds
        case .attachmentPointer:
            return 0
        }
    }

    public required init?(attachment: TSAttachment, owningMessage: TSMessage?) {
        if let attachmentStream = attachment as? TSAttachmentStream {
            let audioDurationSeconds = attachmentStream.audioDurationSeconds()
            guard audioDurationSeconds > 0 else {
                return nil
            }
            state = .attachmentStream(attachmentStream: attachmentStream, audioDurationSeconds: audioDurationSeconds)
        } else if let attachmentPointer = attachment as? TSAttachmentPointer {
            state = .attachmentPointer(attachmentPointer: attachmentPointer)
        } else {
            owsFailDebug("Invalid attachment.")
            return nil
        }

        self.owningMessage = owningMessage
    }

    public func markOwningMessageAsViewed() -> Bool {
        AssertIsOnMainThread()
        guard let incomingMessage = owningMessage as? TSIncomingMessage, !incomingMessage.wasViewed else { return false }
        databaseStorage.asyncWrite { transaction in
            let thread = incomingMessage.thread(transaction: transaction)
            let circumstance: OWSReceiptCircumstance =
                thread.hasPendingMessageRequest(transaction: transaction.unwrapGrdbWrite)
                ? .onThisDeviceWhilePendingMessageRequest
                : .onThisDevice
            incomingMessage.markAsViewed(
                atTimestamp: Date.ows_millisecondTimestamp(),
                thread: thread,
                circumstance: circumstance,
                transaction: transaction
            )
        }
        return true
    }
}
