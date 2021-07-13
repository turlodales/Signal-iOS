//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public protocol ConversationHeaderViewDelegate {
    func didTapConversationHeaderView(_ conversationHeaderView: ConversationHeaderView)
}

public class ConversationHeaderView: UIStackView {

    public weak var delegate: ConversationHeaderViewDelegate?

    public var attributedTitle: NSAttributedString? {
        get {
            return self.titleLabel.attributedText
        }
        set {
            self.titleLabel.attributedText = newValue
        }
    }

    public var titleIcon: UIImage? {
        get {
            return self.titleIconView.image
        }
        set {
            self.titleIconView.image = newValue
            self.titleIconView.tintColor = Theme.secondaryTextAndIconColor
            self.titleIconView.isHidden = newValue == nil
        }
    }

    public var attributedSubtitle: NSAttributedString? {
        get {
            return self.subtitleLabel.attributedText
        }
        set {
            self.subtitleLabel.attributedText = newValue
            self.subtitleLabel.isHidden = newValue == nil
        }
    }

    public var avatarImage: UIImage? {
        get {
            return self.avatarView.image
        }
        set {
            self.avatarView.image = newValue
        }
    }

    public let titlePrimaryFont: UIFont =  UIFont.ows_semiboldFont(withSize: 17)
    public let titleSecondaryFont: UIFont =  UIFont.ows_regularFont(withSize: 9)
    public let subtitleFont: UIFont = UIFont.ows_regularFont(withSize: 12)

    private let titleLabel: UILabel
    private let titleIconView: UIImageView
    private let subtitleLabel: UILabel
    private let avatarView = ConversationAvatarView(diameterPoints: 36,
                                                    localUserDisplayMode: .noteToSelf)

    public required init() {
        // remove default border on avatarView
        avatarView.layer.borderWidth = 0

        titleLabel = UILabel()
        titleLabel.textColor = Theme.navbarTitleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = titlePrimaryFont
        titleLabel.setContentHuggingHigh()

        titleIconView = UIImageView()
        titleIconView.contentMode = .scaleAspectFit
        titleIconView.setCompressionResistanceHigh()

        let titleColumns = UIStackView(arrangedSubviews: [titleLabel, titleIconView])
        titleColumns.spacing = 5

        subtitleLabel = UILabel()
        subtitleLabel.textColor = Theme.navbarTitleColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = subtitleFont
        subtitleLabel.setContentHuggingHigh()

        let textRows = UIStackView(arrangedSubviews: [titleColumns, subtitleLabel])
        textRows.axis = .vertical
        textRows.alignment = .leading
        textRows.distribution = .fillProportionally
        textRows.spacing = 0

        textRows.layoutMargins = UIEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        textRows.isLayoutMarginsRelativeArrangement = true

        // low content hugging so that the text rows push container to the right bar button item(s)
        textRows.setContentHuggingLow()

        super.init(frame: .zero)

        self.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        self.isLayoutMarginsRelativeArrangement = true

        self.axis = .horizontal
        self.alignment = .center
        self.spacing = 0
        self.addArrangedSubview(avatarView)
        self.addArrangedSubview(textRows)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapView))
        self.addGestureRecognizer(tapGesture)

        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange), name: .ThemeDidChange, object: nil)
    }

    required public init(coder: NSCoder) {
        notImplemented()
    }

    required public override init(frame: CGRect) {
        notImplemented()
    }

    public func configure(thread: TSThread) {
        avatarView.configureWithSneakyTransaction(thread: thread)
    }

    public override var intrinsicContentSize: CGSize {
        // Grow to fill as much of the navbar as possible.
        return UIView.layoutFittingExpandedSize
    }

    @objc
    func themeDidChange() {
        titleLabel.textColor = Theme.navbarTitleColor
        subtitleLabel.textColor = Theme.navbarTitleColor
    }

    public func updateAvatar() {
        databaseStorage.read { transaction in
            self.avatarView.updateImage(transaction: transaction)
        }
    }

    // MARK: Delegate Methods

    @objc func didTapView(tapGesture: UITapGestureRecognizer) {
        guard tapGesture.state == .recognized else {
            return
        }

        self.delegate?.didTapConversationHeaderView(self)
    }
}
