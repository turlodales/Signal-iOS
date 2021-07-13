//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc(OWSUnreadIndicatorInteraction)
public class UnreadIndicatorInteraction: TSInteraction {

    public override func isDynamicInteraction() -> Bool {
        return true
    }

    public override func interactionType() -> OWSInteractionType {
        return .unreadIndicator
    }

    @available(*, unavailable, message: "use other constructor instead.")
    public required init(coder aDecoder: NSCoder) {
        notImplemented()
    }

    @available(*, unavailable, message: "use other constructor instead.")
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        notImplemented()
    }

    public init(thread: TSThread, timestamp: UInt64, receivedAtTimestamp: UInt64) {
        // Include timestamp in uniqueId to ensure invariant that
        // interactions don't move in the chat history ordering.
        super.init(uniqueId: "UnreadIndicator_\(timestamp)",
                   timestamp: timestamp,
                   receivedAtTimestamp: receivedAtTimestamp,
                   thread: thread)
    }

    public override var shouldBeSaved: Bool {
        return false
    }

    public override func anyWillInsert(with transaction: SDSAnyWriteTransaction) {
        owsFailDebug("The transient interaction should not be saved in the database.")
    }
}
