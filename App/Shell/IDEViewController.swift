import UIKit

/// Top-level IDE screen: the IDE pane (activity rail, sidebar, editor) and, while a game runs,
/// the game stage. Portrait stacks the game above the IDE; landscape puts them side by side.
///
/// On regular iPhones the game stage is sized to fit the game and the sidebar slides over the
/// editor. On the iPhone Duo's inner display each pane gets one half and the seam between them
/// sits on the physical hinge.
final class IDEViewController: UIViewController, DuoLayoutManagerDelegate, UIGestureRecognizerDelegate {
    private let activityRail = LeftActivityRail()
    private let sidebarView = LeftSidebarView()
    private let sidebarScrim = UIControl()
    private let editor = EditorWebView()
    private let gameStage = GameStageView()
    private var gamePane: GamePaneView { gameStage.gamePane }

    private let contentArea = UIView()
    private let idePane = UIView()
    private let separator = PaneSeparatorView()
    private let errorBanner = ErrorBannerView()
    /// The error the banner shows; nil when it's hidden.
    private var bannerError: (message: String, file: String?, line: Int)?

    private let statusBar = UIView()
    private let statusBackdrop = UIView()
    private let statusLeftLabel = UILabel()
    private let statusRightLabel = UILabel()
    /// The project's interpreter, as VS Code shows the language or Python interpreter; tap to change it.
    private let interpreterButton = UIButton(type: .system)

    private lazy var runtimeHost = RuntimeHost(containerView: gamePane)
    private let duoManager = DuoLayoutManager.shared

    private var layout = DuoLayout(display: .phone, isVertical: true)
    private var isGameVisible = false
    private var isGameMaximized = false
    private var screensSwapped = false
    private var isSidebarOpen = true
    /// `nil` until the first layout decides between a docked and an overlay sidebar.
    private var isSidebarDocked: Bool?
    private var runningRuntimeName: String?
    /// The current run reported a script error; its stage stays open after the game exits.
    private var runHadError = false
    /// The user pressed Stop, so the stage closes even if the run had errors.
    private var stopRequested = false
    private var isStarting = false
    private var didShowWelcome = false

    private static let sidebarDockedWidth: CGFloat = 240
    private static let sidebarOverlayMaxWidth: CGFloat = 280
    /// IDE panes at least this wide keep the sidebar docked beside the editor.
    private static let minWidthForDockedSidebar: CGFloat = 600
    private static let statusBarHeight: CGFloat = 22
    private static let vsCodeBlue = UIColor(red: 0.0, green: 0.48, blue: 0.8, alpha: 1)

    private var gameFocused = false {
        didSet {
            runtimeHost.inputFocused = gameFocused
            gamePane.setFocused(gameFocused)
            if gameFocused {
                editor.webView.resignFirstResponder()
                gamePane.becomeFirstResponder()
            }
            setNeedsUpdateOfPrefersPointerLocked()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            updateStatus()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: name, object: nil)
        }
        view.backgroundColor = Self.rootBackground

        setupPanes()
        setupActivityRail()
        setupSidebar()
        setupGameStage()
        setupStatusBar()

        duoManager.delegate = self
        duoManager.attach(to: view)

        runtimeHost.delegate = self
        gamePane.onTap = { [weak self] in self?.gameFocused = true }
        gameStage.onInput = { [weak self] line in
            guard let self, self.runtimeHost.isRunning else { return }
            self.appendLog("› " + line)
            // Paused in the debugger, the console is the Debug Console: it evaluates.
            if DebugSession.shared.state == .paused {
                DebugSession.shared.evaluate(line, context: "repl") { [weak self] value, error in
                    if let error { self?.appendLog("[error] " + error) } else if let value, !value.value.isEmpty { self?.appendLog(value.value) }
                }
                return
            }
            self.runtimeHost.sendInput(line)
        }
        setupDebugging()
        gamePane.onLayout = { [weak self] in self?.runtimeHost.containerResized() }
        editor.onCommand = { [weak self] cmd, _ in self?.handle(command: cmd) }

        let runtimes = RuntimeManager.shared.runtimes.map(\.manifest.id).joined(separator: ", ")
        appendLog("Mobile Studio ready. Runtimes: [\(runtimes)]")

        if let crashLogCStr = dc_get_last_crash_log(), let crashLog = String(utf8String: crashLogCStr), !crashLog.isEmpty {
            appendLog("\n⚠️ PREVIOUS CRASH REPORT DETECTED:\n\(crashLog)")
            appendLog("Full report also saved to Files app: On My iPhone -> Mobile Studio -> crash.log\n")
        }

        updateStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let screenSize = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
        updateSideEdges()
        layout = duoManager.layout(for: view.bounds, screenSize: screenSize)
        layoutPanes()
    }

    private static let rootBackground = UIColor(white: 0.08, alpha: 1)

    private var safeSideConstraints: [NSLayoutConstraint] = []
    private var edgeSideConstraints: [NSLayoutConstraint] = []

    /// Folded, the cover display's side inset (where the Dynamic Island sits) is more useful as
    /// screen space, so the IDE runs under it. Everywhere else it keeps to the safe area.
    private func updateSideEdges() {
        let useEdges = DuoLayoutManager.shared.hingeStatus == .closed
        guard edgeSideConstraints.first?.isActive != useEdges else { return }
        NSLayoutConstraint.deactivate(useEdges ? safeSideConstraints : edgeSideConstraints)
        NSLayoutConstraint.activate(useEdges ? edgeSideConstraints : safeSideConstraints)
    }

    /// While a game runs its window sits below this one, so the stage is see-through.
    private func updateGameShowThrough() {
        let through = runtimeHost.isRunning
        view.backgroundColor = through ? .clear : Self.rootBackground
        gameStage.backgroundColor = through ? .clear : .black
        gamePane.backgroundColor = through ? .clear : .black
    }

    /// A touch on the game pane belongs to the game window below, unless a sheet or alert is up.
    /// Only the bare pane passes touches on: runtimes that draw in a view inside it get them directly.
    private func touchGoesToGame(_ hit: UIView?) -> Bool {
        guard runtimeHost.isRunning, presentedViewController == nil, hit === gamePane else { return false }
        if !gameFocused { DispatchQueue.main.async { self.gameFocused = true } }
        return true
    }

    /// Where the on-screen keyboard is, in screen coordinates (zero when hidden).
    private var keyboardFrame: CGRect = .zero

    @objc private func keyboardWillChange(_ note: Notification) {
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        keyboardFrame = hiding ? .zero : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero)
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutIDEPane()
            self.gameStage.keyboardInset = self.overlap(of: self.gameStage)
            self.gameStage.layoutIfNeeded()
        } completion: { _ in
            // With the editor above the keyboard WebKit has no reason to scroll the page; undo it if it did.
            self.editor.webView.scrollView.contentOffset = .zero
        }
    }

    /// How much of the IDE pane's bottom the keyboard covers.
    private var keyboardOverlap: CGFloat { overlap(of: idePane) }

    private func overlap(of pane: UIView) -> CGFloat {
        guard keyboardFrame.height > 0, let screen = view.window?.screen else { return 0 }
        let frame = pane.convert(keyboardFrame, from: screen.coordinateSpace)
        guard frame.intersects(pane.bounds) else { return 0 }
        return max(0, pane.bounds.maxY - frame.minY)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.installKeyBar()
        (view.window as? HostWindow)?.passesThrough = { [weak self] hit in self?.touchGoesToGame(hit) ?? false }
        if !didShowWelcome {
            didShowWelcome = true
            showWelcome(animated: false)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { gameFocused && runtimeHost.isRunning }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        gameFocused && runtimeHost.isRunning ? .bottom : []
    }
    override var prefersPointerLocked: Bool { gameFocused && runtimeHost.isRunning }

    // MARK: - Setup

    private func setupPanes() {
        contentArea.clipsToBounds = true
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentArea)

        idePane.clipsToBounds = true
        idePane.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        contentArea.addSubview(idePane)
        contentArea.addSubview(separator)
        contentArea.addSubview(gameStage)
        gameStage.alpha = 0
        separator.alpha = 0

        idePane.addSubview(editor.webView)

        errorBanner.alpha = 0
        errorBanner.onTap = { [weak self] in self?.jumpToBannerError() }
        errorBanner.onDismiss = { [weak self] in self?.hideErrorBanner() }
        idePane.addSubview(errorBanner)

        sidebarScrim.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        sidebarScrim.alpha = 0
        sidebarScrim.addTarget(self, action: #selector(closeOverlaySidebar), for: .touchUpInside)
        idePane.addSubview(sidebarScrim)
        idePane.addSubview(sidebarView)
        idePane.addSubview(activityRail)

        // Tapping the editor hands input focus back from the game.
        let editorTap = UITapGestureRecognizer(target: self, action: #selector(editorTapped))
        editorTap.cancelsTouchesInView = false
        editorTap.delegate = self
        editor.webView.addGestureRecognizer(editorTap)
    }

    private func setupActivityRail() {
        activityRail.onRunStopTap = { [weak self] in
            guard let self else { return }
            self.runtimeHost.isRunning ? self.stopGame() : self.run()
        }
        activityRail.onFilesTap = { [weak self] in self?.toggleSidebar(tab: .files) }
        activityRail.onSearchTap = { [weak self] in self?.toggleSidebar(tab: .search) }
        activityRail.onGitTap = { [weak self] in self?.toggleSidebar(tab: .git) }
        activityRail.onExtensionsTap = { [weak self] in self?.toggleSidebar(tab: .extensions) }
        activityRail.onDebugTap = { [weak self] in self?.toggleSidebar(tab: .debug) }
        activityRail.onViewsTap = { [weak self] in self?.showViews(container: nil) }
        activityRail.onContainerTap = { [weak self] id in self?.showViews(container: id) }
        activityRail.onHomeTap = { [weak self] in self?.showWelcome(animated: true) }
        activityRail.onSettingsTap = { [weak self] in self?.showSettings() }
        activityRail.onSignIn = { [weak self] in
            guard let self else { return }
            GitHubSignInViewController.present(from: self) { _ in }
        }
    }

    private func setupSidebar() {
        sidebarView.layer.shadowColor = UIColor.black.cgColor
        sidebarView.layer.shadowRadius = 16
        sidebarView.layer.shadowOffset = CGSize(width: 4, height: 0)
        sidebarView.onOpenFile = { [weak self] path in
            self?.editor.openFile(path)
            self?.closeOverlaySidebar()
        }
        sidebarView.onOpenToSide = { [weak self] path in
            self?.editor.openFileToSide(path)
            self?.closeOverlaySidebar()
        }
        // Extension views get their items from the extension host through the editor page.
        sidebarView.viewsPanel.callEditor = { [weak self] body, arguments, completion in
            guard let self else { return completion(nil) }
            self.editor.call(body, arguments, completion: completion)
        }
        // The file icon theme's icons are drawn by the editor page (they're SVG or font characters).
        // The Chat agent runs the project and reads its console (run_program).
        ProgramRunCapture.shared.startRun = { [weak self] in self?.run() }
        ProgramRunCapture.shared.stopRun = { [weak self] in self?.stopGame() }
        ProgramRunCapture.shared.isRunning = { [weak self] in self?.runtimeHost.isRunning ?? false }
        FileIconTheme.shared.callEditor = { [weak self] body, arguments, completion in
            guard let self else { return completion(nil) }
            self.editor.call(body, arguments, completion: completion)
        }
        // Settings > Advanced's settings files open in the editor, by the Command Palette's commands.
        NotificationCenter.default.addObserver(forName: SettingsViewController.openFileRequest, object: nil, queue: .main) { [weak self] note in
            guard let command = note.userInfo?["command"] as? String else { return }
            self?.editor.call("return await window.duocode.runCommand(command)", ["command": command]) { _ in }
        }
        NotificationCenter.default.addObserver(forName: PullRequestsViewController.showRequest, object: nil, queue: .main) { [weak self] note in
            self?.showPullRequests(create: note.userInfo?["create"] as? Bool ?? false)
        }
        updateViewButtons()
        for name in [ExtensionManager.didChange, ExtensionViewsPanelView.contextChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the panel has reloaded its contributions.
                DispatchQueue.main.async { self?.updateViewButtons() }
            }
        }
        sidebarView.onOpenMatch = { [weak self] file, line, column, length in
            self?.editor.reveal(file: file, line: line, column: column, length: length)
            self?.closeOverlaySidebar()
        }
        sidebarView.onOpenDiff = { [weak self] request in
            self?.editor.openDiff(request)
            self?.closeOverlaySidebar()
        }
        sidebarView.onPathMoved = { [weak self] from, to in
            self?.editor.pathMoved(from, to: to)
        }
        sidebarView.onShowWelcome = { [weak self] in
            self?.showWelcome(animated: true)
        }
        sidebarView.onSwitchProject = { [weak self] url in
            guard let self else { return }
            // Save first, so this project's edits can't land in the next one.
            self.editor.flushSaves { self.openProject(url) }
        }
        sidebarView.onChangeCountChanged = { [weak self] count in
            self?.activityRail.setChangeCount(count)
        }
        sidebarView.onTabChangeRequest = { [weak self] tab in
            guard let self else { return }
            self.isSidebarOpen = true
            self.activityRail.setActiveTab(tab)
            self.animateLayout(duration: 0.3)
        }
        sidebarView.onProjectChanged = { [weak self] in
            self?.editor.projectChanged()
            self?.editor.openFile("main.lua")
        }
        sidebarView.onSaveEdits = { [weak self] done in
            guard let self else { return done() }
            self.editor.flushSaves(completion: done)
        }
        sidebarView.onFilesChangedOnDisk = { [weak self] in
            self?.editor.reloadFromDisk()
        }
        NotificationCenter.default.addObserver(forName: AutomationServer.filesChangedOnDisk, object: nil, queue: .main) { [weak self] _ in
            self?.editor.reloadFromDisk()
        }
    }

    private func setupGameStage() {
        let bar = gameStage.controlBar
        bar.onRestart = { [weak self] in self?.restartGame() }
        bar.onToggleConsole = { [weak self] in self?.toggleConsole() }
        bar.onSwap = { [weak self] in self?.swapScreens() }
        bar.onToggleMaximize = { [weak self] in self?.toggleMaximizeGame() }
        bar.onStop = { [weak self] in
            guard let self else { return }
            // After an errored run the button closes the stage instead.
            self.runtimeHost.isRunning ? self.stopGame() : self.closeStoppedStage()
        }
        bar.setConsoleVisible(gameStage.isConsoleVisible)
        bar.setMaximized(false)
    }

    /// The status bar's bottom edge: down into the home indicator's area, so the bar isn't 22 points
    /// of text on top of an empty blue strip, but clear of the indicator itself.
    private lazy var statusBottom = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)

    /// How far the status bar sits above the screen's bottom edge for a bottom safe-area inset.
    static func statusBarGap(bottomInset: CGFloat) -> CGFloat {
        bottomInset > 0 ? max(0, bottomInset - 14) : 0
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        statusBottom.constant = -Self.statusBarGap(bottomInset: view.safeAreaInsets.bottom)
    }

    private func setupStatusBar() {
        statusBackdrop.backgroundColor = Self.vsCodeBlue
        statusBackdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBackdrop)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        for label in [statusLeftLabel, statusRightLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(label)
        }
        setupInterpreterButton()
        statusLeftLabel.lineBreakMode = .byTruncatingTail
        statusLeftLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusRightLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let safe = view.safeAreaLayoutGuide
        safeSideConstraints = [
            contentArea.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ]
        edgeSideConstraints = [
            contentArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(safeSideConstraints)
        NSLayoutConstraint.activate([
            contentArea.topAnchor.constraint(equalTo: safe.topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBottom,
            statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),

            // The status bar colour runs under the home indicator.
            statusBackdrop.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLeftLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLeftLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            interpreterButton.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeftLabel.trailingAnchor, constant: 12),
            interpreterButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            interpreterButton.trailingAnchor.constraint(equalTo: statusRightLabel.leadingAnchor, constant: -12),
            statusRightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: interpreterButton.trailingAnchor, constant: 12),
            statusRightLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statusRightLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    // MARK: - Layout

    /// Frames the game stage, separator and IDE pane inside `contentArea`, then the IDE pane's contents.
    private func layoutPanes() {
        let b = contentArea.bounds
        guard b.width > 0, b.height > 0 else { return }

        let vertical = layout.isVertical
        let isDuo = layout.display == .duoInner
        // Portrait: game on top. Landscape: IDE on the left. Swap flips either.
        let gameFirst = vertical != screensSwapped
        let length = vertical ? b.height : b.width
        let cross = vertical ? b.width : b.height

        let seam: CGFloat = isDuo ? DuoLayoutManager.creaseThickness : 1
        var gameExtent: CGFloat
        if isDuo {
            // Centre the seam on the hinge, which runs through the middle of the screen.
            let hinge = contentArea.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            let firstExtent = (vertical ? hinge.y : hinge.x) - seam / 2
            gameExtent = gameFirst ? firstExtent : length - firstExtent - seam
        } else {
            let preferred = vertical
                ? gameStage.preferredHeight(forWidth: cross)
                : gameStage.preferredWidth(forHeight: cross)
            gameExtent = min(preferred, length * 0.55)
        }
        let minExtent = min(160, length / 3)
        gameExtent = max(minExtent, min(gameExtent, length - seam - minExtent))
        let ideExtent = length - seam - gameExtent

        func slice(_ start: CGFloat, _ extent: CGFloat) -> CGRect {
            vertical
                ? CGRect(x: 0, y: start, width: b.width, height: extent)
                : CGRect(x: start, y: 0, width: extent, height: b.height)
        }

        var gameFrame = gameFirst ? slice(0, gameExtent) : slice(ideExtent + seam, gameExtent)
        let seamFrame = gameFirst ? slice(gameExtent, seam) : slice(ideExtent, seam)
        var ideFrame = gameFirst ? slice(gameExtent + seam, ideExtent) : slice(0, ideExtent)

        let maximized = isGameVisible && isGameMaximized
        if !isGameVisible {
            // Park the game stage just outside its edge so it slides in on Run.
            let offset = (gameExtent + seam) * (gameFirst ? -1 : 1)
            gameFrame = vertical ? gameFrame.offsetBy(dx: 0, dy: offset) : gameFrame.offsetBy(dx: offset, dy: 0)
            ideFrame = b
        } else if maximized {
            gameFrame = b
        }

        gameStage.frame = gameFrame
        gameStage.alpha = isGameVisible ? 1 : 0
        separator.frame = seamFrame
        separator.isHinge = isDuo
        separator.isVertical = vertical
        separator.alpha = (isGameVisible && !maximized) ? 1 : 0
        idePane.frame = ideFrame
        idePane.alpha = maximized ? 0 : 1
        idePane.isUserInteractionEnabled = !maximized

        layoutIDEPane()
        // The runtime's game window lives outside this view tree; tell it where the pane went,
        // including moves that don't resize the game pane (e.g. swapping panes).
        runtimeHost.containerResized()
    }

    private func layoutIDEPane() {
        let r = idePane.bounds
        let railWidth = LeftActivityRail.width
        activityRail.frame = CGRect(x: 0, y: 0, width: railWidth, height: r.height)

        let docked = r.width >= Self.minWidthForDockedSidebar
        if isSidebarDocked != docked {
            // Open by default when there's room for it; start closed when it would cover the editor.
            isSidebarDocked = docked
            isSidebarOpen = docked
            activityRail.setActiveTab(isSidebarOpen ? sidebarView.currentTab : nil)
        }

        let sidebarWidth = docked
            ? Self.sidebarDockedWidth
            : min(Self.sidebarOverlayMaxWidth, max(0, r.width - railWidth - 32))
        sidebarView.frame = CGRect(x: isSidebarOpen ? railWidth : railWidth - sidebarWidth,
                                   y: 0, width: sidebarWidth, height: r.height)
        sidebarView.alpha = isSidebarOpen ? 1 : 0
        sidebarView.layer.shadowOpacity = (!docked && isSidebarOpen) ? 0.5 : 0

        let editorX = (docked && isSidebarOpen) ? railWidth + sidebarWidth : railWidth
        // The editor ends where the keyboard starts, so the cursor line is never under it.
        editor.webView.frame = CGRect(x: editorX, y: 0, width: max(0, r.width - editorX), height: max(0, r.height - keyboardOverlap))

        let showScrim = !docked && isSidebarOpen
        sidebarScrim.frame = CGRect(x: railWidth, y: 0, width: max(0, r.width - railWidth), height: r.height)
        sidebarScrim.alpha = showScrim ? 1 : 0
        sidebarScrim.isUserInteractionEnabled = showScrim

        // Error banner floats at the bottom of the editor.
        let editorFrame = editor.webView.frame
        let bannerWidth = min(520, max(0, editorFrame.width - 16))
        let bannerHeight = errorBanner.preferredHeight(forWidth: bannerWidth)
        errorBanner.frame = CGRect(x: editorFrame.maxX - 8 - bannerWidth, y: editorFrame.maxY - 8 - bannerHeight,
                                   width: bannerWidth, height: bannerHeight)
        errorBanner.alpha = bannerError == nil ? 0 : 1
        errorBanner.isUserInteractionEnabled = bannerError != nil

        layoutRailForScreenCorners()
    }

    /// Pushes the rail's first and last buttons clear of the rounded display corners
    /// when the rail sits against the screen's left edge with little safe-area inset.
    private func layoutRailForScreenCorners() {
        guard let window = view.window else { return }
        let radius = displayCornerRadius(of: window)
        let rail = activityRail.convert(activityRail.bounds, to: window)
        // Leading edge of the 36pt icons, centred in the 44pt rail.
        let iconX = rail.minX + (LeftActivityRail.width - 36) / 2
        let clearance = Self.cornerClearance(radius: radius, distanceFromEdge: iconX) + 6
        activityRail.setEdgeInsets(top: max(0, clearance - rail.minY - 8),
                                   bottom: max(0, clearance - (window.bounds.maxY - rail.maxY) - 8))
    }

    /// How far from a rounded corner's top (or bottom) edge something must be to clear the curve,
    /// at `distanceFromEdge` points in from the side edge.
    private static func cornerClearance(radius: CGFloat, distanceFromEdge x: CGFloat) -> CGFloat {
        guard radius > 0, x < radius else { return 0 }
        let dx = radius - max(0, x)
        return radius - sqrt(radius * radius - dx * dx)
    }

    /// The screen's corner radius. UIKit has no public API for it; the private key is read
    /// only if the screen responds to it, else a typical modern-iPhone value is used.
    private func displayCornerRadius(of window: UIWindow) -> CGFloat {
        let screen = window.windowScene?.screen
        let key = "_displayCornerRadius"
        if let screen, screen.responds(to: NSSelectorFromString(key)),
           let radius = screen.value(forKey: key) as? CGFloat {
            return radius
        }
        return 44
    }

    private func animateLayout(duration: TimeInterval = 0.4) {
        view.setNeedsLayout()
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.3,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    func duoLayoutManagerHingeDidChange(_ manager: DuoLayoutManager) {
        animateLayout()
    }

    // MARK: - Sidebar (VS Code desktop style)

    /// Opens the side bar on a view (from the Command Palette's View commands).
    private func showSidebar(_ tab: SidebarTab) {
        if !(isSidebarOpen && sidebarView.currentTab == tab) { toggleSidebar(tab: tab) }
    }

    // MARK: - Extension views

    /// The activity bar's Extension Views button and extensions' own containers, with their icons.
    private func updateViewButtons() {
        let panel = sidebarView.viewsPanel
        activityRail.setViewsAvailable(panel.hasViews)
        let containers = panel.shownContainers
        activityRail.setContainers(containers.map { ($0.id, $0.title) }, active: panel.container)
        for container in containers {
            panel.icon(for: container) { [weak self] image in
                if let image { self?.activityRail.setContainerIcon(container.id, image) }
            }
        }
    }

    /// Shows the views in an extension's container (nil: the built-in ones). A container that's
    /// just one webview (a chat panel, say) opens it in a tab instead of the side bar.
    private func showViews(container: String?) {
        let panel = sidebarView.viewsPanel
        if let container, let view = panel.soleWebview(in: container) {
            panel.openWebview(view)
            return
        }
        if isSidebarOpen && sidebarView.currentTab == .views && panel.container != container {
            panel.container = container
            sidebarView.setTab(.views)
            activityRail.setActiveContainer(container)
            return
        }
        panel.container = container
        activityRail.setActiveContainer(container)
        toggleSidebar(tab: .views)
    }

    private func toggleSidebar(tab: SidebarTab) {
        if isSidebarOpen && sidebarView.currentTab == tab {
            isSidebarOpen = false
            activityRail.setActiveTab(nil)
        } else {
            isSidebarOpen = true
            sidebarView.setTab(tab)
            activityRail.setActiveTab(tab)
        }
        animateLayout(duration: 0.3)
    }

    @objc private func closeOverlaySidebar() {
        guard isSidebarDocked == false, isSidebarOpen else { return }
        isSidebarOpen = false
        activityRail.setActiveTab(nil)
        animateLayout(duration: 0.3)
    }

    @objc private func editorTapped() {
        if gameFocused { gameFocused = false }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Game stage controls

    private func toggleConsole() {
        gameStage.isConsoleVisible.toggle()
        animateLayout(duration: 0.3)
    }

    @objc private func toggleMaximizeGame() {
        guard runtimeHost.isRunning else {
            appendLog("Start the game first to maximize")
            return
        }
        isGameMaximized.toggle()
        gameStage.controlBar.setMaximized(isGameMaximized)
        animateLayout()
    }

    @objc private func swapScreens() {
        screensSwapped.toggle()
        animateLayout()
    }

    private func setGameVisible(_ visible: Bool) {
        isGameVisible = visible
        if !visible && isGameMaximized {
            isGameMaximized = false
            gameStage.controlBar.setMaximized(false)
        }
        animateLayout(duration: 0.45)
    }

    // MARK: - Game Execution

    /// GitHub pull requests for the project (PullRequestsViewController), in a sheet.
    private func showPullRequests(create: Bool) {
        guard presentedViewController == nil else { return }
        let list = PullRequestsViewController(project: ProjectStore.shared.currentProject, create: create)
        list.onOpenDiff = { [weak self] request in self?.editor.openDiff(request) }
        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func handle(command: String) {
        switch command {
        case "run": run()
        case "debug": run(debug: true)
        case "repl": startREPL()
        case "toggleConsole": toggleConsole()
        case "settings": showSettings()
        case "showExtensions": showSidebar(.extensions)
        case "showDebug": showSidebar(.debug)
        case "extViewReveal": showSidebar(.views)
        case "showSourceControl": showSidebar(.git)
        case "showSearch": showSidebar(.search)
        case "showExplorer": showSidebar(.files)
        case "pullRequests": showPullRequests(create: false)
        case "createPullRequest": showPullRequests(create: true)
        case "stop": stopGame()
        case "focusGame": gameFocused = true
        case "focusEditor": gameFocused = false
        default: appendLog("Unknown command: \(command)")
        }
    }

    private func run(debug: Bool = false) {
        if runtimeHost.isRunning {
            restartGame(debug: debug)
            return
        }
        guard !isStarting else { return }
        isStarting = true
        // Unsaved edits must be on disk before the game reads them.
        editor.flushSaves { [weak self] in
            self?.isStarting = false
            self?.startGame(debug: debug)
        }
    }

    /// An interactive Lua or Python session in the console, as VS Code's terminal runs one: the
    /// project's interpreter when it's a console one, otherwise Lua 5.4.
    private func startREPL(runtimeID: String? = nil) {
        let project = ProjectStore.shared.currentProject
        let current = RuntimeManager.shared.resolve(for: project)
        let runtime = runtimeID.flatMap { id in RuntimeManager.shared.runtimes.first { $0.manifest.id == id } }
            ?? ((current?.isConsole ?? false) ? current : nil)
            ?? RuntimeManager.shared.runtimes.first { $0.manifest.id == "lua-5.4" }
        guard let runtime, runtime.isAvailable else { appendLog("No interpreter for a REPL is available."); return }
        if runtimeHost.isRunning {
            stopGame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startREPL(runtimeID: runtime.manifest.id) }
            return
        }
        gameStage.showsGamePane = false
        runHadError = false
        stopRequested = false
        hideErrorBanner()
        do {
            appendLog("▶ \(runtime.manifest.displayName) REPL")
            try runtimeHost.start(runtime: runtime, project: project, arguments: ["--repl"] + nodeArguments(for: runtime))
            runningRuntimeName = runtime.manifest.displayName
            gameStage.controlBar.setTitle("\(runtime.manifest.displayName) REPL")
            gameStage.controlBar.setStopped(false)
            activityRail.setRunning(true)
            if !gameStage.isConsoleVisible { gameStage.isConsoleVisible = true }
            setGameVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.gameStage.inputField.becomeFirstResponder()
            }
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    /// JavaScript runs in the app's Node.js, started on first use; the runtime needs its port.
    private func nodeArguments(for runtime: RuntimeDescriptor) -> [String] {
        guard runtime.manifest.id.hasPrefix("node"), NodeExtensionHost.shared.start() != nil,
              let port = NodeExtensionHost.shared.programPort else { return [] }
        return ["--node-port=\(port)"]
    }

    private func startGame(debug: Bool = false) {
        let project = ProjectStore.shared.currentProject
        guard let rt = RuntimeManager.shared.resolve(for: project) else {
            appendLog("No runtime available."); return
        }

        gamePane.windowConfig = RuntimeManager.shared.parseWindowConfig(for: project)
        gameStage.showsGamePane = !rt.isConsole
        guard rt.isAvailable else {
            appendLog("\(rt.manifest.displayName) isn't bundled in this build yet. Pick another interpreter from the status bar.")
            showErrorBanner(message: "\(rt.manifest.displayName) isn't available yet.", file: nil, line: 0)
            return
        }
        runHadError = false
        stopRequested = false
        hideErrorBanner()

        do {
            appendLog("▶ Running \(project.lastPathComponent) with \(rt.manifest.displayName)")
            // The game shares the app's memory budget; a local AI model reloads when it's next needed.
            AICompletionService.shared.unload()
            AIChatService.shared.unload()
            try runtimeHost.start(runtime: rt, project: project, debugConfig: debug ? BreakpointStore.shared.debugConfig : nil,
                                  arguments: nodeArguments(for: rt))
            if debug { beginDebugSession() }
            runningRuntimeName = rt.manifest.displayName
            gameStage.controlBar.setTitle("\(project.lastPathComponent) · \(rt.manifest.displayName)")
            gameStage.controlBar.setStopped(false)
            gamePane.setPlaceholderVisible(false)
            gameFocused = true
            activityRail.setRunning(true)
            setGameVisible(true)
            updateGameShowThrough()
        } catch {
            appendLog(error.localizedDescription)
            showErrorBanner(message: error.localizedDescription, file: nil, line: 0)
        }
    }

    private func stopGame() {
        stopRequested = true
        runtimeHost.stop()
        gameFocused = false
        activityRail.setRunning(false)
        setGameVisible(false)
        updateStatus()
    }

    /// Closes a stage left open after a game exited with an error.
    private func closeStoppedStage() {
        gameStage.controlBar.setStopped(false)
        setGameVisible(false)
    }

    // MARK: - Error banner

    private func showErrorBanner(message: String, file: String?, line: Int) {
        // The first line is the message; LÖVE appends a traceback after it, which stays in the console.
        let firstLine = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
        let jumpable = file.flatMap { f in (try? ProjectStore.shared.resolve(f)).map { FileManager.default.fileExists(atPath: $0.path) } } ?? false
        bannerError = (firstLine, jumpable ? file : nil, line)
        errorBanner.configure(message: firstLine, location: jumpable ? "\(file!):\(line)" : nil)
        animateLayout(duration: 0.3)
    }

    private func hideErrorBanner() {
        guard bannerError != nil else { return }
        bannerError = nil
        animateLayout(duration: 0.25)
    }

    private func jumpToBannerError() {
        guard let error = bannerError, let file = error.file else { return }
        gameFocused = false
        editor.jumpToLine(file: file, line: error.line)
    }

    // MARK: - Projects

    private func showWelcome(animated: Bool) {
        guard presentedViewController == nil else { return }
        // Save now, so a project switch can't write this project's edits into the next one.
        editor.flushSaves { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            let welcome = WelcomeViewController()
            welcome.modalPresentationStyle = .fullScreen
            welcome.onOpenProject = { [weak self, weak welcome] url in
                self?.openProject(url)
                welcome?.dismiss(animated: true)
            }
            welcome.onCurrentProjectDeleted = { [weak self] in
                guard let self else { return }
                self.openProject(ProjectStore.shared.currentProject)
            }
            self.present(welcome, animated: animated)
        }
    }

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let nav = UINavigationController(rootViewController: SettingsRootViewController())
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func openProject(_ url: URL) {
        if runtimeHost.isRunning { stopGame() }
        closeStoppedStage()
        hideErrorBanner()
        ProjectStore.shared.openProject(url)
        sidebarView.projectDidChange()
        editor.projectChanged()
        if let entry = ProjectStore.shared.entryFile(in: url) {
            editor.openFile(entry)
        }
        updateStatus()
    }

    private func restartGame(debug: Bool = false) {
        stopGame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.run(debug: debug)
        }
    }

    // MARK: - Debugging

    private let debugToolbar = DebugToolbar()

    private func setupDebugging() {
        let session = DebugSession.shared
        runtimeHost.onDebugEvent = { json in session.handle(event: json) }
        session.transport = { [weak self] json in self?.runtimeHost.sendDebugCommand(json) }
        session.onOutput = { [weak self] text in self?.appendLog(text) }
        session.onStopped = { [weak self] frame in
            guard let self else { return }
            // The code is what matters now, not the (frozen) game.
            self.gameFocused = false
            self.editor.setDebugPaused(true)
            self.gameStage.acceptsInput = true
            self.gameStage.inputField.placeholder = "Debug Console: evaluate an expression"
            if let frame { self.editor.showDebugLocation(file: frame.file, line: frame.line) }
            if session.stopReason == "exception", let text = session.stopText { self.appendLog("⏸ Paused on error: \(text)") }
        }
        session.onContinued = { [weak self] in
            guard let self else { return }
            self.gameStage.inputField.placeholder = "Input: type a line and press Return"
            self.gameStage.acceptsInput = self.runtimeHost.isRunning && self.runtimeHost.acceptsInput
            self.editor.setDebugPaused(false)
            self.editor.showDebugLocation(file: nil, line: 0)
        }
        sidebarView.debugPanel.onStart = { [weak self] in self?.run(debug: true) }
        sidebarView.debugPanel.onReveal = { [weak self] file, line in
            self?.editor.jumpToLine(file: file, line: line)
            self?.closeOverlaySidebar()
        }

        debugToolbar.onStop = { [weak self] in self?.stopGame() }
        debugToolbar.onRestart = { [weak self] in self?.run(debug: true) }
        debugToolbar.isHidden = true
        debugToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugToolbar)
        NSLayoutConstraint.activate([
            debugToolbar.topAnchor.constraint(equalTo: editor.webView.topAnchor, constant: 36),
            debugToolbar.trailingAnchor.constraint(equalTo: editor.webView.trailingAnchor, constant: -12),
        ])
    }

    private func beginDebugSession() {
        DebugSession.shared.begin()
        debugToolbar.transform = .identity
        debugToolbar.isHidden = false
        view.bringSubviewToFront(debugToolbar)
        // Reveal Run and Debug where there's room for it beside the editor, as VS Code does.
        if isSidebarDocked == true && !(isSidebarOpen && sidebarView.currentTab == .debug) { toggleSidebar(tab: .debug) }
    }

    private func endDebugSession() {
        guard DebugSession.shared.isActive else { return }
        DebugSession.shared.end()
        debugToolbar.isHidden = true
    }

    private func appendLog(_ line: String) {
        gameStage.appendLog(line)
        ProgramRunCapture.shared.log(line)
    }

    private func setupInterpreterButton() {
        interpreterButton.translatesAutoresizingMaskIntoConstraints = false
        interpreterButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium)
        interpreterButton.tintColor = .white
        interpreterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        interpreterButton.showsMenuAsPrimaryAction = true
        interpreterButton.menu = UIMenu(title: "Select Interpreter", children: [AutomationMenus.deferred { [weak self] done in
            done(self?.interpreterMenuItems() ?? [])
        }])
        statusBar.addSubview(interpreterButton)
    }

    private func updateInterpreterButton() {
        let project = ProjectStore.shared.currentProject
        let name = RuntimeManager.shared.resolve(for: project)?.manifest.displayName ?? "No interpreter"
        interpreterButton.setTitle("{ } \(name)", for: .normal)
        interpreterButton.accessibilityLabel = "Interpreter: \(name). Select Interpreter"
    }

    private func interpreterMenuItems() -> [UIMenuElement] {
        let project = ProjectStore.shared.currentProject
        let manager = RuntimeManager.shared
        let chosen = manager.chosenRuntimeID(for: project)
        var items: [UIMenuElement] = manager.selectableRuntimes.map { runtime in
            let id = runtime.manifest.id
            let title = runtime.isAvailable ? runtime.manifest.displayName : "\(runtime.manifest.displayName) (coming soon)"
            return UIAction(title: title, subtitle: runtime.isConsole ? "Console program" : "Game",
                            attributes: runtime.isAvailable ? [] : [.disabled], state: chosen == id ? .on : .off) { [weak self] _ in
                self?.chooseInterpreter(id)
            }
        }
        let replRuntimes = manager.selectableRuntimes.filter { $0.isConsole && $0.isAvailable }
        if !replRuntimes.isEmpty {
            items.append(UIMenu(title: "Start REPL", image: UIImage(systemName: "terminal"), children: replRuntimes.map { runtime in
                UIAction(title: runtime.manifest.displayName) { [weak self] _ in self?.startREPL(runtimeID: runtime.manifest.id) }
            }))
        }
        items.append(UIAction(title: "Detect from Project Files", state: chosen == nil ? .on : .off) { [weak self] _ in
            self?.chooseInterpreter(nil)
        })
        return items
    }

    private func chooseInterpreter(_ id: String?) {
        let project = ProjectStore.shared.currentProject
        do {
            try RuntimeManager.shared.setRuntime(id, for: project)
        } catch {
            appendLog("Couldn't save the interpreter: \(error.localizedDescription)")
        }
        updateInterpreterButton()
        let name = RuntimeManager.shared.resolve(for: project)?.manifest.displayName ?? "?"
        appendLog(runtimeHost.isRunning ? "Interpreter set to \(name); it's used from the next run." : "Interpreter set to \(name).")
    }

    private func updateStatus() {
        let project = ProjectStore.shared.currentProject.lastPathComponent
        if runtimeHost.isRunning, let name = runningRuntimeName {
            statusLeftLabel.text = "● Running  \(project) · \(name)"
        } else {
            statusLeftLabel.text = "○ Idle  \(project)"
        }
        let jit = RuntimeHost.jitAvailable ? "JIT" : "Interp"
        let focus = gameFocused ? "Game" : "Editor"
        statusRightLabel.text = "Focus: \(focus)  LuaJIT: \(jit)"
        updateInterpreterButton()
        if !runtimeHost.isRunning { gameStage.acceptsInput = false }
        activityRail.setRunning(runtimeHost.isRunning)
        updateGameShowThrough()
    }

    // MARK: - .LOVE File Import (picking one lives on the Welcome page)

    func presentImportError(_ error: Error) {
        let alert = UIAlertController(title: "Import Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        // The Welcome page may be on screen.
        (presentedViewController ?? self).present(alert, animated: true)
    }

    /// A .love/.zip opened from another app (Files, Safari…).
    func importIncomingLoveArchive(_ url: URL) {
        editor.flushSaves { [weak self] in
            do {
                let targetDir = try ProjectStore.shared.importLoveArchive(from: url)
                self?.didImportLoveProject(targetDir)
            } catch {
                self?.presentImportError(error)
            }
        }
    }

    func didImportLoveProject(_ url: URL) {
        appendLog("📦 Imported game archive to Projects/\(url.lastPathComponent)")
        openProject(url)

        let showAlert = { [weak self] in
            let alert = UIAlertController(title: "Game Imported", message: "Imported '\(url.lastPathComponent)'. Press Run (▶) at the top of the activity bar to play.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Play Now", style: .default) { [weak self] _ in
                self?.run()
            })
            alert.addAction(UIAlertAction(title: "Edit Code", style: .cancel))
            self?.present(alert, animated: true)
        }
        // An incoming file can arrive while the Welcome page (or another sheet) is up.
        if presentedViewController != nil {
            dismiss(animated: true, completion: showAlert)
        } else {
            showAlert()
        }
    }

    // MARK: - Keyboard Shortcuts

    private var lastEscape: TimeInterval = 0

    // Run, Start Debugging, the Command Palette and Go to File are in the menu bar (AppDelegate.buildMenu).
    override var keyCommands: [UIKeyCommand]? {
        var cmds = [
            UIKeyCommand(title: "Toggle Game Focus", action: #selector(kbToggleFocus), input: "g", modifierFlags: [.control, .shift]),
            UIKeyCommand(title: "Swap Panes", action: #selector(swapScreens), input: "s", modifierFlags: [.control, .shift]),
            UIKeyCommand(title: "Maximize Game", action: #selector(toggleMaximizeGame), input: "m", modifierFlags: [.control, .shift]),
        ]
        // ⌘. stops a running game; otherwise it's the editor's Quick Fix.
        if runtimeHost.isRunning {
            cmds.append(UIKeyCommand(title: "Stop", action: #selector(kbStop), input: ".", modifierFlags: .command))
        }
        if gameFocused {
            cmds.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(kbEscape)))
        }
        cmds.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return cmds
    }

    @objc private func kbStop() { stopGame() }

    /// A menu bar command (AppDelegate.buildMenu): the app's run commands, or a Command Palette command.
    @objc func performMenuCommand(_ sender: UICommand) {
        guard let command = sender.propertyList as? String else { return }
        switch command {
        case "app.run": run()
        case "app.debug": run(debug: true)
        case "app.stop": stopGame()
        case "workbench.action.showCommands": editor.showCommandPalette()
        case "workbench.action.quickOpen": editor.showQuickOpen()
        default:
            editor.call("return await window.duocode.runCommand(command)", ["command": command]) { _ in }
        }
    }
    @objc private func kbToggleFocus() { gameFocused.toggle() }
    @objc private func kbEscape() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEscape < 0.4 { gameFocused = false }
        lastEscape = now
    }
}

extension IDEViewController: RuntimeHostDelegate {
    func runtimeHost(_ host: RuntimeHost, log message: String, level: dc_log_level) {
        let prefix: String
        switch level {
        case DC_LOG_ERROR: prefix = "[error] "
        case DC_LOG_WARN: prefix = "[warn] "
        case DC_LOG_GAME: prefix = ""
        default: prefix = "[rt] "
        }
        appendLog(prefix + message)
    }

    func runtimeHost(_ host: RuntimeHost, stateChanged state: dc_runtime_state) {
        if state == DC_STATE_STOPPED {
            gameFocused = false
            activityRail.setRunning(false)
        } else if state == DC_STATE_RUNNING {
            setGameVisible(true)
            // Console programs read what's typed into the box under the console.
            gameStage.acceptsInput = host.acceptsInput
        }
        // Whether the stage closes is decided once the exit code is known (didExitWithCode).
        updateStatus()
    }

    func runtimeHost(_ host: RuntimeHost, error message: String, file: String?, line: Int) {
        runHadError = true
        // Console programs (Lua, Python) have already printed the error and its traceback.
        // LÖVE's message already starts with "file:line:", so it's logged as is.
        if !(host.active?.isConsole ?? false) { appendLog("[lua error] \(message)") }
        showErrorBanner(message: message, file: file, line: line)
    }

    func runtimeHost(_ host: RuntimeHost, didExitWithCode code: Int32) {
        endDebugSession()
        ProgramRunCapture.shared.exited(code: code)
        let failed = code != 0 || runHadError
        if failed && !stopRequested {
            // Keep the stage (and its console) open so the failure can be read.
            gameStage.controlBar.setStopped(true)
            gamePane.setPlaceholderVisible(true, text: "The game stopped with an error.\nSee the console below.")
            if bannerError == nil {
                showErrorBanner(message: "The game exited with code \(code). See the console for details.", file: nil, line: 0)
            }
        } else {
            setGameVisible(false)
        }
        stopRequested = false
        updateStatus()
    }
}
