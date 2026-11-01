import UIKit

/// VS Code's activity bar on the leading edge of the IDE pane. Run/Stop sits on top, then the
/// side bar views (Explorer, Search, Source Control) and extensions' own view containers;
/// Accounts, Settings and Home (the Welcome page) are pinned to the bottom.
final class LeftActivityRail: UIView, UIScrollViewDelegate {
    var onRunStopTap: (() -> Void)?
    var onFilesTap: (() -> Void)?
    var onSearchTap: (() -> Void)?
    var onGitTap: (() -> Void)?
    var onExtensionsTap: (() -> Void)?
    var onDebugTap: (() -> Void)?
    var onViewsTap: (() -> Void)?
    /// An extension's view container was tapped (its id).
    var onContainerTap: ((String) -> Void)?
    var onHomeTap: (() -> Void)?
    var onSettingsTap: (() -> Void)?
    var onSignIn: (() -> Void)?

    static let width: CGFloat = 44

    private let runButton = UIButton(type: .custom)
    private let filesBtn = UIButton(type: .custom)
    private let searchBtn = UIButton(type: .custom)
    private let gitBtn = UIButton(type: .custom)
    private let extensionsBtn = UIButton(type: .custom)
    private let debugBtn = UIButton(type: .custom)
    private let viewsBtn = UIButton(type: .custom)
    private let accountBtn = UIButton(type: .custom)
    private let homeBtn = UIButton(type: .custom)
    private let settingsBtn = UIButton(type: .custom)
    private let gitBadge = PaddedLabel()
    private let topStack = UIStackView()
    /// The top buttons scroll when the rail is too short for them and the bottom ones (a phone in
    /// landscape, Split View), rather than running into Accounts, Settings and Welcome.
    private let topScroll = UIScrollView()
    /// Extensions' view containers, in order: (id, button).
    private var containerButtons: [(id: String, button: UIButton)] = []
    /// The container whose views the side bar shows (with the .views tab).
    private var activeContainer: String?
    private var topStackTop: NSLayoutConstraint?
    private var homeBottom: NSLayoutConstraint?

    private let activeStrip = UIView()
    private var activeTab: SidebarTab?
    private var isRunning = false

    /// VS Code's debug start and stop colours.
    private static let runColor = VS.hex(0x89D185)
    private static let stopColor = VS.hex(0xF48771)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupRail()
        setActiveTab(.files)
        setRunning(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupRail() {
        backgroundColor = VS.activityBar

        activeStrip.backgroundColor = .white
        addSubview(activeStrip)

        setupIcon(runButton, icon: .play, label: "Run", action: #selector(runTapped))
        setupIcon(filesBtn, icon: .files, label: "Explorer", action: #selector(filesTapped))
        setupIcon(searchBtn, icon: .search, label: "Search", action: #selector(searchTapped))
        setupIcon(gitBtn, icon: .sourceControl, label: "Source Control", action: #selector(gitTapped))
        setupIcon(extensionsBtn, icon: .extensions, label: "Extensions", action: #selector(extensionsTapped))
        setupIcon(debugBtn, icon: .debugAlt, label: "Run and Debug", action: #selector(debugTapped))
        setupIcon(viewsBtn, icon: .listTree, label: "Extension Views", action: #selector(viewsTapped))
        viewsBtn.isHidden = true
        setupIcon(accountBtn, icon: .account, label: "Accounts", action: nil)
        setupIcon(settingsBtn, icon: .settingsGear, label: "Settings", action: #selector(settingsTapped))
        setupIcon(homeBtn, icon: .home, label: "Welcome", action: #selector(homeTapped))
        for button in [accountBtn, settingsBtn, homeBtn] { button.tintColor = VS.activityBarInactive }

        accountBtn.menu = UIMenu(children: [AutomationMenus.deferred { [weak self] done in
            done(self?.accountMenu() ?? [])
        }])
        accountBtn.showsMenuAsPrimaryAction = true

        // The Source Control badge counts pending changes, as VS Code's does.
        gitBadge.insets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        gitBadge.font = .systemFont(ofSize: 9, weight: .semibold)
        gitBadge.textColor = .white
        gitBadge.backgroundColor = VS.activityBarBadge
        gitBadge.textAlignment = .center
        gitBadge.layer.cornerRadius = 8
        gitBadge.clipsToBounds = true
        gitBadge.isHidden = true
        gitBadge.isUserInteractionEnabled = false
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        gitBtn.addSubview(gitBadge)

        for button in [runButton, filesBtn, searchBtn, gitBtn, debugBtn, extensionsBtn, viewsBtn] { topStack.addArrangedSubview(button) }
        topStack.axis = .vertical
        topStack.spacing = 8
        topStack.alignment = .center
        topStack.setCustomSpacing(16, after: runButton)
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topScroll.showsVerticalScrollIndicator = false
        topScroll.alwaysBounceVertical = false
        topScroll.delegate = self
        topScroll.translatesAutoresizingMaskIntoConstraints = false
        topScroll.addSubview(topStack)
        addSubview(topScroll)
        // The active strip is beside a button in the scroll view, so it's drawn over it.
        bringSubviewToFront(activeStrip)

        let bottomStack = UIStackView(arrangedSubviews: [accountBtn, settingsBtn, homeBtn])
        bottomStack.axis = .vertical
        bottomStack.spacing = 8
        bottomStack.alignment = .center
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomStack)

        // As tall as the buttons, up to the bottom group; any taller and it scrolls.
        let fitContent = topScroll.heightAnchor.constraint(equalTo: topScroll.contentLayoutGuide.heightAnchor)
        fitContent.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            topScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            topScroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomStack.topAnchor, constant: -12),
            fitContent,
            topStack.topAnchor.constraint(equalTo: topScroll.contentLayoutGuide.topAnchor),
            topStack.bottomAnchor.constraint(equalTo: topScroll.contentLayoutGuide.bottomAnchor),
            topStack.leadingAnchor.constraint(equalTo: topScroll.contentLayoutGuide.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: topScroll.contentLayoutGuide.trailingAnchor),
            topStack.widthAnchor.constraint(equalTo: topScroll.frameLayoutGuide.widthAnchor),
            bottomStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            gitBadge.heightAnchor.constraint(equalToConstant: 16),
            gitBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            gitBadge.trailingAnchor.constraint(equalTo: gitBtn.trailingAnchor, constant: 2),
            gitBadge.bottomAnchor.constraint(equalTo: gitBtn.bottomAnchor, constant: 0),
        ])
        topStackTop = topScroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.edgePadding)
        homeBottom = bottomStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.edgePadding)
        topStackTop?.isActive = true
        homeBottom?.isActive = true
    }

    private static let edgePadding: CGFloat = 8

    /// Extra space above the first and below the last button, e.g. to clear a rounded screen corner.
    func setEdgeInsets(top: CGFloat, bottom: CGFloat) {
        topStackTop?.constant = Self.edgePadding + top
        homeBottom?.constant = -(Self.edgePadding + bottom)
    }

    private func setupIcon(_ btn: UIButton, icon: Codicon, label: String, action: Selector?) {
        btn.setImage(icon.image(22), for: .normal)
        btn.accessibilityLabel = label
        btn.isPointerInteractionEnabled = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 36),
            btn.heightAnchor.constraint(equalToConstant: 40),
        ])
        if let action { btn.addTarget(self, action: action, for: .touchUpInside) }
    }

    private func accountMenu() -> [UIMenuElement] {
        let accounts = GitAccountManager.shared
        if accounts.isSignedIn, let user = accounts.currentUser {
            return [
                UIAction(title: "\(user.login) (GitHub)", image: Codicon.account.image(), attributes: .disabled) { _ in },
                UIAction(title: "Sign Out", image: Codicon.signOut.image(), attributes: .destructive) { _ in accounts.signOut() },
            ]
        }
        return [UIAction(title: "Sign in with GitHub to use Source Control", image: Codicon.signIn.image()) { [weak self] _ in
            self?.onSignIn?()
        }]
    }

    /// The number on the Source Control icon; hidden at zero.
    func setChangeCount(_ count: Int) {
        gitBadge.isHidden = count == 0
        gitBadge.text = count > 999 ? "1k+" : "\(count)"
        gitBtn.accessibilityValue = count == 0 ? nil : "\(count) pending changes"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeActiveStrip()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placeActiveStrip()
    }

    /// Beside the active button, cut to the part of it that's scrolled into view.
    private func placeActiveStrip() {
        guard let btn = button(for: activeTab) else { return }
        let f = btn.convert(btn.bounds, to: self).intersection(topScroll.frame)
        activeStrip.alpha = f.isNull || f.height < 1 ? 0 : 1
        if !f.isNull { activeStrip.frame = CGRect(x: 0, y: f.minY, width: 2, height: f.height) }
    }

    /// Scrolls the active button into view (it may have been opened from a menu or shortcut).
    private func revealActiveButton() {
        guard let btn = button(for: activeTab), topScroll.contentSize.height > topScroll.bounds.height else { return }
        topScroll.scrollRectToVisible(btn.convert(btn.bounds, to: topScroll).insetBy(dx: 0, dy: -4), animated: true)
    }

    private func button(for tab: SidebarTab?) -> UIButton? {
        guard let tab else { return nil }
        switch tab {
        case .files: return filesBtn
        case .search: return searchBtn
        case .git: return gitBtn
        case .extensions: return extensionsBtn
        case .debug: return debugBtn
        case .views: return containerButtons.first { $0.id == activeContainer }?.button ?? viewsBtn
        }
    }

    /// Highlights the open side bar view, or nothing when the side bar is closed.
    func setActiveTab(_ tab: SidebarTab?) {
        activeTab = tab
        for t in [SidebarTab.files, .search, .git, .debug, .extensions] {
            button(for: t)?.tintColor = (t == tab) ? .white : VS.activityBarInactive
        }
        let views = tab == .views ? button(for: .views) : nil
        for button in [viewsBtn] + containerButtons.map(\.button) {
            button.tintColor = button === views ? .white : VS.activityBarInactive
        }
        activeStrip.isHidden = (tab == nil)
        setNeedsLayout()
        UIView.animate(withDuration: 0.2) { self.layoutIfNeeded() }
        revealActiveButton()
    }

    func setRunning(_ running: Bool) {
        isRunning = running
        runButton.setImage((running ? Codicon.debugStop : .play).image(22), for: .normal)
        runButton.tintColor = running ? Self.stopColor : Self.runColor
        runButton.accessibilityLabel = running ? "Stop" : "Run"
    }

    @objc private func runTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onRunStopTap?()
    }

    @objc private func filesTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onFilesTap?()
    }

    @objc private func searchTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSearchTap?()
    }

    @objc private func gitTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onGitTap?()
    }

    @objc private func debugTapped() {
        onDebugTap?()
    }

    /// The Extension Views button shows only while an extension adds views.
    func setViewsAvailable(_ available: Bool) {
        viewsBtn.isHidden = !available
        setNeedsLayout()
    }

    /// Extensions' own view containers, each a button after Extension Views. Icons come later
    /// (setContainerIcon); until then a generic one shows.
    func setContainers(_ containers: [(id: String, title: String)], active: String?) {
        guard containers.map(\.id) != containerButtons.map(\.id) else { return setActiveContainer(active) }
        for (_, button) in containerButtons { button.removeFromSuperview() }
        containerButtons = containers.map { container in
            let button = UIButton(type: .custom)
            setupIcon(button, icon: .listFlat, label: container.title, action: nil)
            button.addAction(UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.onContainerTap?(container.id)
            }, for: .touchUpInside)
            topStack.addArrangedSubview(button)
            return (container.id, button)
        }
        setActiveContainer(active)
    }

    func setContainerIcon(_ id: String, _ image: UIImage) {
        containerButtons.first { $0.id == id }?.button.setImage(image, for: .normal)
    }

    /// Which container the open .views side bar shows (nil: Extension Views).
    func setActiveContainer(_ id: String?) {
        activeContainer = id
        setActiveTab(activeTab)
    }

    @objc private func viewsTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onViewsTap?()
    }

    @objc private func extensionsTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onExtensionsTap?()
    }

    @objc private func settingsTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSettingsTap?()
    }

    @objc private func homeTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onHomeTap?()
    }
}
