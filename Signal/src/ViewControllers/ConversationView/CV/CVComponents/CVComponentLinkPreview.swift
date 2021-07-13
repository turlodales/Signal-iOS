//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

public class CVComponentLinkPreview: CVComponentBase, CVComponent {

    private let linkPreviewState: CVComponentState.LinkPreview

    init(itemModel: CVItemModel,
         linkPreviewState: CVComponentState.LinkPreview) {
        self.linkPreviewState = linkPreviewState

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewLinkPreview()
    }

    public func configureForRendering(componentView componentViewParam: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        guard let componentView = componentViewParam as? CVComponentViewLinkPreview else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let linkPreviewView = componentView.linkPreviewView
        linkPreviewView.configureForRendering(state: linkPreviewState.state,
                                              isDraft: false,
                                              hasAsymmetricalRounding: false,
                                              cellMeasurement: cellMeasurement)
    }

    private var stackConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .vertical,
                          alignment: .fill,
                          spacing: 0,
                          layoutMargins: .zero)
    }

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let maxWidth = min(maxWidth, conversationStyle.maxMediaMessageWidth)
        return LinkPreviewView.measure(maxWidth: maxWidth,
                                       measurementBuilder: measurementBuilder,
                                       state: linkPreviewState.state,
                                       isDraft: false)
    }

    // MARK: - Events

    public override func handleTap(sender: UITapGestureRecognizer,
                                   componentDelegate: CVComponentDelegate,
                                   componentView: CVComponentView,
                                   renderItem: CVRenderItem) -> Bool {

        componentDelegate.cvc_didTapLinkPreview(linkPreviewState.linkPreview)
        return true
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewLinkPreview: NSObject, CVComponentView {

        fileprivate let linkPreviewView = LinkPreviewView(draftDelegate: nil)

        public var isDedicatedCellView = false

        public var rootView: UIView {
            linkPreviewView
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            linkPreviewView.reset()
        }
    }
}
