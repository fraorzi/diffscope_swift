import AppKit
import DiffScopeEngine
import DiffScopeGit
import DiffScopeShell
import DiffScopeSyntax
import WebKit

/// DEC-013: the three modes are presentation flags over one renderer, not three code paths.
/// Structural and Expanded share a model and therefore a segment set (INV-5); only Raw
/// builds a different one, and it stays available on the same pinned pair.
enum PresentationMode: String, CaseIterable {
    case raw, structural, expanded

    /// The order the control draws and the menu numbers: Structural, Expanded, Raw (DEC-065).
    /// `allCases` keeps its declaration order because the menu's tags are indices into it and
    /// `12-…` §5's mapping is written against it — the two orders are separate on purpose, and
    /// this is the one a reader sees.
    static let displayOrder: [PresentationMode] = [.structural, .expanded, .raw]

    var usesStructure: Bool { self != .raw }
    var title: String { rawValue.capitalized }
}

enum Lens: String { case diff, blame, history }

final class AppState {
    var repositories: [RepositorySnapshot] = []
    var selectedRepository: RepositorySnapshot?
    var scope: ComparisonScope = .allLocalVsHead
    var files: [ChangedFile] = []
    var mergeBaseRev: String?
    var mode: PresentationMode = .structural
    var selectedFile: ChangedFile?
    var configuration = Configuration()
    /// Sources that are configured and unusable. Kept rather than filtered, so the interface can
    /// say which ones and offer to remove them (DEC-036).
    var sourceProblems: [InspectedSource] = []
    /// Path → label, qualified only where two repositories share a folder name (DEC-037).
    var repositoryLabels: [String: String] = [:]
    /// The file list as drawn: headers and files interleaved (DEC-033 as amended).
    var fileRows: [FileListRow] = []
    /// Group key → what its header says (DEC-074). Computed with the rows, because the shortest
    /// unique form depends on every other group in the list.
    var groupTitles: [String: String] = [:]
    /// Path → what the list can say about the file cheaply. Filled in by a background pass, so a
    /// large working tree lists immediately and gains its badges a moment later.
    var annotations: [String: FileAnnotation] = [:]
    /// Path → how much of the file changed (`12-…` §4). Arrives with the annotations rather than
    /// with the rows: the list appears immediately and the counts fill in, because one more Git
    /// invocation is not worth an empty pane.
    var counts: [String: ChangeCount] = [:]
    /// The last search and its hits (DEC-062). Kept on the state rather than in the view, so a
    /// refresh can decide what to do with them — today it replaces them with the file list, which
    /// is the honest answer: the hits were computed against bytes that have just changed.
    /// Which question the pane is answering (DEC-061). Not a mode and not a scope: the file and
    /// the pinned pair are the same in all three.
    var lens: Lens = .diff
    /// The History lens's selection, and the comparison it names (DEC-061). Not a fifth scope: the
    /// four are untouched, and this is a second way of saying which two sides.
    var pickedCommits: [String] = []
    var historyPair: (old: String, new: String?)?
    var searchQuery = ""
    var searchMatchCase = false
    var searchHits: [SearchHit] = []
    /// Which hit the reader is on, or `nil` when there are none.
    var searchIndex: Int?

    // ---- version two (DEC-092) ---------------------------------------------------------------
    //
    // All four are **read back** after every write rather than mutated in place. The index is
    // shared with WebStorm, the terminal drawer and every hook, so a state this window keeps for
    // itself is one it can be wrong about — which is the objection DEC-092 §2.2 makes to hiding
    // the index in the first place.
    var staging: [String: FileStaging] = [:]
    var branches: [BranchInfo] = []
    var stashes: [StashEntry] = []
    var operation: RepositoryOperation = .none
}

final class Controller: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let state = AppState()
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let reader = RepositoryReader()
    let scopes = ScopeReader()
    /// Asked once per file the reader opens, not once per file listed: the disclosure belongs to
    /// the diff view, and a sweep over 63 files would pay 63 `git check-attr` invocations for an
    /// answer nobody is looking at yet (DEC-051).
    let filters = FilterCheck(runner: GitRunner())
    let configStore = ConfigurationStore()
    /// Version two's two halves (DEC-092): the verbs that write, and the reads they need first.
    /// Held here rather than constructed per call, so `GitWriter`'s command record is one record.
    let actions = WriteActions()
    let gitState = RepositoryStateReader()

    /// The commit box under the file list, the banner over the status line, and the two controls
    /// the status line gained. Held for the same reason every other control here is: the selftest
    /// asks where they were drawn, not what they were asked for.
    var commitBox: CommitBox!
    var operationBanner: OperationBanner!
    var syncButton: SyncButton!
    var branchButton: ChevronButton!
    /// The banner's height, held so a hidden banner takes **no** space. A hidden view still holds
    /// its constraints, so `isHidden` alone would leave a 26 pt gap over the status line for the
    /// whole time nothing is in progress — the empty-notice-bar finding of DEC-088, one band down.
    var bannerHeightConstraint: NSLayoutConstraint!
    /// The panel listing what this application ran. Built on first use.
    var recordWindow: NSWindow?

    let parser = TSXParser()
    /// Renders run here, one at a time. See `render(file:previousAnchor:restoringStop:)`.
    let renderQueue = DispatchQueue(label: "local.diffscope.render", qos: .userInitiated)

    var window: NSWindow!
    var repoTable: NSTableView!
    var fileTable: NSTableView!
    var webView: WKWebView!
    var scopeControl: PillControl!
    var modeControl: PillControl!
    var statusLabel: NSTextField!
    var comparisonLabel: NSTextField!
    var titleBar: NSView!
    var statusBar: NSView!
    /// The scope row and the base block in it (DEC-072). Held because the block changes with the
    /// repository, the scope and the reader's own override, and because the selftest asks where it
    /// was drawn rather than what it was asked for.
    var scopeBar: NSView!
    var baseBlock: FactBlock!
    /// `Sources ⌄` in the title bar (DEC-071's rule, second instance). Held for the selftest, which
    /// asks where it was drawn and what its menu contains.
    var sourcesButton: NSButton!
    var titleRepositoryLabel: NSTextField!
    var titlePathLabel: NSTextField!
    var lensControl: PillControl!
    var preferencesWindow: NSWindow?
    var preferencesField: NSTextField?
    /// The three regions, as views that can carry a ring. Held rather than looked up, because
    /// "the view the diff is in" is a different thing from "the web view".
    var repoFocusRing: NSView?
    var fileFocusRing: NSView?
    var diffFocusRing: NSView?
    var searchField: NSSearchField!
    /// The rim around it (DEC-085 item 5); what the title bar actually lays out.
    var searchFieldHost: NSView!
    /// The title bar's row, held so its centre can be matched to the traffic lights (DEC-086).
    var titleRowStack: NSStackView!
    /// The system material behind the title band (DEC-086).
    var titleVibrancy: NSView!
    /// Which scope the next submission searches. ⇧⌘F sets it and the placeholder says so — the
    /// alternative is a field that answers a different question depending on how it was opened.
    var searchScope: SearchScope = .changedFiles
    /// The sentence stating which convention the uncommitted counts use (`12-…` §2).
    /// The status line's own fields (DEC-075): what the watcher is doing, how old the window is,
    /// the layout, and the wrap switch. The transient message keeps `statusLabel`.
    var watchLabel: NSTextField!
    var layoutControl: PillControl!
    var wrapButton: NSButton!
    var watchState: ChromeLabels.WatchState = .unavailable("no repository open")
    var lastRefresh: Date?
    private var refreshTicker: Timer?
    /// The two column headers (DEC-071). Held because both change with the collapse state and the
    /// changed-file count changes with every reload — the caption and the count are two labels
    /// rather than one string so the count can sit at the pane's other edge, where the eye compares
    /// it against the row counts underneath.
    var repoHeaderCaption: NSTextField!
    var fileHeaderCaption: NSTextField!
    var fileHeaderCount: NSTextField!
    /// The bars themselves, held for the selftest: *drawn where the pane is* is the assertion, and
    /// M8-D's blank lists are what happens when only the string is checked.
    var repoHeaderBar: NSView!
    /// The two header rows themselves (DEC-098). Held because a collapsed pane is 44 pt wide and
    /// the expanded one is 280: the same insets cannot serve both, and the count is what loses.
    var repoHeaderStack: NSStackView!
    var fileHeaderStack: NSStackView!
    /// The rows inside them that hold the controls: their spacing is the last four points a 44 pt
    /// rail has to give the count.
    var repoTrailingStack: NSStackView?
    var fileTrailingStack: NSStackView?
    var fileHeaderBar: NSView!
    /// The two collapse controls (DEC-077). Held because their glyph says which way the pane will go.
    /// Held since DEC-083, so the arm can measure the target rather than trust the constraint.
    var addSourceButton: NSButton!
    var repoCollapseButton: NSButton!
    var fileCollapseButton: NSButton!
    var rendererReady = false
    var pendingModel: String?
    var watcher: RepositoryWatcher?
    var emptyState: NSView!
    var emptyStateDetail: NSTextField!
    /// Held so the empty state can *replace* the three panes rather than float over them: an
    /// overlay leaves the tables visible behind it and still reachable by keyboard.
    var splitView: NSSplitView!
    var wrapMenuItem: NSMenuItem?
    var wrapEnabled = true
    /// What the last ⌘⏎ did, shown in Preferences. F13's failure is visible on the status line the
    /// moment it happens and gone by the time the reader opens the settings to fix it.
    var lastEditorAttempt: String?
    var lensMenuItems: [String: NSMenuItem] = [:]
    var sideBySideMenuItem: NSMenuItem?
    /// DEC-059: the window opens unified, so this starts false.
    var sideBySide = false
    /// DEC-070. Starts false: a window that has just opened has been touched by nobody, and the
    /// first thing most readers do is click.
    var navigatingByKeyboard = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// DEC-060: each region collapses on its own. Collapsed is **reduced, not hidden** — the rail
    /// still says which repositories there are and which have work in them, the spine still says
    /// how many files changed and how big each change is.
    var reposCollapsed = false
    var filesCollapsed = false
    /// See `splitViewDidResizeSubviews`.
    private var collapseInFlight = false
    var reposCollapseMenuItem: NSMenuItem?
    var filesCollapseMenuItem: NSMenuItem?
    var repoPaneWidth: NSLayoutConstraint?
    var filePaneWidth: NSLayoutConstraint?
    var repoPaneMinimum: NSLayoutConstraint?
    var filePaneMinimum: NSLayoutConstraint?
    /// Every menu item by the identifier of the binding that drew it (DEC-057), so the few items
    /// that carry state can be reached without searching the menu bar by title.
    var menuItems: [String: NSMenuItem] = [:]
    var rawRegionMenuItem: NSMenuItem?
    /// The mode ⌥⌘V left, and the change stop it left it at. Both are needed: the point of the
    /// control view is that it returns the reader to *where they were*, not merely to the mode.
    var rawRegionReturn: (mode: PresentationMode, stop: Int)?
    /// The terminal (DEC-054). Built with the window, loaded with the window, and **not started
    /// until it is first shown** — a shell costs ~340 ms and one `ssh-agent` here (T0).
    let terminal = TerminalPane()
    var terminalSplit: NSSplitView!
    var terminalHeightConstraint: NSLayoutConstraint!
    var terminalMinimumConstraint: NSLayoutConstraint!
    var terminalMenuItem: NSMenuItem?
    /// The drawer's own control (DEC-090). Held because the selftest asserts it is drawn where the
    /// pane it opens is, and that it says which way it will go.
    var terminalButton: TerminalButton!
    var terminalRawMenuItem: NSMenuItem?
    var terminalVisible = false
    var lastCommandRefresh = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadRenderer()
        loadConfiguredSources()
    }

    /// DEC-036 as amended: **no suggested path and no auto-detection**. The hardcoded
    /// `~/WebstormProjects` that used to live here was the very string the amendment removed —
    /// a WebStorm-specific name in a product that depends on WebStorm for nothing.
    ///
    /// `DIFFSCOPE_ROOT` survives as a testing hook that *adds* a root for this launch only. It is
    /// never written to the configuration, so it cannot quietly become a default again.
    private func loadConfiguredSources() {
        // A selftest that reads the developer's own configuration is not a selftest of anything
        // repeatable. It also loses: the startup sweep of whatever repositories happen to be on
        // this machine finished *after* the keyboard arm's own scan and replaced the fixture tree
        // with them, so the arm reported a 63-file tree as empty. The arms bring their own sources.
        if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil {
            state.configuration = Configuration(sources: [])
            if let tree = ProcessInfo.processInfo.environment["DIFFSCOPE_KEYBOARD_TREE"] {
                state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository, path: tree)])
            }
            scan(sources: state.configuration.sources)
            return
        }
        let load = configStore.load()
        state.configuration = load.configuration
        if let problem = load.problem {
            // The file is left on disk exactly as it was. Reporting and continuing beats
            // overwriting a configuration the user may be able to repair by hand.
            statusLabel.stringValue = "\(problem) — starting with no sources, the file was left untouched"
        }

        var sources = state.configuration.sources
        if let hook = ProcessInfo.processInfo.environment["DIFFSCOPE_ROOT"],
           !sources.contains(where: { $0.path == hook }) {
            sources.append(ConfiguredSource(kind: .root, path: hook))
        }
        scan(sources: sources)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// DEC-006: the repository list is refreshed on window focus. The FSEvents watcher covers the
    /// repository being *looked at*; everything else goes stale while the reader is in their editor,
    /// and coming back to counts that are minutes old is the case this closes.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !state.repositories.isEmpty else { return }
        rescan()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "DiffScope"
        // Without this the window follows its content down: showing the empty state hides the split
        // view, the drawer has nothing left to give it height, and the content collapses to the two
        // bars — 69 pt — taking the empty state's buttons off the top of the screen with it. A
        // reader who removes their last folder would have watched the window fold up.
        window.contentMinSize = NSSize(width: Theme.windowMinimumWidth,
                                       height: Theme.windowMinimumHeight)
        // The title bar is ours (the adopted design). The system draws the traffic lights and
        // nothing else; the row underneath them says which repository is open and where it is,
        // which is the first question a reader has and was previously only in a list row.
        window.titlebarAppearsTransparent = true
        // DEC-086: the band blurs what is *behind the window*, so the window must let it through.
        // Every other surface in the chrome paints its own opaque colour, so only this band and the
        // titlebar above it are see-through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.center()

        repoTable = makeTable(identifier: "repo")
        fileTable = makeTable(identifier: "file")

        // Labels and keys both from data (DEC-073): the four words are the scopes' own `shortTitle`,
        // and the four keys are the map's. Written out here, they were a second naming of the
        // scopes and a third copy of the keyboard map.
        scopeControl = PillControl(labels: ComparisonScope.allCases.map(\.shortTitle))
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.selectedSegment = 0

        // Structural first, because it is the default and the mode a reader returns to — and
        // because the menu says ⌘1 Structural (DEC-065). A control whose first segment is Raw while
        // the first digit selects Structural is two orders for one set of three things.
        modeControl = PillControl(labels: PresentationMode.displayOrder.map(\.title))
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = PresentationMode.displayOrder.firstIndex(of: state.mode) ?? 0

        // The base row (`12-…` §3, the adopted design). Under the scope control, always: the
        // control says which four scopes exist, and this says what the chosen one is comparing —
        // for scope 4, which ref and how old its newest commit is, the only staleness signal there
        // is (DEC-010, DEC-011).
        comparisonLabel = NSTextField(labelWithString: "")
        comparisonLabel.font = Theme.font(Theme.textSizeTiny)
        comparisonLabel.textColor = Theme.inkQuiet
        comparisonLabel.lineBreakMode = .byTruncatingMiddle

        statusLabel = NSTextField(labelWithString: "scanning…")
        statusLabel.font = Theme.font(Theme.textSizeSmall)
        statusLabel.textColor = Theme.inkQuiet
        statusLabel.lineBreakMode = .byTruncatingMiddle

        // The page can now speak back (DEC-061). It receives calls for everything else; the
        // History lens is the first surface where a *reader's* choice originates inside the
        // webview, and a commit row that cannot act is a list pretending to be a picker.
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "diffscope")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self

        let middleScroll = scrollWrapping(fileTable, surface: Theme.panelFiles)

        // The two column headers (DEC-071). Each says what its pane is, and either counts what is
        // in it or offers the one action that adds to it.
        repoHeaderCaption = paneHeaderLabel()
        fileHeaderCaption = paneHeaderLabel()
        fileHeaderCount = paneHeaderLabel()
        fileHeaderCount.alignment = .right
        // Each header carries the control that folds its own pane (DEC-077). ⌃⌘1 and ⌃⌘2 already
        // did this; the owner could not find a way to do it with the mouse, and a divider that
        // shows a resize cursor and refuses to move is worse than no affordance at all.
        repoCollapseButton = buildCollapseButton(action: #selector(toggleRepositoriesPane),
                                                 collapsed: reposCollapsed)
        fileCollapseButton = buildCollapseButton(action: #selector(toggleFilesPane),
                                                 collapsed: filesCollapsed)
        addSourceButton = buildAddSourceButton()
        repoTrailingStack = NSStackView(views: [addSourceButton, repoCollapseButton])
        let repoTrailing = repoTrailingStack!
        repoTrailing.orientation = .horizontal
        repoTrailing.spacing = Theme.space2
        fileTrailingStack = NSStackView(views: [fileHeaderCount, fileCollapseButton])
        let fileTrailing = fileTrailingStack!
        fileTrailing.orientation = .horizontal
        fileTrailing.spacing = Theme.space2

        var repoStack: NSStackView?
        var fileStack: NSStackView?
        let repoHeader = buildPaneHeader(caption: repoHeaderCaption, trailing: repoTrailing,
                                         surface: Theme.panelRepositories, stack: &repoStack)
        let fileHeader = buildPaneHeader(caption: fileHeaderCaption, trailing: fileTrailing,
                                         surface: Theme.panelFiles, stack: &fileStack)
        repoHeaderStack = repoStack
        fileHeaderStack = fileStack
        repoHeaderBar = repoHeader
        fileHeaderBar = fileHeader
        updatePaneHeaders()

        // DEC-086: **the convention sentence has left the pane.** `12-…` §2 requires the
        // uncommitted count to state which convention it uses, and it does — on the count's own
        // tooltip, where a reader asks. Drawn permanently under the list it was an explanation of
        // how a number was reached, on every window, for everyone who had not asked: DEC-077's
        // subject exactly. The sentence still comes from the Git layer beside the operation it is
        // about, and `TrustSurfaceChecks` still holds the wording.
        let repoScroll = scrollWrapping(repoTable, surface: Theme.panelRepositories)
        // The convention caption belongs to the repository list, not to the status bar: it
        // explains what that list's counts mean, and it is a sentence — in a 24 pt bar it wrapped
        // to two lines and pushed the bar out of shape. `12-…` §2 asks for it *shown*, so it is
        // not a tooltip either.
        // DEC-086: **the convention caption is gone from the pane.** DEC-012's disclosure — the
        // count is of `git status --porcelain` entries, so an untracked directory counts once — is
        // real and surprising, and it was drawn permanently under the list for every reader who had
        // not asked. It is on the count's own tooltip now, where the question gets asked.
        let leftStack = NSStackView(views: [repoHeader, repoScroll])
        // The caption under the repository list sits on the list's own surface, not on the
        // window's: it belongs to that pane and the seam would say otherwise (`--ds-panel-repos`).
        leftStack.wantsLayer = true
        leftStack.layer?.backgroundColor = Theme.panelRepositories.cgColor
        leftStack.orientation = .vertical
        // Centred rather than leading-aligned since the header arrived: the header spans the pane
        // and the list is inset from it, so there is no single leading edge left to align to. The
        // inset is expressed once, as each member's width against the pane's.
        leftStack.alignment = .centerX
        leftStack.spacing = Theme.space2
        // DEC-083: **nothing between the header and the list.** The stack's 4 pt spacing applied
        // there too, so this pane's surface began 4 pt below the other two — the file pane lays its
        // header and list out by hand with no gap, and the diff pane's webview now butts onto its
        // band. The spacing is still wanted *below* the list, where the caption sits.
        leftStack.setCustomSpacing(0, after: repoHeader)
        leftStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: Theme.space3, right: 0)
        // Without this the scroll view's own content width becomes the pane's floor, and a 44 px
        // rail comes out at 87: the constraint said 44, the constant read 44, and the window drew
        // twice that. A check on the constant would have agreed with the wrong number.
        repoScroll.translatesAutoresizingMaskIntoConstraints = false
        repoScroll.widthAnchor.constraint(equalTo: leftStack.widthAnchor,
                                          constant: -2 * Theme.space3).isActive = true
        // The header takes the whole pane, because the hairline under it is the seam between the
        // header and the list: a rule stopping 6 pt short of the divider reads as a mistake.
        repoHeader.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
        repoFocusRing = repoScroll
        fileFocusRing = middleScroll
        diffFocusRing = webView
        let leftScroll = leftStack

        // The file pane is the header plus the list, in the same shape. The list keeps the full
        // pane width — the spine is 34 pt when collapsed (DEC-060) and an inset would take a third
        // of it.
        // **Autoresizing, not constraints, inside a split view's own pane.** `NSSplitView` sets its
        // arranged subviews' frames directly, and that leaves the frame and the layout engine
        // disagreeing: the pane's *frame* went to 34 pt on ⌃⌘0 while the engine still valued its
        // width at 320, so a `width == pane.width` constraint on the scroll view was satisfied
        // against 320 and the list stayed full width inside a collapsed pane. Measured — panes
        // 44/34/1320 with the scroll view at 320 inside the 34. An autoresizing mask follows the
        // frame the split sets, which is the only number that is true here.
        let filePane = FilePane(frame: NSRect(x: 0, y: 0, width: Theme.filePaneWidth,
                                              height: Theme.windowHeight))
        filePane.wantsLayer = true
        filePane.layer?.backgroundColor = Theme.panelFiles.cgColor
        filePane.header = fileHeader
        filePane.list = middleScroll
        // Autoresizing masks as well as the explicit placement: the mask is what AppKit applies when
        // the parent's frame changes, and the placement is what gets the first frames right. Setting
        // the frames alone was not enough — the list was put back to 320 between two `layout` calls,
        // by an engine that still held constraints derived from the frame it was created with.
        for child in [fileHeader, middleScroll] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
        }
        fileHeader.autoresizingMask = [.width, .minYMargin]
        middleScroll.autoresizingMask = [.width, .height]
        filePane.addSubview(fileHeader)
        filePane.addSubview(middleScroll)

        // The commit box, pinned under the list (DEC-092) exactly where GitHub Desktop pins it.
        // Laid out by hand like its two siblings, for the reason `FilePane` records: a pane inside
        // an `NSSplitView` cannot use Auto Layout against a width the engine no longer believes.
        commitBox = CommitBox(frame: NSRect(x: 0, y: 0, width: Theme.filePaneWidth,
                                            height: Theme.commitBoxHeight))
        commitBox.translatesAutoresizingMaskIntoConstraints = true
        commitBox.autoresizingMask = [.width, .maxYMargin]
        commitBox.button.target = self
        commitBox.button.action = #selector(commitStaged)
        // Return in the summary field commits, which is what a one-line field in a box with a
        // button under it means everywhere else in macOS.
        commitBox.summary.target = self
        commitBox.summary.action = #selector(commitStaged)
        // The amend switch fills the fields from the commit it is about to replace (DEC-098).
        commitBox.amend.target = self
        commitBox.amend.action = #selector(amendToggled)
        filePane.footer = commitBox
        filePane.footerHeight = Theme.commitBoxHeight
        filePane.addSubview(commitBox)

        // The lens control sits with the other two (DEC-061). The design draws it inside the pane
        // header; it lives here instead because a control in the webview cannot act — the page
        // receives calls, it does not make them — and a control that looks clickable and is not is
        // worse than one in a different place.
        lensControl = PillControl(labels: ["Diff", "Blame", "History"])
        lensControl.target = self
        lensControl.action = #selector(lensChanged)
        lensControl.selectedSegment = 0

        // A field, not a modal (DEC-062, the adopted design). ⌘F puts the caret here; ⇧⌘F does the
        // same and searches the whole worktree instead of the changed set. The scope is on screen
        // in the placeholder, because a count over the changed set and a count over the worktree
        // are different answers and a reader who does not know which they asked cannot read it.
        // DEC-088 item 1: the cell is ours, because an unbezeled `NSSearchFieldCell` lays the text
        // out on top of its own magnifier. `SearchFieldCell` states the two rectangles instead.
        searchField = SearchField()
        searchField.font = Theme.font(Theme.textSizeSmall)
        searchField.placeholderString = "Find in changed files"
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(equalToConstant: Theme.emptyStateMaximumWidth / 2).isActive = true
        // DEC-085 item 5: the same metal as the `+`. The field keeps its own editing, its focus
        // behaviour and its cancel button — the rim is a container around a system control, not a
        // control drawn from scratch.
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        // The rim's vertical inset is the padding the missing bezel used to hold (DEC-088): the
        // field was exactly its line height, so the caret sat on the metal.
        searchFieldHost = RimHost.wrapping(searchField, verticalPadding: Theme.searchTextPadding)

        // The scope and what it compares have left this band for a row of their own, across the
        // window (DEC-072): changing the scope changes the *file list*, so the control belongs
        // above the lists rather than inside the pane on the other side of them.
        // The mode switch has moved to the status line (DEC-075); the lens stays, because a lens is
        // about this pane and a mode is about the whole window's reading of a file.

        // The right pane is a view with two constraints, not a stack. A stack view inside a split
        // view asks for its *fitting* height, and a fitting height built from a control band and a
        // web view that reports none came out at two thirds of the window — three panes ending in
        // mid-air with a blank band under them.
        let rightStack = NSView(frame: NSRect(x: 0, y: 0,
                                              width: Theme.windowWidth - Theme.repositoryPaneWidth - Theme.filePaneWidth,
                                              height: Theme.windowHeight))
        rightStack.wantsLayer = true
        rightStack.layer?.backgroundColor = Theme.chrome.cgColor
        // DEC-085 item 3: **no band at all.** The lens has moved to the scope row, so the webview
        // starts at the pane's top — which is level with `REPOSITORIES` and `CHANGED FILES`, one
        // band higher than last session's fix put it. That fix aligned the three *contents*; the
        // owner's line is the headers' top, and re-read, it is the line the first report meant.
        rightStack.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        // DEC-083: **the three panes' contents begin at the same height.** This band was
        // `space4 + 24 + space4` = 40 pt against the two lists' 22 pt headers, so the code's
        // background started 18 pt below theirs and the window read as three surfaces that had
        // been laid out separately — which they had. The band is now the same one number the
        // headers are, and `paneHeaderHeight` is sized to hold a control because this one does.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: rightStack.topAnchor),
            webView.leadingAnchor.constraint(equalTo: rightStack.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rightStack.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rightStack.bottomAnchor),
        ])

        // The terminal spans the window (DEC-067). It sat under the diff until then, which wrapped
        // a command's output to a third of the width while two lists nobody was reading kept
        // theirs. T3's arrangement is unchanged in the part that mattered: a command finishes, the
        // sweep runs, and the lists beside it are still on screen.
        let terminalHost = terminal.webView!
        terminalHost.isHidden = true
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        // The constraints follow the drawer's state. `NSSplitView` sets its arranged subviews'
        // frames itself and treats these as a suggestion — `setPosition` is the lever that
        // actually moves the divider — but a hidden pane with a *required* 90 pt floor is a
        // constraint conflict waiting for the first narrow window, so the floor is only in force
        // while the drawer is open.
        terminalHeightConstraint = terminalHost.heightAnchor.constraint(equalToConstant: 0)
        terminalHeightConstraint.priority = NSLayoutConstraint.Priority(999)
        terminalHeightConstraint.isActive = true
        terminalMinimumConstraint = terminalHost.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Theme.terminalPaneMinimumHeight)
        terminalMinimumConstraint.isActive = false

        let vertical = rightStack

        // A non-zero starting frame, and for the reason M8-D recorded: `NSSplitView` distributes by
        // preserving the proportions it already has, so a pane that begins at zero height keeps a
        // share of zero — here it took half the window and left the rest blank.
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: Theme.windowWidth,
                                              height: Theme.windowHeight))
        splitView = split
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(filePane)
        // **Which pane gives way when the window is laid out again.** A width constraint is what the
        // pane asks for; the holding priority is what `NSSplitView` does when it redistributes, and
        // it redistributes on every layout pass — which nothing in this window triggered until the
        // status line began ticking once a second (DEC-075). The two sidebars hold their width; the
        // diff pane is what stretches, which is also what a reader wants.
        split.setHoldingPriority(NSLayoutConstraint.Priority(261), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 2)
        split.addArrangedSubview(vertical)

        // Auto layout inside the split, rather than frame proportions. NSSplitView distributes by
        // preserving existing proportions, and every pane started at zero — so the tables were
        // populated, correct, and drawn at zero width. Width constraints at a priority below
        // `defaultHigh` keep the dividers draggable.
        //
        // The minimum is *required* while a pane is full and dropped while it is collapsed
        // (DEC-060): a rail is 44 px wide and a floor of 140 would quietly refuse to draw it.
        var widthConstraints: [NSLayoutConstraint] = []
        var minimumConstraints: [NSLayoutConstraint] = []
        for (pane, width) in [(leftScroll, Theme.repositoryPaneWidth), (filePane, Theme.filePaneWidth)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let constraint = pane.widthAnchor.constraint(equalToConstant: width)
            // **500, not 999, and this is `28-…` §6 item 1** — the regression the owner reported
            // twice. At 999 the constraint beat `setPosition` outright: the arm asked the split for
            // a 220 pt pane and read 280 back *in the same layout pass*, so a drag never moved
            // anything and the delegate's write-back was writing the old number to itself.
            //
            // The reason 999 was chosen — *a collapse must win against the pane's own content* —
            // is met without it, because `applyCollapses` sets the constant **and** calls
            // `setPosition`, which is the instruction the split cannot reinterpret. That was
            // already the case when this said 999; the priority was insurance against a bug that
            // had been fixed a different way, and it cost the interaction.
            constraint.priority = NSLayoutConstraint.Priority(500)
            // **Inactive until a collapse wants it**, which is `28-…` §6 item 1. An `equalToConstant`
            // constraint on a split view's pane is restored by the layout engine on every pass, so
            // `setPosition` moved the frame and the next pass moved it straight back — the delegate
            // then wrote the restored width into the constant and called it a drag. That is why this
            // was reported fixed and reported again twice: the write-back was writing 280 to 280.
            //
            // What holds the width instead is the split's own divider position plus the minimum
            // below, and a collapse still wins because `applyCollapses` calls `setPosition` — the
            // instruction the split cannot reinterpret — and switches this on for the duration.
            constraint.isActive = false
            widthConstraints.append(constraint)
            let minimum = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.paneMinimumWidth)
            minimum.isActive = true
            minimumConstraints.append(minimum)
        }
        // **The reader can drag the dividers again** (DEC-077). The two width constraints are held at
        // 999 so a collapse cannot be ignored — and that is also what refused a drag: the split moves
        // the divider, the next layout pass restores the constant, and the pane snaps back. The
        // owner saw the resize cursor and nothing else. So the constants are **written back from the
        // drawn widths** whenever the split resizes its own subviews, which is the only event that
        // means *the reader moved this*.
        split.delegate = self
        repoPaneWidth = widthConstraints[0]
        filePaneWidth = widthConstraints[1]
        repoPaneMinimum = minimumConstraints[0]
        filePaneMinimum = minimumConstraints[1]
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.diffPaneMinimumWidth).isActive = true

        titleBar = buildTitleBar()
        scopeBar = buildScopeRow()
        statusBar = buildStatusBar()

        let drawer = NSSplitView()
        terminalSplit = drawer
        drawer.isVertical = false
        drawer.dividerStyle = .thin
        drawer.addArrangedSubview(split)
        drawer.addArrangedSubview(terminalHost)

        buildEmptyState()
        // Constraints rather than a stack view: the drawer has to take **everything** between the
        // two bars, and a stack asked to do that with a split view inside it gave the split its
        // frame height and left the rest of the window empty.
        // The banner (DEC-092), between the panes and the status line: it is about the repository
        // as a whole, and it must be the last thing under the reader's eye before the bar that
        // reports on the window. Hidden until something is in progress — a band that is always
        // there is a band nobody reads when it finally says something.
        operationBanner = OperationBanner()
        operationBanner.verbTarget = self
        operationBanner.verbAction = #selector(bannerVerb(_:))
        operationBanner.isHidden = true
        bannerHeightConstraint = operationBanner.heightAnchor.constraint(equalToConstant: 0)

        let container = NSView()
        container.addSubview(titleBar)
        container.addSubview(scopeBar)
        container.addSubview(drawer)
        container.addSubview(operationBanner)
        container.addSubview(statusBar)
        container.addSubview(emptyState)
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        scopeBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        operationBanner.translatesAutoresizingMaskIntoConstraints = false
        drawer.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: container.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Across the window, under the title bar and over the three panes (DEC-072).
            scopeBar.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scopeBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scopeBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            operationBanner.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            operationBanner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            operationBanner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Zero-height while hidden, so the panes take the space back rather than sitting above
            // an empty band — the same arrangement the notice bar was given in DEC-088.
            bannerHeightConstraint,
            drawer.topAnchor.constraint(equalTo: scopeBar.bottomAnchor),
            drawer.bottomAnchor.constraint(equalTo: operationBanner.topAnchor),
            drawer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The drawer has no height of its own — a split view takes the height it is given. So
            // when the empty state hides the split view inside it, the drawer's fitting height goes
            // to zero, and **the content view follows it down**: 1400×69 pt, the two bars with
            // nothing between them. The empty state is pinned to that container, so its buttons
            // were laid out at `y = −28`, off the top of the window, and the photograph of the
            // first screen a stranger meets came out a 2800×138 strip holding only the caption.
            //
            // `window.contentMinSize` does not reach this: it bounds the *window*, and the window
            // was never the thing that shrank.
            drawer.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.drawerMinimumHeight),
            emptyState.topAnchor.constraint(equalTo: container.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        // **The starting widths, set once through the split rather than held by a constraint.**
        // Nothing holds them any more (DEC-085 item 1: an active `equalToConstant` is what stopped a
        // drag sticking), so without this the split distributes by holding priority and the window
        // opened with a 150 pt repository pane instead of 280. `setPosition` is a starting point a
        // drag can move; a constraint was a floor it could not.
        alignTitleRowToTrafficLights()
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.setPosition(Theme.repositoryPaneWidth, ofDividerAt: 0)
        splitView.setPosition(Theme.repositoryPaneWidth + splitView.dividerThickness
                                  + Theme.filePaneWidth, ofDividerAt: 1)
        // The age changes with nothing else happening, so something has to ask. One second, and the
        // label is only assigned when the sentence changes.
        refreshTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateWatchLabel()
        }
        watchForKeyboardNavigation()
        // The drawer starts closed, and the divider has to say so. `NSSplitView` sets its arranged
        // subviews' frames itself — a height constraint on one of them is a suggestion it ignores —
        // so the only lever that works is `setPosition`, and it works on a laid-out split. One turn
        // of the run loop later, the window has a size and the position takes.
        DispatchQueue.main.async { [self] in
            window.contentView?.layoutSubtreeIfNeeded()
            terminalSplit.setPosition(terminalSplit.bounds.height, ofDividerAt: 0)
        }
        // The divider positions have to be set *after* the split has a width of its own. Setting
        // them on the next run-loop pass looks like it does that and does not: the split is inside
        // a constrained container, so its frame is still zero until layout runs, and every pane
        // collapsed to zero width. The tables were built, populated and invisible.
        container.layoutSubtreeIfNeeded()
    }

    private func makeTable(identifier: String) -> NSTableView {
        let table = HandTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.width = Theme.repositoryPaneWidth - 2 * Theme.space6 + Theme.space4
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = identifier == "repo" ? Theme.repositoryRowHeight : Theme.rowHeight
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        // Alternating rows were the only surface distinction the two lists had. The design gives
        // each list its own background (`--ds-panel-repos`, `--ds-panel-files`) and one selection
        // treatment, so the stripes go: two systems saying "this row is different from that one"
        // is one system too many.
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = identifier == "repo" ? Theme.panelRepositories : Theme.panelFiles
        // Drawn by `SelectedRowView` rather than by AppKit, so the selected row uses the design's
        // own surface **and** its ring (DEC-066). The system highlight is a solid accent fill: it
        // carries the selection in colour alone, and it repaints the row's text white, which takes
        // the file-kind glyph's own colour with it.
        table.selectionHighlightStyle = .regular
        // One column, so "last" is "the one": it grows and shrinks with the pane, which is what a
        // collapse needs (DEC-060).
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // `.plain`, because the automatic style is `.inset` on modern macOS: it adds a 16 pt
        // margin on each side and a 17 pt intercell spacing, and with one column that is 16 pt of
        // padding before the only cell. In a 44 px rail it consumed half the row — `kbt•` was set
        // on the row and `kb` was drawn. Measured rather than guessed: the cell reported its frame
        // 16 pt inside a 32 pt clip view.
        table.style = .plain
        table.intercellSpacing = NSSize(width: Theme.space2, height: 0)
        // The document view keeps whatever width it was last given; the clip view then shows a
        // window onto the middle of it. Tying the width to the clip is what makes a collapsed
        // pane show the *start* of each row rather than the middle.
        table.autoresizingMask = [.width]
        return table
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SelectedRowView()
    }

    private func scrollWrapping(_ view: NSView, surface: NSColor = Theme.chrome) -> NSScrollView {
        // A non-zero starting frame matters: NSSplitView distributes space by *preserving the
        // proportions of the frames it already has*, so panes that begin at zero width stay at
        // zero width no matter how wide the split becomes.
        // DEC-088: an overlay scroller whatever the system preference says, and a knob of our own.
        // *Show scroll bars: Always* is a setting about the system's scrollers, and in a 320 pt
        // pane of paths it is a stripe down the side of every row for as long as the list is
        // longer than the pane. This one is drawn while the reader scrolls and not otherwise.
        let scroll = OverlayScrollView(frame: NSRect(x: 0, y: 0, width: Theme.repositoryPaneWidth, height: Theme.windowHeight))
        scroll.documentView = view
        scroll.verticalScroller = SlimScroller()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // The pane's surface belongs to the scroll view too. A table paints only its own rows'
        // height, and below the last row the reader was seeing the scroll view's default black —
        // a third colour, in a window whose two lists each have one.
        scroll.drawsBackground = true
        scroll.backgroundColor = surface
        return scroll
    }

    /// Selftest lines go to stderr for the arms to read, and a normal launch is not an arm — a
    /// person starting the application should not be told `SELFTEST renderer=index.html` before
    /// their window appears.
    private func selftestLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func loadRenderer() {
        guard let html = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Renderer") else {
            // Not gated: a missing renderer bundle is a real failure of a real launch, and the
            // window can only say so in a status line nobody may be looking at.
            statusLabel.stringValue = "renderer bundle missing"
            FileHandle.standardError.write(Data("SELFTEST renderer=MISSING\n".utf8))
            if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil { exit(2) }
            return
        }
        selftestLog("SELFTEST renderer=\(html.lastPathComponent)\n")
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        terminal.load()
    }

    /// ⌥⌘T. The pane is built with the window and hidden; the *shell* starts here, the first time
    /// the reader asks for it.
    @objc func toggleTerminal() {
        setTerminalVisible(!terminalVisible, startingShell: true)
    }

    /// Showing the pane and starting a shell are separate acts. They were one, and the selftest —
    /// which has its own deterministic command to run — silently got the user's `$SHELL` instead,
    /// then reported on a buffer holding somebody's prompt.
    func setTerminalVisible(_ visible: Bool, startingShell: Bool) {
        terminalVisible = visible
        terminal.webView.isHidden = !visible
        terminalHeightConstraint.constant = visible ? Theme.terminalPaneHeight : 0
        terminalMinimumConstraint.isActive = visible
        terminalMenuItem?.state = visible ? .on : .off
        updateTerminalButton()
        terminalSplit.adjustSubviews()
        guard visible else {
            // Hiding has to move the divider too. A hidden pane keeps whatever share of the height
            // the split last gave it — the three panes stopped two thirds of the way down the
            // window and the rest was blank.
            terminalSplit.setPosition(terminalSplit.bounds.height, ofDividerAt: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            return
        }
        terminalSplit.setPosition(terminalSplit.bounds.height - Theme.terminalPaneHeight,
                                  ofDividerAt: 0)
        terminal.webView.needsDisplay = true
        window.displayIfNeeded()
        if startingShell { startTerminalIfNeeded() }
        terminal.focus()
    }

    /// ⌥⌘R. Opens the pane first if it is closed, because forcing raw mode on a terminal nobody can
    /// see would be a setting with no visible effect.
    /// A second shell in the same drawer (DEC-067). It opens where the reader is looking, which is
    /// the same rule the first one follows — and the only place a new shell can start that is not a
    /// guess.
    @objc func newTerminalTab() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "a terminal tab opens in the selected repository — choose one first"
            return
        }
        if !terminalVisible { setTerminalVisible(true, startingShell: false) }
        terminal.openTab(workingDirectory: repository.url.path)
        terminal.focus()
        statusLabel.stringValue = "terminal: \(terminal.tabs.count) tabs"
    }

    @objc func nextTerminalTab() { terminal.stepTab(by: 1) }
    @objc func previousTerminalTab() { terminal.stepTab(by: -1) }
    @objc func closeTerminalTab() { terminal.closeActiveTab() }

    @objc func toggleTerminalRawMode() {
        if !terminalVisible { setTerminalVisible(true, startingShell: true) }
        startTerminalIfNeeded()
        terminal.toggleForcedRaw()
        terminalRawMenuItem?.state = terminal.isForcedRaw ? .on : .off
    }

    @discardableResult
    func startTerminalIfNeeded() -> Bool {
        guard !terminal.started else { return true }
        // The reader's selection decides where the shell opens. *Following* the selection as it
        // changes belongs to T3; this is the one line that makes the pane useful before then.
        let directory = state.selectedRepository?.url.path ?? NSHomeDirectory()
        let started = terminal.start(workingDirectory: directory)
        if !started { statusLabel.stringValue = "the terminal could not start a shell" }
        terminal.onSessionExit = { [weak self] in
            guard let self else { return }
            self.terminal.stop()
            if self.terminalVisible { self.setTerminalVisible(false, startingShell: false) }
        }
        terminal.onCommandFinished = { [weak self] _ in self?.refreshAfterCommand() }
        return started
    }

    /// What a finished command adds to what the watcher already does.
    ///
    /// **Measured before it was written** (T3-A), and the measurement contradicted the reasoning:
    /// FSEvents *does* see `git commit`, because `.git` lives inside the watched root — one signal
    /// at ~440 ms, same as a plain edit. So the file list needs nothing from here.
    ///
    /// What no file-system event triggers is the **repository-level** sweep: the uncommitted count
    /// and commits-ahead-of-base beside every repository in the list. Those change the moment a
    /// commit lands and otherwise stay stale until the window is focused (DEC-006). That, and only
    /// that, is what a command's end mark is used for.
    func refreshAfterCommand() {
        guard state.selectedRepository != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCommandRefresh) > RefreshDebounce.quietPeriod else { return }
        lastCommandRefresh = now
        rescan()
    }

    /// ⌥⌘K. The explicit half of DEC-056: when the guard refused, the reader decides.
    @objc func followTerminalToSelection() {
        guard let repository = state.selectedRepository else { return }
        startTerminalIfNeeded()
        if !terminalVisible { setTerminalVisible(true, startingShell: true) }
        let outcome = terminal.follow(directory: repository.url.path, force: true)
        if case .sent = outcome {
            statusLabel.stringValue = "terminal followed to \(repository.displayName)"
        }
    }

    /// Called when the reader picks a different repository. The refusals are silent by design: the
    /// pane already shows that the directories disagree, and a status line that shouted every time
    /// somebody had half a command typed would be noise.
    private func followTerminalIfPossible(_ repository: RepositorySnapshot) {
        guard terminal.started else { return }
        terminal.follow(directory: repository.url.path)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        rendererReady = true
        // DEC-059 makes unified the default layout. The shell has always agreed — `sideBySide` is
        // `false` from launch and the menu item drew itself unchecked — and **nobody ever told the
        // page**, whose own default is `split`. So the reader got two panes side by side while
        // every other part of the application said one, and the only thing that ever set the layout
        // was the menu item they had to toggle twice to get the default back.
        //
        // The selftest could not catch it: its unified arm calls `diffscopeSetLayout("unified")`
        // first and then asks what the layout is. A check that sets the thing it is about to read
        // is asking what it asked for.
        webView.evaluateJavaScript(
            "window.diffscopeSetLayout(\"\(sideBySide ? "split" : "unified")\")") { _, _ in }
        if let pending = pendingModel { push(pending); pendingModel = nil }
        guard ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil else { return }
        let old = [UInt8]("const a = \"Z\u{0307}ABKA\";\n".utf8)
        let new = [UInt8]("const a = \"\u{017B}ABKA\";\n".utf8)
        let render = buildRenderModel(model: trivialModel(oldBytes: old, newBytes: new),
                                      pinOld: "pinA", pinNew: "pinB")
        guard let json = try? encodeRenderModel(render) else { exit(3) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // The layout is asked for here, at the first render, **before anything has set it** —
            // which is the only moment the *default* can be observed. Every later arm sets the
            // layout it is about to inspect.
            let ok = text.contains("pinA:pinB") && text.contains("\u{0307}")
                && text.contains("\"layout\":\"unified\"")
            FileHandle.standardError.write(Data("SELFTEST probe=\(ok ? "OK" : "MISMATCH") \(text.prefix(160))\n".utf8))
            if !ok { exit(4) }
            // The default has now been observed, which is the only thing that had to happen while
            // it was untouched. Every arm below reads the **two-pane** DOM — `.cm-lineNumbers`,
            // `.ds-gutter-changed`, `oldText`/`newText` — because they were all written while the
            // application started in split by accident. `runUnifiedSelftest` is the one that tests
            // the other layout, and it sets and restores it around itself.
            //
            // Setting it here rather than in each arm keeps the subject of every arm explicit:
            // one place decides which layout the rest of the walk is about.
            webView.evaluateJavaScript("window.diffscopeSetLayout(\"split\")") { _, _ in
                self.runStructuralSelftest()
            }
        }
    }

    /// Proves the structural path crosses into the renderer natively, not only in the harness:
    /// a formatting-only edit must arrive labelled and be marked as such in the document.
    private func runStructuralSelftest() {
        let old = [UInt8]("""
        export function Card({ title, items }) {
          return (
            <div className='card'>
              <h2>{title}</h2>
              <List items={items} />
            </div>
          );
        }

        """.utf8)
        let new = [UInt8]("""
        export function Card({ title, items }) {
          return (
            <>
                <h2>{title}</h2>
                <List items={items} />
            </>
          );
        }

        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinC", pinNew: "pinD",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(5) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // **Inverted by DEC-077.** The parser-state indicator (`12-…` §5.2) used to have to
            // reach the document on every file; the entry's requirement is the opposite one, and
            // it is the harder of the two to keep: a normal file says **nothing** about how it was
            // read. Every one of those facts is still computed and still asserted in
            // `TrustSurfaceChecks` — what is checked here is that none of them is drawn.
            let ok = text.contains("pinC:pinD")
                && text.contains("formatting-only")
                && !text.contains("parser: ")
                && !text.contains("mode: ")
                && !text.contains("confidence")
                && !text.contains("shown as plain text")
                && !text.contains("\"formattingMarks\":0")
            FileHandle.standardError.write(
                Data("SELFTEST structural=\(ok ? "OK" : "MISMATCH") \(outcome.summary) \(text.suffix(200))\n".utf8))
            if !ok { exit(6) }
            self.snapshot(named: "structural") {
                self.runModeAgreementSelftest(model: outcome.model, validation: outcome.validation,
                                              structuralProbe: text)
            }
        }
    }

    /// M7: two edits far apart, so the middle is foldable and "next change" has somewhere to go.
    private func runNavigationSelftest() {
        let lines = (1...40).map { "const value\($0) = \($0);\n" }.joined()
        let old = [UInt8]("const first = 1;\n\(lines)const last = 2;\n".utf8)
        let new = [UInt8]("const first = 111;\n\(lines)const last = 222;\n".utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinI", pinNew: "pinJ",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(13) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeCommand(\"nextChange\"))") { value, _ in
            let jump = (value as? String) ?? "nil"
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { probe, _ in
                let text = (probe as? String) ?? "nil"
                let ok = jump.contains("\"index\":0") && !text.contains("\"foldMarks\":0")
                FileHandle.standardError.write(
                    Data("SELFTEST navigation=\(ok ? "OK" : "MISMATCH") jump=\(jump) stops=\(render.stops.count) folds=\(render.collapses.count)\n".utf8))
                if !ok { exit(14) }
                self.snapshot(named: "navigation") {
                    self.runExpandToggleSelftest { self.runRefreshSelftest() }
                }
            }
        }
    }

    /// DEC-078: **⌘E is reversible.** Run against the navigation model, which is the one that has
    /// folds in it, and it asks for the round trip rather than for either direction alone — the
    /// defect the owner reported is not "collapse is missing", it is "there is no way back".
    ///
    /// The button's label is read from the document beside the fold count, because the label is the
    /// promise: a control whose effect depends on state the reader cannot see has to say which way
    /// it will go, and a fold set that toggles under a label stuck on `Expand` is the same defect
    /// with an extra step.
    private func runExpandToggleSelftest(then next: @escaping () -> Void) {
        func read(_ label: String, _ handler: @escaping (Int, String) -> Void) {
            webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let text = (value as? String) ?? "nil"
                let data = Data(text.utf8)
                let probe = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let folds = probe["foldMarks"] as? Int ?? -1
                let button = probe["expandLabel"] as? String ?? "?"
                FileHandle.standardError.write(Data(
                    ("SELFTEST expand-\(label) folds=\(folds) button=\(button)\n").utf8))
                handler(folds, button)
            }
        }
        read("before") { before, beforeLabel in
            self.webView.evaluateJavaScript("window.diffscopeCommand(\"expandAll\")") { _, _ in
                read("expanded") { opened, openedLabel in
                    self.webView.evaluateJavaScript("window.diffscopeCommand(\"expandAll\")") { _, _ in
                        read("collapsed") { closed, closedLabel in
                            // Three claims: the folds were there, one press opened every one of
                            // them, and a second press put the document back exactly as it was.
                            let ok = before > 0 && beforeLabel == "Expand"
                                && opened == 0 && openedLabel == "Collapse"
                                && closed == before && closedLabel == "Expand"
                            FileHandle.standardError.write(Data(
                                ("SELFTEST expand-toggle=\(ok ? "OK" : "MISMATCH") "
                                    + "\(before)→\(opened)→\(closed) folds, "
                                    + "\(beforeLabel)→\(openedLabel)→\(closedLabel)\n").utf8))
                            guard ok else { exit(29) }
                            next()
                        }
                    }
                }
            }
        }
    }

    /// M7 part two: a reindented block must arrive as one group that says how much it holds
    /// (DEC-048), and the reader's position must survive a refresh that inserts text above it
    /// (DEC-034). Both are decided in the engine, so what this proves is that the decision
    /// survives the crossing and is actually drawn.
    private func runRefreshSelftest() {
        let filler = (1...20).map { "const filler\($0) = \($0);\n" }.joined()
        let old = [UInt8]("""
        export function Card({ title }) {
          const a = 1;
          const b = 2;
          const c = 3;
          const d = 4;
          return <div>{title}</div>;
        }

        \(filler)
        """.utf8)
        let new = [UInt8]("""
        export function Card({ title }) {
            const a = 1;
            const b = 2;
            const c = 3;
            const d = 4;
          return <div>{title}</div>;
        }

        \(filler)
        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinK", pinNew: "pinL",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(15) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // DEC-017 allows grouping **only while the count is shown**, and until the footer
            // existed that count lived on the fold markers alone — so a reader who had scrolled
            // past them saw nothing. The bar is where it now stays put, so the bar is asserted.
            let grouped = !text.contains("\"formattingFoldMarks\":0") && text.contains("formatting-only changes")
                && text.contains("formatting differences") && text.contains("unchanged lines folded")
                // **The note beside the line is gone** (DEC-083), so what carries DEC-017's
                // requirement is what always did: the disclosed count, in the footer and on the
                // fold marker. The three assertions above are that count in three places; the
                // fourth was the word `formatting` printed after the code, which the contract had
                // already called annotation only and forbidden from being anything's sole carrier.
                && text.contains("\"notes\":[]")
            FileHandle.standardError.write(
                Data("SELFTEST formatting-collapse=\(grouped ? "OK" : "MISMATCH") groups=\(render.formattingCollapses.count) \(text.suffix(200))\n".utf8))
            if !grouped { exit(16) }
            self.snapshot(named: "refresh") { self.runAnchorSelftest(old: old, new: new) }
        }
    }

    private func runAnchorSelftest(old: [UInt8], new: [UInt8]) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeAnchorState())") { value, _ in
            guard let text = value as? String, let data = text.data(using: .utf8),
                  let anchor = try? JSONDecoder().decode(RefreshAnchor.self, from: data) else {
                FileHandle.standardError.write(Data("SELFTEST anchor=MISMATCH no anchor reported\n".utf8))
                exit(17)
            }
            let prefix = [UInt8]("const inserted = 0;\nconst alsoInserted = 1;\n".utf8)
            let outcome = self.buildModel(path: "selftest.tsx", old: prefix + old, new: prefix + new,
                                          mode: .structural)
            let render = buildRenderModel(model: outcome.model, pinOld: "pinM", pinNew: "pinN",
                                          mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                          notices: outcome.notices, previousAnchor: anchor)
            guard let json = try? encodeRenderModel(render) else { exit(18) }
            self.push(json)
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { probe, _ in
                let observed = (probe as? String) ?? "nil"
                let moved = (render.restore?.oldStart ?? 0) > anchor.oldStart
                let ok = render.restore?.resolution == .exact && moved && observed.contains("pinM:pinN")
                FileHandle.standardError.write(
                    Data("SELFTEST anchor=\(ok ? "OK" : "MISMATCH") \(String(describing: render.restore?.resolution)) \(anchor.oldStart) → \(render.restore?.oldStart ?? -1)\n".utf8))
                self.snapshot(named: "anchored") {
                    if ok { self.runDegradationSelftest() } else { exit(19) }
                }
            }
        }
    }

    /// DEC-051/INV-4: the most conservative condition must reach the *screen*, not merely the model.
    /// The harness can prove the ranking; only the webview can prove the sentence arrived, and the
    /// snapshot is the only way to see whether a sentence this long is still readable as a chip.
    private func runDegradationSelftest() {
        let old = [UInt8]("const a = 1;\n".utf8)
        let new = [UInt8]("const a = 2;\n".utf8)
        let disclosure = "a Git filter is active for this file (eol=crlf text=set), so the bytes on "
            + "disk and the bytes recorded in the object database are not the same text. This view "
            + "compares them as they are actually stored, which is why the file can be listed as "
            + "changed by `git status` while `git diff` reports nothing"
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural,
                                 external: [.filterActive(reason: disclosure)])
        let render = buildRenderModel(model: outcome.model, pinOld: "pinO", pinNew: "pinP",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(20) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // **This is INV-4's floor and the one sentence DEC-077 keeps.** The reader asked for
            // structural, the file was never read as code, and the pane has to say so in words
            // they can act on — *silent and right* and *silent and wrong* look identical.
            //
            // The pill and the parser chip carried it before (`23b-…` §2: `mode: structural` with
            // no qualification beside a notice saying structural was unavailable). Both are off
            // the screen now and neither is missed: the sentence says what the window did with the
            // file, why, and that nothing was dropped — and it says it **once**, where the two
            // chips and the notice had said overlapping halves of it in three wordings.
            let ok = text.contains("This file is shown as plain text")
                && text.contains("git status")
                && text.contains("Every difference in it is still shown")
                && !text.contains("mode: ")
                && !text.contains("parser: ")
            FileHandle.standardError.write(
                Data("SELFTEST degradation=\(ok ? "OK" : "MISMATCH") \(outcome.summary.prefix(80))\n".utf8))
            self.snapshot(named: "degraded") {
                if ok { self.runGutterSelftest() } else { exit(21) }
            }
        }
    }

    /// `12-…` §5.1: the gutter is the third carrier of change meaning. The harness proves which
    /// lines the engine marks; only the webview proves the numbers and the marks were drawn, and
    /// only the snapshot shows whether they are legible beside the code.
    private func runGutterSelftest() {
        let lines = (1...12).map { "const value\($0) = \($0);\n" }.joined()
        let old = [UInt8](lines.utf8)
        let new = [UInt8](lines.replacingOccurrences(of: "value7 = 7", with: "value7 = 77").utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinQ", pinNew: "pinR",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(22) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let numbered = !text.contains("\"lineNumbers\":0")
            let marked = !text.contains("\"gutterChanged\":0")
            // DEC-077: the tint replaced the underline, so the changed line now has two carriers
            // in this layout — the gutter edge and the tint behind it. Both are drawn from the
            // engine's `changedLines`, so **they must agree**, and a count that agrees is the only
            // way to catch a decoration that was computed and never reached a line.
            let data = Data(text.utf8)
            let probe = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let tinted = probe["tintedLines"] as? Int ?? -1
            let gutterChanged = probe["gutterChanged"] as? Int ?? -2
            let agree = tinted > 0 && tinted == gutterChanged
            self.webView.evaluateJavaScript("window.diffscopeCurrentLine()") { line, _ in
                let reported = (line as? Int) ?? (line as? NSNumber)?.intValue ?? -1
                // ⌘O used to hand the editor a literal 1 whatever the reader was looking at.
                let ok = numbered && marked && agree && reported >= 1
                FileHandle.standardError.write(
                    Data(("SELFTEST gutter=\(ok ? "OK" : "MISMATCH") line=\(reported) "
                        + "tinted=\(tinted) gutter-marked=\(gutterChanged) \(text.suffix(120))\n").utf8))
                self.snapshot(named: "gutter") {
                    if ok { self.runUnifiedSelftest() } else { exit(23) }
                }
            }
        }
    }

    /// DEC-059: the default layout, asked of the live document. The model is the gutter arm's —
    /// one line changed out of twelve — so the unified projection must show that line twice, once
    /// removed and once added, and the rest exactly once.
    ///
    /// What this arm is really for is the greyscale rule. Side-by-side separates direction by
    /// pane; unified has no panes, so if the sign column is ever empty the two directions differ
    /// by hue alone and the product is lying in a screenshot.
    private func runUnifiedSelftest() {
        webView.evaluateJavaScript("window.diffscopeSetLayout(\"unified\")") { _, _ in
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let text = (value as? String) ?? "nil"
                let data = Data(text.utf8)
                let probe = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let signs = probe["signs"] as? Int ?? 0
                let added = probe["addedLines"] as? Int ?? 0
                let removed = probe["removedLines"] as? Int ?? 0
                let doc = probe["unifiedText"] as? String ?? ""
                // Thirteen lines for twelve, because the changed one appears on both sides; the
                // sign column has one more marker than that, for the empty line a trailing
                // newline leaves behind.
                let lines = probe["unifiedLines"] as? Int ?? -1
                let ok = probe["layout"] as? String == "unified"
                    && lines == 13 && signs == lines + 1 && added == 1 && removed == 1
                    && doc.contains("value7 = 7;") && doc.contains("value7 = 77;")
                FileHandle.standardError.write(Data(
                    ("SELFTEST unified=\(ok ? "OK" : "MISMATCH") signs=\(signs) added=\(added) "
                        + "removed=\(removed) lines=\(lines) "
                        + "glyphs=\(probe["signGlyphs"] as? String ?? "?")\n").utf8))
                // **After a turn of the run loop.** Asked immediately, this reports whatever line
                // heights CodeMirror had before it re-measured, and the answer flips between runs
                // on identical input — which is the scale arm's lesson in a second place: a number
                // taken before the thing settles is a number about the timing, not the layout.
                self.snapshot(named: "unified") {
                    guard ok else { exit(24) }
                    // **After a turn of the run loop, and before the layout goes back.** Asked
                    // immediately, this reports whatever line heights CodeMirror had before it
                    // re-measured, and the answer flips between runs on identical input — the
                    // scale arm's lesson in a second place. Asked *late*, it reports the other
                    // layout: both of these were scheduled beside the snapshot and fired after it,
                    // so `unified-geometry` had been printing `unified: 0→0` — a measurement of a
                    // hidden view, under a name that said otherwise, for two milestones.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeHeights())") { h, _ in
                            FileHandle.standardError.write(Data(
                                ("SELFTEST unified-geometry \((h as? String) ?? "nil")\n").utf8))
                            // `28-…` item 2: the tint behind a changed line is as wide as the line
                            // box, and a line box is as wide as `.cm-content` — which CodeMirror
                            // sizes to the widest line, not to the scroller.
                            self.runWidthSelftest {
                                self.runTrackSelftest {
                                    // Back to two panes: every arm after this one probes two
                                    // documents, and the audit that follows must see the marks the
                                    // reader sees.
                                    self.webView.evaluateJavaScript("window.diffscopeSetLayout(\"split\")") { _, _ in
                                        self.runStyleAuditSelftest()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `28-…` item 2: **the tint behind a changed line reaches the right edge of the pane.**
    ///
    /// The tint is a line decoration, so it is as wide as the line box, and a line box is as wide
    /// as `.cm-content`. The defect was one missing `flex-direction` on the unified host — the
    /// layout switch sets `display: flex`, which made it a *row* container, and a flex item with no
    /// grow is as wide as its content. So every line ended at the longest line and the pane went
    /// black to the right of it. Nothing was wrong with the tint's own rule, which is why the
    /// acceptance test is a measurement of the line box rather than a photograph of the colour.
    ///
    /// Three questions, and the second is the one a single measurement would have missed:
    ///   1. every line box ends at the same place (`minLine == maxLine`) — a three-character line
    ///      and a two-hundred-character line are tinted to the same edge;
    ///   2. that place is the space beside the gutters (`maxLine == available`), **at two window
    ///      widths**, because a layout that has only ever been laid out once is a layout nobody has
    ///      checked (M9-K);
    ///   3. and the measurement can fail: the missing `flex-direction` is put back and the same
    ///      numbers are required to notice.
    private func runWidthSelftest(then next: @escaping () -> Void) {
        func measure(_ label: String, _ handler: @escaping (Bool, String) -> Void) {
            webView.evaluateJavaScript("JSON.stringify(window.diffscopeWidths())") { value, _ in
                let text = (value as? String) ?? "nil"
                let data = Data(text.utf8)
                let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let panes = all["panes"] as? [[String: Any]] ?? []
                let pane = panes.first { $0["view"] as? String == "unified" } ?? [:]
                let minLine = pane["minLine"] as? Int ?? -1
                let maxLine = pane["maxLine"] as? Int ?? -2
                let available = pane["available"] as? Int ?? -3
                let host = pane["hostWidth"] as? Int ?? -4
                let scroller = pane["scrollerWidth"] as? Int ?? -5
                let unmatched = (pane["rowDrift"] as? String ?? "").contains("lines-with-no-row=0")
                // Three relations, and the middle one is what the first control was missing: a
                // shrink-wrapped editor keeps every relation *inside* itself while occupying half
                // its pane, so the editor has to be measured against the pane as well.
                let filled = minLine == maxLine && maxLine == available && available > 0
                    && scroller == host && unmatched
                FileHandle.standardError.write(Data(
                    ("SELFTEST widths-\(label)=\(filled ? "OK" : "MISMATCH") "
                        + "min=\(minLine) max=\(maxLine) available=\(available) "
                        + "scroller=\(scroller) host=\(host) "
                        + "inner=\(all["innerWidth"] as? Int ?? -1) "
                        + "\(pane["rowDrift"] as? String ?? "no drift reported")\n").utf8))
                handler(filled, text)
            }
        }
        // A second width, taken from the window rather than from the page: the page cannot resize
        // itself and a width the layout was built at proves nothing about any other one.
        let original = window.frame
        measure("natural") { natural, _ in
            var narrowed = original
            narrowed.size.width -= 220
            self.window.setFrame(narrowed, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                measure("narrowed") { narrowed2, _ in
                    self.window.setFrame(original, display: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.webView.evaluateJavaScript("window.diffscopeInjectShrinkWrap(true)") { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                measure("control") { stillFilled, _ in
                                    let caught = !stillFilled
                                    FileHandle.standardError.write(Data(
                                        ("SELFTEST widths-control=\(caught ? "OK" : "MISMATCH") "
                                            + "the missing flex-direction is noticed\n").utf8))
                                    self.webView.evaluateJavaScript("window.diffscopeInjectShrinkWrap(false)") { _, _ in
                                        guard natural && narrowed2 && caught else { exit(26) }
                                        next()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `28-…` item 2's acceptance test, on the document that exercises it — and all that is left
    /// of the track arm, because DEC-086 removed the control. What that arm proved besides the
    /// slider is worth keeping: with wrapping off, a three-character line and a three-hundred
    /// character line are tinted to the **same right edge**, which is the long line's rather than
    /// the pane's.
    private func runTrackSelftest(then next: @escaping () -> Void) {
        let short = "abc\n"
        let long = String(repeating: "const someRatherLongIdentifier = 1; ", count: 9) + "\n"
        let old = [UInt8]((short + long).utf8)
        let new = [UInt8]((short + long.replacingOccurrences(of: "= 1;", with: "= 2;")).utf8)
        let outcome = buildModel(path: "selftest-track.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinS", pinNew: "pinT",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(27) }
        push(json)
        webView.evaluateJavaScript("window.diffscopeSetWrap(false)") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeTrackState())") { value, _ in
                    let text = (value as? String) ?? "nil"
                    let data = Data(text.utf8)
                    let probe = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                    let sameEdge = probe["sameEdge"] as? Bool ?? false
                    let span = probe["span"] as? Int ?? 0
                    // And nothing draws a slider for it any more.
                    let hidden = probe["hidden"] as? Bool ?? false
                    let ok = sameEdge && span > 0 && hidden
                    FileHandle.standardError.write(Data(
                        ("SELFTEST same-edge=\(ok ? "OK" : "MISMATCH") sameEdge=\(sameEdge) "
                            + "span=\(span) no-slider=\(hidden)\n").utf8))
                    self.webView.evaluateJavaScript("window.diffscopeSetWrap(true)") { _, _ in
                        guard ok else { exit(28) }
                        next()
                    }
                }
            }
        }
    }

    /// G2 (`23-release-gates.md`): a design may restyle any mark and may never hide one. Asked of
    /// the live document, because a stylesheet can be read and still be wrong about what the reader
    /// gets — a later rule, a cascade, an inherited opacity.
    private func runStyleAuditSelftest() {
        // The same width question asked of the two-pane layout, which sizes its content
        // independently of unified and can therefore be right while unified is wrong.
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeWidths())") { w, _ in
            FileHandle.standardError.write(Data(
                ("SELFTEST split-widths \((w as? String) ?? "nil")\n").utf8))
        }
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeStyleAudit())") { value, _ in
            let text = (value as? String) ?? "nil"
            let data = Data(text.utf8)
            let audit = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] ?? [:]
            var hidden: [String] = []
            var colourOnly: [String] = []
            for (name, entry) in audit {
                if entry["hidden"] as? Bool == true { hidden.append(name) }
                if (entry["distinguishing"] as? [String])?.isEmpty ?? true { colourOnly.append(name) }
            }
            let ok = !audit.isEmpty && hidden.isEmpty && colourOnly.isEmpty
            let line = "SELFTEST style=\(ok ? "OK" : "MISMATCH") audited=\(audit.count)"
                + " hidden=\(hidden.sorted()) colour-only=\(colourOnly.sorted())\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(24) }

            // Negative control: hide a mark deliberately and require the audit to catch it. An
            // audit that passes on a hidden mark would pass on a design that hid one.
            self.webView.evaluateJavaScript("window.diffscopeInjectHostileStyle(true)") { _, _ in
                self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeStyleAudit())") { hostile, _ in
                    let text = (hostile as? String) ?? ""
                    let caught = text.contains("\"ds-changed\":{\"hidden\":true")
                        || text.contains("\"hidden\":true,\"distinguishing\"")
                    FileHandle.standardError.write(Data(
                        "SELFTEST style-control=\(caught ? "OK" : "MISMATCH") the audit catches a hidden mark\n".utf8))
                    self.webView.evaluateJavaScript("window.diffscopeInjectHostileStyle(false)") { _, _ in
                        guard caught else { exit(25) }
                        self.runTerminalSelftest()
                    }
                }
            }
        }
    }

    /// T1 (DEC-054): a command run through a real PTY, its output reaching the grid, and the
    /// alternate screen entered and reported.
    ///
    /// The command is `/bin/sh -c`, not the user's shell: G3 runs this selftest from `/` on a
    /// stranger's machine, where `$SHELL` and `~/.zshrc` are somebody else's. Prompt marks are
    /// covered headlessly in `TerminalChecks` and against a real interactive zsh by gate T0.
    private func runTerminalSelftest() {
        setTerminalVisible(true, startingShell: false)
        // The grid is the first surface in this product that paints on `requestAnimationFrame`, and
        // WebKit suspends those while the window is **occluded** — which a window launched behind a
        // terminal always is. The buffer then fills while the screen stays empty, and every other
        // signal looks healthy: this is M8-D's defect class arriving through a different door.
        //
        // So the selftest brings its own window to the front and requires that painting resumes.
        // Without this the arm below could only ever assert what the buffer holds.
        window.level = .floating
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let script = "printf 'DIFFSCOPE-TERMINAL-OK\\n'; sleep 1;"
            + " printf '\\033[?1049hALTERNATE-OK'; sleep 3"
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                             command: "/bin/sh",
                             arguments: ["-c", script]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal=MISMATCH no shell\n".utf8))
            exit(26)
        }

        // A pane drawn at zero size reports a size and no error anywhere else — M8-D, where two
        // lists rendered completely blank and nothing failed. The grid's own pixel size is part of
        // what is asserted, not just the text in its buffer.
        pollTerminal(until: { probe in
            probe.contains("DIFFSCOPE-TERMINAL-OK") && !probe.contains("\"pixelWidth\":0")
        }, timeout: 6) { reached, probe in
            let sized = !probe.contains("\"pixelWidth\":0") && !probe.contains("\"pixelHeight\":0")
            let tokensPresent = probe.contains("\"missingTokens\":[]")
            let ok = reached && sized && tokensPresent
            let line = "SELFTEST terminal=\(ok ? "OK" : "MISMATCH") output reached the grid; "
                + "\(probe.prefix(700))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(27) }

            self.pollTerminal(until: {
                $0.contains("\"alternateScreen\":true") && $0.contains("ALTERNATE-OK")
            }, timeout: 8) { entered, alternate in
                let line = "SELFTEST terminal-alternate=\(entered ? "OK" : "MISMATCH") "
                    + "\(alternate.prefix(700))\n"
                FileHandle.standardError.write(Data(line.utf8))
                guard entered else { exit(28) }
                self.assertTerminalPainted {
                    self.snapshotTerminal(named: "terminal") { self.runInputLineSelftest() }
                }
            }
        }
    }

    /// What the buffer holds and what the screen shows are different claims, and only the second is
    /// what the reader gets — M8-D was a surface that drew nothing while every check passed.
    ///
    /// The grid paints on `requestAnimationFrame`, and WebKit suspends those while the window is
    /// occluded: `document.visibilityState` goes to `hidden` and the DOM rows are never written. A
    /// selftest launched from a terminal is usually behind that terminal, so this arm **waits for a
    /// genuinely visible window** and says plainly when it never got one, rather than asserting on
    /// pixels that were never asked for.
    private func assertTerminalPainted(then next: @escaping () -> Void) {
        var attempts = 0
        func check() {
            terminal.webView.evaluateJavaScript("document.visibilityState") { value, _ in
                attempts += 1
                if (value as? String) != "visible", attempts < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                    return
                }
                guard (value as? String) == "visible" else {
                    FileHandle.standardError.write(Data(
                        ("SELFTEST terminal-paint=SKIPPED the window stayed occluded for 3 s, so "
                            + "WebKit suspended animation frames and the grid was never asked to "
                            + "paint. Run with DiffScope in front to assert drawn glyphs.\n").utf8))
                    next()
                    return
                }
                self.pollTerminal(until: { $0.contains("\"renderedText\":\"ALTERNATE-OK") },
                                  timeout: 4) { painted, probe in
                    let frames = probe.contains("\"framesSinceLastProbe\":0") ? "none" : "arriving"
                    let line = "SELFTEST terminal-paint=\(painted ? "OK" : "MISMATCH") "
                        + "glyphs on screen, frames \(frames)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard painted else { exit(29) }
                    next()
                }
            }
        }
        check()
    }

    /// Polling rather than a fixed delay: the grid is driven by a real process, and a selftest that
    /// waits a chosen number of milliseconds passes or fails by machine load.
    private func pollTerminal(until condition: @escaping (String) -> Bool,
                              timeout: TimeInterval,
                              deadline: Date? = nil,
                              then completion: @escaping (Bool, String) -> Void) {
        let limit = deadline ?? Date().addingTimeInterval(timeout)
        terminal.probe { probe in
            if condition(probe) { completion(true, probe); return }
            if Date() >= limit { completion(false, probe); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.pollTerminal(until: condition, timeout: timeout, deadline: limit, then: completion)
            }
        }
    }

    /// T2: the input line, driven the way a reader drives it — a prompt mark, then a typed command,
    /// then a handover.
    ///
    /// The fixture is `printf` of a prompt mark followed by `cat`: real marks over a real PTY, an
    /// echo to prove the bytes arrived, and no dependence on whose `~/.zshrc` is installed.
    private func runInputLineSelftest() {
        terminal.stop()
        // The fixture prints a **coloured prompt between the marks** since DEC-089, because the
        // prompt is now half of what this arm is about: one line, the shell's own ink, one caret.
        // `%%` is `printf`'s escape for the `%` a shell prompt ends in.
        let prompt = "printf '\\033]133;A\\007\\033[36muser@host\\033[0m "
            + "\\033[34m~/x\\033[0m %% \\033]133;B\\007'; cat"
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                            command: "/bin/sh",
                            arguments: ["-c", prompt]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal-input=MISMATCH no shell\n".utf8))
            exit(30)
        }

        pollTerminal(until: { $0.contains("\"mode\":\"local\"") }, timeout: 6) { local, probe in
            let visible = probe.contains("\"inputVisible\":true")
            let labelled = probe.contains("\"modeLabel\":\"prompt\"")
            let configured = probe.contains("\"Enter\"") && probe.contains("\"ctrl-r\"")
            let ok = local && visible && labelled && configured
            let line = "SELFTEST terminal-input=\(ok ? "OK" : "MISMATCH") a prompt mark opened the "
                + "input line; \(probe.suffix(220))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(31) }

            // **DEC-089's visible half**, and the assertion is a *disjunction of surfaces*: the
            // prompt is in the row and it is **not** in the grid. Either half alone passes on the
            // arrangement the owner reported — the prompt was in the grid and the field was under
            // it, and both of those were true.
            self.terminal.probe { inlineProbe in
                let inRow = inlineProbe.contains("\"promptText\":\"user@host ~/x % \"")
                let coloured = inlineProbe.contains("--ds-term-cyan")
                    && inlineProbe.contains("--ds-term-blue")
                // The grid's own buffer, which is where it used to be.
                let notInGrid = !(inlineProbe.range(of: "\"text\":\"[^\"]*user@host",
                                                    options: .regularExpression) != nil)
                let oneCaret = inlineProbe.contains("\"gridCursorHidden\":true")
                let ok = inRow && coloured && notInGrid && oneCaret
                let line = "SELFTEST terminal-prompt=\(ok ? "OK" : "MISMATCH") the prompt is beside "
                    + "the caret and not in the grid; inRow=\(inRow) coloured=\(coloured) "
                    + "notInGrid=\(notInGrid) oneCaret=\(oneCaret)\n"
                FileHandle.standardError.write(Data(line.utf8))
                guard ok else { exit(71) }

                // The one state this product has that a check cannot fully settle — *does it read
                // as one line* — and the one the owner asked for. Photographed before anything is
                // typed, which is when the two surfaces used to be most obviously two.
                self.snapshotTerminal(named: "terminal-prompt") {
                // A real keydown through the page's own handler, not a call into its internals: the
                // interception, the routing round trip and the write to the PTY are all on the path.
                let type = """
                (() => { const f = document.getElementById('line'); f.focus(); f.value = 'typed-into-the-line';
                  f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true}));
                  return f.value; })()
                """
                self.terminal.webView.evaluateJavaScript(type) { cleared, _ in
                    self.pollTerminal(until: { $0.contains("typed-into-the-line") }, timeout: 6) { echoed, after in
                        let emptied = (cleared as? String) == "" || after.contains("\"line\":\"\"")
                        let ok = echoed && emptied
                        let line = "SELFTEST terminal-submit=\(ok ? "OK" : "MISMATCH") the line reached the "
                            + "shell and the field cleared\n"
                        FileHandle.standardError.write(Data(line.utf8))
                        guard ok else { exit(32) }

                        // **And the released prompt landed in front of the echo.** This is the whole
                        // reason the prompt is held rather than dropped: the scrollback after a
                        // command has to read exactly as it does in any terminal.
                        let grid = after.range(of: "\"text\":\"[^\"]*\"", options: .regularExpression)
                            .map { String(after[$0]) } ?? ""
                        let ordered = grid.range(of: "user@host").map { promptAt in
                            grid.range(of: "typed-into-the-line").map { promptAt.lowerBound < $0.lowerBound }
                        } ?? nil
                        let cleared = after.contains("\"promptSegments\":0")
                        let inOrder = (ordered ?? false) && cleared
                        let released = "SELFTEST terminal-prompt-release=\(inOrder ? "OK" : "MISMATCH") "
                            + "the withheld prompt reached the grid ahead of the echo; "
                            + "ordered=\(String(describing: ordered)) rowCleared=\(cleared)\n"
                        FileHandle.standardError.write(Data(released.utf8))
                        guard inOrder else { exit(72) }
                        self.runHandoverSelftest()
                    }
                }
                }
            }
        }
    }

    /// Tab is the shell's, not ours: the typed text and the key go over, and the mode says who has
    /// the line. Without this the input line would silently break completion.
    private func runHandoverSelftest() {
        let tab = """
        (() => { const f = document.getElementById('line'); f.focus(); f.value = 'handed-over-text';
          f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true}));
          return true; })()
        """
        terminal.webView.evaluateJavaScript(tab) { _, _ in
            self.pollTerminal(until: {
                $0.contains("\"mode\":\"handedOver\"") && $0.contains("handed-over-text")
            }, timeout: 6) { handed, probe in
                let hidden = probe.contains("\"inputVisible\":false")
                let admits = probe.contains("shell has the line")
                let ok = handed && hidden && admits
                let line = "SELFTEST terminal-handover=\(ok ? "OK" : "MISMATCH") the shell has the "
                    + "line and the chip says so; \(probe.suffix(200))\n"
                FileHandle.standardError.write(Data(line.utf8))
                guard ok else { exit(33) }

                self.terminal.toggleForcedRaw()
                self.pollTerminal(until: { $0.contains("\"mode\":\"forcedRaw\"") }, timeout: 4) { forced, forcedProbe in
                    let admitsForced = forcedProbe.contains("forced")
                    let line = "SELFTEST terminal-escape-hatch=\(forced && admitsForced ? "OK" : "MISMATCH") "
                        + "⌥⌘R forces raw and the chip admits it\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard forced, admitsForced else { exit(34) }
                    self.terminal.toggleForcedRaw()
                    self.snapshotTerminal(named: "terminal-input") { self.runFollowSelftest() }
                }
            }
        }
    }

    /// T3: the terminal belongs to the product — it reports where it is, and follows the reader's
    /// selection when there is provably nothing to disturb.
    ///
    /// The fixture reports a directory over OSC 7 and then echoes, so the chip, the guard and the
    /// composed `cd` are all exercised without depending on anybody's shell.
    private func runFollowSelftest() {
        terminal.stop()
        let target = NSTemporaryDirectory() + "diffscope selftest 'dir"
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let script = "printf '\\033]7;file:///tmp/reported-by-the-shell\\007'; "
            + "printf '\\033]133;A\\007'; cat"
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                             command: "/bin/sh", arguments: ["-c", script]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal-follow=MISMATCH no shell\n".utf8))
            exit(35)
        }

        pollTerminal(until: { $0.contains("reported-by-the-shell") }, timeout: 6) { reported, probe in
            let ok = reported && probe.contains("\"cwdDiverged\":true")
            let line = "SELFTEST terminal-cwd=\(ok ? "OK" : "MISMATCH") the shell reports where it "
                + "is, and the pane says it is not the selected directory; \(probe.suffix(160))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(36) }

            // A path with a space and a quote in it, because that is the case that would go wrong.
            let outcome = self.terminal.follow(directory: target)
            let sent = outcome?.wasSent ?? false
            self.pollTerminal(until: { _ in false }, timeout: 0.4) { _, _ in
                self.terminal.probe { after in
                    // `cat` echoes, so the composed command is visible in the grid's own buffer.
                    let arrived = after.contains("cd -- '") && after.contains("selftest ")
                    let ok = sent && arrived
                    let line = "SELFTEST terminal-follow=\(ok ? "OK" : "MISMATCH") the quoted cd "
                        + "reached the shell; \(String(describing: outcome))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard ok else { exit(37) }
                    try? FileManager.default.removeItem(atPath: target)
                    self.snapshotTerminal(named: "terminal-follow") {
                        // The tabs arm needs the first shell alive: what it checks is that two
                        // scrollbacks stay apart, which cannot be asked of a drawer with one.
                        self.terminalTabsSelftest()
                    }
                }
            }
        }
    }

    /// Definition of done §6: *a 63-file working tree is reviewable entirely from the keyboard*.
    ///
    /// The claim is about a person with their hands on the keys, so this arm presses keys — real
    /// `NSEvent`s through the real menu bar and the real table, not `@objc` methods called directly.
    /// Calling the methods would prove the methods work and say nothing about whether anything is
    /// **bound** to them, which is the half DEC-016 is actually about.
    ///
    /// The tree comes from `Scripts/keyboard-tree.sh` by way of `DIFFSCOPE_KEYBOARD_TREE`. Without
    /// it the arm says SKIPPED **with the reason** — the T1-A pattern, after a blank grid passed
    /// every arm it had.
    /// DEC-067: a second shell in the same drawer. What a picture cannot check is that the two
    /// scrollbacks stay apart — one grid replaying a buffer would show the first shell's output in
    /// the second tab and look completely right.
    private func terminalTabsSelftest() {
        let directory = NSTemporaryDirectory()
        guard terminal.openTab(workingDirectory: directory, command: "/bin/sh",
                               arguments: ["-c", "printf SECOND-TAB-OK; sleep 4"]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal-tabs=MISMATCH no second shell\n".utf8))
            exit(54)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.terminal.probe { second in
                let secondHasOwn = second.contains("SECOND-TAB-OK")
                    && !second.contains("DIFFSCOPE-TERMINAL-OK")
                let count = self.terminal.tabs.count
                // Back to the first tab: its scrollback must still hold what it held, which is the
                // whole claim behind one emulator per tab.
                // **Never silently.** A packaging run died here once in four and the log simply
                // stopped after the previous arm — no MISMATCH, no trace, nothing to grep for. An
                // `exit` with no message is a failure that cannot be read, which is the shape M9-C
                // was written about.
                guard let first = self.terminal.tabs.first else {
                    FileHandle.standardError.write(Data(
                        "SELFTEST terminal-tabs=MISMATCH the tab list was empty after opening one\n".utf8))
                    exit(54)
                }
                self.terminal.selectTab(first.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.terminal.probe { back in
                        // The claim is that the two scrollbacks stay **apart**, not that the first
                        // one holds any particular string: by this point its shell has been
                        // restarted twice by earlier arms and holds a prompt and a `cd`. What must
                        // never be true is that the second tab's output turns up in it — which is
                        // exactly what one grid replaying a buffer would produce.
                        let firstKeptIts = !back.contains("SECOND-TAB-OK")
                        let ok = count == 2 && secondHasOwn && firstKeptIts
                        FileHandle.standardError.write(Data(
                            ("SELFTEST terminal-tabs=\(ok ? "OK" : "MISMATCH") tabs=\(count) "
                                + "second-own-scrollback=\(secondHasOwn) "
                                + "first-scrollback-clean=\(firstKeptIts)\n").utf8))
                        self.snapshotTerminal(named: "terminal-tabs") {
                            guard ok else { exit(54) }
                            // And closing one leaves the other running rather than taking the
                            // drawer with it.
                            let closing = self.terminal.tabs.last!.id
                            self.terminal.closeTab(closing)
                            let survived = self.terminal.tabs.count == 1 && self.terminal.started
                            FileHandle.standardError.write(Data(
                                ("SELFTEST terminal-tab-close=\(survived ? "OK" : "MISMATCH") "
                                    + "left=\(self.terminal.tabs.count) open=\(self.terminal.started)\n").utf8))
                            guard survived else { exit(55) }
                            self.terminal.stop()
                            self.runKeyboardSelftest()
                        }
                    }
                }
            }
        }
    }

    private func runKeyboardSelftest() {
        guard let tree = ProcessInfo.processInfo.environment["DIFFSCOPE_KEYBOARD_TREE"],
              FileManager.default.fileExists(atPath: tree + "/.git") else {
            FileHandle.standardError.write(Data(
                ("SELFTEST keyboard=SKIPPED no DIFFSCOPE_KEYBOARD_TREE — build one with "
                    + "Scripts/keyboard-tree.sh and the walk over 63 files is measured\n").utf8))
            exit(0)
        }
        // The **configuration** is pointed at the tree, not just this one sweep. DEC-006 refreshes
        // the list when the window becomes active, and that refresh reads the configuration — so a
        // scan of the tree alone was being replaced by the reader's real repositories a second
        // later, and the arm then reported a tree with no changes in it. The race was invisible
        // until two arms were added ahead of this one and it started losing.
        state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository, path: tree)])
        scan(sources: state.configuration.sources)
        // A sweep already in flight when this one starts still finishes, and finishing later means
        // winning: the startup sweep of the reader's own configuration replaced the fixture tree a
        // second after it was scanned, and the arm reported a tree with no changes in it. So the
        // arm waits for the list to *be* the tree rather than assuming its own scan was the last
        // word. Invisible until two arms were added ahead of this one and the timing shifted.
        waitForTree(tree, attemptsLeft: 40) {
        // The sweep is off the main thread; the walk needs the list it produces.
        self.waitForFiles(attemptsLeft: 40) { files in
            guard files == 63 else {
                FileHandle.standardError.write(Data(
                    ("SELFTEST keyboard=MISMATCH the tree has \(files) changed files, not 63 "
                        + "repos=\(self.state.repositories.count) selected=\(self.state.selectedRepository?.url.lastPathComponent ?? "none") "
                        + "rows=\(self.state.fileRows.count) scope=\(self.state.scope)\n").utf8))
                exit(40)
            }
            self.walkTheFileList()
        }
        }
    }

    private func waitForTree(_ tree: String, attemptsLeft: Int, then next: @escaping () -> Void) {
        if state.repositories.count == 1, state.repositories[0].url.path == tree {
            next(); return
        }
        guard attemptsLeft > 0 else {
            FileHandle.standardError.write(Data(
                ("SELFTEST keyboard=MISMATCH the list never became the fixture tree — "
                    + "\(state.repositories.map { $0.url.lastPathComponent })\n").utf8))
            exit(40)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.scan(sources: self.state.configuration.sources)
            self.waitForTree(tree, attemptsLeft: attemptsLeft - 1, then: next)
        }
    }

    private func waitForFiles(attemptsLeft: Int, then next: @escaping (Int) -> Void) {
        let files = state.fileRows.compactMap { $0.file }.count
        guard files == 0, attemptsLeft > 0 else { next(files); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForFiles(attemptsLeft: attemptsLeft - 1, then: next)
        }
    }

    /// Two walks over the same list: ⌘] through the menu bar, and ↓ through the table itself. They
    /// disagreed until M8-J — ⌘] stepped past headers and ↓ landed on them — which is why both are
    /// pressed here rather than one being taken as evidence for the other.
    private func walkTheFileList() {
        let headers = state.fileRows.filter { $0.file == nil }.count
        focusFiles()
        fileTable.selectRowIndexes(IndexSet(integer: RowNavigation.firstSelectable(in: state.fileRows) ?? 0),
                                   byExtendingSelection: false)

        var visited: [String] = []
        var headerStops = 0
        var keystrokes = 0
        func record() {
            let row = fileTable.selectedRow
            if row >= 0, row < state.fileRows.count {
                if let file = state.fileRows[row].file { visited.append(file.path) } else { headerStops += 1 }
            }
        }
        record()
        while keystrokes < 200 {
            let before = fileTable.selectedRow
            // ⌥↓ since DEC-065 re-cut the map: the file tier of the three movement tiers. This
            // was ⌘] and the walk kept passing with the old key bound to nothing, which is why the
            // press is asserted rather than merely sent.
            guard press(key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                        modifiers: [.option, .function, .numericPad], keyCode: 125) else { break }
            // The end of the list is where the selection stops moving; ⌥↓ does not wrap, which is
            // itself the behaviour under test. That last press is a probe for the end rather than a
            // step, so it is not counted.
            guard fileTable.selectedRow != before else { break }
            keystrokes += 1
            record()
        }
        let distinct = Set(visited).count
        let menuOK = distinct == 63 && headerStops == 0 && keystrokes == 62
        FileHandle.standardError.write(Data(
            ("SELFTEST keyboard=\(menuOK ? "OK" : "MISMATCH") ⌥↓ visited \(distinct) of 63 files in "
                + "\(keystrokes) keystrokes past \(headers) headers, \(headerStops) blind stops\n").utf8))
        guard menuOK else { exit(41) }

        // The bare arrow keys, through the table's own key handling rather than through the menu.
        // `shouldSelectRow` is what makes them agree with the menu route; before it, ↓ selected headers and the diff pane kept showing the last file.
        fileTable.selectRowIndexes(IndexSet(integer: RowNavigation.firstSelectable(in: state.fileRows) ?? 0),
                                   byExtendingSelection: false)
        var arrowVisited: [String] = []
        var arrowHeaderStops = 0
        for _ in 0..<80 {
            let row = fileTable.selectedRow
            guard row >= 0, row < state.fileRows.count else { break }
            if let file = state.fileRows[row].file { arrowVisited.append(file.path) } else { arrowHeaderStops += 1 }
            sendArrowDown()
            if fileTable.selectedRow == row { break }
        }
        let arrowOK = Set(arrowVisited).count == 63 && arrowHeaderStops == 0
        FileHandle.standardError.write(Data(
            ("SELFTEST keyboard-arrows=\(arrowOK ? "OK" : "MISMATCH") ↓ visited "
                + "\(Set(arrowVisited).count) of 63 files, \(arrowHeaderStops) blind stops\n").utf8))
        guard arrowOK else { exit(42) }

        rawForCurrentRegionSelftest()
    }

    /// ⌘R since DEC-065 (⌥⌘V when M8-J built it): the row of `12-…` §9 that had no implementation
    /// at all before that milestone. The same region, shown raw, and the mode it left restored on
    /// the second press.
    private func rawForCurrentRegionSelftest() {
        guard let modified = state.fileRows.compactMap({ $0.file }).first(where: { $0.kind == .modified }),
              let row = state.fileRows.firstIndex(where: { $0.file?.path == modified.path }) else {
            FileHandle.standardError.write(Data("SELFTEST keyboard-raw-region=MISMATCH no modified file\n".utf8))
            exit(43)
        }
        fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileTable.scrollRowToVisible(row)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.press(key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                             modifiers: [.command, .function, .numericPad], keyCode: 125) else { exit(43) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { value, _ in
                    let before = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
                    guard self.press(key: "r", modifiers: [.command]) else { exit(44) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { raw, _ in
                            let inRaw = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? -1
                            let ok = self.state.mode == .raw && inRaw == before && before >= 0
                            FileHandle.standardError.write(Data(
                                ("SELFTEST keyboard-raw-region=\(ok ? "OK" : "MISMATCH") mode="
                                    + "\(self.state.mode.rawValue) stop \(before) → \(inRaw)\n").utf8))
                            guard ok else { exit(45) }
                            guard self.press(key: "r", modifiers: [.command]) else { exit(46) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                let returned = self.state.mode == .structural
                                FileHandle.standardError.write(Data(
                                    ("SELFTEST keyboard-return=\(returned ? "OK" : "MISMATCH") the second "
                                        + "press returns to \(self.state.mode.rawValue)\n").utf8))
                                guard returned else { exit(47) }
                                // The drawer is closed first: `cacheDisplay` cannot capture a
                                // `WKWebView`, so an open terminal turns a third of the chrome
                                // picture into a black rectangle — which is exactly how six
                                // rounds went into "why do the panes stop two thirds down".
                                self.setTerminalVisible(false, startingShell: false)
                                self.windowSnapshot(named: "keyboard") { self.fileSelectionSelftest() }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `28-…` §5 item 1: **the file being shown is the selected row**, after a sweep and not only
    /// after a click.
    ///
    /// The arm exists because the defect could not be seen from anywhere else. The three calls to
    /// `fileTable.selectRowIndexes` in this file were all in the selftest, so every walk *set* the
    /// selection it then measured — a check asking what it had just asked for, which is the shape
    /// `23b-…` §2 records for the unified layout. This asks the opposite way round: the pane is
    /// told which file to show, the list is rebuilt from Git, and only then is the row read.
    private func fileSelectionSelftest() {
        guard let file = state.selectedFile else {
            FileHandle.standardError.write(Data(
                "SELFTEST file-selected=MISMATCH nothing is being shown\n".utf8))
            exit(68)
        }
        // The control first: drop the selection the way a reload used to, and confirm the arm can
        // see it gone. A check that has only ever run against a selected row would pass on a list
        // that selects everything.
        fileTable.deselectAll(nil)
        let cleared = selectedFileRowPath == nil

        // Then the product path — the whole list rebuilt from Git, which is what a refresh does.
        reloadFiles()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let marked = self.selectedFileRowPath
            let agrees = marked == file.path
            // And it must be marked the way the repository row is: a fill *and* a leading bar, so
            // the mark survives greyscale (DEC-035, the same rule the diff marks follow).
            let rowView = self.fileTable.rowView(atRow: self.fileTable.selectedRow, makeIfNecessary: false)
            let drawnBySelectedRowView = rowView is SelectedRowView
            let ok = cleared && agrees && drawnBySelectedRowView
            FileHandle.standardError.write(Data(
                ("SELFTEST file-selected=\(ok ? "OK" : "MISMATCH") shown=\"\(file.path)\" "
                    + "marked=\"\(marked ?? "nothing")\" control-saw-it-cleared=\(cleared) "
                    + "drawn-by-SelectedRowView=\(drawnBySelectedRowView)\n").utf8))
            guard ok else { exit(68) }
            self.focusRingSelftest()
        }
    }

    /// A key equivalent, routed the way macOS routes one. `performKeyEquivalent` returning false
    /// means **nothing is bound** to that keystroke, which is the defect DEC-016 names.
    @discardableResult
    private func press(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
        // **A shifted key equivalent cannot be reached by a hand-made event at all** (M9-J).
        // Measured against a probe menu holding both `⌘1` and `⇧⌘1`: an event built by the system
        // from the virtual key code fires the right one every time, and *no* combination of the two
        // character fields does it by hand — `1`/`!` is refused outright, and `!`/`1` and `1`/`1`
        // both fire **⌘1**, so an arm asking for *Scope: Staged* silently gets *Raw* while
        // `performKeyEquivalent` returns true. So where a key code is known, the event comes from
        // the system: `CGEvent` fills in the characters from this machine's layout.
        // The key codes of the keys this selftest presses, so no arm has to know them. `a` really is
        // 0, so the lookup is what decides whether a code is known — not the parameter's default.
        let virtualKeys: [String: UInt16] = [
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
            "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
            "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
            "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "`": 50, "[": 33, "]": 30, ",": 43,
        ]
        let code = keyCode != 0 ? keyCode : virtualKeys[key.lowercased()]
        if let code, let cg = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState),
                                      virtualKey: code, keyDown: true) {
            cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            if let event = NSEvent(cgEvent: cg) {
                return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
            }
        }
        // **The two character fields of a shifted key equivalent**, measured against the system
        // rather than guessed (M9-J). With Command held, macOS reports the *unshifted* character in
        // `characters` and the *shifted* one in `charactersIgnoringModifiers`: a real ⇧⌘3 is
        // `characters: "3"`, `charactersIgnoringModifiers: "#"`. Both of the obvious guesses are
        // wrong and neither fails loudly — `3`/`3` fires the **⌘3** item (the arm asked for *Scope:
        // Staged* and silently got *Raw*), and `#`/`#` fires nothing while `performKeyEquivalent`
        // returns false. T0's rule in a fourth place: when a measurement disagrees with
        // expectation, suspect the driver first.
        let shifted = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
                       "6": "^", "7": "&", "8": "*", "9": "(", "0": ")"]
        let ignoringModifiers = modifiers.contains(.shift)
            ? (shifted[key] ?? key.uppercased())
            : key
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode
        ) else { return false }
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func sendArrowDown() {
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: down,
            charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125
        ) else { return }
        window.sendEvent(event)
    }

    private func snapshotTerminal(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"] else {
            next(); return
        }
        terminal.webView.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                do {
                    try png.write(to: url)
                    FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
                }
            }
            next()
        }
    }

    /// DEC-038: a block relocated without modification must read as one move, on both sides.
    private func runMoveSelftest() {
        let old = [UInt8]("""
        const formatPrice = (value: number) => value.toFixed(2) + " zl";

        export function Cart({ items }) {
          return <ul>{items.map(i => <li>{formatPrice(i.price)}</li>)}</ul>;
        }

        """.utf8)
        let new = [UInt8]("""
        export function Cart({ items }) {
          return <ul>{items.map(i => <li>{formatPrice(i.price)}</li>)}</ul>;
        }

        const formatPrice = (value: number) => value.toFixed(2) + " zl";

        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinG", pinNew: "pinH",
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(11) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("\"moved\":") && text.contains("pinG:pinH")
            FileHandle.standardError.write(
                Data("SELFTEST moves=\(ok ? "OK" : "MISMATCH") \(outcome.summary)\n".utf8))
            if !ok { exit(12) }
            self.snapshot(named: "moved") { self.runNavigationSelftest() }
        }
    }

    /// DEC-023: the corpus's own case — one side decomposed, both rendering identically. The
    /// interface has to say why the marked region looks the same on both sides.
    private func runDisclosureSelftest() {
        let old = [UInt8]("const shop = \"Z\u{0307}ABKA\";\n".utf8)
        let new = [UInt8]("const shop = \"\u{017B}ABKA\";\n".utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .expanded)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinE", pinNew: "pinF",
                                      mode: "expanded", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(9) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("normalization-form") && text.contains("U+0307")
            FileHandle.standardError.write(
                Data("SELFTEST disclosure=\(ok ? "OK" : "MISMATCH") \(outcome.summary) \(text.suffix(220))\n".utf8))
            if !ok { exit(10) }
            self.snapshot(named: "disclosure") { self.runMoveSelftest() }
        }
    }

    /// The rendered result is otherwise only checkable through the probe, which cannot see
    /// whether a mark is legible. `DIFFSCOPE_SNAPSHOT_DIR` writes what the webview drew.
    /// Photographs the **window**, not the webview.
    ///
    /// Every other snapshot in this selftest shows the document only, which is why M8-D's blank
    /// rows survived: the one surface nothing photographed was the shell. The keyboard walk happens
    /// in the file list, so this is the arm that has to show it.
    ///
    /// The diff pane comes out black here, and that is the method rather than the application:
    /// `cacheDisplay` copies AppKit's own drawing, and a `WKWebView` renders out of process. The
    /// document has its own snapshots — this one is of the lists.
    /// DEC-060, photographed rather than asserted. Both lists collapsed with 63 files in the tree
    /// is the worst case for width, and the question a check cannot answer is whether the rail and
    /// the spine still say anything — three letters and a kind glyph are the smallest claims in
    /// the window.
    /// DEC-070. The walk above has been pressing keys for sixty-three files, so a ring must be lit
    /// on whichever region has focus — that is DEC-016's commitment and it has to survive this
    /// change. Then a click, and it must go out.
    ///
    /// **The click is the control.** A ring that is simply always drawn passes the first half of
    /// this arm perfectly, which is exactly what shipped: the ring was lit whenever a region held
    /// first responder, including for a reader who had touched nothing but the mouse.
    /// DEC-077, and this arm is DEC-070's with its **intent inverted and stated**: the ring is gone,
    /// so what has to be true is that *nothing* draws one — on the keyboard or after a click.
    ///
    /// Kept rather than deleted, because the ring is the kind of thing a later change puts back by
    /// accident: `updateFocusRings` still runs on every selection change, and a single line setting
    /// a border width would restore it silently.
    private func focusRingSelftest() {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeHeights())") { value, _ in
            FileHandle.standardError.write(Data(
                ("SELFTEST page-heights \((value as? String) ?? "nil") "
                    + "against a web view of \(Int(self.webView.frame.height))pt\n").utf8))
        }
        moveFocus(to: fileTable, named: "files")
        func ringWidths() -> [CGFloat] {
            [repoFocusRing, fileFocusRing, diffFocusRing].map { $0?.layer?.borderWidth ?? -1 }
        }
        let onKeyboard = ringWidths()
        navigatingByKeyboard = false
        updateFocusRings()
        let afterClick = ringWidths()
        // Both states dark. The keyboard half is the one that used to be lit, so it is the half that
        // proves the removal rather than merely agreeing with it.
        let ok = onKeyboard.allSatisfy { $0 == 0 } && afterClick.allSatisfy { $0 == 0 }
        FileHandle.standardError.write(Data(
            ("SELFTEST no-focus-ring=\(ok ? "OK" : "MISMATCH") "
                + "on the keyboard=\(onKeyboard.map { String(format: "%.0f", $0) }.joined(separator: "/")) "
                + "after a click=\(afterClick.map { String(format: "%.0f", $0) }.joined(separator: "/"))\n").utf8))
        guard ok else { exit(61) }
        scopeRowSelftest()
    }

    /// DEC-072, in the window. Two things only a laid-out window can answer: the row spans it, and
    /// the row is **above the panes** rather than inside one of them — which is the whole of the
    /// decision, and is a fact about frames rather than about a stack view's membership.
    private func scopeRowSelftest() {
        let content = window.contentView?.bounds ?? .zero
        let row = scopeBar.frame
        let panes = splitView.convert(splitView.bounds, to: nil)
        let rowInWindow = scopeBar.convert(scopeBar.bounds, to: nil)
        let block = baseBlock.convert(baseBlock.bounds, to: nil)
        let pills = scopeControl.convert(scopeControl.bounds, to: nil)

        let spans = abs(row.width - content.width) < 1
        // AppKit's origin is bottom-left, so *above* is a larger minY. Asked of the drawn frames
        // rather than of the constraints: the constraint is what was asked for.
        let abovePanes = rowInWindow.minY >= panes.maxY - 1
        // Both controls inside the row they were put in, and neither of them zero — M8-D's lists
        // were correct, populated and 0 pt wide.
        let inside = rowInWindow.contains(block) && rowInWindow.contains(pills)
            && block.width > 1 && pills.width > 1
        let ok = spans && abovePanes && inside

        FileHandle.standardError.write(Data(
            ("SELFTEST scope-row=\(ok ? "OK" : "MISMATCH") "
                + "row=\(Int(row.width))×\(Int(row.height))@\(Int(rowInWindow.minY)) "
                + "of \(Int(content.width))pt panesTop=\(Int(panes.maxY)) "
                + "pills=[\(Int(pills.minX)),\(Int(pills.minY)) \(Int(pills.width))×\(Int(pills.height))] "
                + "base=[\(Int(block.minX)),\(Int(block.minY)) \(Int(block.width))×\(Int(block.height))] "
                + "\"\(baseBlock.toolTip ?? "")\"\n").utf8))
        guard ok else { exit(65) }
        searchFieldSelftest()
    }

    /// DEC-088 item 1: **the reader's own text does not land on the magnifier.**
    ///
    /// The arm exists in this shape because the defect did. A resting `NSSearchField` has always
    /// drawn its text at x=26 with the glyph at x=2, so every picture of the field and every
    /// reading of `searchTextRect` said it was fine — and it was, until somebody clicked in.
    /// `select`/`edit` hand the field editor the cell's **whole frame** when the field is
    /// unbezeled, so the string was drawn from x=0. What has to be measured is therefore the
    /// **field editor**, with the field focused and holding text; the cell's own rectangles would
    /// have passed before the fix and after it.
    ///
    /// And the glyph is measured where it is *drawn*: `SearchFieldCell` moves the whole interior a
    /// `space3` off the rim, so the un-shifted `searchButtonRect` is not where the reader sees it.
    private func searchFieldSelftest() {
        let bounds = searchField.bounds
        let cell = searchField.cell as? NSSearchFieldCell
        var glyph = cell?.searchButtonRect(forBounds: bounds) ?? .zero
        glyph.origin.x += Theme.space3
        // **The ink, not the button.** `searchButtonRect` is a hit target several points wider than
        // the magnifier drawn inside it, and the stock cell already lets its text rect begin inside
        // that target — so a comparison against the target's trailing edge fails on a field that is
        // perfectly legible. The image is what the reader sees overlap, so the image is what is
        // measured: centred in the target, at its own size.
        let ink = cell?.searchButtonCell?.image?.size.width ?? glyph.width
        let inkTrailing = glyph.midX + ink / 2

        searchField.stringValue = "selftest"
        window.makeFirstResponder(searchField)
        // The **editor's own container**, not the text view's bounds. `select(withFrame:)` positions
        // the clip view AppKit wraps the field editor in; the text view inside it is as tall as its
        // clip and reports the field's whole height whatever the frame it was given.
        var host = window.fieldEditor(false, for: searchField) as NSView?
        while let view = host, view.superview !== searchField, view.superview != nil {
            host = view.superview
        }
        let text = host.map { $0.frame } ?? .zero

        let clear = text.minX >= inkTrailing
        // The other half of the item, and it is a fact about the **rim**, not about the editor: a
        // field 14 pt tall wants all 14 for its line, and the room the owner asked for is around it.
        // Measured as the gap the host holds above and below, which is what a reader sees.
        let padded = searchFieldHost.frame.height - bounds.height >= 2 * Theme.searchTextPadding - 1
        let ok = clear && padded && bounds.width > 1 && text.height > 0

        FileHandle.standardError.write(Data(
            ("SELFTEST search-field=\(ok ? "OK" : "MISMATCH") "
                + "field=\(Int(bounds.width))×\(Int(bounds.height)) "
                + "host=\(Int(searchFieldHost.frame.width))×\(Int(searchFieldHost.frame.height)) "
                + "glyph=[\(Int(glyph.minX))→\(Int(glyph.maxX))] ink→\(Int(inkTrailing)) "
                + "editor=[\(Int(text.minX))→\(Int(text.maxX)) h=\(Int(text.height))] "
                + "clear=\(clear) padded=\(padded)\n").utf8))

        searchField.stringValue = ""
        window.makeFirstResponder(nil)
        guard ok else { exit(70) }
        glassSelftest()
    }

    /// `28-…` item 6: the switches are made of the **system's own material**, not of a drawing that
    /// looks like it.
    ///
    /// **The material cannot be photographed on this machine.** `cacheDisplay` renders an
    /// `NSGlassEffectView` as a flat fill exactly as it renders a `WKWebView` as black, and the
    /// window-server path needs screen-recording permission and an unoccluded window, which a
    /// terminal-launched selftest is not. So this asserts what a picture could not settle anyway:
    /// that the view is **real AppKit** and not something this project drew, that it covers the
    /// chosen segment and *only* it, and that it is absent where a raised pill would be a lie.
    ///
    /// The second of those is not hypothetical. The first version handed the glass straight to
    /// `NSGlassEffectContainerView.contentView`, which fills itself with the view it is given — so
    /// the thumb became the size of the whole control and the picture showed one solid pill across
    /// all four scopes with the labels behind it.
    private func glassSelftest() {
        guard #available(macOS 26, *) else {
            FileHandle.standardError.write(Data(
                "SELFTEST glass=SKIPPED this system has no NSGlassEffectView; the pill is drawn\n".utf8))
            statusBarSelftest()
            return
        }
        let controls: [(String, PillControl)] = [
            ("scope", scopeControl), ("mode", modeControl),
            ("lens", lensControl), ("layout", layoutControl),
        ]
        var failures: [String] = []
        var described: [String] = []
        for (name, control) in controls {
            let report = control.glassReport
            let box = control.bounds
            let fits = report.frame.width > 1 && report.frame.height > 1
                && report.frame.width < box.width - 1
                && box.insetBy(dx: -1, dy: -1).contains(report.frame)
            if !report.present { failures.append("\(name): no glass at all") }
            if report.className != "NSGlassEffectView" {
                failures.append("\(name): \(report.className), not the system's own")
            }
            if report.hidden { failures.append("\(name): glass present and not drawn") }
            if !fits {
                failures.append("\(name): thumb \(Int(report.frame.width))pt of a "
                    + "\(Int(box.width))pt control")
            }
            // The one thing a flat capture cannot rule out: a chosen segment with no title on it.
            // The label is inside the glass, which is where the API puts content and where no
            // picture taken here can show it — so it is asked for by name, by frame and by
            // ancestry rather than looked at.
            let expected = control.segments.indices.contains(control.selectedSegment)
                ? control.segments[control.selectedSegment].title : ""
            if report.label != expected {
                failures.append("\(name): glass says \"\(report.label)\", chosen is \"\(expected)\"")
            }
            if !report.labelInGlass { failures.append("\(name): the title is not inside the glass") }
            if report.labelFrame.width < 1 || report.labelFrame.height < 1 {
                failures.append("\(name): the title is \(Int(report.labelFrame.width))×"
                    + "\(Int(report.labelFrame.height))pt")
            }
            described.append("\(name)=\(Int(report.frame.width))×\(Int(report.frame.height))"
                + "@\(Int(report.frame.minX))\"\(report.label)\"")
        }
        // The control: a selection that cannot be chosen is never raised. Set it, read it, put it
        // back — the dashed outline is what says *unavailable*, and glass under a dashed outline
        // would read as *chosen and unavailable* at once.
        let wasEnabled = scopeControl.glassReport.hidden == false
        scopeControl.setEnabled(false, forSegment: scopeControl.selectedSegment)
        scopeControl.layoutSubtreeIfNeeded()
        let hiddenWhenDisabled = scopeControl.glassReport.hidden
        scopeControl.setEnabled(true, forSegment: scopeControl.selectedSegment)
        scopeControl.layoutSubtreeIfNeeded()

        let ok = failures.isEmpty && wasEnabled && hiddenWhenDisabled
        FileHandle.standardError.write(Data(
            ("SELFTEST glass=\(ok ? "OK" : "MISMATCH") \(described.joined(separator: " ")) "
                + "control: an unavailable choice is not raised=\(hiddenWhenDisabled) "
                + "\(failures.joined(separator: " | "))\n").utf8))
        guard ok else { exit(66) }
        optionsSelftest()
    }

    /// `28-…` item 7: **a switch shows one option, not all of them.**
    ///
    /// Three claims, and the third is the one the plan warns about. The control shows the chosen
    /// option; the popover holds every option with its state; and **the keyboard does not run
    /// through the popover** — every one of these is also a menu item (`12-…` §9), so ⌘1 selects
    /// Structural whether or not this list has ever been opened.
    private func optionsSelftest() {
        let before = scopeControl.selectedSegment
        // A scope that cannot be chosen, with its reason — the state `12-…` §3 is about, and the
        // one a system control renders as grey and silent.
        let unavailable = (0..<ComparisonScope.allCases.count).first { $0 != before } ?? 0
        scopeControl.setEnabled(false, forSegment: unavailable)
        scopeControl.setToolTip("no upstream branch is configured", forSegment: unavailable)

        let closed = scopeControl.optionsReport
        scopeControl.showOptions()
        let open = scopeControl.optionsReport

        let chosenOnly = scopeControl.bounds.width
            < ComparisonScope.allCases.map(\.shortTitle)
                .reduce(0) { $0 + CGFloat($1.count) * 10 }
        let built = open.built
        let listsAll = open.titles == ComparisonScope.allCases.map(\.shortTitle)
        let marksChosen = open.chosen == ComparisonScope.allCases[before].shortTitle
        let saysWhy = open.reasons == ["no upstream branch is configured"]

        // **The keyboard, with the popover open.** ⌘1…⌘3 are menu items and the menu calls
        // `selectMode(_:)` with the mode's tag — so this drives the same selector the key drives,
        // through a real `NSMenuItem`, while the scope list is on screen. If the popover were on
        // the path, this would either do nothing or need the list open on the right control.
        let modeBefore = modeControl.selectedSegment
        let target = PresentationMode.displayOrder.firstIndex(of: .raw) ?? 0
        let item = NSMenuItem()
        item.tag = PresentationMode.allCases.firstIndex(of: .raw) ?? 0
        selectMode(item)
        let keyboardWorked = modeControl.selectedSegment == target && modeBefore != target

        scopeControl.showOptions()   // closes it again
        scopeControl.setEnabled(true, forSegment: unavailable)
        scopeControl.setToolTip(nil, forSegment: unavailable)

        // **The content is gated; the presentation is reported.** `NSPopover.show` refuses on a
        // window that is not visible, which a terminal-launched selftest cannot promise — this arm
        // spent a run reporting an empty list for that reason and nothing else. What the list holds
        // is this project's claim; whether AppKit put it on screen is AppKit's.
        let ok = !closed.built && built && listsAll && marksChosen && saysWhy
            && chosenOnly && keyboardWorked
        FileHandle.standardError.write(Data(
            ("SELFTEST options=\(ok ? "OK" : "MISMATCH") closed-shows-nothing=\(!closed.built) "
                + "open=\(open.titles) chosen=\"\(open.chosen)\" reasons=\(open.reasons) "
                + "why=\"\(open.why)\" presented=\(open.shown) "
                + "control-width=\(Int(scopeControl.bounds.width))pt one-option=\(chosenOnly) "
                + "keyboard-without-the-popover=\(keyboardWorked)\n").utf8))
        guard ok else { exit(67) }
        statusBarSelftest()
    }

    /// DEC-075, in the window. The three fields are laid out against each other rather than in one
    /// stack, so the arm asks what only the window can answer: the modes are **centred on the bar**
    /// and neither neighbour overlaps them, and the watcher's sentence is the one the state produces.
    private func statusBarSelftest() {
        let bar = statusBar.convert(statusBar.bounds, to: nil)
        let modes = modeControl.convert(modeControl.bounds, to: nil)
        let watch = watchLabel.convert(watchLabel.bounds, to: nil)
        let layout = layoutControl.convert(layoutControl.bounds, to: nil)
        let wrap = wrapButton.convert(wrapButton.bounds, to: nil)
        // The legend, drawn in full or not at all: `⌘⏎ open in…` is a keystroke with its purpose cut
        // off, and a truncated promise about a key is worse than no promise. Asked as *what it needs
        // against what it got*, which is the only form a picture cannot disagree with.
        let legendView = (statusBar.subviews.compactMap { $0 as? NSStackView }.last?
            .views.compactMap { $0 as? NSTextField }.last)
        let legendNeeds = legendView?.intrinsicContentSize.width ?? 0
        let legendHas = legendView?.frame.width ?? 0
        let legendWhole = legendHas >= legendNeeds - 1

        // Centred *if the bar has room*, which is the honest form of the assertion: the constraint
        // is a preference precisely so that a narrow window shifts the pills instead of growing.
        let hasRoom = bar.width >= Theme.windowWidth
        let centred = !hasRoom || abs(modes.midX - bar.midX) < 1
        // And the bar must not have made the window wider than it asked to be.
        let didNotGrow = bar.width <= (window.screen?.frame.width ?? bar.width)
        let drawer = terminalButton.convert(terminalButton.bounds, to: nil)
        let drawn = [modes, watch, layout, wrap, drawer].allSatisfy { bar.contains($0) && $0.width > 1 }
        // Nothing overlaps the modes: a message arriving on the left must not push a control the
        // reader is aiming at, and a stack view is exactly what would have.
        let clear = watch.maxX <= modes.minX && layout.minX >= modes.maxX
        // The sentence, against the same function the suite asks — including the age, which is what
        // separates *watching* from *watching, and this is how old it is*.
        //
        // **Against every age the label could honestly be showing**, which is 0 up to the elapsed
        // time. The age is a clock and the label is written *on a tick*: the arm's first version
        // failed on `3s` against `4s` and was widened to a second either side, and that was still a
        // window sized against a guess. It fails again here for the same reason with a bigger gap —
        // the keyboard walk holds the run loop for 63 files, so no tick fires while it runs and the
        // label read straight afterwards is several seconds behind the clock.
        //
        // What this arm is for is that the sentence **comes from `ChromeLabels.watcherStatus`**
        // rather than from a string written by hand in the window (DEC-075). Bounding the set by
        // the elapsed time keeps that whole and stops the check being about the scheduler: a label
        // that has never been written, or one from an older refresh epoch, is still outside it.
        let seconds = lastRefresh.map { Int(Date().timeIntervalSince($0)) }
        let acceptable = (seconds.map { Array(0...max(0, $0 + 1)) } ?? [])
            .map { ChromeLabels.watcherStatus(watchState, refreshedSecondsAgo: $0) }
            + (seconds == nil ? [ChromeLabels.watcherStatus(watchState, refreshedSecondsAgo: nil)] : [])
        let saidIt = acceptable.contains(watchLabel.stringValue)
            && watchLabel.stringValue.hasPrefix("● Watching")
            && watchLabel.stringValue.contains("refreshed")
        let ok = centred && drawn && clear && saidIt && didNotGrow && legendWhole

        FileHandle.standardError.write(Data(
            ("SELFTEST status-bar=\(ok ? "OK" : "MISMATCH") bar=\(Int(bar.width))×\(Int(bar.height)) "
                + "watch=\"\(watchLabel.stringValue)\"@\(Int(watch.maxX)) "
                + "modes=[\(Int(modes.minX)),\(Int(modes.width))] centred=\(centred) "
                + "layout=\(Int(layout.minX)) wrap=\(Int(wrap.minX)) "
                // **Every term of `ok`, not three of six.** This arm printed `drawn` and `clear` and
                // left `saidIt` and `didNotGrow` out, so a failure said `MISMATCH` and nothing about
                // which claim had failed — the M9-C lesson (*if a check ever fails once, keep the
                // whole output*) applied to the arm's own line.
                + "saidIt=\(saidIt) didNotGrow=\(didNotGrow) legendWhole=\(legendWhole) "
                + "expected=\(acceptable) "
                + "legend=\"\(legendView?.stringValue ?? "nil")\" needs \(Int(legendNeeds))pt "
                + "has \(Int(legendHas))pt drawn=\(drawn) clear=\(clear)\n").utf8))
        guard ok else { exit(69) }
        terminalButtonSelftest()
    }

    /// DEC-090: **the drawer can be opened with a pointer**, and the control says which way it will
    /// go.
    ///
    /// The action is compared against the one the *keyboard map* resolves rather than against a
    /// selector written here — that is DEC-071's rule, and a button wired to its own copy of a
    /// command is the drift this project has now paid for three times.
    ///
    /// **The state is exercised without starting a shell.** `toggleTerminal` would spawn the
    /// reader's `$SHELL`, and G3 runs this from `/` on a stranger's machine; what has to be true is
    /// that the button follows the drawer, which `setTerminalVisible` settles on its own.
    private func terminalButtonSelftest() {
        let bar = statusBar.convert(statusBar.bounds, to: nil)
        let button = terminalButton.convert(terminalButton.bounds, to: nil)
        let bound = terminalButton.action == selector(for: "terminal")
        let big = button.width >= Theme.minimumHitTarget && button.height >= Theme.minimumHitTarget

        // **What it draws, not only what it holds.** The state was always right; the picture was
        // not — `keyboard.png` had this button raised with the drawer shut, because the window
        // server had not been given the new frame. So the two states are *rendered* and compared,
        // which is the assertion a stale pixel cannot pass.
        func drawn() -> Data {
            guard let rep = terminalButton.bitmapImageRepForCachingDisplay(in: terminalButton.bounds)
            else { return Data() }
            terminalButton.cacheDisplay(in: terminalButton.bounds, to: rep)
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }

        let wasVisible = terminalVisible
        setTerminalVisible(true, startingShell: false)
        let opened = terminalButton.isOn && (terminalButton.toolTip ?? "").hasPrefix("Hide")
        let raised = drawn()
        setTerminalVisible(false, startingShell: false)
        let closed = !terminalButton.isOn && (terminalButton.toolTip ?? "").hasPrefix("Show")
        let bare = drawn()
        let looksDifferent = !raised.isEmpty && raised != bare
        // The shortcut is in the tooltip, from the map — the one place a keystroke may still be
        // composed for the reader (DEC-077's replacement rule).
        let named = (terminalButton.toolTip ?? "").contains(KeyboardMap.binding(id: "terminal")?.shortcut ?? "∅")
        setTerminalVisible(wasVisible, startingShell: false)

        let ok = bar.contains(button) && button.width > 1 && bound && big && opened && closed
            && named && looksDifferent
        FileHandle.standardError.write(Data(
            ("SELFTEST terminal-button=\(ok ? "OK" : "MISMATCH") "
                + "button=[\(Int(button.minX)),\(Int(button.minY)) "
                + "\(Int(button.width))×\(Int(button.height))] inBar=\(bar.contains(button)) "
                + "bound=\(bound) big=\(big) opened=\(opened) closed=\(closed) named=\(named) "
                + "drawnApart=\(looksDifferent) (\(raised.count) vs \(bare.count) bytes) "
                + "tip=\"\(terminalButton.toolTip ?? "nil")\"\n").utf8))
        guard ok else { exit(73) }
        sourcesButtonSelftest()
    }

    /// DEC-071's rule in the title bar: the button is drawn, and the menu it opens is the map's.
    /// Counted rather than looked at — a pop-up that opened an empty menu would photograph as a
    /// button that does nothing, which is exactly what a picture cannot tell you.
    private func sourcesButtonSelftest() {
        let bar = titleBar.convert(titleBar.bounds, to: nil)
        let button = sourcesButton.convert(sourcesButton.bounds, to: nil)
        let items = sourceMenu(additionsOnly: false).items
        let additions = sourceMenu(additionsOnly: true).items
        let bindings = KeyboardMap.bindings(in: .sources)
        let titles = Set(items.map(\.title))
        let ok = bar.contains(button) && button.width > 1
            && items.count == bindings.count
            && titles == Set(bindings.map(\.title))
            && additions.count == 2
        FileHandle.standardError.write(Data(
            ("SELFTEST sources-button=\(ok ? "OK" : "MISMATCH") "
                + "button=[\(Int(button.minX)),\(Int(button.minY)) "
                + "\(Int(button.width))×\(Int(button.height))] in titleBar=\(Int(bar.width))×\(Int(bar.height)) "
                + "menu=\(items.count) of \(bindings.count) bindings, additions=\(additions.count) "
                + "titles=\(items.map(\.title).joined(separator: " | "))\n").utf8))
        guard ok else { exit(68) }
        pillHintSelftest()
    }

    /// DEC-077, in the window, and it is DEC-073's arm with its **intent restated**: the keys are no
    /// longer printed anywhere, and every one of them still works.
    ///
    /// Both halves matter. Removing a hint is a promise that the keyboard is unchanged, and the only
    /// way to keep that promise honest is to press the four keys the pills used to advertise.
    private func pillHintSelftest() {
        func labels(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels(in:))
        }
        // Every visible string in the two bars the controls live in. A keystroke is a modifier run
        // followed by a character, which is what `KeyboardBinding.shortcut` composes.
        let onScreen = (labels(in: scopeBar) + labels(in: statusBar)).filter { !$0.isEmpty }
        let printed = onScreen.filter { text in
            text.contains(where: { "⌃⌥⇧⌘".contains($0) })
        }
        let silent = printed.isEmpty

        pressEachScopeHint(index: 0, reached: []) { reached in
            let ok = silent && reached == ComparisonScope.allCases
            FileHandle.standardError.write(Data(
                ("SELFTEST no-keys-on-screen=\(ok ? "OK" : "MISMATCH") "
                    + "printed=\(printed.joined(separator: " | ")) "
                    + "reached=\(reached.map(\.shortTitle).joined(separator: ","))\n").utf8))
            guard ok else { exit(66) }
            guard self.press(key: "1", modifiers: [.shift, .command]) else { exit(66) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.paneHeaderSelftest() }
        }
    }

    /// Presses ⇧⌘1 … ⇧⌘4 in turn and reports which scope each one reached. Sequential with a pause,
    /// because each press runs a sweep of the working tree and the answer is read afterwards.
    private func pressEachScopeHint(index: Int, reached: [ComparisonScope],
                                    then finish: @escaping ([ComparisonScope]) -> Void) {
        guard index < ComparisonScope.allCases.count else { finish(reached); return }
        guard press(key: String(index + 1), modifiers: [.shift, .command]) else {
            finish(reached); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.pressEachScopeHint(index: index + 1, reached: reached + [self.state.scope],
                                    then: finish)
        }
    }

    /// DEC-071, expanded. The strings are checked headlessly in `runChromeChecks`; what only the
    /// window can answer is whether the header is **drawn over the pane it belongs to** — M8-D's two
    /// lists were correct, populated and 0 pt wide, and every check passed.
    private func paneHeaderSelftest() {
        let repoPane = repoTable.enclosingScrollView?.superview?.frame ?? .zero
        let filePane = fileTable.enclosingScrollView?.superview?.frame ?? .zero
        let repoBar = repoHeaderBar.frame
        let fileBar = fileHeaderBar.frame
        let files = state.files.count

        // Width against the pane, not against a constant: the constraint says the pane's width and
        // the pane is what the split view did with it, and those disagreed by a factor of two the
        // last time anything in here was measured from the constant.
        let spanned = abs(repoBar.width - repoPane.width) < 1 && abs(fileBar.width - filePane.width) < 1
        let tall = abs(repoBar.height - Theme.paneHeaderHeight) < 1
            && abs(fileBar.height - Theme.paneHeaderHeight) < 1
        // The captions the reader actually has, against the same function the check suite asks.
        let expectedRepo = ChromeLabels.repositoriesHeader(count: state.repositories.count,
                                                          collapsed: false)
        let expectedFiles = ChromeLabels.changedFilesHeader(count: files, collapsed: false)
        let worded = repoHeaderCaption.stringValue == expectedRepo.caption
            && fileHeaderCaption.stringValue == expectedFiles.caption
            && fileHeaderCount.stringValue == expectedFiles.count
        // And the count is the file list's own count, not a number that happens to be there: the
        // tree has 63 changed files under nine group headers, so a header counting *rows* would say
        // 72 here. That is the mistake this line exists to catch.
        let counted = fileHeaderCount.stringValue == "\(files)" && files == state.fileRows.compactMap(\.file).count

        // The open repository has to be the selected row: a sweep replaces the snapshots, and until
        // DEC-077 nothing re-selected, so the list said nothing about which repository was open.
        let repositorySelected = state.repositories.isEmpty || repoTable.selectedRow >= 0

        // DEC-083: **the three panes' contents begin at the same height.** Asked of the drawn
        // frames in window coordinates, because the constraint is what was *asked for* — and the
        // two that agreed did so from one constant while the third was built from three (`space4`,
        // a pill, `space4`) and came out 18 pt lower. The webview is the third surface; its top is
        // where the code's background starts.
        // **The headers' top, not the lists'** (DEC-085 item 3). Last session aligned the three
        // *contents* and the owner asked again: the diff surface should begin level with
        // `CHANGED FILES`, one band higher. The lens has left the diff pane for the scope row, so
        // there is nothing above the webview to push it down.
        let repoTop = repoHeaderBar.convert(repoHeaderBar.bounds, to: nil).maxY
        let fileTop = fileHeaderBar.convert(fileHeaderBar.bounds, to: nil).maxY
        let codeTop = webView.convert(webView.bounds, to: nil).maxY
        // AppKit's origin is bottom-left, so the *top* of a pane is its larger y.
        let aligned = abs(repoTop - fileTop) < 1 && abs(fileTop - codeTop) < 1
        // And the two switches are one row: same centre line, to the pixel.
        let scopeBox = scopeControl.convert(scopeControl.bounds, to: nil)
        let lensBox = lensControl.convert(lensControl.bounds, to: nil)
        let oneRow = abs(scopeBox.midY - lensBox.midY) < 1

        // DEC-083: **the three smallest targets in the window are big enough to hit.** Measured
        // from the drawn frames, because a constraint is what was asked for — and these three had
        // no size of their own at all, so the target was the glyph: 11 pt for a chevron, and in a
        // collapsed 44 pt rail that chevron is the only thing there is to aim at.
        let targets: [(String, NSButton?)] = [
            ("+", addSourceButton), ("repos «", repoCollapseButton), ("files «", fileCollapseButton),
        ]
        var undersized: [String] = []
        var sizes: [String] = []
        for (name, button) in targets {
            let box = button?.frame ?? .zero
            sizes.append("\(name)=\(Int(box.width))×\(Int(box.height))")
            if box.width < Theme.minimumHitTarget || box.height < Theme.minimumHitTarget {
                undersized.append("\(name) \(Int(box.width))×\(Int(box.height))")
            }
        }
        // And they say they can be clicked. There was no `NSCursor` anywhere in the chrome.
        let handed = targets.allSatisfy { $0.1 is HandButton }

        let ok = spanned && tall && worded && counted && repositorySelected && aligned
            && undersized.isEmpty && handed && oneRow
        FileHandle.standardError.write(Data(
            ("SELFTEST pane-headers=\(ok ? "OK" : "MISMATCH") "
                + "tops repos=\(Int(repoTop)) files=\(Int(fileTop)) code=\(Int(codeTop)) "
                + "aligned=\(aligned) one-row=\(oneRow) "
                + "scope-midY=\(Int(scopeBox.midY)) lens-midY=\(Int(lensBox.midY)) "
                + "targets \(sizes.joined(separator: " ")) "
                + "hand=\(handed) undersized=[\(undersized.joined(separator: ", "))] "
                + "repos=\"\(repoHeaderCaption.stringValue)\"@\(Int(repoBar.width))×\(Int(repoBar.height)) "
                + "of pane \(Int(repoPane.width)) "
                + "files=\"\(fileHeaderCaption.stringValue)\" count=\"\(fileHeaderCount.stringValue)\""
                + "@\(Int(fileBar.width))×\(Int(fileBar.height)) of pane \(Int(filePane.width)) "
                + "rows=\(state.fileRows.count) filesInScope=\(files) "
                + "repoSelected=\(repoTable.selectedRow)\n").utf8))
        guard ok else { exit(64) }
        dragSelftest()
    }

    /// `28-…` §6 item 1: **a dragged divider stays where it was dragged.**
    ///
    /// DEC-077 recorded this as fixed and the owner has reported it twice since. It survived because
    /// **nothing in this suite has ever dragged a divider** — every pane assertion is about a state
    /// a *command* produces, ⌃⌘0 and back, and the whole middle ground between the rail and the full
    /// pane was untested. Two of the fourth session's six defects live in that gap.
    ///
    /// A drag is `setPosition` followed by the layout pass that comes after it, so the arm does both
    /// and reads the width *after* the pass. Reading it before is what would have called this fixed:
    /// the split moves the frame immediately and the constraint takes it back on the next pass.
    private func dragSelftest() {
        let wanted: CGFloat = 220
        splitView.setPosition(wanted, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()
        let immediately = splitView.arrangedSubviews[0].frame.width

        // **After a turn of the run loop**, which is when the constraint would win it back — and the
        // status line ticks once a second, so a layout pass is never far away in the real window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.window.contentView?.layoutSubtreeIfNeeded()
            let settled = self.splitView.arrangedSubviews[0].frame.width
            let held = abs(settled - wanted) < 2

            // The second divider, because the two panes hold different priorities and a fix that
            // only reaches the first is a fix for half the window.
            let secondWanted = settled + self.splitView.dividerThickness + 260
            self.splitView.setPosition(secondWanted, ofDividerAt: 1)
            self.window.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.window.contentView?.layoutSubtreeIfNeeded()
                let secondSettled = self.splitView.arrangedSubviews[1].frame.width
                let secondHeld = abs(secondSettled - 260) < 2
                let ok = held && secondHeld
                FileHandle.standardError.write(Data(
                    ("SELFTEST drag=\(ok ? "OK" : "MISMATCH") "
                        + "repo asked=\(Int(wanted)) at-once=\(Int(immediately)) "
                        + "after-a-pass=\(Int(settled)) held=\(held) "
                        + "files asked=260 after-a-pass=\(Int(secondSettled)) held=\(secondHeld)\n").utf8))
                guard ok else { exit(69) }
                self.collapseSelftest()
            }
        }
    }

    private func collapseSelftest() {
        guard press(key: "0", modifiers: [.control, .command]) else { exit(48) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // The **drawn** widths. A constraint's constant is what was asked for: at priority 600
            // the file pane ignored it and stayed at 320 while the rail obeyed, and an assertion on
            // the constants would have called that a pass.
            let railDrawn = self.repoTable.enclosingScrollView?.superview?.frame.width ?? -1
            let spineDrawn = self.fileTable.enclosingScrollView?.frame.width ?? -1
            let ok = self.reposCollapsed && self.filesCollapsed
                && abs(railDrawn - Theme.railWidth) < 1 && abs(spineDrawn - Theme.spineWidth) < 1
            // The **drawn** widths, not the constants. A constraint's constant is what was asked
            // for; the pane is what the window did with it, and the two disagreed by a factor of
            // two until the scroll view stopped setting the floor. Asserting the constant would
            // have been a check that agreed with the wrong number.
            let repoCell = self.repoTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
            let fileCell = self.fileTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView
            // The row has to start where the pane does. `.inset` — the automatic table style —
            // put the cell 16 pt in, and the rail then drew two letters of the three that separate
            // one repository from another. Asserted rather than eyeballed, because the picture is
            // the only other thing that can see it.
            // The rows are columns now and no longer set `cell.textField`, so the arm looks for
            // the first label it can see rather than for the one AppKit used to be handed.
            func firstLabel(_ view: NSView?) -> NSTextField? {
                guard let view else { return nil }
                if let field = view as? NSTextField { return field }
                for child in view.subviews {
                    if let found = firstLabel(child) { return found }
                }
                return nil
            }
            let field = firstLabel(repoCell)
            let fieldInWindow = field.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let paneOrigin = self.repoTable.enclosingScrollView?.convert(NSPoint.zero, to: nil).x ?? 0
            let indent = fieldInWindow.minX - paneOrigin
            let indented = indent >= 0 && indent <= Theme.space4
            // DEC-071, collapsed: the word goes and the count stays. Both halves matter — a header
            // that kept `REPOSITORIES` in a 44 pt rail draws `REPOS` and means nothing, and one
            // that dropped the count leaves a pane with no statement of its size at all.
            let railHeader = ChromeLabels.repositoriesHeader(count: self.state.repositories.count,
                                                            collapsed: true)
            let spineHeader = ChromeLabels.changedFilesHeader(count: self.state.files.count,
                                                              collapsed: true)
            let headersWorded = self.repoHeaderCaption.stringValue == railHeader.caption
                && self.fileHeaderCaption.stringValue == spineHeader.caption
                && self.fileHeaderCount.stringValue == spineHeader.count
            // **Against the label's own drawn width, not the pane's.** The first version of this
            // compared the string against the *pane* — 12 pt of `21` against a 44 pt rail, which
            // passes — while the label itself was laid out beside a 24 pt chevron in a bar with
            // 16 pt of insets and was handed nothing. The reader saw `2`. A count clipped to its
            // first digit is a number that lies about its own magnitude, which is the one thing
            // `compactCount` exists to prevent.
            func fits(_ label: NSTextField) -> Bool {
                label.stringValue.isEmpty || label.intrinsicContentSize.width <= label.frame.width + 0.5
            }
            let headersFit = fits(self.repoHeaderCaption) && fits(self.fileHeaderCount)

            // **The fixture has one repository, and one digit fits anything.** The rail this arm
            // is about is the owner's, where the number is 21 — so the label is stressed with two
            // digits and with the widest form `compactCount` can produce, and the two are held to
            // different promises: two digits must be drawn in full, and anything longer may be
            // shortened *provided the tooltip still states the exact figure*. A count clipped with
            // nothing behind it is the defect this arm exists over.
            let restore = self.repoHeaderCaption.stringValue
            self.repoHeaderCaption.stringValue = "21"
            self.repoHeaderCaption.superview?.layoutSubtreeIfNeeded()
            let twoDigitsFit = fits(self.repoHeaderCaption)
            let twoDigitsDrawn = self.repoHeaderCaption.frame.width
            self.repoHeaderCaption.stringValue = ChromeLabels.compactCount(1000)
            self.repoHeaderCaption.superview?.layoutSubtreeIfNeeded()
            let widestMarked = fits(self.repoHeaderCaption)
                || self.repoHeaderCaption.lineBreakMode == .byTruncatingTail
            let tooltipExact = self.repoHeaderCaption.toolTip
                == ChromeLabels.paneCountTooltip(count: self.state.repositories.count,
                                                 noun: "repository", plural: "repositories")
            self.repoHeaderCaption.stringValue = restore
            self.repoHeaderCaption.superview?.layoutSubtreeIfNeeded()
            let stressed = twoDigitsFit && widestMarked && tooltipExact
            FileHandle.standardError.write(Data(
                ("SELFTEST collapse=\(ok && indented && headersWorded && headersFit && stressed ? "OK" : "MISMATCH") "
                    + "rail=\(railDrawn) "
                    + "spine=\(spineDrawn) indent=\(indent) "
                    + "repoRow=\(field?.stringValue ?? "nil")@\(fieldInWindow.width) "
                    + "fileRow=\(firstLabel(fileCell)?.stringValue ?? "nil") "
                    + "railHeader=\"\(self.repoHeaderCaption.stringValue)\""
                    + "@\(Int(self.repoHeaderCaption.intrinsicContentSize.width))pt"
                    + "/drawn\(Int(self.repoHeaderCaption.frame.width))pt "
                    + "twoDigits=\(twoDigitsFit)@\(Int(twoDigitsDrawn))pt widestMarked=\(widestMarked) "

                    + "tooltip=\"\(self.repoHeaderCaption.toolTip ?? "")\" "
                    + "spineHeader=\"\(self.fileHeaderCaption.stringValue)|\(self.fileHeaderCount.stringValue)\""
                    + "@\(Int(self.fileHeaderCount.intrinsicContentSize.width))pt"
                    + "/drawn\(Int(self.fileHeaderCount.frame.width))pt\n").utf8))
            guard ok, indented, headersWorded, headersFit, stressed else { exit(48) }
            // **And it has to still be collapsed a second later.** A collapse is a set of
            // constraints on panes whose frames `NSSplitView` owns, so any later layout pass can
            // redistribute the width back — and until the status line started ticking once a second
            // (DEC-075), nothing in this window ever laid out again after a collapse, so the
            // question had never been asked. The pane the window grew under, in M9-K, is what asked
            // it: the rail obeyed and the file spine went back to 320.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let railAfter = self.repoTable.enclosingScrollView?.superview?.frame.width ?? -1
                let spineAfter = self.fileTable.enclosingScrollView?.frame.width ?? -1
                let paneAfter = self.fileTable.enclosingScrollView?.superview?.frame.width ?? -1
                let held = abs(railAfter - Theme.railWidth) < 1
                    && abs(spineAfter - Theme.spineWidth) < 1
                    && abs(paneAfter - Theme.spineWidth) < 1
                FileHandle.standardError.write(Data(
                    ("SELFTEST collapse-holds=\(held ? "OK" : "MISMATCH") after a second of ticks: "
                        + "rail=\(railAfter) spine=\(spineAfter) pane=\(paneAfter) "
                        + "window=\(Int(self.window.frame.width))pt\n").utf8))
                guard held else { exit(48) }
                self.windowSnapshot(named: "collapsed") { self.lensSelftest() }
            }
        }
    }

    /// DEC-061, end to end against the fixture tree: a real repository with one commit and 63
    /// modified files, so blame has both committed lines and lines that are not committed yet —
    /// the state the parser's all-zero sha exists for, and the one a repository will not produce
    /// on demand when you want it.
    private func lensSelftest() {
        guard press(key: "b", modifiers: [.control, .command]) else { exit(49) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let probe = ((try? JSONSerialization.jsonObject(
                    with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                let rows = probe["lensRows"] as? Int ?? 0
                let uncommitted = probe["lensUncommitted"] as? Int ?? 0
                let ok = rows > 0 && uncommitted > 0
                FileHandle.standardError.write(Data(
                    ("SELFTEST lens-blame=\(ok ? "OK" : "MISMATCH") rows=\(rows) "
                        + "uncommitted=\(uncommitted)\n").utf8))
                self.snapshot(named: "blame") {
                    guard ok else { exit(49) }
                    guard self.press(key: "h", modifiers: [.control, .command]) else { exit(50) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                            let probe = ((try? JSONSerialization.jsonObject(
                                with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                            let commits = probe["lensRows"] as? Int ?? 0
                            let historyOK = commits > 0
                            FileHandle.standardError.write(Data(
                                ("SELFTEST lens-history=\(historyOK ? "OK" : "MISMATCH") "
                                    + "commits=\(commits)\n").utf8))
                            self.snapshot(named: "history") {
                                guard historyOK else { exit(50) }
                                self.renderedSelftest()
                            }
                        }
                    }
                }
            }
        }
    }

    /// DEC-063, end to end: two PNGs built here that differ in a known number of pixels, so the
    /// count in the sentence can be wrong in a way a picture would never show.
    private func renderedSelftest() {
        func png(dot: Bool) -> [UInt8] {
            let size = 16
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = 40; pixels[index + 1] = 40; pixels[index + 2] = 200
                pixels[index + 3] = 255
            }
            if dot {
                // Four pixels, in a square, so the expected count is a number rather than "some".
                for (x, y) in [(4, 4), (5, 4), (4, 5), (5, 5)] {
                    let index = (y * size + x) * 4
                    pixels[index] = 255; pixels[index + 1] = 255; pixels[index + 2] = 255
                }
            }
            var buffer = pixels
            let data: Data? = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
                                              bitsPerComponent: 8, bytesPerRow: size * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let image = context.makeImage() else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
            return [UInt8](data ?? Data())
        }

        let old = png(dot: false)
        let new = png(dot: true)
        let kind = renderableKind(path: "assets/mark.png", bytes: new)
        guard kind == .raster(format: "PNG") else {
            FileHandle.standardError.write(Data("SELFTEST rendered=MISMATCH not classified as PNG\n".utf8))
            exit(51)
        }
        showRendered(file: ChangedFile(path: "assets/mark.png", originalPath: nil, kind: .modified),
                     oldBytes: old, newBytes: new, kind: kind)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let probe = ((try? JSONSerialization.jsonObject(
                    with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                let modes = probe["renderedModes"] as? Int ?? 0
                let images = probe["renderedImages"] as? Int ?? 0
                let ok = modes == 4 && images == 2
                FileHandle.standardError.write(Data(
                    ("SELFTEST rendered=\(ok ? "OK" : "MISMATCH") modes=\(modes) images=\(images) "
                        + "off=\(probe["renderedModesOff"] as? Int ?? -1)\n").utf8))
                self.snapshot(named: "rendered") {
                    guard ok else { exit(51) }
                    self.renderedFixtureSelftest()
                }
            }
        }
    }

    /// The §4.7a fixtures, through the real path (DEC-063). Two of them make claims a picture
    /// cannot check — *0 pixels differ* and *the boundary held* — and both are the kind of claim
    /// that stays true by accident until it does not.
    private func renderedFixtureSelftest() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures")
        func bytes(_ case_: String, _ file: String) -> [UInt8] {
            [UInt8]((try? Data(contentsOf: root.appendingPathComponent("\(case_)/\(file)"))) ?? Data())
        }
        func differing(_ case_: String, _ ext: String) -> Int? {
            guard let old = ImageComparison.image(from: bytes(case_, "before.\(ext)")),
                  let new = ImageComparison.image(from: bytes(case_, "after.\(ext)")) else { return nil }
            return ImageComparison.compare(old: old, new: new).differing
        }

        // The pair whose bytes moved and whose picture did not. If this is ever non-zero the
        // sentence F18 requires would be replaced by a count, which is the failure in reverse.
        let identical = differing("raster-identical-bytes-differ", "png")
        // The same file with a square moved two units: the pass must find it.
        let moved = differing("raster-resize", "png")

        // The packaged bundle is run from wherever the tester put it, and the corpus is in the
        // checkout — so this arm says SKIPPED **with the reason** rather than failing, the way the
        // keyboard walk does without its tree. `./Scripts/package.sh` runs the selftest as its last
        // gate, and a gate that fails for being packaged is a gate nobody can pass.
        guard identical != nil, moved != nil else {
            FileHandle.standardError.write(Data(
                ("SELFTEST rendered-fixtures=SKIPPED no fixtures/ beside the binary — "
                    + "run the selftest from the checkout and the §4.7a pairs are measured\n").utf8))
            renderedBoundarySelftest()
            return
        }
        let fixturesOK = identical == 0 && (moved ?? 0) > 0
        FileHandle.standardError.write(Data(
            ("SELFTEST rendered-fixtures=\(fixturesOK ? "OK" : "MISMATCH") "
                + "identical-render=\(identical.map(String.init) ?? "undecodable") "
                + "resize=\(moved.map(String.init) ?? "undecodable")\n").utf8))
        guard fixturesOK else { exit(52) }
        renderedBoundarySelftest()
    }

    /// The `<img>` boundary, asked of the real hostile fixture where there is one and of an
    /// equivalent built here where there is not — the control is the point, and it must survive
    /// being packaged.
    private func renderedBoundarySelftest() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures")
        func bytes(_ case_: String, _ file: String) -> [UInt8] {
            [UInt8]((try? Data(contentsOf: root.appendingPathComponent("\(case_)/\(file)"))) ?? Data())
        }

        // The boundary control. The SVG carries a script, an onload handler and two remote
        // references; it is drawn through an `<img>` from a `data:` URL, where none of them can
        // run. A marker the file would set is asked for afterwards.
        let fromCorpus = bytes("svg-hostile", "after.svg")
        // Built here when the corpus is not beside the binary: an SVG carrying a script, an event
        // handler and a remote reference is four lines, and the control is worth more than the
        // convenience of reading it from disk.
        let inline = Array("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" \
            onload="globalThis.__diffscopeHostile = 1">
              <script type="text/javascript">globalThis.__diffscopeHostile = 1;</script>
              <image href="https://example.invalid/pixel.png" x="0" y="0" width="1" height="1"/>
              <rect width="16" height="16" fill="#282860"/>
            </svg>
            """.utf8)
        let hostile = fromCorpus.isEmpty ? inline : fromCorpus
        let before = bytes("svg-hostile", "before.svg")
        showRendered(file: ChangedFile(path: "public/hostile.svg", originalPath: nil, kind: .modified),
                     oldBytes: before.isEmpty ? inline : before, newBytes: hostile,
                     kind: .textThatRenders(format: "SVG"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.webView.evaluateJavaScript("String(globalThis.__diffscopeHostile)") { value, _ in
                let marker = (value as? String) ?? "undefined"
                let images = "document.querySelectorAll(\"#rendered img\").length"
                self.webView.evaluateJavaScript(images) { count, _ in
                    let drawn = (count as? Int) ?? (count as? NSNumber)?.intValue ?? 0
                    // Drawn **and** inert: either half alone would pass while the product failed.
                    let held = marker == "undefined" && drawn == 2
                    FileHandle.standardError.write(Data(
                        ("SELFTEST svg-boundary=\(held ? "OK" : "MISMATCH") marker=\(marker) "
                            + "images=\(drawn)\n").utf8))
                    self.snapshot(named: "rendered-svg") {
                        guard held else { exit(53) }
                        self.scaleSelftest()
                    }
                }
            }
        }
    }

    private struct ScaleCase {
        let name: String
        let old: [UInt8]
        let new: [UInt8]
        /// What the case is for, printed beside its numbers so a fast run cannot be mistaken for a
        /// fast layout — a raw fallback carries one segment, and the loop this measures is over
        /// segments.
        let asks: String
        /// What the composition must produce, **derived from the input rather than recorded from a
        /// run.** One merged block per change, and one extra line per block because the changed line
        /// appears on both sides — so `lines == sourceLines + blocks` is arithmetic, not a number
        /// copied out of last week's output.
        let sourceLines: Int
        let blocks: Int
        let path: String
    }

    /// DEC-059 left one thing unmeasured: unified composes its document **in JavaScript, from both
    /// sides, on every render**, and nobody had run that on a large or a minified file. `16-…` §1.3
    /// carries rendering numbers from a prototype — five thousand lines, side by side, taken before
    /// this layout existed — and §3 has no row for composition at all.
    ///
    /// Each case is measured in **both** layouts on the same model, so the number reported is what
    /// unified costs over the layout that shipped first. An absolute millisecond is a fact about
    /// this machine under this load; the ratio is the claim (M8-N).
    private func scaleSelftest() {
        func ordinary(lines: Int, changeEvery: Int) -> (old: [UInt8], new: [UInt8]) {
            let old = (1...lines).map { "const value\($0) = \($0);\n" }.joined()
            let new = (1...lines).map {
                $0 % changeEvery == 0 ? "const value\($0) = \($0 + 1);\n" : "const value\($0) = \($0);\n"
            }.joined()
            return ([UInt8](old.utf8), [UInt8](new.utf8))
        }

        let big = ordinary(lines: 50_000, changeEvery: 200)
        // Under DEC-050's gates on purpose: this is the only shape that reaches `projectSegments`
        // with a segment count worth the name. Everything larger falls back to raw, where one
        // fallback segment makes the loop free and a check of it vacuous.
        let dense = ordinary(lines: 3_000, changeEvery: 5)
        let minifiedOld = (1...60_000).map { "a\($0)=\($0)" }.joined(separator: ";") + ";\n"
        let minifiedNew = minifiedOld.replacingOccurrences(of: "a30000=30000", with: "a30000=30001")

        let cases = [
            ScaleCase(name: "50k-lines", old: big.old, new: big.new,
                      asks: "many blocks, many runs, a line-meta entry per line",
                      sourceLines: 50_000, blocks: 250, path: "raw"),
            ScaleCase(name: "minified", old: [UInt8](minifiedOld.utf8), new: [UInt8](minifiedNew.utf8),
                      asks: "one enormous line, and the line scans around a stop",
                      sourceLines: 1, blocks: 1, path: "raw"),
            ScaleCase(name: "dense-under-budget", old: dense.old, new: dense.new,
                      asks: "the structural path, with segments the projection has to walk",
                      sourceLines: 3_000, blocks: 600, path: "structural"),
        ]
        measureScale(cases, index: 0)
    }

    /// **The timings are reported and the structure is asserted, and that split is the point.**
    ///
    /// This arm first gated on the ratio between the two layouts' render times, and the packaging
    /// step — the one that runs the selftest from `/` with nothing from the checkout — failed on it
    /// the same day. Measured there three times over: side-by-side takes 239, 250 and 243 ms where
    /// the checkout takes 48, and unified takes ~380 where the checkout takes 28. The run that
    /// failed did so at **7.8×** because its *baseline* came in at 49 ms, not because unified had
    /// regressed. A ratio absorbs environment only when both sides share a bottleneck, and these
    /// two do not: one populates two editors, the other one.
    ///
    /// The composition numbers are no better as a gate. `compose` reads 1.150 ms in the checkout and
    /// **0.000, 0.000, 0.050** in the packaged runs, which is T1-A's hazard in a new place — an
    /// occluded WebKit view is not a reliable clock. An assertion built on those would be a check
    /// that cannot fail exactly where the gate runs.
    ///
    /// So what is asserted is what the composition *produced*, which is arithmetic on the input and
    /// cannot flake: one merged block per change, one extra line per block because the changed line
    /// appears on both sides, three runs per block, and a projection that never returns fewer
    /// segments than it was given. Timing stays in the output as a record, where a human reading two
    /// runs can see what changed.
    private func measureScale(_ cases: [ScaleCase], index: Int) {
        guard index < cases.count else { stagingSelftest(); return }
        let subject = cases[index]
        let outcome = buildModel(path: "scale.ts", old: subject.old, new: subject.new,
                                 mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "scaleA\(index)",
                                      pinNew: "scaleB\(index)", mode: "structural",
                                      pathTaken: outcome.pathTaken, parser: outcome.parser,
                                      validation: outcome.validation, notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(57) }
        push(json)
        webView.evaluateJavaScript("window.diffscopeSetLayout(\"split\")") { _, _ in
            self.readTimings { split in
                self.webView.evaluateJavaScript("window.diffscopeSetLayout(\"unified\")") { _, _ in
                    self.readTimings { unified in
                        // Twenty compositions, because a single one reads as `0` or `2` under this
                        // webview's millisecond clamp and neither number describes how it grows.
                        self.webView.evaluateJavaScript(
                            "JSON.stringify(window.diffscopeMeasureCompose(20))"
                        ) { value, _ in
                            let repeated = ((try? JSONSerialization.jsonObject(
                                with: Data(((value as? String) ?? "null").utf8)
                            )) as? [String: Any]) ?? [:]
                            func ms(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? -1 }
                            func count(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }
                            let splitTotal = ms(split["total"])
                            let unifiedTotal = ms(unified["total"])
                            let ratio = splitTotal > 0 ? unifiedTotal / splitTotal : -1
                            let lines = count(unified["lines"])
                            let runs = count(unified["runs"])
                            let blocks = count(unified["blocks"])
                            let segIn = count(unified["segmentsIn"])
                            let segOut = count(unified["segmentsOut"])
                            // **This arm reports and does not gate, and the reason is that its own
                            // probe has not earned the right to fail a build.**
                            //
                            // It gated on a time ratio first, and the packaging step refused a build
                            // at 7.82× because the *baseline* varied fivefold (M9-G). The gate was
                            // then moved onto quantities that are arithmetic on the input and cannot
                            // flake — blocks, lines, runs, segments — and **those disagreed with
                            // themselves across two runs of the same binary on the same input**:
                            // the minified case read `lines=2 segIn=2` in the morning and
                            // `lines=10 segIn=77` in the afternoon. Deterministic quantities do not
                            // do that; a probe reading them does.
                            //
                            // So the numbers are printed, where two runs side by side show a human
                            // what moved, and nothing here decides whether a build ships. Restoring
                            // the assertion means first explaining that disagreement — the open
                            // question is in `22-experiment-log.md` → M9-G.

                            FileHandle.standardError.write(Data((
                                "SELFTEST scale-\(subject.name)=REPORT "
                                    + "path=\(outcome.pathTaken) "
                                    + String(format: "split=%.0fms unified=%.0fms ratio=%.2fx ",
                                             splitTotal, unifiedTotal, ratio)
                                    + String(format: "compose=%.3fms project=%.3fms dispatch=%.0fms ",
                                             ms(repeated["composeMs"]), ms(repeated["projectMs"]),
                                             ms(unified["dispatch"]))
                                    + "lines=\(lines)/\(subject.sourceLines + subject.blocks) "
                                    + "runs=\(runs) blocks=\(blocks)/\(subject.blocks) "
                                    + "segIn=\(segIn) segOut=\(segOut) "
                                    + "— \(subject.asks)\n").utf8))
                            self.measureScale(cases, index: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func readTimings(_ then: @escaping ([String: Any]) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeTimings())") { value, _ in
            let text = (value as? String) ?? "null"
            then((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:])
        }
    }

    /// Version two's arm (DEC-092): **the window stages a file and commits it, through the controls
    /// a reader would use.**
    ///
    /// Not a check on `WriteActions` — `WriteChecks` owns that, and INV-6 is proven there. What
    /// this asserts is the half a headless check cannot reach: that the box is drawn beside every
    /// path, that clicking it moves the index, that the box then draws the *other* state, and that
    /// the button under the list makes a commit out of what the box staged. Every one of those was
    /// a place the window could agree with itself and disagree with git.
    private func stagingSelftest() {
        let repository = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-staging-\(UUID().uuidString)")
        func git(_ arguments: [String]) { fixtureGit(arguments, in: repository) }
        try? FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try? "one\ntwo\nthree\n".write(to: repository.appendingPathComponent("a.txt"),
                                       atomically: true, encoding: .utf8)
        git(["init", "-q", "-b", "main", "."])
        git(["config", "user.email", "fixture@diffscope.local"])
        git(["config", "user.name", "DiffScope Fixture"])
        git(["config", "commit.gpgsign", "false"])
        git(["add", "."]); git(["commit", "-q", "-m", "first"])
        try? "one\nTWO\nthree\n".write(to: repository.appendingPathComponent("a.txt"),
                                       atomically: true, encoding: .utf8)

        state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository,
                                                                       path: repository.path)])
        state.selectedRepository = nil
        scan(sources: state.configuration.sources)

        func boxes() -> [CheckButton] {
            func find(_ view: NSView) -> [CheckButton] {
                if let box = view as? CheckButton { return [box] }
                return view.subviews.flatMap(find)
            }
            return (0..<fileTable.numberOfRows).compactMap {
                fileTable.view(atColumn: 0, row: $0, makeIfNecessary: true)
            }.flatMap(find)
        }

        // The collapse arm runs before this one and leaves the file pane folded; a folded pane
        // draws the spine (DEC-060), which has room for a kind glyph and nothing else. The arm
        // that needs the boxes has to put the pane back rather than photograph the absence.
        let folded = (repositories: reposCollapsed, files: filesCollapsed)
        if folded.files { toggleFilesPane() }
        if folded.repositories { toggleRepositoriesPane() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let before = boxes()
            let drawnEmpty = before.count == 1 && before[0].inclusion == .none
                && before[0].frame.width > 1 && before[0].frame.height > 1
            // The click a reader makes, through the action the control is wired to.
            if let box = before.first { self.toggleInclusion(box) }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let staged = self.state.staging["a.txt"] == .all
                let redrawn = boxes().first?.inclusion == .all
                let branchNamed = self.commitBox.branchName == "main"
                let counted = self.commitBox.status.stringValue.contains("1 staged")

                self.commitBox.summary.stringValue = "Staged from the window"
                self.commitStaged()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let runner = GitRunner()
                    let count = (try? runner.run(.revListCount("HEAD"), in: repository))?
                        .trimmedOutput ?? "0"
                    let message = self.gitState.commitMessage(of: "HEAD", in: repository)
                    let recorded = GitWriter.commandRecord.contains { $0.arguments.first == "commit" }
                    let cleared = self.commitBox.summaryText.isEmpty
                    let ok = drawnEmpty && staged && redrawn && branchNamed && counted
                        && count == "2" && message.contains("Staged from the window")
                        && recorded && cleared
                    FileHandle.standardError.write(Data(
                        ("SELFTEST staging=\(ok ? "OK" : "MISMATCH") box-drawn=\(drawnEmpty) "
                            + "staged=\(staged) box-redrawn=\(redrawn) branch=\(branchNamed) "
                            + "counted=\(counted) commits=\(count) recorded=\(recorded) "
                            + "cleared=\(cleared) boxes=\(before.count) rows=\(self.state.fileRows.count) "
                            + "files=\(self.state.files.count) collapsed=\(self.filesCollapsed) "
                            + "scope=\(self.state.scope.rawValue) repo="
                            + "\(self.state.selectedRepository?.url.lastPathComponent ?? "none")\n").utf8))
                    try? FileManager.default.removeItem(at: repository)
                    guard ok else { exit(71) }
                    self.emptyScopeSelftest()
                }
            }
        }
    }

    /// The first screen a stranger meets (DEC-036, G3), and the only one where a control is the
    /// subject rather than a tool. Photographed because that is the only way to see whether the
    /// rim reads at all — and because an empty state is reached by having *nothing*, which is a
    /// configuration the selftest has to construct rather than wait for.
    /// DEC-073's second half, in the window. No scope of the 63-file fixture tree is empty — it has
    /// 63 local changes, 56 unstaged and 4 staged — so the state is reached the only honest way: a
    /// repository with a commit in it and nothing changed since.
    /// **The one place this application spawns git for itself**, and the exemption R-8's static
    /// half names (DEC-088 item 2). Two selftest arms need a repository with a history in it —
    /// the empty-scope state and DEC-092's staging arm — and neither can be reached any other
    /// honest way.
    ///
    /// The guard is the point: it refuses any directory that is not under `NSTemporaryDirectory()`,
    /// so the exemption cannot grow into a path that touches a repository the reader chose. It was
    /// a comment in a check before, and a comment is not a refusal.
    private func fixtureGit(_ arguments: [String], in directory: URL) {
        guard directory.path.hasPrefix(NSTemporaryDirectory()) else {
            FileHandle.standardError.write(Data(
                "SELFTEST fixture-git=REFUSED \(directory.path) is not under NSTemporaryDirectory()\n".utf8))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "DiffScope Fixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@diffscope.local"
        environment["GIT_COMMITTER_NAME"] = "DiffScope Fixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@diffscope.local"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func emptyScopeSelftest() {
        let clean = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-clean-\(getpid())")
        func git(_ arguments: [String]) { fixtureGit(arguments, in: clean) }
        try? FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        try? "committed\n".write(to: clean.appendingPathComponent("file.txt"),
                                 atomically: true, encoding: .utf8)
        git(["init", "-q", "."])
        git(["config", "user.email", "fixture@diffscope.local"])
        git(["config", "user.name", "DiffScope Fixture"])
        git(["config", "commit.gpgsign", "false"])
        git(["add", "."])
        git(["commit", "-q", "-m", "one commit, nothing since"])

        state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository,
                                                                       path: clean.path)])
        state.selectedRepository = nil
        scan(sources: state.configuration.sources)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let said = self.comparisonLabel.stringValue
            let wanted = ChromeLabels.scopeState(
                shortTitle: ComparisonScope.allLocalVsHead.shortTitle,
                emptyDescription: ComparisonScope.allLocalVsHead.emptyDescription)
            // The header's count and the row's sentence have to agree: `0` above a list and a
            // sentence saying why are the two halves of the same statement.
            let counted = self.fileHeaderCount.stringValue == "0"
            let ok = self.state.files.isEmpty && said == wanted && counted
            FileHandle.standardError.write(Data(
                ("SELFTEST empty-scope=\(ok ? "OK" : "MISMATCH") files=\(self.state.files.count) "
                    + "said=\"\(said)\" header=\"\(self.fileHeaderCount.stringValue)\" "
                    + "repos=\(self.state.repositories.count)\n").utf8))
            try? FileManager.default.removeItem(at: clean)
            guard ok else { exit(67) }
            self.emptyStateSelftest()
        }
    }

    private func emptyStateSelftest() {
        state.repositories = []
        repoTable.reloadData()
        updatePaneHeaders()
        showEmptyState(problems: [])
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let shown = !self.emptyState.isHidden
            func buttons(in view: NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }
                return view.subviews.flatMap(buttons(in:))
            }
            let found = buttons(in: self.emptyState)
            let content = self.window.contentView?.bounds ?? .zero
            // `emptyState.isHidden == false` was the whole of this arm, and it passed while the
            // photograph came out **2800×138** — a strip holding the caption and neither button.
            // The rim is a **1 px border**: it cannot be checked by any means except looking, so
            // the arm now asserts the buttons are drawn, non-empty, and inside the picture that is
            // about to be taken. Not hidden is not the same as on screen.
            let drawn = found.filter { $0.frame.width > 1 && $0.frame.height > 1 }
            let placed = drawn.map { $0.convert($0.bounds, to: nil) }
            let inside = !placed.isEmpty && placed.allSatisfy { content.contains($0) }
            let ok = shown && drawn.count == 2 && inside
            FileHandle.standardError.write(Data(
                ("SELFTEST empty-state=\(ok ? "OK" : "MISMATCH") "
                    + "content=\(Int(content.width))×\(Int(content.height))pt "
                    + "buttons=\(drawn.count) "
                    + placed.map { "[\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))]" }
                        .joined(separator: " ")
                    + " inside=\(inside)\n").utf8))
            self.windowSnapshot(named: "empty") { exit(ok ? 0 : 56) }
        }
    }

    /// A pixel grid coarse enough to be cheap and fine enough to catch a picture that is one
    /// colour. Used to tell a real capture from the blank one a denied screen-recording permission
    /// hands back without saying so.
    private func looksBlank(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        // 64 rather than 16 across. A sixteenth of 2800 px is a 175 px stride, which on the empty
        // state — a large flat surface with three lines of text in the middle — walks straight past
        // the only pixels that are not the background, and the real capture was thrown away as
        // blank. The grid has to be finer than the smallest thing that proves the picture is real.
        let stepX = max(1, rep.pixelsWide / 64)
        let stepY = max(1, rep.pixelsHigh / 64)
        var seen = Set<Int>()
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let key = Int(colour.redComponent * 255) << 16
                    | Int(colour.greenComponent * 255) << 8
                    | Int(colour.blueComponent * 255)
                seen.insert(key)
                // **One** colour, not three. The first version called anything with three or fewer
                // distinct samples blank, and rejected the real capture of the empty state — a
                // large flat surface with a little text on it is legitimately almost one colour.
                // What a denied permission hands back is *exactly* one.
                if seen.count > 1 { return false }
            }
        }
        return true
    }

    /// **The window, as the window server composites it** — which is the only way to get the diff
    /// and the chrome into one picture.
    ///
    /// `cacheDisplay` cannot capture a `WKWebView`. Every full-window photograph this project has
    /// ever taken therefore has a black rectangle where the diff is, and the interface the design
    /// is mostly about has never appeared in a picture of the window at all. Six rounds once went
    /// into "why do the panes stop two thirds down" before anyone printed a frame; this is the same
    /// blind spot from the other side.
    ///
    /// The window server needs screen-recording permission and says so by handing back nothing, or
    /// something blank, rather than by failing — so both are checked, the method used is printed,
    /// and the `cacheDisplay` picture remains the fallback **with its limitation stated in the log
    /// line**. A snapshot that quietly changed meaning between runs would be worse than none.
    private func windowSnapshot(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"],
              let view = window.contentView else { next(); return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        let expected = view.bounds.size
        // Printed on every snapshot: `empty.png` came out 2800×138 and nobody could see that from
        // the file name. A picture that says how big it is cannot silently become a strip.
        //
        // The panes go with it. `setTerminalVisible(false, …)` carries a comment about the three
        // panes stopping two thirds down the window with the rest left blank — it happened once,
        // was fixed, and a picture cannot say whether it has come back unless it prints where the
        // panes actually were.
        func box(_ rect: NSRect) -> String {
            "\(Int(rect.width))×\(Int(rect.height))@\(Int(rect.minY))"
        }
        let size = "\(Int(expected.width))×\(Int(expected.height))pt"
            + " drawer=\(box(terminalSplit?.frame ?? .zero))"
            + " panes=\(box(splitView?.frame ?? .zero))"
            // The **host**, not the web view inside it. Logging the web view said `1400×0` and
            // looked like proof the drawer was closed, while the pane holding it kept its share of
            // the split — which is exactly the difference between a pane that is gone and one that
            // is merely empty.
            + " drawerPanes=\((terminalSplit?.arrangedSubviews ?? []).map { box($0.frame) }.joined(separator: ","))"
            + " terminalWeb=\(box(terminal.webView.frame))"
            + " diffPane=\(box(webView.superview?.frame ?? .zero))"
            + " diffWeb=\(box(webView.frame))"

        // **Draw, then commit, then photograph** (DEC-090). `CGWindowListCreateImage` asks the
        // *window server* what it has, and what it has is whatever was last committed to it — so a
        // control that changed state in this turn is still wearing its old picture. The drawer's
        // button was raised in `keyboard.png` with the drawer shut: the state was right, the arm
        // that asked was right, and the pixel was several turns old. Found by sampling the pixel;
        // it is invisible to every assertion this project makes about state.
        //
        // The AppKit twin of `window.diffscopeSettle()`, and for the same reason — a picture of a
        // pass that has not run is a picture of something that was never on screen.
        view.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()

        if let composited = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), !looksBlank(composited) {
            let rep = NSBitmapImageRep(cgImage: composited)
            if let png = rep.representation(using: .png, properties: [:]),
               (try? png.write(to: url)) != nil {
                FileHandle.standardError.write(Data(
                    ("SELFTEST snapshot=\(url.path) via=window-server "
                        + "\(rep.pixelsWide)×\(rep.pixelsHigh)px of \(size) — the web views are in it\n").utf8))
                next(); return
            }
        }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { next(); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            FileHandle.standardError.write(Data(
                ("SELFTEST snapshot=\(url.path) via=cacheDisplay "
                    + "\(rep.pixelsWide)×\(rep.pixelsHigh)px of \(size) — "
                    + "the diff and terminal panes are black; grant screen recording for a real one\n").utf8))
        } catch {
            FileHandle.standardError.write(
                Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
        }
        next()
    }

    private func snapshot(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"] else {
            next(); return
        }
        // **Settled before it is photographed.** CodeMirror re-measures inside an animation frame
        // and the frame never comes while the window is occluded, which this one always is — so
        // every picture taken before this line shows the gutter rows the editor was *constructed*
        // with (16.87 px) beside lines the stylesheet lays out at 15, and a number column that has
        // drifted a whole line by the sixth row. The reader never sees that; the pictures did.
        webView.evaluateJavaScript("window.diffscopeSettle()") { settled, _ in
            if let text = settled as? String, !text.isEmpty {
                FileHandle.standardError.write(Data(
                    ("SELFTEST settle \(name) line-height \(text)\n").utf8))
            }
            self.captureSnapshot(named: name, into: dir, then: next)
        }
    }

    private func captureSnapshot(named name: String, into dir: String,
                                 then next: @escaping () -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                // Reported rather than swallowed: this line claimed to have written a snapshot
                // whether or not the directory existed, so a run with a mistyped path looked
                // identical to a successful one.
                do {
                    try png.write(to: url)
                    FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
                }
            }
            next()
        }
    }

    /// INV-5: Structural and Expanded must produce identical segment sets. They are flags over
    /// one model, so agreement is structural — this proves it survives the crossing anyway.
    private func runModeAgreementSelftest(model: DiffModel, validation: ValidationResult,
                                          structuralProbe: String) {
        let render = buildRenderModel(model: model, pinOld: "pinC", pinNew: "pinD",
                                      mode: "expanded", validation: validation)
        guard let json = try? encodeRenderModel(render) else { exit(7) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            func field(_ probe: String, _ key: String) -> String? {
                guard let range = probe.range(of: "\"\(key)\":") else { return nil }
                return String(probe[range.upperBound...].prefix(while: { $0.isNumber }))
            }
            let sameSegments = field(text, "oldSegments") == field(structuralProbe, "oldSegments")
                && field(text, "newSegments") == field(structuralProbe, "newSegments")
            let quietened = field(text, "formattingMarks") == "0"
            let ok = sameSegments && quietened && text.contains("\"mode\":\"expanded\"")
            FileHandle.standardError.write(
                Data("SELFTEST modes=\(ok ? "OK" : "MISMATCH") segments agree=\(sameSegments) expanded marks=\(field(text, "formattingMarks") ?? "?")\n".utf8))
            if !ok { exit(8) }
            self.snapshot(named: "expanded") { self.runDisclosureSelftest() }
        }
    }

    /// DEC-036: one screen serves both first run and a root that has been moved, so there is no
    /// state in which the window is empty with nothing to act on. No suggested path appears here —
    /// the amendment rejected both that and auto-detection, in favour of predictability.
    /// The window's own title bar (the adopted design). The system keeps the traffic lights; this
    /// carries the name of the application, the repository open in it and that repository's path —
    /// the fact that tells two repositories of the same name apart (DEC-037), which until now lived
    /// only in a list row.
    private func buildTitleBar() -> NSView {
        let name = NSTextField(labelWithString: "DiffScope")
        name.font = Theme.prose(Theme.textSize, weight: .semibold)
        name.textColor = Theme.ink

        titleRepositoryLabel = NSTextField(labelWithString: "")
        titleRepositoryLabel.font = Theme.prose(Theme.textSize)
        titleRepositoryLabel.textColor = Theme.inkQuiet

        titlePathLabel = NSTextField(labelWithString: "")
        titlePathLabel.font = Theme.font(Theme.textSizeSmall)
        titlePathLabel.textColor = Theme.inkFaint
        titlePathLabel.lineBreakMode = .byTruncatingMiddle

        // DEC-083 draws the line at **borderless**: a control AppKit gives no affordance to gets the
        // hand, and a standard bordered button keeps the arrow the platform gives it. The empty
        // state's two buttons and Settings' are already unmistakably buttons — the complaint was
        // about the ones that are not, and a push button with a pointing hand looks like the web.
        // DEC-085 item 6: the same chevron the switches draw, rather than a character in the
        // title. The button keeps its menu — `Sources` opens the four things a reader does to
        // *which repositories exist* (DEC-071), which is a different question from the switches'
        // *what am I looking at*, so it keeps a menu rather than gaining a popover of options.
        sourcesButton = ChevronButton(title: "Sources", target: self,
                                      action: #selector(showSourcesMenu(_:)))
        sourcesButton.isBordered = false
        sourcesButton.font = Theme.prose(Theme.textSizeSmall)
        sourcesButton.contentTintColor = Theme.inkQuiet
        sourcesButton.setButtonType(.momentaryChange)
        sourcesButton.translatesAutoresizingMaskIntoConstraints = false
        // Every item it opens, and its key, in the one place a pointer user can see them without
        // opening the menu bar.
        sourcesButton.toolTip = KeyboardMap.bindings(in: .sources)
            .map { $0.key.isEmpty ? $0.title : "\($0.title)  \($0.shortcut)" }
            .joined(separator: "\n")

        let stack = NSStackView(views: [name, titleRepositoryLabel, titlePathLabel,
                                        spacerView(), sourcesButton, searchFieldHost])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.space3
        // The traffic lights live at the left of this bar and the system draws them there, so the
        // content starts clear of them rather than under them.
        //
        // **Horizontally that was already right; vertically it was not** (DEC-086). The lights are
        // centred in the *titlebar* the system owns, and this stack is centred in a 44 pt bar of
        // ours — two different centre lines, which is what the owner saw. `titleRowCentring` is
        // applied once the window exists, because only then is there a button to measure.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.trafficLightInset,
                                        bottom: 0, right: Theme.space6)
        titleRowStack = stack

        // DEC-086: **the desktop shows through this band.** `NSVisualEffectView` with the system's
        // `.headerView` material and `.behindWindow` blending — the platform's API for a window
        // band, in use long before glass existed.
        //
        // DEC-083 banned this class from the chrome under *nothing imitates the material where the
        // system has none*. That rule was right where it was aimed — vibrancy standing in for
        // `NSGlassEffectView` **on a control**, on a system that does not have it — and too wide as
        // worded: a window band is not a control, and the system's blur is not an imitation of the
        // system's blur. The check names the surface now rather than the class.
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .headerView
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        vibrancy.translatesAutoresizingMaskIntoConstraints = false
        titleVibrancy = vibrancy

        let bar = ChromeBar(surface: nil, edge: .bottom)
        bar.addSubview(vibrancy)
        NSLayoutConstraint.activate([
            vibrancy.topAnchor.constraint(equalTo: bar.topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            vibrancy.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        bar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: Theme.titleBarHeight),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    /// The scope row (DEC-072): what the window is comparing, across the window.
    ///
    /// Above the three panes rather than inside the diff pane, because **changing the scope changes
    /// the file list** — the middle pane — and only then what the diff pane draws. A control inside
    /// the diff pane says it belongs to the diff pane.
    private func buildScopeRow() -> NSView {
        let caption = NSTextField(labelWithString: ChromeLabels.scopeCaption)
        caption.font = Theme.font(Theme.textSizeTiny, weight: .semibold)
        caption.textColor = Theme.inkFaint
        caption.translatesAutoresizingMaskIntoConstraints = false

        baseBlock = FactBlock()
        baseBlock.target = self
        baseBlock.action = #selector(setBaseBranch)
        updateBaseBlock(for: nil)

        // DEC-085: **the lens sits at the scope switch's height.** DEC-072 put the scope row above
        // the panes and left the lens in a band of its own inside the diff pane, so the window had
        // two rows of switches at two heights. A reader reads them as one row — the scope changes
        // what the file list holds and the lens changes what the diff pane answers, but both are
        // *what am I looking at* — so they are one row.
        let stack = NSStackView(views: [caption, scopeControl, comparisonLabel,
                                        spacerView(), lensControl, baseBlock])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.space4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.space6, bottom: 0, right: Theme.space6)
        // The comparison text yields before the two controls do: it is a sentence with a shorter
        // form (`HEAD ↔ working tree`) and the pills and the base cannot be shortened at all.
        comparisonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = ChromeBar(surface: Theme.chrome, edge: .bottom)
        bar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: Theme.scopeBarHeight),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    /// The base block's three parts, from one composition in the Git layer (DEC-072). `nil` is the
    /// state before a repository is selected, and it says *not determined* rather than nothing —
    /// an empty block would look like a base that has no name.
    private func updateBaseBlock(for repository: RepositorySnapshot?) {
        let detail = baseDetail(
            ref: repository?.baseRefUsed,
            chosenByUser: repository.map {
                state.configuration.baseOverrides[$0.url.standardizedFileURL.path] != nil
            } ?? false,
            committerDate: repository?.baseRefCommitterDate)
        // A History selection names its own two sides, so the base is not what is being compared
        // then either — the dashed rim is about what is on screen, not about which scope is armed.
        baseBlock.show(ChromeLabels.baseBlock(
            detail: detail,
            comparingAgainstBase: repository != nil && state.scope == .branchVsMergeBase
                && state.historyPair == nil))
    }

    /// One label of a column header (DEC-071). Small, quiet and upper-cased by the string it is
    /// given: the caption is a label for a pane, not a sentence, so it takes the faintest of the
    /// three inks and the smallest of the three sizes.
    private func paneHeaderLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = Theme.font(Theme.textSizeTiny, weight: .semibold)
        field.textColor = Theme.inkFaint
        // Truncation rather than clipping (DEC-098): a count cut off mid-number reads as a
        // different number, and an ellipsis is the only form that says *there is more of this*.
        //
        // **Resistance stays at the default.** Making the label refuse to shrink widened the file
        // spine from 42 pt to 46.5 — a header that cannot be squeezed becomes a floor under the
        // pane, which is the same defect the commit box's button title had. The room comes from
        // the insets instead, which belong to the header rather than to the pane.
        field.lineBreakMode = .byTruncatingTail
        field.cell?.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A column header for one of the two lists: what the pane is at one edge, and either what is in
    /// it or the one action that adds to it at the other.
    ///
    /// The same `ChromeBar` the title bar and the status line are, on **the pane's own surface** — a
    /// header drawn on the window's surface would read as belonging to the window rather than to the
    /// list under it, which is the seam DEC-066's two panel tokens exist to draw.
    private func buildPaneHeader(caption: NSTextField, trailing: NSView,
                                 surface: NSColor, stack stackOut: inout NSStackView?) -> NSView {
        let stack = NSStackView(views: [caption, spacerView(), trailing])
        stackOut = stack
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.space2
        // The caption starts where the rows start: the pane's inset plus the cell's own, so the
        // header's first letter and the first letter of every row below it share a left edge.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.space3 + Theme.space2, bottom: 0,
                                        right: Theme.space3)

        let bar = ChromeBar(surface: surface, edge: .bottom)
        bar.addSubview(stack)
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: Theme.paneHeaderHeight),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    /// The `+` on the repositories header (DEC-071): a pointer route to the two Sources bindings,
    /// and **nothing else**. The menu is composed from `KeyboardMap.bindings(in: .sources)`, so the
    /// titles and the key equivalents are the menu bar's own — a button that named them itself would
    /// be the third hand-written copy of the keyboard map, which is exactly the drift M8-P found in
    /// the tester packet.
    private func buildAddSourceButton() -> NSButton {
        // DEC-084: the design draws this as a rimmed disc rather than as a character.
        let button = RimButton(title: "+", target: self, action: #selector(showAddSourceMenu(_:)))
        button.isBordered = false
        // DEC-091: two strokes, not a character. The title stays — it is what VoiceOver reads and
        // what the arms name this control by — and it stops being the picture.
        button.mark = { Theme.drawPlus(in: $0) }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryChange)
        button.toolTip = KeyboardMap.bindings(in: .sources)
            .filter { $0.id.hasPrefix("sources.add") }
            .map { "\($0.title)  \($0.shortcut)" }
            .joined(separator: "\n")
        // DEC-083: the glyph was the target. A `+` at 12 pt in a header a reader is aiming at with
        // a pointer is a control that gets missed, and missing it opens nothing.
        button.enforceMinimumTarget()
        return button
    }

    /// The Sources menu, or the half of it that adds (DEC-071). One builder, because the `+` on the
    /// repositories header and the `Sources ⌄` button in the title bar are the same promise: a
    /// pointer route to bindings that already exist.
    private func sourceMenu(additionsOnly: Bool) -> NSMenu {
        let menu = NSMenu()
        for binding in KeyboardMap.bindings(in: .sources)
        where !additionsOnly || binding.id.hasPrefix("sources.add") {
            guard let action = selector(for: binding.id) else { continue }
            let item = NSMenuItem(title: binding.title, action: action,
                                  keyEquivalent: keyEquivalent(binding.key))
            item.keyEquivalentModifierMask = modifierFlags(binding.modifiers)
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// The chevron that folds a pane. The glyph is the direction the pane will move, so the control
    /// says what it will do rather than what state it is in — which is the one thing a reader cannot
    /// work out from a collapsed rail.
    private func buildCollapseButton(action: Selector, collapsed: Bool) -> NSButton {
        // DEC-091: it was `«` and `»` — *guillemets*, which are quotation marks being used as
        // arrows. Set in the text font at the text weight with a quotation mark's spacing, they
        // never matched the chevron on the switches beside them. Two drawn chevrons now, from the
        // one construction every chevron in the chrome comes out of.
        let button = MarkButton(title: collapsed ? "»" : "«", target: self, action: action)
        button.isBordered = false
        button.mark = { [weak button] box in
            Theme.drawDoubleChevron(in: box, pointing: button?.title == "»")
        }
        button.setButtonType(.momentaryChange)
        // The chevron at 11 pt was the smallest target in the window, and **collapsed it is the
        // only one in a 44 pt rail** — the state in which a reader most needs it.
        button.enforceMinimumTarget()
        return button
    }

    /// The drawer's button, told what the drawer is doing (DEC-090). Its words come from
    /// `KeyboardMap`, so a button and a menu item cannot describe the same command differently —
    /// the drift M8-P found in the tester packet, and DEC-071's rule about pointer routes.
    private func updateTerminalButton() {
        guard let terminalButton else { return }
        terminalButton.isOn = terminalVisible
        let binding = KeyboardMap.binding(id: "terminal")
        let title = binding.map { terminalVisible ? "Hide the \($0.title.lowercased())"
            : "Show the \($0.title.lowercased())" } ?? "Terminal"
        terminalButton.toolTip = [title, binding?.shortcut].compactMap { $0 }.joined(separator: "  ")
    }

    private func updateCollapseButtons() {
        // The title is still the state — VoiceOver reads it, the arms name the control by it, and
        // the mark reads it back to decide which way to point (DEC-091).
        repoCollapseButton?.title = reposCollapsed ? "»" : "«"
        fileCollapseButton?.title = filesCollapsed ? "»" : "«"
        repoCollapseButton?.needsDisplay = true
        fileCollapseButton?.needsDisplay = true
        repoCollapseButton?.toolTip = reposCollapsed ? "Show the repository list" : "Fold the repository list"
        fileCollapseButton?.toolTip = filesCollapsed ? "Show the file list" : "Fold the file list"
    }

    @objc private func showAddSourceMenu(_ sender: NSButton) {
        sourceMenu(additionsOnly: true).popUp(
            positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + Theme.space2), in: sender)
    }

    /// `Sources ⌄` in the title bar (the adopted design). The whole menu this time, `Remove Source`
    /// and `Set Base Branch…` included: the title bar says which repository is open, and these are
    /// the four things a reader does to *which repositories exist at all*.
    @objc private func showSourcesMenu(_ sender: NSButton) {
        sourceMenu(additionsOnly: false).popUp(
            positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + Theme.space2), in: sender)
    }

    /// The headers' text, from `ChromeLabels` (DEC-071). Called wherever either number can change:
    /// a scan, a reload, and a collapse — the third because collapsing is what drops the word and
    /// keeps the count.
    private func updatePaneHeaders() {
        let repositories = ChromeLabels.repositoriesHeader(count: state.repositories.count,
                                                          collapsed: reposCollapsed)
        let files = ChromeLabels.changedFilesHeader(count: state.files.count,
                                                   collapsed: filesCollapsed)
        repoHeaderCaption.stringValue = repositories.caption
        fileHeaderCaption.stringValue = files.caption
        fileHeaderCount.stringValue = files.count

        // DEC-098: **the collapsed rail was drawing `2` for twenty-one repositories.** The header
        // is one row — a label, a spacer, and a 24 pt chevron — laid out with the expanded pane's
        // 16 pt of insets, which in a 44 pt rail leaves the count nothing and clips it to its first
        // digit. A number clipped to one digit is not a smaller number, it is a wrong one.
        //
        // Collapsed, the insets go to the seam and the spacer is squeezed; the label keeps every
        // point that is left, and anything still too long is *marked* by an ellipsis rather than
        // silently cut. The exact figure is on the tooltip in both states.
        for (stack, collapsed) in [(repoHeaderStack, reposCollapsed), (fileHeaderStack, filesCollapsed)] {
            guard let stack else { continue }
            let side = collapsed ? Theme.space1 : Theme.space3 + Theme.space2
            stack.edgeInsets = NSEdgeInsets(top: 0, left: side, bottom: 0,
                                            right: collapsed ? Theme.space1 : Theme.space3)
            stack.spacing = collapsed ? Theme.space1 : Theme.space2
        }
        // The trailing row's own gap goes too: with the `+` hidden it sits between the count and
        // the chevron, and in a rail those four points are a third of what the number has.
        repoTrailingStack?.spacing = reposCollapsed ? 0 : Theme.space2
        fileTrailingStack?.spacing = filesCollapsed ? 0 : Theme.space2
        repoHeaderCaption.toolTip = ChromeLabels.paneCountTooltip(count: state.repositories.count,
                                                                  noun: "repository", plural: "repositories")
        fileHeaderCount.toolTip = ChromeLabels.paneCountTooltip(count: state.files.count,
                                                                noun: "changed file", plural: "changed files")
    }

    /// The status line, at the bottom edge where the design puts it. A line that reports what just
    /// happened belongs where a reader glances, not between the controls and the thing they
    /// control.
    private func buildStatusBar() -> NSView {
        // Left: what the watcher is doing and how old the window is (DEC-075), then whatever
        // happened last — the line that used to be the whole bar.
        watchLabel = NSTextField(labelWithString: "")
        watchLabel.font = Theme.font(Theme.textSizeSmall)
        watchLabel.textColor = Theme.inkQuiet
        watchLabel.lineBreakMode = .byTruncatingTail
        watchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // The transient message is what yields when the bar runs out of room: the watcher's state is
        // a standing fact and `removed /some/path` is a sentence about a moment.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let left = NSStackView(views: [watchLabel, statusLabel])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = Theme.space4

        // Right: the layout, the wrap switch, and the keys that move the reader around.
        layoutControl = PillControl(labels: ChromeLabels.layoutTitles)
        layoutControl.selectedSegment = sideBySide ? 1 : 0
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)

        // A real checkbox: it keeps its own drawn state, its accessibility and its behaviour, which
        // is the same reasoning the empty state's buttons are built on.
        // DEC-086: the system's blue tick goes, and the metal takes its place. Still an
        // `NSButton` checkbox underneath, so the key equivalent and the state are the system's.
        wrapButton = NSButton(checkboxWithTitle: ChromeLabels.wrapTitle, target: self,
                              action: #selector(toggleWrap))
        wrapButton.font = Theme.prose(Theme.textSizeSmall)
        wrapButton.state = wrapEnabled ? .on : .off
        wrapButton.toolTip = KeyboardMap.binding(id: "wrap")?.shortcut

        // DEC-090: the drawer opens with a pointer as well as with ⌃`. It is the only pane in the
        // window with no control of its own — the two lists have chevrons, the diff has the lens —
        // and a reader who does not know the keystroke has no way to find out that it exists.
        //
        // In the status line because that is the edge the drawer comes out of: a control belongs
        // beside the thing it moves, which is the same reasoning that put the scope row above the
        // lists rather than inside a pane on the far side of them.
        terminalButton = TerminalButton(title: "", target: self, action: #selector(toggleTerminal))
        terminalButton.isBordered = false
        terminalButton.setButtonType(.momentaryChange)
        terminalButton.enforceMinimumTarget()
        updateTerminalButton()

        // Version two's two controls (DEC-092), at the leading edge of the right-hand group: the
        // branch this window is on, and the one sync button with its three states. Both are in the
        // status line rather than a toolbar of their own, because this window's status line is
        // already where facts about the *repository as a whole* are stated.
        branchButton = ChevronButton(title: "", target: self, action: #selector(showBranchMenu(_:)))
        branchButton.isBordered = false
        branchButton.font = Theme.prose(Theme.textSizeSmall)
        branchButton.identifier = NSUserInterfaceItemIdentifier("git.branchButton")
        branchButton.toolTip = KeyboardMap.binding(id: "git.branches")?.shortcut
        branchButton.enforceMinimumTarget()

        syncButton = SyncButton(title: "Fetch origin", target: self, action: #selector(syncButtonPressed))
        syncButton.bezelStyle = .rounded
        syncButton.font = Theme.prose(Theme.textSizeSmall)
        syncButton.identifier = NSUserInterfaceItemIdentifier("git.syncButton")

        // The key legend has gone with the hints (DEC-077). The menu bar is where the map lives; a
        // status line that recites it is three lines of text a reader stops seeing after a day.
        let right = NSStackView(views: [branchButton, syncButton, terminalButton, layoutControl, wrapButton])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = Theme.space6

        let bar = ChromeBar(surface: Theme.statusBar, edge: .top)
        for view in [left, modeControl!, right] {
            bar.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        // Centred against the bar rather than laid out between the two groups: a stack would put the
        // modes wherever the left field's length left them, and a control that moves when a message
        // arrives is a control a reader has to look for.
        //
        // **A preference, not a requirement**, and that is the whole of what this constraint had to
        // learn. Required, it forced a minimum window width of twice the right-hand group plus the
        // pills — the window opened **72 pt wider than `Theme.windowWidth`**, and the split view
        // redistributed that extra width the next time the panes were laid out, so ⌃⌘0 collapsed the
        // rail and left the file spine at 320. A bar that cannot fit its contents must shift them,
        // never grow the window under the panes.
        let centred = modeControl.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centred.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: Theme.statusBarHeight),
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.space6),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centred,
            modeControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            modeControl.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor,
                                                 constant: Theme.space4),
            modeControl.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor,
                                                  constant: -Theme.space4),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.space6),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        updateWatchLabel()
        return bar
    }

    /// `● Watching · refreshed 4s ago` (DEC-075). Called on a tick, because the age changes without
    /// anything else happening — and only assigned when the sentence changes, so the bar is not
    /// redrawn once a second for a string that reads the same.
    private func updateWatchLabel() {
        let age = lastRefresh.map { Int(Date().timeIntervalSince($0)) }
        let sentence = ChromeLabels.watcherStatus(watchState, refreshedSecondsAgo: age)
        if watchLabel.stringValue != sentence { watchLabel.stringValue = sentence }
    }

    /// Stamped where the window actually re-reads the repository, not where an event arrives: an
    /// event the debounce swallowed changed nothing on screen and must not reset the clock (DEC-026).
    private func markRefreshed() {
        lastRefresh = Date()
        updateWatchLabel()
    }

    @objc private func layoutChanged() {
        // The control and ⌥⌘→ are one thing (DEC-059): the toggle owns the state, so the segment
        // only asks for it when the two disagree.
        guard (layoutControl.selectedSegment == 1) != sideBySide else { return }
        toggleSideBySide()
    }

    private func buildEmptyState() {
        let title = NSTextField(labelWithString: "No folders chosen yet")
        title.font = Theme.prose(Theme.emptyStateTitleSize, weight: .medium)

        emptyStateDetail = NSTextField(wrappingLabelWithString:
            "Choose a folder and DiffScope will look inside it for Git repositories. "
            + "You can add as many folders as you like, and add single repositories from anywhere.")
        emptyStateDetail.font = Theme.prose(Theme.textSize)
        emptyStateDetail.textColor = Theme.inkQuiet
        emptyStateDetail.alignment = .center
        emptyStateDetail.preferredMaxLayoutWidth = Theme.emptyStateMaximumWidth - 2 * Theme.space6 - Theme.space4

        let chooseFolder = NSButton(title: "Choose a Folder…", target: self,
                                    action: #selector(addRootFolder))
        chooseFolder.keyEquivalent = "\r"
        let chooseRepository = NSButton(title: "Add a Single Repository…", target: self,
                                        action: #selector(addRepository))
        // The rim goes *around* the system button, not instead of it. `bezelColor` tints the
        // bezel the cell still draws, so the pressed state, the default-button pulse and the focus
        // ring all survive; the layer adds the border the design asks for.
        for button in [chooseFolder, chooseRepository] {
            button.bezelColor = Theme.buttonFill
            button.wantsLayer = true
            button.layer?.cornerRadius = Theme.buttonRadius
            button.layer?.borderWidth = Theme.buttonRimWidth
            button.layer?.borderColor = Theme.buttonRim.cgColor
        }

        let buttons = NSStackView(views: [chooseFolder, chooseRepository])
        buttons.orientation = .horizontal
        buttons.spacing = Theme.space6 - Theme.space2

        let stack = NSStackView(views: [title, emptyStateDetail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.space6

        emptyState = NSView()
        // `--ds-empty-bg`. The one screen AppKit draws before any pane exists, so it is the one
        // place the window's own surface is visible on its own.
        emptyState.wantsLayer = true
        emptyState.layer?.backgroundColor = Theme.emptyStateSurface.cgColor
        emptyState.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.emptyStateMaximumWidth),
        ])
        emptyState.isHidden = true
    }

    private func showEmptyState(problems: [InspectedSource]) {
        if problems.isEmpty {
            emptyStateDetail.stringValue =
                "Choose a folder and DiffScope will look inside it for Git repositories. "
                + "You can add as many folders as you like, and add single repositories from anywhere."
        } else {
            // Named rather than quietly forgotten: the user is the only one who can tell a moved
            // folder from one they no longer want.
            let list = problems.map { "\($0.source.path) — \($0.state.rawValue)" }.joined(separator: "\n")
            emptyStateDetail.stringValue =
                "Everything you have added is currently unreachable, so there is nothing to show:\n\n"
                + list + "\n\nThey are still configured. Choose them again if they moved, "
                + "or use Sources ▸ Remove Source."
        }
        emptyState.isHidden = false
        // **The split view is covered, not hidden.** `emptyState` is added to the container last
        // and pinned to all four edges, so it is opaque and on top; hiding what is underneath buys
        // nothing and costs the drawer its height, which the content view then follows down to the
        // two bars. That is what put the empty state's buttons at `y = −28`.
        statusLabel.stringValue = problems.isEmpty ? "no folders chosen" : "no reachable sources"
    }

    private func hideEmptyState() {
        emptyState.isHidden = true
        splitView.isHidden = false
    }

    /// DEC-037: every configured source, merged into one list. Depth 2 applies per root (DEC-018);
    /// individually added repositories bypass scanning, which is also the answer for a repository
    /// nested deeper than the limit would ever reach.
    private func scan(sources: [ConfiguredSource]) {
        let inspected = configStore.inspect(Configuration(sources: sources))
        let unusable = inspected.filter { $0.state != .present }
        state.sourceProblems = unusable

        // A folder the reader chose that holds no repositories has to say so. Showing three empty
        // panes leaves them wondering whether the application is broken or their folder is empty —
        // the first thing a stranger meets if they pick the wrong directory (G3).
        func explainEmptyResult(_ count: Int) -> Bool {
            guard count == 0, !sources.isEmpty, unusable.count < sources.count else { return false }
            self.state.repositories = []
            self.repoTable.reloadData()
            self.updatePaneHeaders()
            self.emptyStateDetail.stringValue =
                noRepositoriesFoundMessage(paths: sources.map(\.path),
                                           depth: self.discovery.maximumDepth)
            self.emptyState.isHidden = false
            // Covered, not hidden — the same reason as in `showEmptyState`.
            self.statusLabel.stringValue = "no repositories found"
            return true
        }

        guard !sources.isEmpty, unusable.count < sources.count else {
            // Nothing configured, or nothing that still exists. Either way the reader needs the
            // picker rather than an empty table with no explanation (DEC-036, `12-…` §7.5).
            DispatchQueue.main.async {
                self.state.repositories = []
                self.repoTable.reloadData()
                self.updatePaneHeaders()
                self.showEmptyState(problems: unusable)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.discovery.discover(sources: sources.map(\.discoverySource))
            let sweep = RepositorySweep(reader: self.reader)
            let outcome = sweep.run(over: found.repositories.map(\.url),
                                    baseOverrides: self.state.configuration.baseOverrides)
            let labels = disambiguatedNames(for: outcome.snapshots.map(\.url.path))
            DispatchQueue.main.async {
                guard !explainEmptyResult(outcome.snapshots.count) else { return }
                self.state.repositories = outcome.snapshots
                self.state.repositoryLabels = labels
                self.hideEmptyState()
                self.repoTable.reloadData()
                self.updatePaneHeaders()
                var summary = String(format: "%d repositories from %d sources · swept in %.0f ms",
                                     outcome.snapshots.count, sources.count - unusable.count,
                                     outcome.elapsedSeconds * 1000)
                // A missing root is named, not dropped: a source that vanishes from the list looks
                // exactly like one that was never added.
                if !unusable.isEmpty {
                    summary += " · " + unusable.map { "\($0.source.path) \($0.state.rawValue)" }
                        .joined(separator: ", ")
                }
                self.markRefreshed()
                self.statusLabel.stringValue = summary
                // Opening onto three empty panes makes the reader click before the application has
                // said anything. Selecting after the summary, not before, so that whatever the
                // selection has to say — an unavailable scope, for instance — is what stays on
                // screen rather than being overwritten by the sweep's own line.
                // **The open repository is selected in the list** (DEC-077). A sweep replaces every
                // snapshot with a new object, and the selection was only ever set when there was no
                // repository open — so after the first refresh the list had *no* selected row while
                // the window was showing a repository's diff, and the only thing saying which one
                // was the title bar. Measured: `repoSelected=-1` on a window with 63 changed files.
                let openPath = self.state.selectedRepository?.url.standardizedFileURL.path
                let row = outcome.snapshots.firstIndex {
                    $0.url.standardizedFileURL.path == openPath
                } ?? (outcome.snapshots.isEmpty ? nil : 0)
                if let row, self.repoTable.selectedRow != row {
                    self.repoTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
        }
    }

    /// DEC-083: **the file being shown is the selected row**, the way the open repository is.
    ///
    /// The repository list had exactly this defect and DEC-077 fixed it there: the row was set on a
    /// click and lost on the next `reloadData`, so after any refresh the list had no selected row
    /// while the pane beside it showed that row's diff. Nobody carried the fix to the second list —
    /// `fileTable.selectRowIndexes` was called in three places and **all three were in the
    /// selftest**, so the product path had never existed and no arm could notice.
    ///
    /// Matched by path rather than by index, because a sweep reorders and regroups: the row a file
    /// was on is not the row it is on now, and selecting the old index would mark the wrong file.
    private func restoreFileSelection() {
        guard let path = state.selectedFile?.path else { return }
        let row = state.fileRows.firstIndex { $0.file?.path == path }
        guard let row, fileTable.selectedRow != row else { return }
        fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// The selected row's file path, for the arm that asks whether the mark and the pane agree.
    var selectedFileRowPath: String? {
        guard fileTable.selectedRow >= 0,
              state.fileRows.indices.contains(fileTable.selectedRow) else { return nil }
        return state.fileRows[fileTable.selectedRow].file?.path
    }

    /// DEC-086: **the title row sits on the traffic lights' centre line**, not on its own bar's.
    ///
    /// The system centres its three buttons in the titlebar it owns; this row is centred in the
    /// 44 pt bar the window draws. The two are different numbers, and the difference is what the
    /// owner reported as *not aligned*. Measured from the button rather than assumed: a constant
    /// would be a guess about a height the system chooses.
    func alignTitleRowToTrafficLights() {
        guard let close = window.standardWindowButton(.closeButton),
              let bar = titleRowStack?.superview else { return }
        let buttonCentre = close.convert(close.bounds, to: bar).midY
        let offset = buttonCentre - bar.bounds.midY
        titleRowStack.edgeInsets = NSEdgeInsets(top: max(0, -2 * offset), left: Theme.trafficLightInset,
                                                bottom: max(0, 2 * offset), right: Theme.space6)
    }

    /// What the arm measures: the two centre lines, in the window's own coordinates.
    var titleAlignmentReport: (row: CGFloat, lights: CGFloat) {
        let rowBox = titleRowStack.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let lightBox = window.standardWindowButton(.closeButton)
            .map { $0.convert($0.bounds, to: nil) } ?? .zero
        return (rowBox.midY, lightBox.midY)
    }

    func rescan() {
        var sources = state.configuration.sources
        if let hook = ProcessInfo.processInfo.environment["DIFFSCOPE_ROOT"],
           !sources.contains(where: { $0.path == hook }) {
            sources.append(ConfiguredSource(kind: .root, path: hook))
        }
        scan(sources: sources)
    }

    private func add(kind: ConfiguredSource.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = kind == .root
        panel.prompt = kind == .root ? "Add Root Folder" : "Add Repository"
        panel.message = kind == .root
            ? "Choose a folder to scan for Git repositories."
            : "Choose a Git repository."
        // No default directory is offered. DEC-036's amendment rejected both a suggested path and
        // auto-detection, in favour of predictability over convenience.
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let source = ConfiguredSource(kind: kind, path: url.standardizedFileURL.path)
            // DEC-069: the same directory, not the same string. `contains` compared the two paths
            // exactly, so a folder already configured under another spelling — a different case, or
            // reached through a symlinked parent — was added a second time and then listed twice.
            guard !state.configuration.sources.contains(where: {
                $0.kind == source.kind && PathIdentity.same($0.path, source.path)
            }) else { continue }
            state.configuration.sources.append(source)
        }
        if let problem = configStore.save(state.configuration) {
            statusLabel.stringValue = problem
        }
        rescan()
    }

    /// DEC-009: the detected base is overridable per repository, and the override is stored in
    /// application configuration — never written into the repository.
    @objc private func setBaseBranch() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "select a repository first"
            return
        }
        let key = repository.url.standardizedFileURL.path
        let alert = NSAlert()
        alert.messageText = "Base branch for \(repository.displayName)"
        alert.informativeText = "Detected: \(repository.baseRefUsed ?? "none — detection did not resolve"). "
            + "Leave empty to go back to detection."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Theme.filePaneWidth - 2 * Theme.space6 - 2 * Theme.space4, height: Theme.space6 + Theme.space4))
        field.stringValue = state.configuration.baseOverrides[key] ?? ""
        field.placeholderString = "origin/main"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use This")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        if entered.isEmpty {
            state.configuration.baseOverrides.removeValue(forKey: key)
        } else {
            state.configuration.baseOverrides[key] = entered
        }
        if let problem = configStore.save(state.configuration) { statusLabel.stringValue = problem }
        // Re-swept rather than patched: the merge-base and the ahead count both depend on the ref,
        // and recomputing them is the only way to keep the row honest.
        rescan()
    }

    /// `12-…` §5.4: wrapping is *available*, not compulsory. Forced wrapping pushes the two panes
    /// out of vertical alignment on exactly the minified files that section was written about.
    @objc private func toggleWrap() {
        wrapEnabled.toggle()
        wrapMenuItem?.state = wrapEnabled ? .on : .off
        wrapButton?.state = wrapEnabled ? .on : .off
        webView.evaluateJavaScript("window.diffscopeSetWrap(\(wrapEnabled))") { _, _ in }
        statusLabel.stringValue = wrapEnabled ? "long lines wrap" : "long lines scroll horizontally"
    }

    /// DEC-059. Unified is what the window opens on; this is the mode a reader opts into for a
    /// large restructure, where the question is whether two versions correspond rather than what
    /// changed. The renderer re-projects the model it already has, so the pinned pair and the
    /// current change stop both survive the switch.
    @objc private func toggleSideBySide() {
        sideBySide.toggle()
        sideBySideMenuItem?.state = sideBySide ? .on : .off
        layoutControl?.selectedSegment = sideBySide ? 1 : 0
        webView.evaluateJavaScript("window.diffscopeSetLayout(\"\(sideBySide ? "split" : "unified")\")") { _, _ in }
        statusLabel.stringValue = sideBySide ? "side by side" : "unified"
    }

    /// DEC-060. Three toggles rather than one focus mode, because the two lists stop being useful
    /// at different moments: the repository list goes quiet once you are inside a repository, and
    /// the file list stays in use for the whole review.
    @objc private func toggleRepositoriesPane() {
        reposCollapsed.toggle()
        reposCollapseMenuItem?.state = reposCollapsed ? .on : .off
        applyCollapses()
    }

    @objc private func toggleFilesPane() {
        filesCollapsed.toggle()
        filesCollapseMenuItem?.state = filesCollapsed ? .on : .off
        applyCollapses()
    }

    @objc private func toggleBothPanes() {
        let collapsing = !(reposCollapsed && filesCollapsed)
        reposCollapsed = collapsing
        filesCollapsed = collapsing
        reposCollapseMenuItem?.state = collapsing ? .on : .off
        filesCollapseMenuItem?.state = collapsing ? .on : .off
        applyCollapses()
    }

    /// `NSSplitViewDelegate`. A drag ends here: the split has already moved the divider and set the
    /// frames, and this makes the constraints agree with what the reader did rather than undoing it.
    ///
    /// Guarded by `applyingCollapse`, because a collapse resizes the subviews too — writing the
    /// animated intermediate widths back into the constants would make the collapse fight itself.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingCollapse, (notification.object as? NSSplitView) === splitView else { return }
        let widths = splitView.arrangedSubviews.map(\.frame.width)
        guard widths.count == 3 else { return }
        if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil {
            FileHandle.standardError.write(Data(
                ("SELFTEST split-resized widths=\(widths.map { Int($0) }) "
                    + "constants=[\(Int(repoPaneWidth?.constant ?? -1)),"
                    + "\(Int(filePaneWidth?.constant ?? -1))]\n").utf8))
        }
        if !reposCollapsed, widths[0] > Theme.paneMinimumWidth { repoPaneWidth?.constant = widths[0] }
        if !filesCollapsed, widths[1] > Theme.paneMinimumWidth { filePaneWidth?.constant = widths[1] }
    }

    /// True while `applyCollapses` is moving the dividers itself.
    private var applyingCollapse: Bool {
        get { collapseInFlight }
        set { collapseInFlight = newValue }
    }

    private func applyCollapses() {
        applyingCollapse = true
        defer { DispatchQueue.main.async { self.applyingCollapse = false } }
        // DEC-064: the pane moves, unless the reader has asked the system for less motion — in
        // which case it is simply the other width, with nothing in between. The system setting is
        // the authority; there is no preference of our own to disagree with it.
        // The constant is set outright and the *layout pass* is what animates. Animating the
        // constant itself left it at its old value whenever the animation did not run to
        // completion — the selftest caught a collapse that had been asked for and not made, which
        // is the failure mode worth having a check for at all.
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The width constraints are switched on only while a collapse is being applied: outside
        // that they are what prevented a drag from sticking.
        repoPaneWidth?.constant = reposCollapsed ? Theme.railWidth : Theme.repositoryPaneWidth
        filePaneWidth?.constant = filesCollapsed ? Theme.spineWidth : Theme.filePaneWidth
        // **Strong, and only while collapsed.** At 500 the split redistributed proportionally and
        // the rail came out at 54.5 instead of 44; at 999 it wins, which is what a collapse needs.
        // Outside a collapse the constraint is off entirely, because an active `equalToConstant` is
        // what the layout engine restores after every drag.
        repoPaneWidth?.priority = NSLayoutConstraint.Priority(999)
        filePaneWidth?.priority = NSLayoutConstraint.Priority(999)
        repoPaneWidth?.isActive = reposCollapsed
        filePaneWidth?.isActive = filesCollapsed
        repoPaneMinimum?.constant = reposCollapsed ? Theme.railWidth : Theme.paneMinimumWidth
        filePaneMinimum?.constant = filesCollapsed ? Theme.spineWidth : Theme.paneMinimumWidth

        // DEC-083's 24 pt floor meets DEC-060's 44 pt rail: two targets side by side need 48 pt of
        // header and the rail grew to 66, taking the width out of the diff pane it was collapsed to
        // give. **The `+` leaves the rail and the chevron stays** — the chevron is the control that
        // un-collapses the pane and has nowhere else to be, while adding a source is reachable from
        // `Sources ⌄` in the title bar and from the menu bar. DEC-060's *reduced, never hidden* is
        // about the pane's content; this is a second pointer route to a function that keeps two.
        addSourceButton.isHidden = reposCollapsed
        updatePaneHeaders()
        updateCollapseButtons()
        repoTable.reloadData()
        fileTable.reloadData()
        // The dividers are moved through the split view's own API as well as by constraint.
        // Constraints alone were satisfied for the rail and quietly ignored for the spine — twice,
        // at two different priorities — because `NSSplitView` keeps the divider position it last
        // computed and a width constraint is only one of the things it weighs. `setPosition` is
        // the instruction it cannot reinterpret.
        let first = reposCollapsed ? Theme.railWidth : Theme.repositoryPaneWidth
        let second = first + splitView.dividerThickness
            + (filesCollapsed ? Theme.spineWidth : Theme.filePaneWidth)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.motionQuick
                context.allowsImplicitAnimation = true
                splitView.animator().setPosition(first, ofDividerAt: 0)
                splitView.animator().setPosition(second, ofDividerAt: 1)
                splitView.animator().layoutSubtreeIfNeeded()
            }
        } else {
            splitView.setPosition(first, ofDividerAt: 0)
            splitView.setPosition(second, ofDividerAt: 1)
            splitView.layoutSubtreeIfNeeded()
        }
        // The split view is not the constraint owner; the window's content view is. Laying out the
        // subtree from the split alone left the second divider exactly where it had been.
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        splitView.setPosition(first, ofDividerAt: 0)
        splitView.setPosition(second, ofDividerAt: 1)
        // The column does not follow the pane on its own, and a column narrower than its pane
        // draws a row that is mostly empty — M8-D's defect exactly: two lists full of correct
        // rows, rendered blank, in a window that passed every check. Setting the width by hand
        // was worse: the table resized it back to 10 pt behind the change.
        for (table, collapsed) in [(repoTable!, reposCollapsed), (fileTable!, filesCollapsed)] {
            // A legacy scroller reserves its own width whether or not it is shown, and that
            // reservation becomes the pane's floor.
            table.enclosingScrollView?.scrollerStyle = .overlay
            table.enclosingScrollView?.hasVerticalScroller = !collapsed
            // A pane that shrinks keeps its horizontal scroll offset, and the rail then drew its
            // three letters starting 27 pt into a 44 pt column — present, correct, and mostly off
            // the left edge. Nothing about the row was wrong; the clip view was where it had been.
            if let clip = table.enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard let column = table.tableColumns.first,
                  let clip = table.enclosingScrollView?.contentView else { continue }
            // The table keeps whatever width it had and the clip view then centres the difference,
            // which put a 32 pt cell 16 pt into a 32 pt window — three letters set, two drawn.
            // Sizing the table to the clip is what makes the row start where the pane does.
            column.minWidth = Theme.spineWidth - 2 * Theme.space2
            column.maxWidth = Theme.windowWidth
            column.width = max(column.minWidth, clip.bounds.width)
            table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
            table.tile()
            // …and again after the split view's own layout pass, which re-tiles the scroll view
            // and puts the width back. The first assignment is what the table is asked for; this
            // is what it keeps.
            DispatchQueue.main.async {
                // The pane's own children go with it. `NSSplitView` sets the *pane's* frame and the
                // layout engine then puts the list back to the width it valued it at — traced:
                // `320 → 34` from the engine, and 34 → 320 again by the time the next pass ran. The
                // pane is asked to place its children once more, after everything has settled.
                (table.enclosingScrollView?.superview as? FilePane)?.place()
                table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
                table.tile()
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        statusLabel.stringValue = "repositories: \(reposCollapsed ? "rail" : "list")"
            + " · files: \(filesCollapsed ? "spine" : "list")"
    }

    @objc private func addRootFolder() { add(kind: .root) }
    @objc private func addRepository() { add(kind: .repository) }

    /// Removes whichever source the selected repository came from, or the selected missing source
    /// when the empty state is showing.
    @objc private func removeSource() {
        let selectedPath = state.selectedRepository?.url.path
        // DEC-069. Discovery reports the filesystem's spelling and the configuration holds the
        // user's, and the two need not agree: a root typed in one case, or a path under `/var`
        // against the `/private/var` the scan returns, matched nothing here — so the reader was
        // told to *select a repository to remove the source it came from* while one was selected.
        let match = state.configuration.sources.first { source in
            guard let selectedPath else { return false }
            return source.contains(repositoryPath: selectedPath)
        } ?? state.sourceProblems.first?.source

        guard let match else {
            statusLabel.stringValue = "select a repository to remove the source it came from"
            return
        }
        state.configuration.sources.removeAll { $0 == match }
        if let problem = configStore.save(state.configuration) {
            statusLabel.stringValue = problem
        }
        state.selectedRepository = nil
        state.selectedFile = nil
        watcher?.stop()
        rescan()
        statusLabel.stringValue = "removed \(match.path)"
    }

    @objc private func scopeChanged() {
        // Same reasoning as the menu route: picking a scope is picking two sides.
        state.historyPair = nil
        state.pickedCommits = []
        state.scope = [.allLocalVsHead, .unstagedVsIndex, .stagedVsHead, .branchVsMergeBase][scopeControl.selectedSegment]
        reloadFiles()
    }

    /// DEC-016 commits to full keyboard operation of *every* function, so this is a map rather
    /// than a shortcut list: anything reachable only by pointer is a defect. The bindings live
    /// in the menu bar so they are discoverable and so macOS routes them regardless of focus.
    ///
    /// **The map is `KeyboardMap.bindings`, and this only draws it** (DEC-057). It used to be a
    /// hand-written list here, with the specification's coverage table in Markdown and nothing
    /// comparing the two — which is how *show raw for the current region* stayed specified,
    /// unimplemented and unreported from M6 to M8. A binding that is not in the map is now not in
    /// the menu, and a specified function with no binding fails the check suite.
    func buildMenu() {
        let main = NSMenu()

        for menu in KeyboardMenu.allCases {
            let hosting = NSMenuItem()
            let submenu = NSMenu(title: menu.title)
            for binding in KeyboardMap.bindings(in: menu) {
                // A separator before the scope block keeps the View menu readable; it is drawn from
                // the map's own ordering rather than being a row in it, since a separator is not a
                // function and DEC-016's rule is about functions.
                if binding.id == "scope.allLocal" { submenu.addItem(.separator()) }
                let item = submenu.addItem(withTitle: binding.title,
                                           action: selector(for: binding.id),
                                           keyEquivalent: keyEquivalent(binding.key))
                item.keyEquivalentModifierMask = modifierFlags(binding.modifiers)
                if binding.id != "quit" { item.target = self }
                if let tag = binding.tag { item.tag = tag }
                if binding.isToggle { item.state = initialToggleState(of: binding.id) }
                menuItems[binding.id] = item
            }
            hosting.submenu = submenu
            main.addItem(hosting)
        }

        wrapMenuItem = menuItems["wrap"]
        sideBySideMenuItem = menuItems["layout.sideBySide"]
        for id in ["lens.diff", "lens.blame", "lens.history"] { lensMenuItems[id] = menuItems[id] }
        lensMenuItems["lens.diff"]?.state = .on
        reposCollapseMenuItem = menuItems["collapse.repositories"]
        filesCollapseMenuItem = menuItems["collapse.files"]
        terminalMenuItem = menuItems["terminal"]
        terminalRawMenuItem = menuItems["terminal.raw"]
        rawRegionMenuItem = menuItems["rawRegion"]

        NSApplication.shared.mainMenu = main
    }

    /// The one place an identifier in the map becomes a method here. A binding whose identifier is
    /// unknown is a programming error rather than a missing feature, and it is loud: the menu item
    /// is drawn disabled, so it cannot look like a working function that quietly does nothing.
    private func selector(for id: String) -> Selector? {
        switch id {
        case "quit": return #selector(NSApplication.terminate(_:))
        case "preferences": return #selector(showPreferences)
        case "mode.raw", "mode.structural", "mode.expanded": return #selector(selectMode(_:))
        case "rawRegion": return #selector(toggleRawForCurrentRegion)
        case "terminal": return #selector(toggleTerminal)
        case "terminal.newTab": return #selector(newTerminalTab)
        case "terminal.nextTab": return #selector(nextTerminalTab)
        case "terminal.previousTab": return #selector(previousTerminalTab)
        case "terminal.closeTab": return #selector(closeTerminalTab)
        case "terminal.raw": return #selector(toggleTerminalRawMode)
        case "terminal.follow": return #selector(followTerminalToSelection)
        case "wrap": return #selector(toggleWrap)
        case "layout.sideBySide": return #selector(toggleSideBySide)
        case "lens.diff": return #selector(showDiffLens)
        case "lens.blame": return #selector(showBlameLens)
        case "lens.history": return #selector(showHistoryLens)
        case "collapse.repositories": return #selector(toggleRepositoriesPane)
        case "collapse.files": return #selector(toggleFilesPane)
        case "collapse.both": return #selector(toggleBothPanes)
        case "scope.allLocal", "scope.unstaged", "scope.staged", "scope.base":
            return #selector(selectScope(_:))
        case "sources.addRoot": return #selector(addRootFolder)
        case "sources.addRepository": return #selector(addRepository)
        case "sources.remove": return #selector(removeSource)
        case "sources.baseBranch": return #selector(setBaseBranch)
        case "search": return #selector(searchChangedFiles)
        case "search.next": return #selector(nextHit)
        case "search.previous": return #selector(previousHit)
        case "search.worktree": return #selector(searchWorktree)
        case "change.next": return #selector(nextChange)
        case "change.previous": return #selector(previousChange)
        case "expandAll": return #selector(expandAll)
        case "file.next": return #selector(nextFile)
        case "file.previous": return #selector(previousFile)
        case "repository.next": return #selector(nextRepository)
        case "repository.previous": return #selector(previousRepository)
        case "focus.repositories": return #selector(focusRepositories)
        case "focus.files": return #selector(focusFiles)
        case "focus.diff": return #selector(focusDiff)
        case "openInEditor": return #selector(openInEditor)
        // Version two (DEC-092). Every one of these writes, and every one of them goes through
        // `WriteActions` — there is no second path into the repository from this window.
        case "git.stage": return #selector(stageSelectedFile)
        case "git.unstage": return #selector(unstageSelectedFile)
        case "git.stageAll": return #selector(stageEverything)
        case "git.unstageAll": return #selector(unstageEverything)
        case "git.discard": return #selector(discardSelectedFile)
        case "git.commit": return #selector(commitStaged)
        case "git.focusSummary": return #selector(focusCommitSummary)
        case "git.undoCommit": return #selector(undoLastCommit)
        case "git.branches": return #selector(showBranchMenu(_:))
        case "git.newBranch": return #selector(newBranch)
        case "git.stash": return #selector(stashEverything)
        case "git.stashes": return #selector(showStashMenu(_:))
        case "git.worktrees": return #selector(showWorktreeMenu(_:))
        case "git.tags": return #selector(showTagMenu(_:))
        case "git.bisect": return #selector(startBisect)
        case "git.stageHunk": return #selector(stageHunkUnderCursor)
        case "git.unstageHunk": return #selector(unstageHunkUnderCursor)
        case "git.rewrite": return #selector(rewriteHistory(_:))
        case "git.revert": return #selector(revertPickedCommit)
        case "git.cherryPick": return #selector(cherryPickCommit)
        case "git.reset": return #selector(resetToPickedCommit)
        case "git.fetch": return #selector(fetchRemote)
        case "git.pull": return #selector(pullRemote)
        case "git.push": return #selector(pushRemote)
        case "git.forcePush": return #selector(forcePush)
        case "git.resolve": return #selector(resolveConflicts(_:))
        case "git.reflog": return #selector(showReflog(_:))
        case "git.commands": return #selector(showCustomCommands(_:))
        case "git.record": return #selector(showCommandRecord)
        default: return nil
        }
    }

    /// The map writes keys as a reader sees them — `↓`, `⏎` — and this is the one place that
    /// becomes AppKit's notation. Keeping the translation here rather than in the map is what lets
    /// `diffscope-verify` link the map without linking AppKit (DEC-057), and what lets the
    /// documents quote `⌘↓` and mean the thing the menu prints.
    private func keyEquivalent(_ key: String) -> String {
        switch key {
        case "↑": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "↓": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "←": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "→": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "⏎": return "\r"
        default: return key
        }
    }

    private func modifierFlags(_ modifiers: KeyboardModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    private func initialToggleState(of id: String) -> NSControl.StateValue {
        id == "wrap" ? .on : .off
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        // The menu's tag is an index into `allCases`; the control is drawn in `displayOrder`.
        modeControl.selectedSegment = PresentationMode.displayOrder
            .firstIndex(of: PresentationMode.allCases[sender.tag]) ?? 0
        modeChanged()
    }

    /// Choosing a scope says *compare these two sides*, which is the thing a history selection was
    /// also saying — so the selection is dropped rather than left to argue with the scope bar.
    @objc private func selectScope(_ sender: NSMenuItem) {
        state.historyPair = nil
        state.pickedCommits = []
        scopeControl.selectedSegment = sender.tag
        scopeChanged()
    }

    @objc private func nextChange() { runCommand("nextChange") }
    @objc private func previousChange() { runCommand("previousChange") }
    @objc private func expandAll() { runCommand("expandAll") }

    private func runCommand(_ name: String) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeCommand(\"\(name)\"))") { value, _ in
            guard let text = value as? String, text != "null" else { return }
            self.statusLabel.stringValue = "\(name): \(text)"
        }
    }

    private func step(_ table: NSTableView, by delta: Int) {
        let count = numberOfRows(in: table)
        guard count > 0 else { return }
        guard let next = nextSelectableRow(in: table, from: table.selectedRow, delta: delta) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Where the reader is in the list, in the list's own terms.
    ///
    /// A 63-file working tree walked by keyboard gives no sense of progress otherwise: the rows
    /// scroll, and nothing says whether there are two files left or forty. Headers are excluded from
    /// both numbers, because they are not stops (DEC-033) and counting them would make the total
    /// disagree with the number of keystrokes it takes to reach the end.
    func filePositionText() -> String? {
        let files = state.fileRows.compactMap { $0.file }
        guard !files.isEmpty else { return nil }
        let row = fileTable.selectedRow
        guard row >= 0, row < state.fileRows.count, let selected = state.fileRows[row].file,
              let index = files.firstIndex(where: { $0.path == selected.path }) else {
            return "\(files.count) files"
        }
        return "file \(index + 1)/\(files.count)"
    }

    /// Off the main thread, because it stats and reads a few kilobytes per file and the list is
    /// already on screen by then. Only the repository still selected gets its badges applied.
    private func annotateFiles(of repository: RepositorySnapshot) {
        let files = state.files
        let scope = state.scope
        let baseRef = repository.baseRefUsed ?? repository.base.ref
        DispatchQueue.global(qos: .utility).async {
            let counts = (try? self.scopes.changeCounts(scope: scope, in: repository.url,
                                                        baseRef: baseRef)) ?? [:]
            var found: [String: FileAnnotation] = [:]
            for file in files {
                if let annotation = annotate(path: file.path, in: repository.url,
                                             sizeLimit: structuralSizeLimit) {
                    found[file.path] = annotation
                }
            }
            DispatchQueue.main.async {
                guard self.state.selectedRepository?.url == repository.url else { return }
                self.state.annotations = found
                self.state.counts = counts
                self.fileTable.reloadData()
                // The annotations arrive on a background sweep and land after the list is already
                // on screen. `reloadData` keeps the selected *index* and this pass does not change
                // the rows — but it is the one place a selection could be dropped without anybody
                // seeing it happen, so it is restored here too rather than assumed safe.
                self.restoreFileSelection()
            }
        }
    }

    @objc private func nextFile() { step(fileTable, by: 1) }
    @objc private func previousFile() { step(fileTable, by: -1) }

    /// DEC-033: group headers are labels, not focus stops. Stepping past them keeps next/previous
    /// file one keystroke per *file* — otherwise grouping would silently make navigation longer.
    ///
    /// The walk itself is `RowNavigation.step`, in `DiffScopeGit` beside the row type, so a 63-file
    /// list can be walked without a window (M8-J).
    private func nextSelectableRow(in table: NSTableView, from row: Int, delta: Int) -> Int? {
        guard table === fileTable else {
            let count = numberOfRows(in: table)
            let candidate = row < 0 ? (delta > 0 ? 0 : count - 1) : row + delta
            guard candidate >= 0, candidate < count else { return nil }
            return candidate
        }
        return RowNavigation.step(rows: state.fileRows, from: row < 0 ? nil : row, delta: delta)
    }
    @objc private func nextRepository() { step(repoTable, by: 1) }
    @objc private func previousRepository() { step(repoTable, by: -1) }
    @objc private func focusRepositories() { moveFocus(to: repoTable, named: "repositories") }
    @objc private func focusFiles() { moveFocus(to: fileTable, named: "files") }
    @objc private func focusDiff() { moveFocus(to: webView, named: "diff") }

    /// Focus movement says where the keyboard went. Without it the three ⌥⌘ keys are indistinguishable
    /// from doing nothing, since a table with no selection draws no focus ring worth the name.
    private func moveFocus(to responder: NSResponder, named name: String) {
        window.makeFirstResponder(responder)
        // Reaching here **is** keyboard navigation: ⌥⌘1–3 are the only callers. The event monitor
        // cannot be relied on for this — a key equivalent delivered through the menu, which is how
        // these arrive, does not pass through `addLocalMonitorForEvents`. Marking it at the action
        // rather than at the event also means the selftest exercises the real path instead of
        // setting the flag behind the application's back.
        navigatingByKeyboard = true
        updateFocusRings()
        let position = responder === fileTable ? filePositionText().map { " · \($0)" } ?? "" : ""
        statusLabel.stringValue = "keyboard: \(name)\(position)"
    }

    /// `12-…` §9: *show raw for the current region* — the last row of the coverage table, and the
    /// one that had no implementation at all until M8-J.
    ///
    /// Not a fourth mode. Change stops come from the **canonical diff** and are therefore the same
    /// set in every mode, so this switches to Raw on the same pinned pair and jumps back to the stop
    /// the reader was standing on; pressing it again returns to the mode it left. That is what makes
    /// it *the control view for this region* rather than a global toggle the reader has to re-navigate
    /// after using.
    @objc private func toggleRawForCurrentRegion() {
        guard state.selectedFile != nil else {
            statusLabel.stringValue = "raw for current region: no file selected"
            return
        }
        if let previous = rawRegionReturn {
            rawRegionReturn = nil
            rawRegionMenuItem?.state = .off
            apply(mode: previous.mode, restoringStop: previous.stop)
            return
        }
        guard state.mode != .raw else {
            statusLabel.stringValue = "raw for current region: already raw"
            return
        }
        let leaving = state.mode
        webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { value, _ in
            let stop = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
            self.rawRegionReturn = (mode: leaving, stop: stop)
            self.rawRegionMenuItem?.state = .on
            self.apply(mode: .raw, restoringStop: stop)
        }
    }

    /// Switches mode and puts the reader back on the same change stop once the new model has been
    /// rendered. The delay is a render, not a guess: `showDiff` reads the pair off the main thread.
    private func apply(mode: PresentationMode, restoringStop stop: Int) {
        state.mode = mode
        modeControl.selectedSegment = PresentationMode.displayOrder.firstIndex(of: mode) ?? 0
        guard let file = state.selectedFile else { return }
        showDiff(for: file, restoringStop: stop >= 0 ? stop : nil)
    }

    /// DEC-015: a configurable template, never populated from repository content — the template
    /// is user configuration and a repository is untrusted input. Failure is shown, not swallowed.
    @objc private func openInEditor() {
        // DEC-092: ⌘⏎ is claimed twice, and the commit box wins it while it has focus — which is
        // GitHub Desktop's own rule and the only one that does not surprise a reader in the middle
        // of typing a message. ⇧⌘⏎ commits from anywhere, so the function is never out of reach.
        if commitBoxHasFocus() {
            commitStaged()
            return
        }
        guard let repository = state.selectedRepository, let file = state.selectedFile else {
            statusLabel.stringValue = "open in editor: no file selected"
            return
        }
        // With search results on screen, ⌘⏎ opens the hit under the marker rather than the file
        // the list happens to have selected: the marker is where the reader is.
        let hit = state.searchIndex.flatMap { index -> SearchHit? in
            index < state.searchHits.count ? state.searchHits[index] : nil
        }
        let template = editorTemplate()
        let path = repository.url.appendingPathComponent(hit?.path ?? file.path).path

        // The line comes from the renderer, which is the only side that knows where the reader is
        // looking. It used to be a literal 1 — correct in the sense that it opened the file, and
        // useless on the 900-line file where the change is at the bottom.
        webView.evaluateJavaScript("window.diffscopeCurrentLine()") { value, _ in
            let line = hit?.line ?? (value as? Int) ?? (value as? NSNumber)?.intValue ?? 1
            guard let command = EditorCommand(template: template, file: path, line: max(1, line)) else {
                self.statusLabel.stringValue = "open in editor failed — the editor template is empty"
                return
            }
            // Waiting for the exit status is the point (F13), so it happens off the main thread: a
            // template that takes a second to return must not take the interface with it.
            self.statusLabel.stringValue = "opening \(file.path):\(line)…"
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = launchEditor(command, file: "\(file.path):\(line)")
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = outcome.message
                    self.lastEditorAttempt = outcome.message
                }
            }
        }
    }

    /// DEC-015: the command is **user configuration**. The environment variable stays as a testing
    /// override — F13's broken-editor arm needs a way in that does not write to the reader's file —
    /// and the configuration is what a person edits, in Preferences or in the JSON itself.
    private func editorTemplate() -> String {
        ProcessInfo.processInfo.environment["DIFFSCOPE_EDITOR"]
            ?? state.configuration.editorTemplate
            ?? EditorCommand.defaultTemplate
    }

    /// The preferences window (DEC-015, `12-…` §10). One setting today, and it is the one with a
    /// failure the reader has to be able to see: the last attempt and its exit status are shown
    /// here, because "nothing happened" is the least useful thing an editor integration can say.
    @objc private func showPreferences() {
        if let existing = preferencesWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // A window rather than a modal alert (`12-…` §10, the adopted design). A setting a reader
        // edits *because* something failed cannot sit behind a sheet that blocks the window the
        // failure is in.
        let field = NSTextField(string: editorTemplate())
        field.font = Theme.font(Theme.textSize)
        field.placeholderString = EditorCommand.defaultTemplate

        let legend = NSTextField(wrappingLabelWithString:
            "{file} is the absolute path, {line} the 1-based line. The template is split into "
            + "arguments first and substituted afterwards, so a path with spaces stays one argument.")
        legend.font = Theme.prose(Theme.textSizeTiny)
        legend.textColor = Theme.inkQuiet

        let attempt = NSTextField(wrappingLabelWithString:
            "Last attempt: " + (lastEditorAttempt ?? "none this session"))
        attempt.font = Theme.prose(Theme.textSizeSmall)
        attempt.textColor = Theme.inkQuiet

        let save = NSButton(title: "Save", target: self, action: #selector(savePreferences))
        save.keyEquivalent = "\r"
        let reset = NSButton(title: "Reset to default", target: self,
                             action: #selector(resetPreferences))
        let buttons = NSStackView(views: [reset, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [field, legend, attempt, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.space4
        stack.edgeInsets = NSEdgeInsets(top: Theme.space6, left: Theme.space6,
                                        bottom: Theme.space6, right: Theme.space6)
        field.widthAnchor.constraint(equalToConstant: Theme.emptyStateMaximumWidth
                                        - 2 * Theme.space6).isActive = true

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.emptyStateMaximumWidth,
                                                 height: Theme.emptyStateMaximumWidth * 0.6),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Editor command"
        panel.contentView = stack
        panel.center()
        panel.isReleasedWhenClosed = false
        preferencesWindow = panel
        preferencesField = field
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func savePreferences() {
        let entered = (preferencesField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        state.configuration.editorTemplate = entered.isEmpty ? nil : entered
        configStore.save(state.configuration)
        statusLabel.stringValue = "editor command: \(editorTemplate())"
        preferencesWindow?.close()
    }

    @objc private func resetPreferences() {
        state.configuration.editorTemplate = nil
        configStore.save(state.configuration)
        preferencesField?.stringValue = EditorCommand.defaultTemplate
        statusLabel.stringValue = "editor command: \(editorTemplate())"
    }

    /// Draws a comparison the diff engine has nothing to say about (DEC-063).
    ///
    /// Every number in the sentence is computed here and checked in the engine's own words before
    /// it reaches the view: dimensions from the decoded images, differing pixels from a real pass
    /// over both, and the modes that cannot work here disabled **with their reason**.
    /// Bytes rather than the pinned pair: the pair is a Git-layer type with no public initialiser,
    /// and widening it so a selftest can build one would be the tail wagging the dog. What this
    /// needs is two sides.
    private func showRendered(file: ChangedFile, oldBytes: [UInt8], newBytes: [UInt8],
                              kind: RenderableKind) {
        let oldImage = oldBytes.isEmpty ? nil : ImageComparison.image(from: oldBytes)
        let newImage = newBytes.isEmpty ? nil : ImageComparison.image(from: newBytes)
        var differing: Int?
        var maskSource: String?
        if let oldImage, let newImage {
            let outcome = ImageComparison.compare(old: oldImage, new: newImage)
            differing = outcome.differing
            maskSource = outcome.mask.map { "data:image/png;base64," + $0.base64EncodedString() }
        }

        let comparison = RenderedComparison(
            kind: kind,
            oldBytes: oldBytes.count, newBytes: newBytes.count,
            oldSize: oldImage.map(ImageComparison.size), newSize: newImage.map(ImageComparison.size),
            differingPixels: differing)
        let summary = renderedComparisonSummary(comparison)

        // A mode is offered or refused **with a reason**; there is no third state. An SVG's pixel
        // pass is refused for a reason worth stating rather than hidden: the bytes are handed to an
        // `<img>` so nothing inside them can run, and an `<img>` is exactly what cannot be read
        // back pixel by pixel.
        let missingSide = oldImage == nil || newImage == nil
        let svg = kind == .textThatRenders(format: "SVG")
        func mode(_ id: String, _ label: String, _ reason: String?) -> [String: Any] {
            reason.map { ["id": id, "label": label, "reason": $0] } ?? ["id": id, "label": label]
        }
        let modes: [[String: Any]] = [
            mode("sidebyside", "Side by side", nil),
            mode("blend", "Blend", missingSide ? "no counterpart" : nil),
            mode("split", "Split", missingSide ? "no counterpart" : nil),
            mode("pixel", "Pixel diff",
                 missingSide ? "no counterpart"
                     : svg ? "drawn through an <img>, which cannot be read back"
                     : !comparison.withinPixelBudget
                         ? "over \(RenderedComparison.megapixelBudget) megapixels"
                         : differing == 0 ? "0 pixels differ" : nil),
        ]

        let mime = ImageComparison.mimeType(for: kind)
        var payload: [String: Any] = ["summary": "\(file.path) · \(summary)", "modes": modes]
        if !oldBytes.isEmpty {
            payload["oldSrc"] = ImageComparison.dataURL(bytes: oldBytes, mimeType: mime)
        }
        if !newBytes.isEmpty {
            payload["newSrc"] = ImageComparison.dataURL(bytes: newBytes, mimeType: mime)
        }
        if let maskSource { payload["maskSrc"] = maskSource }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let wrapped = try? JSONSerialization.data(withJSONObject: [json]),
              let escaped = String(data: wrapped, encoding: .utf8) else { return }
        let argument = String(escaped.dropFirst().dropLast())
        webView.evaluateJavaScript("window.diffscopeShowRendered(\(argument))") { _, _ in }
        statusLabel.stringValue = summary
    }

    // ---- The lenses (DEC-061) ----------------------------------------------------------------
    //
    // Same file, same window, same gutter geometry: what changes is the question. Both run through
    // the closed operation registry, so R-8's proof covers them the moment they exist — an
    // operation that is not in the registry cannot be issued at all.
    @objc private func showDiffLens() {
        state.lens = .diff
        updateLensMenu()
        webView.evaluateJavaScript("window.diffscopeHideLens()") { _, _ in }
        statusLabel.stringValue = "lens: diff"
    }

    @objc private func showBlameLens() {
        guard let repository = state.selectedRepository, let file = state.selectedFile else {
            statusLabel.stringValue = "blame needs a file — choose one first"
            return
        }
        let result = try? GitRunner().run(.blame(path: file.path), in: repository.url)
        guard let result, result.succeeded else {
            statusLabel.stringValue = "blame unavailable for \(file.path) — the file has no history yet"
            return
        }
        // Not `trimmedOutput`: blame's content lines carry their own leading whitespace and the
        // last line of a file may be blank, and trimming would quietly edit the file's text.
        let lines = parseBlamePorcelain(String(decoding: result.standardOutput, as: UTF8.self))
        state.lens = .blame
        updateLensMenu()
        let rows = lines.map { line in
            ["sha": line.sha, "who": line.author, "when": line.committed,
             "line": String(line.line), "text": line.text,
             "uncommitted": line.isUncommitted ? "1" : ""] as [String: String]
        }
        let uncommitted = lines.filter(\.isUncommitted).count
        pushLens(kind: "blame", rows: rows,
                 summary: "\(file.path) · \(lines.count) lines · \(uncommitted) not committed yet")
    }

    @objc private func showHistoryLens() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "history needs a repository — choose one first"
            return
        }
        let result = try? GitRunner().run(.log(limit: 200), in: repository.url)
        guard let result, result.succeeded else {
            statusLabel.stringValue = "history unavailable — this repository has no commits yet"
            return
        }
        let commits = parseLog(String(decoding: result.standardOutput, as: UTF8.self))
        state.lens = .history
        updateLensMenu()
        // DEC-092/DEC-098: the topology, in a column of its own. `--graph`'s own drawing is a
        // presentation and is not parsed — the lanes are computed from `%P` in the Git layer, and
        // this is a lookup by sha so a commit the log has and the graph does not simply has no
        // lane rather than shifting every row under it.
        let lanes = Dictionary(uniqueKeysWithValues: gitState.graph(in: repository.url, limit: 200)
            .map { ($0.sha, $0.laneColumn) })
        let rows = commits.map { commit in
            ["sha": commit.sha, "who": commit.author, "when": commit.committed,
             "subject": commit.subject, "refs": commit.refs,
             "graph": lanes[commit.sha] ?? ""] as [String: String]
        }
        let picked = state.pickedCommits
        let selection = state.historyPair.map {
            " · comparing " + scopes.historyComparisonDescription(old: $0.old, new: $0.new)
        } ?? " · pick a commit to compare it with the working tree, two to compare them"
        pushLens(kind: "history", rows: rows, picked: picked,
                 summary: historySummary(commits: commits,
                                         branch: repository.head.displayText,
                                         ahead: repository.aheadCount) + selection)
    }

    /// `--ds-focus-ring`, on the region rather than on a row inside it (`12-…` §9's *"a 2 px focus
    /// ring on its own border"*). The token was mirrored into `Theme.swift` when the chrome landed
    /// and **nothing drew it** — a value a designer could change to no effect, which is the failure
    /// the token checks exist to prevent, arriving on the side of the window those checks cannot
    /// see.
    /// DEC-070: **only while the reader is using the keyboard**, which is what AppKit does with its
    /// own focus rings and what this drew instead of. A ring that is lit whenever a region holds
    /// first responder is lit permanently — including for someone who has touched nothing but the
    /// mouse, and who has no use for the answer.
    ///
    /// DEC-016 asks for full keyboard operation with the focus *visible*, and that is unchanged:
    /// the ring appears on the first keystroke and stays for as long as the keyboard is in use.
    /// **No ring at all** (DEC-077). DEC-070 narrowed it to keyboard navigation and the owner asked
    /// for it to go entirely — DEC-070's option 2, offered then and declined, chosen now. DEC-016's
    /// *visible focus* is carried by the selected row, which is drawn whether or not the region has
    /// the keyboard.
    ///
    /// Kept as a method rather than deleted at its call sites: `navigatingByKeyboard` still says
    /// whether the reader is on the keyboard, and the selftest asserts that **nothing draws a ring**.
    private func updateFocusRings() {
        for view in [repoFocusRing, fileFocusRing, diffFocusRing] {
            view?.layer?.borderWidth = 0
        }
    }

    /// A click puts it out, a keystroke lights it. Deliberately not `isFullKeyboardAccessEnabled`:
    /// that setting says whether Tab *reaches* every control, which is a different question from
    /// whether the person is using the keyboard right now.
    private func watchForKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.navigatingByKeyboard else { return event }
            self.navigatingByKeyboard = true
            self.updateFocusRings()
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.navigatingByKeyboard else { return event }
            self.navigatingByKeyboard = false
            self.updateFocusRings()
            return event
        }
    }

    /// The only thing the page is allowed to ask for, and it is named rather than evaluated: a
    /// message with an unknown action is ignored. Repository content reaches this webview (an SVG
    /// is drawn in it), so what arrives here is treated as input rather than as instruction —
    /// DEC-028's rule, one surface further out.
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["action"] as? String {
        case "pickCommit":
            guard let sha = body["sha"] as? String,
                  sha.count >= 7, sha.allSatisfy({ $0.isHexDigit }) else { return }
            pickCommit(sha)
        // DEC-092: a line of the diff, put into the next commit or taken out of it. The number is
        // checked the way the sha above is — a message from the page is data, and this one becomes
        // a write.
        case "stageLine":
            let raw = (body["line"] as? Int) ?? (body["line"] as? NSNumber)?.intValue
            guard let raw, raw != 0, abs(raw) < 5_000_000, let file = state.selectedFile else { return }
            // Positive is a new-side line, negative an old-side one; `stageSelection` takes the
            // zero-based form of each, with removals encoded negatively.
            let selection = raw > 0 ? [raw - 1] : [raw]
            stageSelection(selection, from: file, unstage: state.scope == .stagedVsHead)
        default:
            return
        }
    }

    /// One commit is *since this*; a second is *between these*; a third starts again. The order is
    /// the reader's, not the log's, because "compare this with that" is a sentence with a
    /// direction.
    private func pickCommit(_ sha: String) {
        var picked = state.pickedCommits
        if let existing = picked.firstIndex(of: sha) {
            picked.remove(at: existing)
        } else if picked.count >= 2 {
            picked = [sha]
        } else {
            picked.append(sha)
        }
        state.pickedCommits = picked
        guard let first = picked.first else {
            state.historyPair = nil
            showHistoryLens()
            reloadFiles()
            return
        }
        // Two picks compare in selection order: the first is the left side.
        state.historyPair = (old: first, new: picked.count > 1 ? picked[1] : nil)
        showHistoryLens()
        reloadFiles()
    }

    @objc private func lensChanged() {
        switch lensControl.selectedSegment {
        case 1: showBlameLens()
        case 2: showHistoryLens()
        default: showDiffLens()
        }
    }

    private func updateLensMenu() {
        lensControl.selectedSegment = [Lens.diff, .blame, .history].firstIndex(of: state.lens) ?? 0
        lensMenuItems["lens.diff"]?.state = state.lens == .diff ? .on : .off
        lensMenuItems["lens.blame"]?.state = state.lens == .blame ? .on : .off
        lensMenuItems["lens.history"]?.state = state.lens == .history ? .on : .off
    }

    private func pushLens(kind: String, rows: [[String: String]], picked: [String] = [],
                          summary: String) {
        let payload: [String: Any] = ["kind": kind, "summary": summary, "picked": picked,
                                      "rows": rows.map { row -> [String: Any] in
                                          var out: [String: Any] = row
                                          out["uncommitted"] = (row["uncommitted"] ?? "") == "1"
                                          out["line"] = Int(row["line"] ?? "") ?? 0
                                          return out
                                      }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let escaped = String(data: try! JSONSerialization.data(withJSONObject: [json]),
                                   encoding: .utf8) else { return }
        // The payload is passed as a JSON string inside a JSON array, so quoting it is the
        // serialiser's problem rather than a piece of string arithmetic here.
        let argument = String(escaped.dropFirst().dropLast())
        webView.evaluateJavaScript("window.diffscopeShowLens(\(argument))") { _, _ in }
        statusLabel.stringValue = summary
    }

    // ---- Search (DEC-062) -------------------------------------------------------------------
    //
    // The default scope is the changed set, because that is the material under review; the whole
    // worktree is a different question and is asked with a different key rather than a hidden
    // default. Both are read-only: the reader's query is matched as a literal, and nothing
    // compiled from a repository is ever run (DEC-028).
    @objc private func searchChangedFiles() { focusSearch(scope: .changedFiles) }
    @objc private func searchWorktree() { focusSearch(scope: .wholeWorktree) }

    private func focusSearch(scope: SearchScope) {
        searchScope = scope
        searchField.placeholderString = "Find in \(scope.title)"
        window.makeFirstResponder(searchField)
    }

    @objc private func searchSubmitted() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "search needs a repository — choose one first"
            return
        }
        state.searchQuery = searchField.stringValue
        guard !state.searchQuery.isEmpty else {
            // An empty field is not an empty result: it is the way back to the file list.
            state.searchHits = []
            reloadFiles()
            return
        }
        let contents = searchableContents(of: repository, scope: searchScope)
        let result = search(query: state.searchQuery, in: contents,
                            options: SearchOptions(matchCase: state.searchMatchCase))
        state.searchHits = result.hits
        showSearchResults(result, scope: searchScope)
    }

    /// The text to search. Changed files come from the scope the reader is already looking at;
    /// the worktree walk skips `.git` and `node_modules` for the reason DEC-027 skips them in the
    /// watcher, and stops at a file count rather than reading a repository of unknown size.
    private func searchableContents(of repository: RepositorySnapshot,
                                    scope: SearchScope) -> [(path: String, text: String)] {
        func read(_ relative: String) -> (path: String, text: String)? {
            let url = repository.url.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return (path: relative, text: text)
        }
        switch scope {
        case .changedFiles:
            return state.files.compactMap { read($0.path) }
        case .wholeWorktree:
            let skipped = Set([".git", "node_modules", ".next", "dist", "build"])
            var out: [(path: String, text: String)] = []
            let base = repository.url.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: repository.url,
                                                              includingPropertiesForKeys: [.isDirectoryKey]) else {
                return out
            }
            for case let url as URL in walker {
                if skipped.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                guard out.count < 4_000 else { break }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                if let entry = read(String(path.dropFirst(base.count + 1))) { out.append(entry) }
            }
            return out
        }
    }

    /// Results go in the **pane**, grouped by file, with each hit's line split around the match —
    /// the file list keeps showing files. Results are an answer to a question rather than a
    /// replacement for the thing being reviewed, and a reader who loses the file list to a search
    /// cannot see where the answer sits.
    private func showSearchResults(_ result: SearchResult, scope: SearchScope) {
        state.searchHits = result.hits
        state.searchIndex = result.hits.isEmpty ? nil : 0
        pushSearch(summary: searchSummary(query: state.searchQuery, result: result, scope: scope))
    }

    private func pushSearch(summary: String) {
        var groups: [[String: Any]] = []
        for hit in state.searchHits {
            let row: [String: Any] = ["line": hit.line, "before": hit.before,
                                      "match": hit.match, "after": hit.after]
            if var last = groups.last, last["path"] as? String == hit.path {
                var hits = last["hits"] as? [[String: Any]] ?? []
                hits.append(row)
                last["hits"] = hits
                groups[groups.count - 1] = last
            } else {
                groups.append(["path": hit.path, "hits": [row]])
            }
        }
        let payload: [String: Any] = ["summary": summary, "groups": groups,
                                      "current": state.searchIndex ?? -1]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let wrapped = try? JSONSerialization.data(withJSONObject: [json]),
              let escaped = String(data: wrapped, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.diffscopeShowSearch(\(String(escaped.dropFirst().dropLast())))") { _, _ in }
        statusLabel.stringValue = summary
    }

    @objc private func nextHit() { stepHit(by: 1) }
    @objc private func previousHit() { stepHit(by: -1) }

    /// Moving between hits moves the marker and says where it is. It does **not** open the file:
    /// opening replaces the pane the results are in, and a reader stepping through nine matches
    /// would lose the list at the first one. ⌘⏎ opens the hit under the marker, in the editor, at
    /// its line.
    private func stepHit(by delta: Int) {
        guard !state.searchHits.isEmpty else {
            statusLabel.stringValue = "no search results"
            return
        }
        let count = state.searchHits.count
        let current = state.searchIndex ?? 0
        // No wrapping, for the reason ⌘] does not wrap in the file list: the end of a list is a
        // fact worth feeling.
        let next = max(0, min(count - 1, current + delta))
        state.searchIndex = next
        let hit = state.searchHits[next]
        pushSearch(summary: "\(hit.path):\(hit.line) · hit \(next + 1) of \(count)")
    }

    @objc private func modeChanged() {
        state.mode = PresentationMode.displayOrder[modeControl.selectedSegment]
        // Choosing a mode by hand ends the ⌥⌘V excursion: the reader has said where they want to
        // be, and a return key that took them somewhere else would be worse than none.
        rawRegionReturn = nil
        rawRegionMenuItem?.state = .off
        if let file = state.selectedFile { showDiff(for: file) }
    }

    func reloadFiles() {
        guard let repository = state.selectedRepository else { return }
        var baseRef: String?
        state.mergeBaseRev = nil
        if state.scope == .branchVsMergeBase, let resolved = repository.base.ref {
            baseRef = repository.baseRefUsed ?? resolved
            if let ref = baseRef,
               let result = try? GitRunner().run(.mergeBase(ref, "HEAD"), in: repository.url),
               result.succeeded {
                state.mergeBaseRev = result.trimmedOutput
            }
        }
        // `12-…` §3: scopes that cannot work are **disabled with a stated reason, never hidden**.
        // Leaving them enabled lets the reader click into a dead end and makes the control lie
        // about what is available.
        var unavailable: [String] = []
        for (index, scope) in ComparisonScope.allCases.enumerated() {
            let state = scopes.availability(of: scope, head: repository.head, base: repository.base)
            scopeControl.setEnabled(state == .available, forSegment: index)
            if case let .unavailable(reason) = state {
                scopeControl.setToolTip("\(scope.title) — \(reason)", forSegment: index)
                unavailable.append("\(scope.title) — \(reason)")
            } else {
                scopeControl.setToolTip(scope.title, forSegment: index)
            }
        }

        let availability = scopes.availability(of: state.scope, head: repository.head, base: repository.base)
        if case let .unavailable(reason) = availability {
            state.files = []
            state.fileRows = []
            updateBaseBlock(for: repository)
            updatePaneHeaders()
            fileTable.reloadData()
            statusLabel.stringValue = "\(state.scope.title) unavailable — \(reason)"
            return
        }
        // A history selection names the two sides instead of the scope (DEC-061). The scope bar
        // still shows which four exist and which one is armed; the base row says what is actually
        // being compared, which is the question a reader has after picking a commit.
        if let pair = state.historyPair {
            state.files = (try? scopes.changedFiles(between: pair.old, and: pair.new,
                                                    in: repository.url)) ?? []
        } else {
            state.files = (try? scopes.changedFiles(scope: state.scope, in: repository.url, baseRef: baseRef)) ?? []
        }
        state.fileRows = fileListRows(state.files,
                                      workspacePackages: declaredWorkspacePackages(in: repository.url))
        state.groupTitles = groupHeaderTitles(state.fileRows.compactMap {
            if case let .header(key) = $0 { return key }
            return nil
        })
        state.annotations = [:]
        updatePaneHeaders()
        // DEC-092: the staging state is read before the rows are drawn, because the box in each
        // row is drawn from it. Read rather than remembered — WebStorm, the drawer and every hook
        // share this index.
        state.staging = gitState.staging(in: repository.url)
        fileTable.reloadData()
        restoreFileSelection()
        annotateFiles(of: repository)
        // DEC-010/DEC-011: the age is the signal, not the date. The application never fetches, so
        // this line is the only thing telling the reader how old the comparison actually is.
        var ageText = ""
        if state.scope == .branchVsMergeBase {
            ageText = " · " + baseSummary(
                ref: repository.baseRefUsed,
                chosenByUser: state.configuration.baseOverrides[repository.url.standardizedFileURL.path] != nil,
                committerDate: repository.baseRefCommitterDate)
        }
        // A greyed-out segment with its reason in a tooltip is the defect DEC-058 named: a tooltip
        // is invisible until pointed at, and a reader walking the window from the keyboard never
        // sees it. `12-…` §3 asks for the reason to be *stated*, so it goes on the line.
        updateBaseBlock(for: repository)
        let reasons = unavailable.isEmpty ? "" : " · unavailable: " + unavailable.joined(separator: ", ")
        comparisonLabel.stringValue = state.historyPair.map {
            scopes.historyComparisonDescription(old: $0.old, new: $0.new) + " · from History"
        // A scope with nothing in it says so, in the shape the unavailable state already uses
        // (DEC-073). *What this scope compares* is not the reader's question when the answer is
        // nothing, so the sentence takes the row rather than sitting beside it.
        } ?? (state.files.isEmpty
            ? ChromeLabels.scopeState(shortTitle: state.scope.shortTitle,
                                      emptyDescription: state.scope.emptyDescription)
            : state.scope == .branchVsMergeBase
            ? baseSummary(ref: repository.baseRefUsed,
                          chosenByUser: state.configuration.baseOverrides[repository.url.standardizedFileURL.path] != nil,
                          committerDate: repository.baseRefCommitterDate)
            : state.scope.comparisonDescription)
        markRefreshed()
        statusLabel.stringValue = "\(state.files.count) files · \(state.scope.title)\(ageText)\(reasons)"
        // The same sentence, into the page (the adopted design's `SHOWING` row). The diff pane is
        // where a reader is actually looking, and until now *what is being compared* was only in
        // the chrome above it — a fact stated once, far from the thing it describes.
        //
        // Pushed rather than derived: `comparisonDescription` and `baseSummary` are composed in the
        // Git layer precisely so a sentence the interface assembles cannot go unchecked, and
        // rebuilding it in JavaScript would be a second voice for the same fact.
        pushComparison(comparisonLabel.stringValue)
    }

    private func pushComparison(_ text: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: [text]),
              let argument = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.diffscopeSetComparison(\(argument.dropFirst().dropLast()))") { _, _ in }
    }

    private func showDiff(for file: ChangedFile, restoringStop stop: Int? = nil) {
        state.selectedFile = file
        if let json = try? JSONSerialization.data(withJSONObject: [file.path]),
           let argument = String(data: json, encoding: .utf8) {
            webView.evaluateJavaScript(
                "window.diffscopeSetFile(\(argument.dropFirst().dropLast()))") { _, _ in }
        }
        render(file: file, previousAnchor: nil, restoringStop: stop)
    }

    /// A refresh asks the renderer where the reader is *before* rebuilding, because the answer is
    /// about the document currently on screen (DEC-034). The engine then decides where that anchor
    /// lands in the new model; the renderer only executes the decision.
    private func refreshCurrentFile() {
        guard let file = state.selectedFile else { return }
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeAnchorState())") { value, _ in
            var anchor: RefreshAnchor?
            if let text = value as? String, let data = text.data(using: .utf8) {
                anchor = try? JSONDecoder().decode(RefreshAnchor.self, from: data)
            }
            self.render(file: file, previousAnchor: anchor)
        }
    }

    private func render(file: ChangedFile, previousAnchor: RefreshAnchor?, restoringStop: Int? = nil) {
        guard let repository = state.selectedRepository else { return }
        let mode = state.mode
        // One at a time, and the newest wins. Walking a 63-file list at keyboard speed used to start
        // a render per keystroke on the concurrent queue: they raced inside the shared tree-sitter
        // parser (fixed in `TSXParser`), and the ones that survived pushed diffs for files the
        // reader had already walked past. Serialising is also the honest model of the work — only
        // the file now selected is worth rendering.
        renderQueue.async {
            let history = self.state.historyPair
            guard let pair = history.map({ selection in
                try? self.scopes.pinnedPair(for: file, between: selection.old, and: selection.new,
                                            in: repository.url)
            }) ?? (try? self.scopes.pinnedPair(
                for: file, scope: self.state.scope, in: repository.url,
                mergeBaseRev: self.state.mergeBaseRev)) else { return }
            // DEC-049: the file was still being written, so these bytes may be half of one
            // version and half of another. Showing them with a warning would still be showing a
            // blend — the watcher fires again when the writing stops.
            guard pair.stable else {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue =
                        "\(file.path) is being written — showing it once the file settles"
                }
                return
            }
            // DEC-063: a file that renders is compared by being drawn. Decided from the bytes as
            // well as the name, because a `.png` that is not a PNG is a placeholder, an LFS
            // pointer or a rename that outran its content — and drawing it would show an empty
            // frame with no explanation.
            let kind = renderableKind(path: file.path,
                                      bytes: pair.newBytes.isEmpty ? pair.oldBytes : pair.newBytes)
            if kind.rendersAsImage {
                DispatchQueue.main.async {
                    self.showRendered(file: file, oldBytes: pair.oldBytes, newBytes: pair.newBytes,
                                      kind: kind)
                }
                return
            }

            // DEC-028/DEC-041: asked here, on the file actually being shown, so an active filter is
            // disclosed where the discrepancy it causes is visible.
            let filterState = self.filters.state(for: file.path, in: repository.url)
            let external = filterState.disclosure.map { [Degradation.filterActive(reason: $0)] } ?? []
            let outcome = self.buildModel(path: file.path, old: pair.oldBytes, new: pair.newBytes,
                                          mode: mode, external: external)
            let render = buildRenderModel(
                model: outcome.model, pinOld: pair.oldHash, pinNew: pair.newHash,
                mode: mode.rawValue, pathTaken: outcome.pathTaken, parser: outcome.parser,
                validation: outcome.validation, notices: outcome.notices,
                previousAnchor: previousAnchor
            )
            guard let json = try? encodeRenderModel(render) else { return }
            DispatchQueue.main.async {
                // The reader may have moved on while this was being built. Pushing it anyway would
                // put one file's diff under another file's name.
                guard self.state.selectedFile?.path == file.path else { return }
                let position = self.filePositionText().map { "\($0) · " } ?? ""
                self.statusLabel.stringValue = "\(position)\(file.path) · \(outcome.summary)"
                if self.rendererReady { self.push(json) } else { self.pendingModel = json }
                // ⌥⌘V (DEC-057): the stop is restored *after* the new model is in the document,
                // because the stop list belongs to the model that is on screen.
                if let stop = restoringStop {
                    self.webView.evaluateJavaScript(
                        "JSON.stringify(window.diffscopeCommand(\"goToStopIndex:\(stop)\"))"
                    ) { value, _ in
                        guard let text = value as? String, text != "null" else { return }
                        let where_ = self.rawRegionReturn == nil ? "back to \(mode.rawValue)" : "raw"
                        self.statusLabel.stringValue =
                            "\(position)\(file.path) · \(where_) at this region · \(text)"
                    }
                }
            }
        }
    }

    /// DEC-007/DEC-027: one stream, on the repository being looked at, `node_modules` excluded.
    private func startWatching(_ repository: RepositorySnapshot) {
        watcher?.stop()
        let watcher = RepositoryWatcher(root: repository.url) { [weak self] signal in
            self?.handle(signal, in: repository)
        }
        self.watcher = watcher
        if watcher.start() {
            watchState = .watching
        } else {
            // Standing, not transient (DEC-075): the old message was overwritten by the next thing
            // that happened, and the reader was left with a window that had quietly stopped
            // following the disk.
            watchState = .unavailable("auto-refresh unavailable for \(repository.displayName)")
            statusLabel.stringValue = "auto-refresh unavailable for \(repository.displayName)"
        }
        updateWatchLabel()
        for diagnostic in watcher.diagnostics {
            statusLabel.stringValue = diagnostic.message
        }
    }

    private func handle(_ signal: WatchSignal, in repository: RepositorySnapshot) {
        guard state.selectedRepository?.url == repository.url else { return }
        switch signal {
        case .changed, .rescan:
            let selected = state.selectedFile
            reloadFiles()
            // Selection survives where the file is still in scope, and says so where it is not.
            // Against the drawn rows, not the flat file array: with headers interleaved the two
            // indices differ, and restoring the flat index would land the reader on a neighbour.
            if let selected, state.files.contains(where: { $0.path == selected.path }) {
                if let row = state.fileRows.firstIndex(where: { $0.file?.path == selected.path }) {
                    fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                refreshCurrentFile()
            } else if selected != nil {
                statusLabel.stringValue = "\(selected!.path) is no longer in \(state.scope.title)"
            }
            if signal == .rescan {
                statusLabel.stringValue += " · rescanned after dropped file-system events"
            }
        case .rootChanged:
            statusLabel.stringValue = "\(repository.displayName) was moved or renamed — auto-refresh stopped"
            watchState = .stopped("\(repository.displayName) was moved or renamed")
            updateWatchLabel()
            watcher?.stop()
        }
    }

    struct ModelOutcome {
        let model: DiffModel
        let validation: ValidationResult
        let notices: [String]
        let summary: String
        /// Which path produced this model, as opposed to which mode asked for it. The two disagree
        /// exactly when a structural run was withheld or discarded, and `23b-…` §2 records what
        /// happened while only the mode was carried: the pill said `structural` beside a notice
        /// saying structural analysis was unavailable.
        let pathTaken: String
        /// `12-…` §5.2's parser-state indicator, decided where the parse outcome is known.
        let parser: ParserStateReport
    }

    /// Raw is never a degraded structural run: it is its own path on the same pinned pair.
    /// A structural result that fails validation is discarded whole and replaced by raw,
    /// carrying a notice — a fallback that is not visible is an INV-4 violation.
    ///
    /// - Parameter external: conditions detected outside the syntax layer, F8 above all (DEC-051).
    ///   They are disclosed in **every** mode, because a filter changes what the compared bytes
    ///   mean — Raw is not exempt from an explanation it is the reason for.
    func buildModel(path: String, old: [UInt8], new: [UInt8], mode: PresentationMode,
                    external: [Degradation] = []) -> ModelOutcome {
        let outside = Degradation.mostConservative(external)

        func rawOutcome(notices: [String], summary: String,
                        parser: ParserStateReport) -> ModelOutcome {
            let model = trivialModel(oldBytes: old, newBytes: new)
            return ModelOutcome(model: model, validation: validate(model),
                                notices: notices, summary: summary,
                                pathTaken: "raw", parser: parser)
        }

        guard mode.usesStructure else {
            return rawOutcome(notices: outside.map { [$0.notice] } ?? [],
                              summary: outside.map { "plain text — \($0.reason)" } ?? "plain text",
                              parser: ParserStateReport.of(structuralRequested: false,
                                                           structuralUsed: false,
                                                           degradation: outside))
        }

        let result = structuralDiff(oldPath: path, oldBytes: old, newPath: path, newBytes: new,
                                    parser: parser, external: external)
        if result.stats.usedFallback {
            let degradation = result.stats.degradation
                ?? .parseFailure(reason: "structural analysis unavailable")
            return ModelOutcome(model: result.model, validation: validate(result.model),
                                notices: [degradation.notice],
                                summary: "plain text — \(degradation.reason)",
                                pathTaken: "raw", parser: result.stats.parserState)
        }

        let validation = validate(result.model)
        guard validation.passed else {
            let discarded = Degradation.invariantViolation(reason: validation.summary)
            return rawOutcome(
                notices: [discarded.notice],
                summary: "plain text — structural result discarded",
                // The file parsed. What failed was the check afterwards, and saying "not parsed"
                // here would make the indicator report the wrong stage of the pipeline — the whole
                // reason §5.2 lists parser state separately from fallback marking.
                parser: ParserStateReport(state: "parsed",
                                          detail: "structural result discarded after parsing")
            )
        }

        let stats = result.stats
        var summary = "structural · \(stats.anchors) anchors"
        if stats.movedSegments > 0 { summary += " · \(stats.movedSegments) moved" }
        if stats.formattingOnlySegments > 0 { summary += " · \(stats.formattingOnlySegments) formatting-only" }
        if stats.behaviorAffectingSegments > 0 { summary += " · \(stats.behaviorAffectingSegments) reordered" }
        if stats.invisibleSegments > 0 { summary += " · \(stats.invisibleSegments) invisible" }
        if stats.ambiguities > 0 { summary += " · \(stats.ambiguities) ambiguous" }
        // A structural run that succeeded can still carry a condition worth disclosing: byte-equal
        // sides under an active filter are shown as unchanged while the file list says changed.
        let carried = stats.degradation ?? outside
        return ModelOutcome(model: result.model, validation: validation,
                            notices: carried.map { [$0.notice] } ?? [],
                            summary: carried.map { "\(summary) · \($0.reason)" } ?? summary,
                            pathTaken: "structural", parser: stats.parserState)
    }

    private func push(_ json: String) {
        let escaped = String(decoding: (try? JSONEncoder().encode(json)) ?? Data("\"\"".utf8), as: UTF8.self)
        webView.evaluateJavaScript("window.diffscopeRender(\(escaped))") { _, error in
            if let error { self.statusLabel.stringValue = "render error: \(error)" }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === repoTable ? state.repositories.count : state.fileRows.count
    }

    /// Returns a cell view with the label constrained inside it.
    ///
    /// A bare `NSTextField` was returned here before, and **every row rendered blank** — the label
    /// was left at zero width, so a middle-truncating label truncated the whole string away. The
    /// window looked like a working application with an empty repository list, which is why it
    /// survived: nothing crashed, the counts in the status line were right, and the check suite
    /// cannot see the screen.
    /// Rows as the adopted design draws them: columns rather than one string.
    ///
    /// One string was enough while a row said three things; it says six now — kind, package, file,
    /// note, and two counts — and a reader comparing two rows has to be able to find the same fact
    /// in the same place. The label built here is still the whole row's `toolTip`, so nothing the
    /// columns clip is lost.
    func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular,
                       _ colour: NSColor = Theme.ink) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = Theme.font(size, weight: weight)
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func row(_ fields: [NSTextField], in cell: NSTableCellView,
                     leading: CGFloat = Theme.space2) -> NSStackView {
        let stack = NSStackView(views: fields)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = Theme.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                            constant: -Theme.space2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return stack
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        if tableView === repoTable {
            return repositoryCell(cell, row: row)
        }
        return fileCell(cell, row: row)
    }

    private func repositoryCell(_ cell: NSTableCellView, row: Int) -> NSView {
        let snapshot = state.repositories[row]
        let name = state.repositoryLabels[snapshot.url.path] ?? snapshot.displayName

        if reposCollapsed {
            // Three letters, because two do not separate `web` from `wea`, and a dot for "there is
            // work in here". The full row is one hover — and one ⌃⌘1 — away.
            let rail = label(Theme.textSizeTiny, .semibold, Theme.ink)
            rail.stringValue = String(name.prefix(3)) + (snapshot.uncommittedCount > 0 ? "•" : "")
            rail.lineBreakMode = .byClipping
            _ = self.row([rail], in: cell)
            cell.toolTip = "\(name) — \(snapshot.head.displayText), "
                + "\(snapshot.uncommittedCount) uncommitted"
            return cell
        }

        let title = label(Theme.textSizeSmall, .semibold, Theme.ink)
        title.stringValue = name
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        // `12-…` §2 lists the branch as **displayed**, and it was in the tooltip only until DEC-058.
        // Italic for the two unusual head states, which is the design's way of saying *this is not
        // an ordinary branch* without spending a word on it.
        let head = label(Theme.textSizeSmall, .regular, Theme.inkQuiet)
        head.stringValue = snapshot.head.displayText
        if case .onBranch = snapshot.head {} else {
            head.font = NSFontManager.shared.convert(head.font!, toHaveTrait: .italicFontMask)
        }

        let files = label(Theme.textSizeTiny, .regular,
                          snapshot.uncommittedCount == 0 ? Theme.inkFaint : Theme.inkQuiet)
        files.stringValue = snapshot.uncommittedCount == 0
            ? "clean" : "\(snapshot.uncommittedCount) files"

        // The ahead-count, and the one chip in the window that is not a number: unknown is said,
        // never rendered as 0 (`12-…` §2). Dashed, because the difference has to survive greyscale.
        let ahead = ChipView(text: snapshot.aheadCount.map { "↑\($0)" } ?? "↑ unknown",
                             dashed: snapshot.aheadCount == nil,
                             emphasis: snapshot.aheadCount == nil)

        let path = label(Theme.textSizeTiny, .regular, Theme.inkFaint)
        path.stringValue = snapshot.url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        path.lineBreakMode = .byTruncatingMiddle

        let top = NSStackView(views: [title, head, spacerView(), files, ahead])
        top.orientation = .horizontal
        // Centred, not baseline-aligned: a chip is a drawn view with no baseline to align to, and
        // a stack asked for one puts it on a line of its own.
        top.alignment = .centerY
        top.spacing = Theme.space2
        let stack = NSStackView(views: [top, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.space2),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.space2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        // DEC-086: the convention rides with the count it is about. `12-…` §2 asks the count to
        // state its convention; it does so where the question is asked rather than in a caption
        // under the whole list.
        cell.toolTip = "\(snapshot.url.path)\n\(snapshot.head.displayText)\n"
            + "\(snapshot.baseRefUsed ?? "base: prompt")\n"
            + RepositoryReader.uncommittedCountConvention
        return cell
    }

    private func fileCell(_ cell: NSTableCellView, row: Int) -> NSView {
        switch state.fileRows[row] {
        case let .header(key):
            let header = label(Theme.textSizeTiny, .semibold, Theme.inkQuiet)
            // The short, front-anchored form (DEC-074). Truncating the key from the head removed
            // the components that tell one group from another — `…/components/nested`, nine times.
            header.stringValue = filesCollapsed ? "···" : (state.groupTitles[key] ?? key)
            header.lineBreakMode = .byTruncatingTail
            _ = self.row([header], in: cell)
            // The path in full, where nothing else in the row carries it.
            cell.toolTip = key
            return cell

        case let .file(file, display):
            let annotation = state.annotations[file.path]
            let count = state.counts[file.path]
            if filesCollapsed {
                // One bar per file, carrying the kind glyph: the design drew these bars
                // distinguished by hue alone, which DEC-035 forbids. The bar's *length* is the
                // design's other idea and now has a number behind it.
                let spine = label(Theme.textSizeTiny, .regular, Theme.kind(file.kind))
                let size = count.map { min(4, max(1, ($0.added + $0.deleted) / 12 + 1)) } ?? 1
                spine.stringValue = "\(file.kind.glyph)\(String(repeating: "▍", count: size))"
                spine.lineBreakMode = .byClipping
                _ = self.row([spine], in: cell)
                cell.toolTip = "\(file.path) — \(file.kind.rawValue)"
                    + (count.map { " \($0.text)" } ?? "")
                return cell
            }

            let glyph = label(Theme.textSizeSmall, .semibold, Theme.kind(file.kind))
            glyph.stringValue = file.kind.glyph
            glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
            glyph.widthAnchor.constraint(equalToConstant: Theme.space6 - Theme.space2).isActive = true

            let name = label(Theme.textSizeSmall, .regular, Theme.ink)
            name.stringValue = display
            name.lineBreakMode = .byTruncatingHead

            // The note is a chip, not a word in the middle of a row: it is a different kind of
            // fact from the path beside it, and the design draws it as one.
            let note: NSView = annotation.map { ChipView(text: $0.badge) } ?? spacerView()

            // Counts on the right, where the eye can compare them down the column instead of
            // hunting for them at the end of paths of different lengths.
            let counts = label(Theme.textSizeTiny, .regular, Theme.inkQuiet)
            counts.stringValue = count?.text ?? ""
            counts.setContentCompressionResistancePriority(.required, for: .horizontal)
            counts.alignment = .right

            // The inclusion box (DEC-092). Only where staging is a question the scope can answer:
            // `vs base` compares two commits, and a box beside a file in it would be offering to
            // stage something that is already committed.
            let box = CheckButton(title: "", target: self, action: #selector(toggleInclusion(_:)))
            box.isBordered = false
            box.setButtonType(.momentaryChange)
            box.inclusion = inclusion(of: file.path)
            box.tag = row
            box.toolTip = box.inclusion == .partial
                ? "Part of this file is staged — click to stage the rest"
                : (box.inclusion == .all ? "Staged — click to take it out of the commit"
                                         : "Not staged — click to put it in the commit")
            let staging: NSView = state.scope == .branchVsMergeBase ? spacerView() : box

            let stack = NSStackView(views: [staging, glyph, name, spacerView(), note, counts])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = Theme.space2
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.space2),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.space2),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.toolTip = file.path + (count.map { " · \($0.text)" } ?? "")
            return cell
        }
    }

    func spacerView() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === fileTable else { return true }
        return RowNavigation.isSelectable(rows: state.fileRows, row: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFocusRings()
        guard let table = notification.object as? NSTableView else { return }
        if table === repoTable {
            guard table.selectedRow >= 0 else { return }
            let repository = state.repositories[table.selectedRow]
            state.selectedRepository = repository
            titleRepositoryLabel.stringValue = state.repositoryLabels[repository.url.path]
                ?? repository.displayName
            titlePathLabel.stringValue = repository.url.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            startWatching(repository)
            followTerminalIfPossible(repository)
            reloadFiles()
            refreshGitState()
        } else {
            guard table.selectedRow >= 0, table.selectedRow < state.fileRows.count,
                  let file = state.fileRows[table.selectedRow].file else { return }
            showDiff(for: file)
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
