//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc(OWSTypingIndicatorInteraction)
public class TypingIndicatorInteraction: TSInteraction {
    public static let TypingIndicatorId = "TypingIndicator"

    public override func isDynamicInteraction() -> Bool {
        return true
    }

    public override func interactionType() -> OWSInteractionType {
        return .typingIndicator
    }

    @available(*, unavailable, message: "use other constructor instead.")
    public required init(coder aDecoder: NSCoder) {
        notImplemented()
    }

    @available(*, unavailable, message: "use other constructor instead.")
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        notImplemented()
    }

    public let address: SignalServiceAddress

    public init(thread: TSThread, timestamp: UInt64, address: SignalServiceAddress) {
        self.address = address

        super.init(uniqueId: TypingIndicatorInteraction.TypingIndicatorId,
            timestamp: timestamp, thread: thread)
    }

    public override var shouldBeSaved: Bool {
        return false
    }

    public override func anyWillInsert(with transaction: SDSAnyWriteTransaction) {
        owsFailDebug("The transient interaction should not be saved in the database.")
    }
}
