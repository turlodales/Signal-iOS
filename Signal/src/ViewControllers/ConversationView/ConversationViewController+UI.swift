//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

extension ConversationViewController {
    public func updateNavigationTitle() {
        AssertIsOnMainThread()

        self.title = nil

        var name: String?
        var attributedName: NSAttributedString?
        var icon: UIImage?
        if let contactThread = thread as? TSContactThread {
            if thread.isNoteToSelf {
                name = MessageStrings.noteToSelf
            } else {
                name = contactsManager.displayName(for: contactThread.contactAddress)
            }

            // If the user is in the system contacts, show a badge
            if self.contactsManagerImpl.isSystemContact(address: contactThread.contactAddress) {
                icon = UIImage(named: "contact-outline-16")?.withRenderingMode(.alwaysTemplate)
            }
        } else if let groupThread = thread as? TSGroupThread {
            name = groupThread.groupNameOrDefault
        } else {
            owsFailDebug("Invalid thread.")
        }

        self.headerView.titleIcon = icon

        if nil == attributedName,
           let unattributedName = name {
            attributedName = NSAttributedString(string: unattributedName,
                                                attributes: [
                                                    .foregroundColor: Theme.primaryTextColor
                                                ])
        }

        if attributedName == headerView.attributedTitle {
            return
        }
        headerView.attributedTitle = attributedName
    }

    public func createHeaderViews() {
        AssertIsOnMainThread()

        headerView.configure(thread: thread)
        headerView.accessibilityLabel = NSLocalizedString("CONVERSATION_SETTINGS",
                                                          comment: "title for conversation settings screen")
        headerView.accessibilityIdentifier = "headerView"
        headerView.delegate = self
        navigationItem.titleView = headerView

        if shouldUseDebugUI() {
            headerView.addGestureRecognizer(UILongPressGestureRecognizer(
                target: self,
                action: #selector(navigationTitleLongPressed)
            ))
        }

        updateNavigationBarSubtitleLabel()
    }

    @objc
    private func navigationTitleLongPressed(_ gestureRecognizer: UIGestureRecognizer) {
        AssertIsOnMainThread()

        if gestureRecognizer.state == .began {
            showDebugUI(thread, self)
        }
    }

    public var unreadCountViewDiameter: CGFloat { 16 }

    public func updateBarButtonItems() {
        AssertIsOnMainThread()

        // Don't include "Back" text on view controllers pushed above us, just use the arrow.
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "",
                                                           style: .plain,
                                                           target: nil,
                                                           action: nil)

        navigationItem.hidesBackButton = false
        navigationItem.leftBarButtonItem = nil
        self.groupCallBarButtonItem = nil

        switch uiMode {
        case .search:
            if self.userLeftGroup {
                navigationItem.rightBarButtonItems = []
                return
            }
            if #available(iOS 13, *) {
                owsAssertDebug(navigationItem.searchController != nil)
            } else {
                navigationItem.rightBarButtonItems = []
                navigationItem.leftBarButtonItem = nil
                navigationItem.hidesBackButton = true
            }
            return
        case .selection:
            navigationItem.rightBarButtonItems = [ self.cancelSelectionBarButtonItem ]
            navigationItem.leftBarButtonItem = self.deleteAllBarButtonItem
            navigationItem.hidesBackButton = true
            return
        case .normal:
            if self.userLeftGroup {
                navigationItem.rightBarButtonItems = []
                return
            }
            var barButtons = [UIBarButtonItem]()
            if self.canCall {
                if self.isGroupConversation {
                    let videoCallButton = UIBarButtonItem()

                    if threadViewModel.groupCallInProgress {
                        let pill = JoinGroupCallPill()
                        pill.addTarget(self,
                                       action: #selector(showGroupLobbyOrActiveCall),
                                       for: .touchUpInside)
                        let returnString = NSLocalizedString("RETURN_CALL_PILL_BUTTON",
                                                             comment: "Button to return to current group call")
                        let joinString = NSLocalizedString("JOIN_CALL_PILL_BUTTON",
                                                           comment: "Button to join an active group call")
                        pill.buttonText = self.isCurrentCallForThread ? returnString : joinString
                        videoCallButton.customView = pill
                    } else {
                        videoCallButton.image = Theme.iconImage(.videoCall)
                        videoCallButton.target = self
                        videoCallButton.action = #selector(showGroupLobbyOrActiveCall)
                    }

                    videoCallButton.isEnabled = (self.callService.currentCall == nil
                                                    || self.isCurrentCallForThread)
                    videoCallButton.accessibilityLabel = NSLocalizedString("VIDEO_CALL_LABEL",
                                                                           comment: "Accessibility label for placing a video call")
                    self.groupCallBarButtonItem = videoCallButton
                    barButtons.append(videoCallButton)
                } else {
                    let audioCallButton = UIBarButtonItem(
                        image: Theme.iconImage(.audioCall),
                        style: .plain,
                        target: self,
                        action: #selector(startIndividualAudioCall)
                    )
                    audioCallButton.isEnabled = !Self.windowManager.hasCall
                    audioCallButton.accessibilityLabel = NSLocalizedString("AUDIO_CALL_LABEL",
                                                                           comment: "Accessibility label for placing an audio call")
                    barButtons.append(audioCallButton)

                    let videoCallButton = UIBarButtonItem(
                        image: Theme.iconImage(.videoCall),
                        style: .plain,
                        target: self,
                        action: #selector(startIndividualVideoCall)
                    )
                    videoCallButton.isEnabled = !Self.windowManager.hasCall
                    videoCallButton.accessibilityLabel = NSLocalizedString("VIDEO_CALL_LABEL",
                                                                           comment: "Accessibility label for placing a video call")
                    barButtons.append(videoCallButton)
                }
            }

            navigationItem.rightBarButtonItems = barButtons
            showGroupCallTooltipIfNecessary()
            return
        }
    }

    public func updateNavigationBarSubtitleLabel() {
        AssertIsOnMainThread()

        let hasCompactHeader = self.traitCollection.verticalSizeClass == .compact
        if hasCompactHeader {
            self.headerView.attributedSubtitle = nil
            return
        }

        let subtitleText = NSMutableAttributedString()
        let subtitleFont = self.headerView.subtitleFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: Theme.navbarTitleColor.withAlphaComponent(0.9)
        ]
        let hairSpace = "\u{200a}"
        let thinSpace = "\u{2009}"
        let iconSpacer = UIDevice.current.isNarrowerThanIPhone6 ? hairSpace : thinSpace
        let betweenItemSpacer = UIDevice.current.isNarrowerThanIPhone6 ? " " : "  "

        let isMuted = threadViewModel.isMuted
        let hasTimer = disappearingMessagesConfiguration.isEnabled
        var isVerified = thread.recipientAddresses.count > 0
        for address in thread.recipientAddresses {
            if Self.identityManager.verificationState(for: address) != .verified {
                isVerified = false
                break
            }
        }

        if isMuted {
            subtitleText.appendTemplatedImage(named: "bell-disabled-outline-24", font: subtitleFont)
            if !isVerified {
                subtitleText.append(iconSpacer, attributes: attributes)
                subtitleText.append(NSLocalizedString("MUTED_BADGE",
                                                      comment: "Badge indicating that the user is muted."),
                                    attributes: attributes)
            }
        }

        if hasTimer {
            if isMuted {
                subtitleText.append(betweenItemSpacer, attributes: attributes)
            }

            subtitleText.appendTemplatedImage(named: "timer-outline-16", font: subtitleFont)
            subtitleText.append(iconSpacer, attributes: attributes)
            subtitleText.append(NSString.formatDurationSeconds(
                disappearingMessagesConfiguration.durationSeconds,
                useShortFormat: true
            ),
            attributes: attributes)
        }

        if isVerified {
            if hasTimer || isMuted {
                subtitleText.append(betweenItemSpacer, attributes: attributes)
            }

            subtitleText.appendTemplatedImage(named: "check-12", font: subtitleFont)
            subtitleText.append(iconSpacer, attributes: attributes)
            subtitleText.append(NSLocalizedString("PRIVACY_IDENTITY_IS_VERIFIED_BADGE",
                                                  comment: "Badge indicating that the user is verified."),
                                attributes: attributes)
        }

        headerView.attributedSubtitle = subtitleText
    }

    public var safeContentHeight: CGFloat {
        // Don't use self.collectionView.contentSize.height as the collection view's
        // content size might not be set yet.
        //
        // We can safely call prepareLayout to ensure the layout state is up-to-date
        // since our layout uses a dirty flag internally to debounce redundant work.
        collectionView.collectionViewLayout.collectionViewContentSize.height
    }

    public func buildInputToolbar(conversationStyle: ConversationStyle,
                                  messageDraft: MessageBody?,
                                  voiceMemoDraft: VoiceMessageModel?) -> ConversationInputToolbar {
        AssertIsOnMainThread()
        owsAssertDebug(hasViewWillAppearEverBegun)

        let inputToolbar = ConversationInputToolbar(conversationStyle: conversationStyle,
                                                    messageDraft: messageDraft,
                                                    inputToolbarDelegate: self,
                                                    inputTextViewDelegate: self,
                                                    mentionDelegate: self)
        inputToolbar.accessibilityIdentifier = "inputToolbar"

        if let voiceMemoDraft = voiceMemoDraft {
            inputToolbar.showVoiceMemoDraft(voiceMemoDraft)
        }

        return inputToolbar
    }
}
// MARK: - Keyboard Shortcuts

public extension ConversationViewController {
    func focusInputToolbar() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.clearDesiredKeyboard()
        self.popKeyBoard()
    }

    func openAllMedia() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }

        self.showConversationSettingsAndShowAllMedia()
    }

    func openStickerKeyboard() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.showStickerKeyboard()
    }

    func openAttachmentKeyboard() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.showAttachmentKeyboard()
    }

    func openGifSearch() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard nil != inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        self.showGifPicker()
    }
}
