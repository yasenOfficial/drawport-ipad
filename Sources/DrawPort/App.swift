import UIKit
import PencilKit

@main
final class App: UIResponder, UIApplicationDelegate {
    // xtool's SwiftPM IPA currently has no UIApplicationSceneManifest. On iPadOS 18
    // provide a legacy UIWindow so the existing DrawController actually appears;
    // preserve DrawScene for builds that opt into UIKit scenes later.
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") == nil {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = DrawController()
            window.makeKeyAndVisible()
            self.window = window
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        (window?.rootViewController as? DrawController)?.becomeForeground()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        (window?.rootViewController as? DrawController)?.enterBackground()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        (window?.rootViewController as? DrawController)?.enterBackground()
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DocumentOrientation.saved().supportedInterfaceOrientations
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Main", sessionRole: session.role)
        config.delegateClass = DrawScene.self
        return config
    }
}

final class DrawScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = DrawController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? DrawController)?.becomeForeground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? DrawController)?.enterBackground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? DrawController)?.enterBackground()
    }
}

enum ToolbarPosition: String, CaseIterable {
    case bottom, top, right, left

    var isVertical: Bool { self == .left || self == .right }
    var comesFirst: Bool { self == .top || self == .left }
    var title: String { rawValue.capitalized }

    static func saved(in defaults: UserDefaults = .standard) -> ToolbarPosition {
        ToolbarPosition(rawValue: defaults.string(forKey: "toolbarPosition") ?? "") ?? .left
    }
}

enum DocumentOrientation: String, CaseIterable {
    case portrait, landscape

    static let defaultsKey = "documentOrientation"

    init(metadata: String?) {
        self = DocumentOrientation(rawValue: metadata ?? "") ?? .portrait
    }

    static func saved(in defaults: UserDefaults = .standard) -> DocumentOrientation {
        DocumentOrientation(metadata: defaults.string(forKey: defaultsKey))
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: String { rawValue.capitalized }
    var symbol: String { self == .portrait ? "rectangle.portrait" : "rectangle" }
    var supportedInterfaceOrientations: UIInterfaceOrientationMask { self == .portrait ? .portrait : .landscapeRight }
    var interfaceOrientation: UIInterfaceOrientation { self == .portrait ? .portrait : .landscapeRight }
    var pageSize: CGSize {
        self == .portrait ? CGSize(width: 1024, height: 1361) : CGSize(width: 1361, height: 1024)
    }

    func fits(_ metadata: String?) -> Bool { self == DocumentOrientation(metadata: metadata) }
}

// Pencil-only drawingPolicy does not disable PencilKit's finger editing menus.
// Keep the drawing recognizer and first-responder behavior intact for Pencil input.
final class DrawingCanvas: PKCanvasView {
    var selectionEditingEnabled = false {
        didSet {
            if selectionEditingEnabled {
                for recognizer in suppressedPresses.allObjects { recognizer.isEnabled = true }
                suppressedPresses.removeAllObjects()
            } else {
                endEditing(true)
                disableSelectionPresses(in: self)
            }
        }
    }
    private let suppressedPresses = NSHashTable<UIGestureRecognizer>.weakObjects()

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        selectionEditingEnabled ? .default : .none
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard selectionEditingEnabled,
              ["cut:", "copy:", "paste:", "delete:", "duplicate:"].contains(NSStringFromSelector(action)) else { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !selectionEditingEnabled { disableSelectionPresses(in: self) }
    }

    private func disableSelectionPresses(in view: UIView) {
        for recognizer in view.gestureRecognizers ?? [] {
            if recognizer is UILongPressGestureRecognizer && recognizer !== drawingGestureRecognizer && recognizer.isEnabled {
                suppressedPresses.add(recognizer)
                recognizer.isEnabled = false
            }
        }
        for child in view.subviews { disableSelectionPresses(in: child) }
    }
}

// Fit existing ink uniformly, then extend the drawable paper to the viewport's
// edges instead of letterboxing it. Saved stroke coordinates are never changed.
final class PageViewport: UIView {
    let surface = UIView()
    var pageSize = CGSize.zero { didSet { if pageSize != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = UIColor(white: 0.96, alpha: 1)
        surface.backgroundColor = .white
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pageSize.width > 0, pageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        surface.bounds = CGRect(x: 0, y: 0, width: bounds.width / scale, height: bounds.height / scale)
        surface.transform = CGAffineTransform(scaleX: scale, y: scale)
        surface.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// Only present while Carry is armed. A completed single tap (finger or Pencil)
// is consumed here, never delivered to PencilKit's editing/drawing recognizers.
final class CarryTapOverlay: UIView {
    var onTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "carryTapOverlay"
        isMultipleTouchEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                 NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        tap.cancelsTouchesInView = true
        tap.requiresExclusiveTouchType = true
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onTap?(gesture.location(in: self))
    }
}

final class PaperView: UIView {
    static let spacing = PaperDrawing.spacing
    var pattern = 0 { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        PaperDrawing.draw(context: ctx, size: bounds.size, pattern: pattern)
    }
}

// Also usable by offscreen composites without creating a UIView off main actor.
enum PaperDrawing {
    static let spacing: CGFloat = 36

    static func draw(context ctx: CGContext, size: CGSize, pattern: Int) {
        // All paper is blank in this port, including previews and exports.
        // Preserve the old `Page.background` field for lossless document decoding.
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

final class DrawController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIColorPickerViewControllerDelegate {
    private let store: Store
    private let injectedAIClient: AIClient?
    private let injectedSyncClient: SyncClient?
    private let injectedAIJournal: AINetworkJournal?
    private let syncDefaults: UserDefaults
    private let onError: ((Error, String) -> Void)?
    private(set) var lastSyncedSources: [UUID: SyncPackage] = [:]

    init(store: Store? = nil, aiClient: AIClient? = nil, syncClient: SyncClient? = nil, aiJournal: AINetworkJournal? = nil,
         syncDefaults: UserDefaults = .standard, onError: ((Error, String) -> Void)? = nil) {
        self.store = store ?? Self.makeStore()
        injectedAIClient = aiClient
        injectedSyncClient = syncClient
        injectedAIJournal = aiJournal
        self.syncDefaults = syncDefaults
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeStore() -> Store {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            let fixtureID = ProcessInfo.processInfo.environment["DRAW_UI_TEST_FIXTURE_ID"]
            let directoryName = fixtureID.map { "Draw-UI-Tests-" + $0 } ?? "Draw-UI-Tests"
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(directoryName)
            let store = Store(directory: directory)
            if store.notebooks.isEmpty {
                let book = try! store.addNotebook("UI Test Notebook")
                let points = [CGPoint(x: 60, y: 130), CGPoint(x: 160, y: 130)].enumerated().map { i, location in
                    PKStrokePoint(location: location, timeOffset: Double(i) / 10, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let stroke = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                try! store.commit(book: book, page: store.notebook(book)!.pages[0].id, drawing: PKDrawing(strokes: [stroke]))
            }
            return store
        }
        #endif
        return Store()
    }
    private var homeFolderID: UUID?
    private var bookID: UUID?
    private var pageID: UUID?
    private weak var overviewScroll: UIScrollView?
    private var selectedPage: UUID?
    private var deletedMode = false
    private let paper = PaperView()
    private let canvas = DrawingCanvas()
    private var pageViewport: PageViewport?
    private let content = UIView()
    private let toolbar = UIView()
    private var currentInk = 6
    private var currentTool = UserDefaults.standard.integer(forKey: "tool") // 0 pen, 1 retired eraser, 2 marker, 3 lasso
    private var lastInkTool = UserDefaults.standard.integer(forKey: "lastInkTool") == 2 ? 2 : 0
    private var rulerEnabled = false
    private var widthIndex = 1
    private var markerWidthIndex = 6
    private let markerWidths: [CGFloat] = [8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 35, 40, 45, 50, 55, 60]
    private let widths: [CGFloat] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 7, 8, 9, 10, 11, 12]
    private var inkColors: [UIColor] = [.black, .systemBlue, .systemGreen, .systemOrange, .systemYellow, .systemRed, UIColor(red: 0, green: 0.2, blue: 0.8, alpha: 1), QuestionInk.color]
    private var colorSwatches: [Int: UIView] = [:]
    private var editingColorIndex: Int?
    private var squeezePalette: UIView?
    private var eraserByPixel = UserDefaults.standard.bool(forKey: "eraserByPixel")
    private var shapeModeEnabled = false
    private var carryOverlay: CarryTapOverlay?
    private var quickArmed = false
    private var quickEraserQueued = false
    private var usingTool = false
    private var loadingDrawing = false
    private var savedDrawing = PKDrawing()
    private var pageInkSize = CGSize.zero
    private var documentPageSize = DocumentOrientation.portrait.pageSize
    private var saveWork: DispatchWorkItem?
    private var colorSelection: Set<UUID>?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var selectionKeyboardVisible = false
    #if DEBUG && targetEnvironment(simulator)
    private var keyboardDebugWillShow = 0, keyboardDebugDidShow = 0, keyboardDebugDidHide = 0
    private var keyboardDebugSelectionChanges = 0, keyboardDebugToolEnds = 0
    private var keyboardDebugAttempts = 0, keyboardDebugEnded = 0, keyboardDebugGlobalResigns = 0
    #endif
    private var buttons: [UIButton] = []
    private var syncMessage = ""
    private let syncStatus = UILabel()
    private let aiObjects = AIObjectsView()
    private var aiButton: UIButton?
    private var aiJournal: AINetworkJournal?
    private lazy var aiClient = injectedAIClient ?? AIClient(endpoint: DrawEndpoints.configured("ai"), token: DrawEndpoints.token)
    private lazy var syncClient = injectedSyncClient ?? SyncClient(endpoint: DrawEndpoints.configured("sync"), token: DrawEndpoints.token)
    private let aiChannel = AIForegroundChannel()
    private var aiForeground = false
    private var foregroundGeneration = 0
    private var aiRegistration: Task<Void, Never>?
    private var aiReadyChecks: [UUID: Task<Void, Never>] = [:]
    private var readyCheckedDocument: UUID?
    private var busyDocuments = Set<UUID>()
    private var aiPolls: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var aiOperations: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var syncInProgress = false


    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        if let saved = UserDefaults.standard.array(forKey: "customInkColors") as? [[Double]], saved.count == inkColors.count {
            for (index, components) in saved.enumerated() where components.count == 3 && components.allSatisfy({ (0...1).contains($0) }) {
                inkColors[index] = UIColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
            }
        }
        do { aiJournal = try injectedAIJournal ?? AINetworkJournal() }
        catch { DispatchQueue.main.async { self.failure(error) } }
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") && ProcessInfo.processInfo.arguments.contains("--ui-test-finger-drawing") {
            canvas.drawingPolicy = .anyInput
        }
        #endif
        canvas.accessibilityIdentifier = "drawingCanvas"
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.addInteraction(UIPencilInteraction(delegate: self))
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        syncStatus.heightAnchor.constraint(equalToConstant: 36).isActive = true
        if currentTool == 1 { selectTool(lastInkTool) }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                self.selectionKeyboardVisible = true
                #if DEBUG && targetEnvironment(simulator)
                if notification.name == UIResponder.keyboardWillShowNotification { self.keyboardDebugWillShow += 1 }
                else { self.keyboardDebugDidShow += 1 }
                #endif
                // Preserve the original WillShow-time dismissal. Deferring only
                // this attempt can miss UIKit's keyboard presentation transaction.
                self.endSelectionKeyboardEditing()
                self.dismissSelectionKeyboard()
            })
        }
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.selectionKeyboardVisible = false
            #if DEBUG && targetEnvironment(simulator)
            self.keyboardDebugDidHide += 1
            #endif
            self.updateKeyboardDiagnostics()
        })
        updateKeyboardDiagnostics()
        applyTool()
        showHome()
        #if DEBUG
        if let book = store.notebooks.first {
            if ProcessInfo.processInfo.arguments.contains("--preview") {
                bookID = book.id
                openPage(book.currentPage ?? book.pages.first?.id)
            } else if ProcessInfo.processInfo.arguments.contains("--overview") {
                bookID = book.id
                showOverview()
            }
        }
        #endif
        if let error = store.loadError {
            DispatchQueue.main.async { self.failure(error) }
        }
    }

    deinit {
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        DocumentOrientation.saved().supportedInterfaceOrientations
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        DocumentOrientation.saved().interfaceOrientation
    }

    // UIKit must allow rotation to honor explicit geometry requests. The single
    // supported axis prevents device motion from changing the chosen orientation.
    override var shouldAutorotate: Bool { true }

    func requestManualOrientation() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Also fit ink made in the extra area exposed by a different toolbar edge.
        // Capture its extent only when opening the page. Editing and history
        // navigation must keep the same scale, origin and Pencil coordinate mapping.
        pageViewport?.pageSize = CGSize(width: max(documentPageSize.width, pageInkSize.width),
                                       height: max(documentPageSize.height, pageInkSize.height))
    }

    private func clear() {
        squeezePalette?.removeFromSuperview()
        squeezePalette = nil
        cancelCarry()
        saveWork?.cancel()
        colorSelection = nil
        rulerEnabled = false
        canvas.isRulerActive = false
        canvas.selectionEditingEnabled = false
        pageViewport = nil
        aiButton = nil
        content.removeFromSuperview()
        toolbar.removeFromSuperview()
        content.subviews.forEach { $0.removeFromSuperview() }
        toolbar.subviews.forEach { $0.removeFromSuperview() }
        buttons = []
        colorSwatches = [:]
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .black
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.adjustsImageSizeForAccessibilityContentSizeCategory = false
        return b
    }

    private func row(_ items: [UIView], height: CGFloat = 52) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: items)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        if height > 0 { stack.heightAnchor.constraint(equalToConstant: height).isActive = true }
        return stack
    }

    private func vertical(_ children: [UIView], axis: NSLayoutConstraint.Axis = .vertical) {
        let stack = UIStackView(arrangedSubviews: children)
        stack.axis = axis
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func mutate(_ action: () throws -> Void) {
        do { try action() } catch { failure(error) }
    }

    private func failure(_ error: Error) {
        if let onError { onError(error, "Could not save"); return }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Could not save", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: false)
    }

    private func showHome() {
        bookID = nil
        pageID = nil
        documentOpened(nil)
        clear()
        let head = button("plus", label: "New document") { [weak self] in self?.askName() }
        let sync = button("arrow.triangle.2.circlepath", label: "Sync with DGX") { [weak self] in self?.syncWithServer() }
        let folder = store.folders.first { $0.id == homeFolderID }
        if folder == nil { homeFolderID = nil }
        let title = UILabel()
        title.text = homeFolderID.flatMap { Folder.path(of: $0, in: store.folders) } ?? "Documents"
        title.font = .preferredFont(forTextStyle: .title1)
        let settings = button("gearshape", label: "Settings") { [weak self] in self?.showSettings() }
        let newFolder = button("folder.badge.plus", label: "New folder") { [weak self] in self?.askFolderName() }
        var controls: [UIView] = [newFolder, title, settings, sync, head]
        if let folder {
            let parentName = folder.parentID.flatMap { Folder.path(of: $0, in: store.folders) } ?? "Documents"
            let back = button("chevron.left", label: "Back to \(parentName)") { [weak self] in
                self?.homeFolderID = folder.parentID
                self?.showHome()
            }
            controls.insert(back, at: 0)
        }
        let top = row(controls, height: 56)
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 12
        for folder in store.folders.filter({ $0.parentID == homeFolderID }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let b = UIButton(type: .system)
            b.contentHorizontalAlignment = .leading
            b.setImage(UIImage(systemName: "folder"), for: .normal)
            let count = store.notebooks.filter { $0.folderID == folder.id }.count
            b.setTitle("  \(folder.name)    ·    \(count) document\(count == 1 ? "" : "s")", for: .normal)
            b.titleLabel?.font = .preferredFont(forTextStyle: .title3)
            b.tintColor = .black
            b.accessibilityLabel = "Open folder \(folder.name)"
            b.heightAnchor.constraint(equalToConstant: 58).isActive = true
            b.addAction(UIAction { [weak self] _ in self?.homeFolderID = folder.id; self?.showHome() }, for: .touchUpInside)
            let options = button("ellipsis", label: "Folder options \(folder.name)") {}
            options.widthAnchor.constraint(equalToConstant: 54).isActive = true
            var destinations: [UIMenuElement] = [UIAction(title: "Documents", state: folder.parentID == nil ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.mutate { try self.store.moveFolder(folder.id, into: nil) }
                self.showHome()
            }]
            destinations += store.folderDestinations(excluding: folder.id).map { destination in
                UIAction(title: Folder.path(of: destination.id, in: store.folders) ?? destination.name,
                         image: UIImage(systemName: "folder"), state: folder.parentID == destination.id ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.mutate { try self.store.moveFolder(folder.id, into: destination.id) }
                    self.showHome()
                }
            }
            options.menu = UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.askFolderName(folder.id) },
                UIMenu(title: "Move to", image: UIImage(systemName: "folder"), children: destinations),
                UIAction(title: "Delete folder", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.mutate { try self.store.deleteFolder(folder.id) }
                    self.showHome()
                }
            ])
            options.showsMenuAsPrimaryAction = true
            list.addArrangedSubview(UIStackView(arrangedSubviews: [b, options]))
        }
        for book in store.notebooks.filter({ $0.folderID == homeFolderID }).sorted(by: { $0.modified > $1.modified }) {
            let b = UIButton(type: .system)
            b.contentHorizontalAlignment = .leading
            let date = book.modified.formatted(date: .abbreviated, time: .omitted)
            let orientation = DocumentOrientation(metadata: book.orientation)
            b.setImage(UIImage(systemName: orientation.symbol), for: .normal)
            b.setTitle("  \(book.name)    ·    \(book.pages.count) pages    ·    \(date)", for: .normal)
            b.accessibilityLabel = "\(book.name), \(orientation.title), \(book.pages.count) pages, \(date)"
            b.isEnabled = DocumentOrientation.saved().fits(book.orientation)
            if !b.isEnabled { b.accessibilityHint = "Choose \(orientation.title) in Settings to open" }
            b.titleLabel?.font = .preferredFont(forTextStyle: .title3)
            b.tintColor = .black
            b.addAction(UIAction { [weak self] _ in
                guard let self, DocumentOrientation.saved().fits(book.orientation) else { return }
                self.bookID = book.id
                self.openPage(book.currentPage ?? book.pages.last?.id)
            }, for: .touchUpInside)
            b.heightAnchor.constraint(equalToConstant: 58).isActive = true
            let options = button("ellipsis", label: "Document options \(book.name)") {}
            options.widthAnchor.constraint(equalToConstant: 54).isActive = true
            var destinations: [UIMenuElement] = [UIAction(title: "Documents", state: book.folderID == nil ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.mutate { try self.store.moveNotebook(book.id, into: nil) }
                self.showHome()
            }]
            destinations += store.folderDestinations().map { folder in
                UIAction(title: Folder.path(of: folder.id, in: store.folders) ?? folder.name, image: UIImage(systemName: "folder"), state: book.folderID == folder.id ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.mutate { try self.store.moveNotebook(book.id, into: folder.id) }
                    self.showHome()
                }
            }
            options.menu = UIMenu(children: [
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.askRename(book.id) },
                UIMenu(title: "Move to", image: UIImage(systemName: "folder"), children: destinations)
            ])
            options.showsMenuAsPrimaryAction = true
            let item = UIStackView(arrangedSubviews: [b, options])
            item.axis = .horizontal
            list.addArrangedSubview(item)
        }
        let scroll = UIScrollView()
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        syncStatus.text = syncMessage
        syncStatus.textAlignment = .center
        syncStatus.font = .preferredFont(forTextStyle: .footnote)
        syncStatus.textColor = .secondaryLabel
        vertical([top, scroll, syncStatus])
    }

    private func syncWithServer() {
        guard bookID == nil, !syncInProgress else { return }
        syncInProgress = true
        content.isUserInteractionEnabled = false
        syncStatus.text = "Syncing with DGX…"
        Task { @MainActor in
            defer { syncInProgress = false; content.isUserInteractionEnabled = true; showHome() }
            do {
                var journal = try SyncJournal.load(in: syncDefaults)
                // Resolve uncertain document publications before global reconcile:
                // old receipt A authorizes A, never the newer local copy B.
                for key in journal.pendingDocuments.keys.sorted() {
                    guard let id = UUID(uuidString: key) else { throw SyncError.invalidPackage }
                    let local = try store.exportCurrentPackage(book: id)
                    let remote = try await syncClient.fetchDocument(id, local: local)
                    _ = try await recoverPendingDocument(id, journal: &journal, local: local, remote: remote)
                }
                for attempt in 0..<3 {
                    let local = try store.exportCurrentPackage()
                    let remote = try await syncClient.fetchIncremental(local: local)
                    try initializeJournal(&journal, local: local, remote: remote)
                    let merged = try journal.reconcile(local: local, remote: remote)
                    do {
                        _ = try await syncClient.uploadIncremental(merged, baseRevision: remote.revision, pages: merged.portablePages())
                    } catch SyncError.conflict where attempt < 2 { continue }
                    // Save only after CAS confirmation. The disabled Home UI
                    // cannot add a new local edit while this merge is in flight.
                    if try merged.digest() != local.digest() { try store.importPackage(merged) }
                    // Opaque document receipts are obtained against the latest
                    // state, not guessed from Swift's native package digest.
                    for book in merged.notebooks {
                        let confirmed = try await syncClient.fetchDocument(book.id, local: merged)
                        let source = try merged.document(book.id)
                        guard let package = confirmed.package, try package.digest() == source.digest(),
                              let wire = confirmed.documentDigest,
                              confirmed.revision >= (journal.documents[book.id.uuidString]?.revision ?? 0) else { throw SyncError.conflict }
                        journal.documents[book.id.uuidString] = DocumentSyncBaseline(serverDigest: wire,
                            localDigest: try source.digest(), revision: confirmed.revision,
                            lastSyncedAt: confirmed.lastSyncedAt ?? "")
                        journal.remoteLocalDigests[book.id.uuidString] = try source.digest()
                        // Only this verified document supersedes its old pending ID.
                        journal.pendingDocuments.removeValue(forKey: book.id.uuidString)
                    }
                    journal.folders = merged.folders ?? []
                    journal.legacyInvalidated = true
                    try journal.save(in: syncDefaults)
                    try store.completeSuccessfulSync()
                    syncMessage = "Synced with DGX · \(Date().formatted(date: .omitted, time: .shortened))"
                    return
                }
                throw SyncError.conflict
            } catch {
                syncMessage = "Sync unsuccessful"
                networkFailure(error, title: "Sync unsuccessful")
            }
        }
    }

    private func initializeJournal(_ journal: inout SyncJournal, local: SyncPackage, remote: SyncState) throws {
        var preMigration: [String: String] = [:]
        if let migration = try store.migrationJournal() {
            let old = try JSONDecoder().decode(SyncPackage.self, from: migration.preMigrationPackage)
            for book in old.notebooks { preMigration[book.id.uuidString] = try old.document(book.id).digest() }
            if journal.legacy == nil, let bytes = migration.globalBaseline {
                journal.legacy = try JSONDecoder().decode(SyncBaseline.self, from: bytes)
            }
        }
        // Honor the existing exact operator-pinned repair without deleting its
        // evidence or clearing authority after the representation upgrade.
        let repairURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Draw/sync-baseline-repair.json")
        if !journal.legacyInvalidated, FileManager.default.fileExists(atPath: repairURL.path) {
            let repair = try JSONDecoder().decode(SyncBaselineRepair.self, from: Data(contentsOf: repairURL))
            journal.legacy = try repair.apply(local: local, remote: remote, baseline: journal.legacy)
        }
        try journal.establishLegacy(local: local, remote: remote, preMigration: preMigration)
        try journal.save(in: syncDefaults)
    }

    // Called only by an explicit foreground server command, never on reconnect.
    // The requested UUID need not be the open document; UI identity stays put.
    func syncDocument(_ id: UUID) async throws -> DocumentSyncReceipt {
        guard aiForeground else { throw AIClientError.notForeground }
        repeat { try await waitForSyncEnd() } while syncInProgress
        syncInProgress = true
        defer { syncInProgress = false }
        lastSyncedSources.removeValue(forKey: id)
        guard let networkJournal = aiJournal else { throw AIClientError.invalidResponse }
        try await waitForPencilEnd()
        try saveCanvasIfChanged()
        var journal = try SyncJournal.load(in: syncDefaults)
        let local = try store.exportCurrentPackage(book: id)
        if !journal.legacyInvalidated && journal.legacy != nil {
            // Whole-library reads are confined to the one-time legacy proof.
            let library = try store.exportCurrentPackage()
            let whole = try await syncClient.fetchIncremental(local: library)
            try initializeJournal(&journal, local: library, remote: whole)
        }
        let remote = try await syncClient.fetchDocument(id, local: local)
        if let baseline = journal.documents[id.uuidString], baseline.serverDigest.hasPrefix("legacy:"),
           let source = remote.package, try source.digest() == String(baseline.serverDigest.dropFirst(7)),
           let wire = remote.documentDigest {
            journal.documents[id.uuidString]?.serverDigest = wire
            journal.remoteLocalDigests[id.uuidString] = try source.digest()
            try journal.save(in: syncDefaults)
        }
        if let receipt = try await recoverPendingDocument(id, journal: &journal, local: local, remote: remote) {
            return receipt
        }
        let decision = try SyncDecision.document(local: local, remote: remote, baseline: journal.documents[id.uuidString])
        let source: SyncPackage
        if decision == .download {
            guard let package = remote.package else { throw SyncError.invalidPackage }
            source = package
        } else { source = local }
        // Only immutable package bytes cross the worker boundary, never Store
        // or the live canvas. Keep the Sync mutation gate through this await.
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
        let pages = try await Task.detached(priority: .userInitiated) {
            try source.portablePages()
        }.value
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
        let syncID = UUID()
        // Native source bytes must survive receipt loss and subsequent local ink.
        // This cache remains local; it is never uploaded to Notes CAS.
        try networkJournal.stageCommittedSource(source, syncID: syncID)
        journal.pendingDocuments[id.uuidString] = .init(syncID: syncID, localDigest: try source.digest(),
            localBeforeDigest: try local.digest(), download: decision == .download)
        try journal.save(in: syncDefaults)
        let receipt = try await syncClient.uploadDocument(source, documentID: id, syncID: syncID,
            baseDocumentDigest: remote.documentDigest, pages: pages)
        guard aiForeground else { throw AIClientError.notForeground }
        if decision == .download {
            try await waitForPencilEnd()
            try saveCanvasIfChanged()
            let latest = try store.exportCurrentPackage()
            // Writing during download must not be replaced by remote ink.
            guard try latest.document(id).digest() == local.digest() else { throw SyncError.conflict }
            try importDocument(source, into: latest, id: id)
            try refreshCurrentScene(document: id)
        }
        journal.documents[id.uuidString] = DocumentSyncBaseline(serverDigest: receipt.documentDigest,
            localDigest: try source.digest(), revision: receipt.revision, lastSyncedAt: receipt.lastSyncedAt)
        journal.remoteLocalDigests[id.uuidString] = try source.digest()
        journal.confirmTargetFolder(in: source)
        journal.pendingDocuments.removeValue(forKey: id.uuidString)
        journal.legacyInvalidated = true
        try journal.save(in: syncDefaults)
        try store.completeSuccessfulSync(book: id)
        lastSyncedSources[id] = source
        return receipt
    }

    private func recoverPendingDocument(_ id: UUID, journal: inout SyncJournal,
                                        local: SyncPackage, remote: DocumentSyncState) async throws -> DocumentSyncReceipt? {
        guard let pending = journal.pendingDocuments[id.uuidString] else { return nil }
        guard let networkJournal = aiJournal else { throw AIClientError.invalidResponse }
        do {
            let receipt = try await syncClient.fetchSyncReceipt(pending.syncID)
            if try journal.receiptIsSuperseded(receipt, document: id, localDigest: pending.localDigest) {
                // Home or a newer confirmation already acknowledged another state.
                // Retire this ID without replacing authority/content with old A.
                journal.pendingDocuments.removeValue(forKey: id.uuidString)
                try journal.save(in: syncDefaults)
                return nil
            }
            let committedSource: SyncPackage
            if let cached = try networkJournal.committedSource(syncID: pending.syncID) { committedSource = cached }
            else {
                guard remote.documentDigest == receipt.documentDigest, let confirmed = remote.package else { throw SyncError.conflict }
                committedSource = confirmed
            }
            guard committedSource.notebooks.count == 1, committedSource.notebooks[0].id == id,
                  try committedSource.digest() == pending.localDigest else { throw SyncError.conflict }
            if pending.download, try local.digest() != pending.localDigest {
                // A cached archive proves old bytes, not current download authority.
                guard remote.documentDigest == receipt.documentDigest,
                      try local.digest() == pending.localBeforeDigest else { throw SyncError.conflict }
                try await waitForPencilEnd()
                try saveCanvasIfChanged()
                let latest = try store.exportCurrentPackage()
                guard try latest.document(id).digest() == pending.localBeforeDigest else { throw SyncError.conflict }
                try importDocument(committedSource, into: latest, id: id)
                try refreshCurrentScene(document: id)
            }
            journal.documents[id.uuidString] = DocumentSyncBaseline(serverDigest: receipt.documentDigest,
                localDigest: pending.localDigest, revision: receipt.revision, lastSyncedAt: receipt.lastSyncedAt)
            journal.remoteLocalDigests[id.uuidString] = pending.localDigest
            journal.confirmTargetFolder(in: committedSource)
            journal.pendingDocuments.removeValue(forKey: id.uuidString)
            journal.legacyInvalidated = true
            try journal.save(in: syncDefaults)
            try store.completeSuccessfulSync(book: id)
            lastSyncedSources[id] = committedSource
            return receipt
        } catch SyncError.http(404) {
            // Unknown ID did not commit; allow explicit normal reconciliation.
            journal.pendingDocuments.removeValue(forKey: id.uuidString)
            try journal.save(in: syncDefaults)
            return nil
        }
    }

    private func importDocument(_ source: SyncPackage, into latest: SyncPackage, id: UUID) throws {
        var books = latest.notebooks
        guard let i = books.firstIndex(where: { $0.id == id }), let incoming = source.notebooks.first else { throw SyncError.invalidPackage }
        books[i] = incoming
        var folders = latest.folders ?? []
        for folder in source.folders ?? [] {
            if let existing = folders.first(where: { $0.id == folder.id }) {
                guard existing == folder else { throw SyncError.conflict }
            } else { folders.append(folder) }
        }
        try store.importPackage(SyncPackage.combine(books, sources: [source, latest], folders: folders))
    }

    func becomeForeground() {
        requestManualOrientation()
        guard !aiForeground else { return }
        aiForeground = true
        foregroundGeneration += 1
        let generation = foregroundGeneration
        aiChannel.open(bookID)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture"),
           ProcessInfo.processInfo.environment["DRAW_AI_FIXTURE_URL"] == nil { return }
        #endif
        guard let journal = aiJournal else { return }
        aiRegistration = Task { @MainActor in
            defer { if foregroundGeneration == generation { aiRegistration = nil } }
            do {
                try await aiClient.register(journal.state.clientID)
                try checkForeground(generation)
                try aiChannel.start(client: aiClient, clientID: journal.state.clientID) { [weak self] command in
                    guard let self, self.aiForeground, self.foregroundGeneration == generation else { return }
                    await self.handleSyncCommand(command)
                }
                // Receipt recovery uses only local durable IDs, never replays an
                // inference submission or uploads a captured context on reconnect.
                for id in journal.state.applyAckIDs {
                    if let receipt = store.appliedAIRequests[id.uuidString] {
                        try await aiClient.acknowledge(receipt, clientID: journal.state.clientID)
                        try checkForeground(generation)
                        try journal.acknowledged(id)
                    }
                }
                for pending in journal.state.pending.values {
                    startPolling(requestID: pending.requestID, documentID: pending.documentID, recovering: true)
                }
                try checkForeground(generation)
                documentOpened(bookID)
            } catch {
                // Foreground registration/channel failures cannot trigger asks.
                // An explicit button press supplies the standard error dialog.
            }
        }
    }

    func enterBackground() {
        cancelCarry()
        aiForeground = false
        foregroundGeneration += 1
        aiRegistration?.cancel()
        aiRegistration = nil
        aiReadyChecks.values.forEach { $0.cancel() }
        aiReadyChecks.removeAll()
        aiChannel.stop()
        aiPolls.values.forEach { $0.task.cancel() }
        aiPolls.removeAll()
        aiOperations.values.forEach { $0.task.cancel() }
        aiOperations.removeAll()
        busyDocuments.removeAll()
        refreshToolbar()
        readyCheckedDocument = nil
        finishSave()
    }

    private func documentOpened(_ id: UUID?) {
        aiChannel.open(id)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture"),
           ProcessInfo.processInfo.environment["DRAW_AI_FIXTURE_URL"] == nil { return }
        #endif
        guard aiForeground else { return }
        guard let id else { readyCheckedDocument = nil; return }
        guard readyCheckedDocument != id, let journal = aiJournal else { return }
        readyCheckedDocument = id
        let generation = foregroundGeneration
        let checkID = UUID()
        aiReadyChecks[checkID] = Task { @MainActor in
            defer { aiReadyChecks.removeValue(forKey: checkID) }
            let receipts: [AIRequestReceipt]
            do {
                receipts = try await aiClient.ready(documentID: id, clientID: journal.state.clientID)
                try checkForeground(generation)
            } catch {
                // Automatic discovery is opportunistic. No upload, ask or retry.
                // Malformed successful responses still need a verification alert.
                guard shouldReportAI(error, generation: generation), !(error is URLError) else { return }
                if case AIClientError.server = error { return }
                networkFailure(error, title: "AI unavailable")
                return
            }
            do {
                for receipt in receipts {
                    try checkForeground(generation)
                    try await receiveReady(receipt, generation: generation)
                }
            } catch {
                if shouldReportAI(error, generation: generation) { networkFailure(error, title: "AI unavailable") }
            }
        }
    }

    private func checkForeground(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == foregroundGeneration else { throw CancellationError() }
        guard aiForeground else { throw AIClientError.notForeground }
    }

    private func shouldReportAI(_ error: Error, generation: Int) -> Bool {
        guard aiForeground, generation == foregroundGeneration, !Task.isCancelled else { return false }
        if error is CancellationError { return false }
        if let error = error as? URLError, error.code == .cancelled { return false }
        if case AIClientError.notForeground = error { return false }
        return true
    }

    private func captureNetworkContext(book: UUID, focus: UUID, source: SyncPackage? = nil) async throws -> (contextData: Data, assets: [String: Data]) {
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
        let captured = try await store.capturedAIContextAsync(book: book, focusPage: focus,
            pageSize: DocumentOrientation.portrait.pageSize, source: source)
        // The worker owns pinned bytes; newer ink is not read after this await.
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
        let bytes = try captured.context.encoded()
        guard bytes.count <= SyncObjects.metadataLimit else { throw SyncError.tooLarge }
        // Frozen page metadata binds current source heads, portable source CAS,
        // current object descriptors and the actual native paper/ink PNG layers.
        return (bytes, captured.assets)
    }

    private func askAI() {
        guard let id = bookID, let focus = pageID, !busyDocuments.contains(id), let journal = aiJournal else { return }
        let generation = foregroundGeneration
        busyDocuments.insert(id)
        refreshToolbar()
        let operationID = UUID()
        let operation = Task { @MainActor in
            defer { if aiOperations[id]?.id == operationID { aiOperations.removeValue(forKey: id) } }
            do {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture"),
                   ProcessInfo.processInfo.arguments.contains("--ui-test-ai-answer") {
                    let fixture = try makeAIAnswerFixture(documentID: id, pageID: focus)
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    try checkForeground(generation)
                    try await applyApprovedAI(data: fixture.0, assets: fixture.1)
                    busyDocuments.remove(id)
                    refreshToolbar()
                    return
                }
                #endif
                try await waitForPencilEnd()
                try checkForeground(generation)
                try saveCanvasIfChanged()
                let submission: AIRequestSubmission
                if let pending = journal.state.pending[id.uuidString] {
                    submission = pending // Explicit retry keeps its pinned context and ID.
                } else {
                    let captured = try await captureNetworkContext(book: id, focus: focus)
                    try checkForeground(generation)
                    submission = try journal.prepare(documentID: id, focusPageID: focus,
                        context: captured.contextData, assets: captured.assets)
                }
                try await aiClient.register(journal.state.clientID)
                try checkForeground(generation)
                try await aiClient.uploadAssets(journal.assets(for: submission))
                try checkForeground(generation)
                var receipt = try await aiClient.submit(submission)
                try checkForeground(generation)
                if receipt.status == "interrupted" {
                    receipt = try await aiClient.retry(receipt.requestID)
                    try checkForeground(generation)
                }
                if receipt.status == "ready" { try await receiveReady(receipt, generation: generation) }
                else { startPolling(requestID: receipt.requestID, documentID: id) }
            } catch {
                guard foregroundGeneration == generation, aiOperations[id]?.id == operationID else { return }
                busyDocuments.remove(id)
                refreshToolbar()
                if shouldReportAI(error, generation: generation) { networkFailure(error, title: "AI unavailable") }
            }
        }
        aiOperations[id] = (operationID, operation)
    }

    // Wait only for a pending capture/apply, not as an idle network timer.
    private func waitForSyncEnd() async throws {
        while syncInProgress {
            try Task.checkCancellation()
            guard aiForeground else { throw AIClientError.notForeground }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
    }

    private func waitForPencilEnd() async throws {
        while usingTool {
            try Task.checkCancellation()
            if !aiForeground { throw AIClientError.notForeground }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // PencilKit can deliver its final drawing after the end-tool callback.
        await Task.yield()
        if usingTool { try await waitForPencilEnd() }
        try Task.checkCancellation()
        guard aiForeground else { throw AIClientError.notForeground }
    }

    private func startPolling(requestID: UUID, documentID: UUID, recovering: Bool = false) {
        guard aiForeground, aiPolls[requestID] == nil else { return }
        let generation = foregroundGeneration
        busyDocuments.insert(documentID)
        refreshToolbar()
        let pollID = UUID()
        let poll = Task { @MainActor in
            defer {
                if aiPolls[requestID]?.id == pollID {
                    aiPolls.removeValue(forKey: requestID)
                    busyDocuments.remove(documentID)
                    refreshToolbar()
                }
            }
            var errorTitle = "AI unavailable"
            do {
                while aiForeground && !Task.isCancelled {
                    let receipt: AIRequestReceipt
                    do {
                        receipt = try await aiClient.status(requestID)
                    } catch {
                        try checkForeground(generation)
                        // Preparation precedes upload/submission. A recovered ID
                        // may never have reached DGX; keep its exact explicit retry.
                        if recovering, case AIClientError.server(404, _) = error { return }
                        throw error
                    }
                    try checkForeground(generation)
                    guard receipt.documentID == documentID else { throw AIClientError.invalidResponse }
                    switch receipt.status {
                    case "ready": try await receiveReady(receipt, generation: generation); return
                    case "applied":
                        try aiJournal?.finish(requestID, needsAck: false)
                        return
                    case "failed":
                        try aiJournal?.finish(requestID, needsAck: false)
                        errorTitle = "AI request failed"
                        throw AIClientError.server(422, receipt.error?.message ?? "The AI request failed. Your notes are safe.")
                    case "interrupted":
                        throw AIClientError.server(409, "The AI request was interrupted. Press AI to retry this request.")
                    case "queued", "running": break
                    default: throw AIClientError.invalidResponse
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError {
            } catch {
                if shouldReportAI(error, generation: generation) { networkFailure(error, title: errorTitle) }
            }
        }
        aiPolls[requestID] = (pollID, poll)
    }

    private func receiveReady(_ receipt: AIRequestReceipt, generation: Int) async throws {
        try checkForeground(generation)
        guard receipt.status == "ready", let sha = receipt.resultSHA256,
              let journal = aiJournal else { throw AIClientError.invalidResponse }
        let applied: AIApplyReceipt
        if let existing = store.appliedAIRequests[receipt.requestID.uuidString] {
            guard existing.resultSHA256 == sha else { throw AIError.duplicateRequest }
            applied = existing
        } else {
            let bytes = try await aiClient.download(sha, maxBytes: SyncObjects.metadataLimit)
            try checkForeground(generation)
            let result = try AIResult.approved(data: bytes)
            guard result.requestID == receipt.requestID, result.documentID == receipt.documentID else { throw AIClientError.invalidResponse }
            if let pending = journal.state.pending[receipt.documentID.uuidString], pending.requestID == receipt.requestID {
                guard pending.contextSHA256 == result.contextSHA256 else { throw AIClientError.invalidResponse }
            }
            var assets: [String: Data] = [:]
            var total = bytes.count
            for object in result.pageEdits.flatMap(\.objectEdits).compactMap(\.object) {
                if assets[object.asset.sha256] == nil {
                    if let local = try? store.assetData(object.asset) { assets[object.asset.sha256] = local }
                    else {
                        assets[object.asset.sha256] = try await aiClient.download(object.asset.sha256,
                            maxBytes: SyncObjects.objectLimit - total)
                        try checkForeground(generation)
                    }
                    total += assets[object.asset.sha256]!.count
                    guard total <= SyncObjects.objectLimit else { throw SyncError.tooLarge }
                }
            }
            applied = try await applyApprovedAI(data: bytes, assets: assets)
        }
        try checkForeground(generation)
        try journal.finish(receipt.requestID, needsAck: true)
        // A failed ack leaves a durable local receipt and retry ID. Undo cannot
        // turn this approved result into a new application candidate.
        try await aiClient.acknowledge(applied, clientID: journal.state.clientID)
        try checkForeground(generation)
        try journal.acknowledged(receipt.requestID)
        busyDocuments.remove(receipt.documentID)
        refreshToolbar()
    }

    // Integration tests use the same stable flush/apply path as downloaded PNGs.
    @discardableResult
    func applyApprovedAI(data: Data, assets: [String: Data]) async throws -> AIApplyReceipt {
        let generation = foregroundGeneration
        let result = try AIResult.approved(data: data)
        repeat {
            try await waitForSyncEnd()
            try await waitForPencilEnd()
            // Pencil waiting yields the actor: a Sync may have started meanwhile.
            // No await follows this check before the atomic local mutation.
        } while syncInProgress
        try checkForeground(generation)
        try saveCanvasIfChanged()
        let receipt = try store.applyAI(result, assets: assets)
        try refreshCurrentScene(document: result.documentID)
        return receipt
    }

    private func refreshCurrentScene(document: UUID) throws {
        guard bookID == document, let page = activePage(), pageViewport != nil else { return }
        setDrawing(try store.drawing(book: document, page: page))
        try aiObjects.load(store.objects(book: document, page: page), store: store)
        paper.pattern = page.background
        refreshToolbar()
        // No openPage, navigation or pageInkSize update: keep the current mapping.
    }

    func handleSyncCommand(_ command: AIChannelCommand) async {
        guard aiForeground, let journal = aiJournal else { return }
        let generation = foregroundGeneration
        busyDocuments.insert(command.documentID)
        refreshToolbar()
        do {
            // ACK before Sync, Pencil waits or capture so a responsive foreground
            // client gets the manager's long synchronizing deadline.
            let started = try await aiClient.syncStarted(requestID: command.requestID, clientID: journal.state.clientID)
            try checkForeground(generation)
            guard started.documentID == command.documentID else { throw AIClientError.invalidResponse }
            let receipt = try await syncDocument(command.documentID)
            try checkForeground(generation)
            try await waitForPencilEnd()
            try checkForeground(generation)
            try saveCanvasIfChanged()
            guard let source = lastSyncedSources[command.documentID],
                  let book = source.notebooks.first(where: { $0.id == command.documentID }) else { throw AIError.missingPage }
            let visible = bookID == book.id ? pageID : nil
            let focus: UUID
            if let requested = command.focusPageID {
                guard book.pages.contains(where: { $0.id == requested }) else { throw AIError.missingPage }
                focus = requested
            } else {
                guard let fallback = visible.flatMap({ id in book.pages.contains(where: { $0.id == id }) ? id : nil })
                    ?? book.currentPage.flatMap({ id in book.pages.contains(where: { $0.id == id }) ? id : nil })
                    ?? book.pages.first?.id else { throw AIError.missingPage }
                focus = fallback
            }
            let captured = try await captureNetworkContext(book: book.id, focus: focus, source: source)
            try checkForeground(generation)
            let bytes = captured.contextData
            let sha = SyncObjects.digest(bytes)
            var assets = captured.assets
            assets[sha] = bytes
            try await aiClient.uploadAssets(assets)
            try checkForeground(generation)
            let queued = try await aiClient.syncReady(requestID: command.requestID, clientID: journal.state.clientID,
                syncID: receipt.syncID, contextSHA256: sha)
            try checkForeground(generation)
            guard queued.requestID == command.requestID, queued.documentID == command.documentID else { throw AIClientError.invalidResponse }
            if queued.status == "ready" { try await receiveReady(queued, generation: generation) }
            else { startPolling(requestID: queued.requestID, documentID: queued.documentID) }
        } catch {
            guard foregroundGeneration == generation else { return }
            busyDocuments.remove(command.documentID)
            refreshToolbar()
            if shouldReportAI(error, generation: generation) { networkFailure(error, title: "Sync unsuccessful") }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private func makeAIAnswerFixture(documentID: UUID, pageID: UUID) throws -> (Data, [String: Data]) {
        let request = UUID(), contextSHA = String(repeating: "a", count: 64)
        var objects: [AIObject] = [], assets: [String: Data] = [:]
        for (index, kind) in ["circle", "latex", "text"].enumerated() {
            let size = CGSize(width: 200, height: 50)
            let image = UIGraphicsImageRenderer(size: size, format: AICapture.rendererFormat()).image { context in
                UIColor.black.setStroke()
                if kind == "circle" {
                    context.cgContext.setLineWidth(1)
                    context.cgContext.strokeEllipse(in: CGRect(x: 1, y: 1, width: 198, height: 48))
                } else {
                    let text = kind == "latex" ? "x² + y² = r²" : "Approved answer"
                    text.draw(at: CGPoint(x: 2, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                }
            }
            let png = try AICapture.png(image)
            let sha = SyncObjects.digest(png)
            assets[sha] = png
            objects.append(AIObject(id: UUID(), revision: 1, kind: kind,
                source: kind == "latex" ? "x^2+y^2=r^2" : kind == "circle" ? "{\"cx\":100,\"cy\":25,\"rx\":99,\"ry\":24}" : "Approved answer",
                frame: AIFrame(x: 100, y: Double(250 + index * 60), width: 200, height: 50), style: AIStyle(),
                asset: AIAsset(sha256: sha, pixelWidth: 400, pixelHeight: 100),
                provenance: AIProvenance(requestID: request, contextSHA256: contextSHA, rendererSignature: "draw-ai-render-v1")))
        }
        let result = AIResult(requestID: request, documentID: documentID, contextSHA256: contextSHA,
            draftVersion: 1, rendererSignature: "draw-ai-render-v1",
            pageEdits: [AIPageEdit(pageID: pageID, objectEdits: objects.map { AIObjectEdit(op: "add", object: $0) }, strokeEdits: [])],
            previewSHA256s: [pageID.uuidString: String(repeating: "b", count: 64)])
        return (try AIHash.encoded(result), assets)
    }
    #endif

    private func networkFailure(_ error: Error, title: String) {
        if let onError { onError(error, title); return }
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let message = error is URLError
            ? "Could not reach DGX. Check internet and Tailscale VPN, then retry. Your local notes are safe."
            : error.localizedDescription
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: false)
    }

    private func showSettings() {
        clear()
        let back = button("chevron.left", label: "Documents") { [weak self] in self?.showHome() }
        let title = UILabel()
        title.text = "Settings"
        title.textAlignment = .center
        title.font = .preferredFont(forTextStyle: .headline)
        let label = UILabel()
        label.text = "Toolbar position"
        label.font = .preferredFont(forTextStyle: .body)
        let options = ToolbarPosition.allCases
        let picker = UISegmentedControl(items: options.map(\.title))
        picker.accessibilityIdentifier = "toolbarPosition"
        picker.selectedSegmentIndex = options.firstIndex(of: .saved()) ?? 0
        picker.addAction(UIAction { [weak picker] _ in
            guard let picker, options.indices.contains(picker.selectedSegmentIndex) else { return }
            UserDefaults.standard.set(options[picker.selectedSegmentIndex].rawValue, forKey: "toolbarPosition")
        }, for: .valueChanged)
        let orientationLabel = UILabel()
        orientationLabel.text = "Orientation"
        orientationLabel.font = .preferredFont(forTextStyle: .body)
        let orientations = DocumentOrientation.allCases
        let orientationPicker = UISegmentedControl(items: orientations.map(\.title))
        orientationPicker.accessibilityIdentifier = "documentOrientation"
        orientationPicker.selectedSegmentIndex = orientations.firstIndex(of: .saved()) ?? 0
        orientationPicker.addAction(UIAction { [weak self, weak orientationPicker] _ in
            guard let self, let orientationPicker, orientations.indices.contains(orientationPicker.selectedSegmentIndex) else { return }
            orientations[orientationPicker.selectedSegmentIndex].save()
            self.requestManualOrientation()
        }, for: .valueChanged)
        let paletteLabel = UILabel()
        paletteLabel.text = "Show all ink colors"
        paletteLabel.font = .preferredFont(forTextStyle: .body)
        let paletteSwitch = UISwitch()
        paletteSwitch.isOn = UserDefaults.standard.bool(forKey: "showAllColors")
        paletteSwitch.addAction(UIAction { [weak paletteSwitch] _ in
            guard let paletteSwitch else { return }
            UserDefaults.standard.set(paletteSwitch.isOn, forKey: "showAllColors")
        }, for: .valueChanged)
        let paletteRow = UIStackView(arrangedSubviews: [paletteLabel, paletteSwitch])
        paletteRow.axis = .horizontal
        let setting = UIStackView(arrangedSubviews: [orientationLabel, orientationPicker, label, picker, paletteRow])
        setting.axis = .vertical
        setting.spacing = 12
        for (name, key) in [
            ("Notebook tabs", "showNotebookTabs"), ("Numbered page tabs", "showPageTabs"),
            ("All pages shortcut", "showOverviewShortcut"), ("New page shortcut", "showNewPageShortcut"),
            ("Selection tool", "showSelectionControl"), ("Ruler", "showRulerControl"),
            ("Stroke size controls", "showSizeControls"), ("Carry to next page", "showCarryControl"),
            ("Shapes tool", "showShapesControl")
        ] {
            let caption = UILabel()
            caption.text = name
            caption.font = .preferredFont(forTextStyle: .body)
            let toggle = UISwitch()
            toggle.isOn = controlVisible(key)
            toggle.addAction(UIAction { [weak toggle] _ in
                guard let toggle else { return }
                UserDefaults.standard.set(toggle.isOn, forKey: key)
            }, for: .valueChanged)
            let line = UIStackView(arrangedSubviews: [caption, toggle])
            line.axis = .horizontal
            setting.addArrangedSubview(line)
        }
        setting.isLayoutMarginsRelativeArrangement = true
        setting.layoutMargins = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let scroll = UIScrollView()
        scroll.addSubview(setting)
        setting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            setting.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            setting.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            setting.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            setting.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            setting.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        vertical([row([back, title, UIView()], height: 48), scroll])
    }

    private func askName() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "New document", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.mutate {
                let id = try self.store.addNotebook(name.isEmpty ? "Untitled" : name, in: self.homeFolderID, orientation: DocumentOrientation.saved().rawValue)
                self.bookID = id
                self.openPage(self.store.notebook(id)?.pages.first?.id)
            }
        })
        present(alert, animated: false)
    }

    private func askFolderName(_ id: UUID? = nil) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: id == nil ? "New folder" : "Rename folder", message: nil, preferredStyle: .alert)
        let existing = store.folders.first { $0.id == id }?.name
        alert.addTextField { $0.text = existing; $0.placeholder = "Name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: id == nil ? "Create" : "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.mutate {
                if let id { try self.store.renameFolder(id, to: name) }
                else { _ = try self.store.addFolder(name, in: self.homeFolderID) }
            }
            self.showHome()
        })
        present(alert, animated: false)
    }

    private func askRename(_ id: UUID) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        guard let book = store.notebook(id) else { return }
        let alert = UIAlertController(title: "Rename document", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = book.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self] _ in
            guard let self, let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.mutate { try self.store.update(id) { $0.name = name } }
            self.showHome()
        })
        present(alert, animated: false)
    }

    private func controlVisible(_ key: String) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    }

    private func drawingHeader(book: Notebook, page: Page) -> UIView {
        func tabs(_ values: [(String, Bool, () -> Void)]) -> UIScrollView {
            let strip = UIStackView()
            strip.axis = .horizontal
            strip.spacing = 5
            strip.alignment = .fill
            for (title, active, action) in values {
                let tab = UIButton(type: .system)
                tab.setTitle(title, for: .normal)
                tab.setTitleColor(active ? .white : .label, for: .normal)
                tab.backgroundColor = active ? .systemBlue : .secondarySystemBackground
                tab.layer.cornerRadius = 9
                tab.titleLabel?.font = .systemFont(ofSize: 14, weight: active ? .semibold : .regular)
                tab.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
                tab.addAction(UIAction { _ in action() }, for: .touchUpInside)
                strip.addArrangedSubview(tab)
            }
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.addSubview(strip)
            strip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
                strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
                strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                strip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
            ])
            return scroll
        }
        let home = button("house", label: "Notebooks") { [weak self] in
            self?.finishSave()
            self?.showHome()
        }
        let notebooks = tabs(store.notebooks.filter { DocumentOrientation.saved().fits($0.orientation) }.map { notebook in
            (notebook.name, notebook.id == book.id, { [weak self] in
                guard let self, notebook.id != self.bookID else { return }
                self.finishSave()
                self.bookID = notebook.id
                self.openPage(notebook.currentPage ?? notebook.pages.first?.id)
            })
        })
        notebooks.accessibilityIdentifier = "notebookTabs"
        notebooks.isHidden = !controlVisible("showNotebookTabs")
        let pages = tabs(book.pages.enumerated().map { index, entry in
            ("\(index + 1)", entry.id == page.id, { [weak self] in
                guard let self, entry.id != self.pageID else { return }
                self.finishSave()
                self.openPage(entry.id)
            })
        })
        pages.accessibilityIdentifier = "numberedPageTabs"
        pages.isHidden = !controlVisible("showPageTabs")
        let add = button("plus", label: "New page") { [weak self] in self?.toolbarAction(3) }
        let overview = button("square.grid.2x2", label: "All numbered pages") { [weak self] in self?.toolbarAction(2) }
        add.isHidden = !controlVisible("showNewPageShortcut")
        overview.isHidden = !controlVisible("showOverviewShortcut")
        let header = UIStackView(arrangedSubviews: [home, notebooks, pages, add, overview])
        header.axis = .horizontal
        header.alignment = .fill
        header.spacing = 4
        header.backgroundColor = UIColor.secondarySystemBackground
        header.heightAnchor.constraint(equalToConstant: 48).isActive = true
        home.widthAnchor.constraint(equalToConstant: 44).isActive = true
        if !add.isHidden { add.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        if !overview.isHidden { overview.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        if !notebooks.isHidden { notebooks.widthAnchor.constraint(equalTo: header.widthAnchor, multiplier: 0.44).isActive = true }
        return header
    }

    func openPage(_ id: UUID?) {
        guard let bookID, let book = store.notebook(bookID), DocumentOrientation.saved().fits(book.orientation), let page = book.pages.first(where: { $0.id == id }) ?? book.pages.last else { showHome(); return }
        let drawing: PKDrawing
        do { drawing = try store.drawing(book: bookID, page: page) }
        catch { failure(error); return }
        pageID = page.id
        documentOpened(bookID)
        if book.currentPage != page.id { mutate { try store.update(bookID) { $0.currentPage = page.id } } }
        clear()
        let work = PageViewport()
        work.accessibilityIdentifier = "pageViewport"
        work.surface.accessibilityIdentifier = "drawingSurface"
        work.surface.clipsToBounds = true
        pageViewport = work
        paper.removeFromSuperview()
        canvas.removeFromSuperview()
        aiObjects.removeFromSuperview()
        paper.pattern = page.background
        work.surface.addSubview(paper)
        work.surface.addSubview(aiObjects)
        work.surface.addSubview(canvas)
        mutate { try aiObjects.load(store.objects(book: bookID, page: page), store: store) }
        for child in [paper, aiObjects, canvas] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: work.surface.topAnchor),
                child.bottomAnchor.constraint(equalTo: work.surface.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: work.surface.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: work.surface.trailingAnchor)
            ])
        }
        documentPageSize = DocumentOrientation(metadata: book.orientation).pageSize
        let bounds = drawing.bounds
        let objects = store.objects(book: bookID, page: page)
        pageInkSize = CGSize(width: max(bounds.isNull ? 0 : bounds.maxX, CGFloat(objects.map { $0.frame.x + $0.frame.width }.max() ?? 0)),
                             height: max(bounds.isNull ? 0 : bounds.maxY, CGFloat(objects.map { $0.frame.y + $0.frame.height }.max() ?? 0)))
        setDrawing(drawing)
        applyTool()
        let position = ToolbarPosition.saved()
        let bar = drawingToolbar(position: position)
        let workArea = UIStackView(arrangedSubviews: position.comesFirst ? [bar, work] : [work, bar])
        workArea.axis = position.isVertical ? .horizontal : .vertical
        vertical([drawingHeader(book: book, page: page), workArea])
    }

    private func endSelectionKeyboardEditing() {
        guard pageViewport != nil, currentTool == 3, canvas.selectionEditingEnabled,
              let window = canvas.window ?? viewIfLoaded?.window else { updateKeyboardDiagnostics(); return }
        // Preserve native canvas/menu first-responder state when there is no
        // text editor. A restored predictive strip may omit Show notifications.
        let textFocus = (window.windowScene?.windows ?? [window]).contains { hasTextResponder(in: $0) }
        guard selectionKeyboardVisible || textFocus else { updateKeyboardDiagnostics(); return }
        #if DEBUG && targetEnvironment(simulator)
        keyboardDebugAttempts += 1
        #endif
        let ended = window.endEditing(true)
        #if DEBUG && targetEnvironment(simulator)
        if ended { keyboardDebugEnded += 1 }
        #endif
        // A native text responder can belong to another window in this scene.
        // Only use the public responder-chain action for a reported keyboard,
        // not for ordinary native selection/menu focus.
        if !ended && (selectionKeyboardVisible || textFocus) {
            let sent = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #if DEBUG && targetEnvironment(simulator)
            if sent { keyboardDebugGlobalResigns += 1 }
            #endif
        }
        updateKeyboardDiagnostics()
    }

    private func hasTextResponder(in view: UIView) -> Bool {
        if view.isFirstResponder && view is UITextInput { return true }
        return view.subviews.contains { hasTextResponder(in: $0) }
    }

    private func dismissSelectionKeyboard() {
        guard pageViewport != nil, currentTool == 3, canvas.selectionEditingEnabled else { updateKeyboardDiagnostics(); return }
        // Selection can acquire its native text responder AFTER selection-change
        // delivery, including a predictive strip with no fresh Show notification.
        // Do not gate these two turns on the Show/Hide bookkeeping flag.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.usingTool { self.endSelectionKeyboardEditing() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.usingTool else { return }
                self.endSelectionKeyboardEditing()
            }
        }
    }

    private func updateKeyboardDiagnostics() {
        #if DEBUG && targetEnvironment(simulator)
        let selectionGuard = pageViewport != nil && currentTool == 3 && canvas.selectionEditingEnabled
        let textFocus = (canvas.window?.windowScene?.windows ?? []).contains { hasTextResponder(in: $0) }
        let value = "observers=\(keyboardObservers.count);will=\(keyboardDebugWillShow);did=\(keyboardDebugDidShow);hide=\(keyboardDebugDidHide);selection=\(keyboardDebugSelectionChanges);toolEnd=\(keyboardDebugToolEnds);attempts=\(keyboardDebugAttempts);ended=\(keyboardDebugEnded);globalResign=\(keyboardDebugGlobalResigns);tool=\(currentTool);guard=\(selectionGuard ? 1 : 0);reported=\(selectionKeyboardVisible ? 1 : 0);rootWindow=\(viewIfLoaded?.window == nil ? 0 : 1);canvasWindow=\(canvas.window == nil ? 0 : 1);canvasResponder=\(canvas.isFirstResponder ? 1 : 0);textFocus=\(textFocus ? 1 : 0);usingTool=\(usingTool ? 1 : 0);main=\(Thread.isMainThread ? 1 : 0)"
        // Numeric state only. Never make the root an AX element or hide its
        // native stroke/button descendants; no note text or responder names.
        viewIfLoaded?.accessibilityIdentifier = "drawControllerDiagnostics"
        viewIfLoaded?.accessibilityValue = value
        pageViewport?.accessibilityValue = value
        #endif
    }

    private func selectTool(_ tool: Int) {
        guard !usingTool else { return }
        cancelCarry()
        currentTool = tool
        shapeModeEnabled = false
        UserDefaults.standard.set(tool, forKey: "tool")
        if tool == 0 || tool == 2 {
            lastInkTool = tool
            UserDefaults.standard.set(tool, forKey: "lastInkTool")
        } else { rulerEnabled = false }
        quickArmed = false
        quickEraserQueued = false
        applyTool()
        if tool == 3 { dismissSelectionKeyboard() }
        updateKeyboardDiagnostics()
        refreshToolbar()
    }

    private func selectInk(_ index: Int) {
        guard !usingTool else { return }
        cancelCarry()
        currentInk = index
        UserDefaults.standard.set(index, forKey: "ink")
        let capturedSelection = colorSelection
        colorSelection = nil
        if #available(iOS 27.0, *), currentTool == 3, !quickArmed {
            let selection = capturedSelection ?? canvas.selection
            guard !selection.isEmpty else { selectTool(lastInkTool); return }
            var changed = false
            var recoloredSelection = Set<UUID>()
            let color = inkColors[index].resolvedColor(with: canvas.traitCollection)
            let strokes = canvas.drawing.strokes.map { stroke -> PKStroke in
                guard selection.contains(stroke.id) else { return stroke }
                let ink = PKInk(stroke.ink.inkType, color: color)
                let oldColor = stroke.ink.color.cgColor, newColor = ink.color.cgColor
                let oldComponents = oldColor.components ?? [], newComponents = newColor.components ?? []
                let sameColor = oldColor.colorSpace == newColor.colorSpace && oldComponents.count == newComponents.count
                    && zip(oldComponents, newComponents).allSatisfy { abs($0.0 - $0.1) < 0.000001 }
                guard !sameColor else {
                    recoloredSelection.insert(stroke.id)
                    return stroke
                }
                changed = true
                // PencilKit can retain the old rendered color when a live stroke ID is reused.
                // Replace the stroke identity while retaining its geometry, masks and render state.
                let id = UUID()
                recoloredSelection.insert(id)
                return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask,
                                randomSeed: stroke.randomSeed, id: id,
                                renderGroupID: stroke.renderGroupID, renderState: stroke.renderState)
            }
            if changed {
                loadingDrawing = true
                canvas.drawing = PKDrawing(strokes: strokes)
                canvas.selection = recoloredSelection
                loadingDrawing = false
                mutate { try saveCanvasIfChanged() }
            }
            dismissSelectionKeyboard()
            refreshToolbar()
            return
        }
        selectTool(lastInkTool)
    }

    @objc private func configureInkColor(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton,
              inkColors.indices.contains(button.tag), presentedViewController == nil else { return }
        editingColorIndex = button.tag
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = inkColors[button.tag]
        picker.delegate = self
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard let index = editingColorIndex, inkColors.indices.contains(index) else { return }
        let color = viewController.selectedColor.resolvedColor(with: traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        inkColors[index] = UIColor(red: r, green: g, blue: b, alpha: 1)
        colorSwatches[index]?.backgroundColor = inkColors[index]
        let saved = inkColors.map { color -> [Double] in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            _ = color.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [Double(red), Double(green), Double(blue)]
        }
        UserDefaults.standard.set(saved, forKey: "customInkColors")
        if currentInk == index { applyTool() }
    }

    @objc private func configureEraser(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }
        let sheet = UIAlertController(title: "Eraser", message: "Choose how one eraser contact removes ink", preferredStyle: .actionSheet)
        for (title, pixel) in [("Pixel eraser", true), ("Whole stroke eraser", false)] {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.eraserByPixel = pixel
                UserDefaults.standard.set(pixel, forKey: "eraserByPixel")
                self.applyTool()
                self.refreshToolbar()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = gesture.view
        sheet.popoverPresentationController?.sourceRect = gesture.view?.bounds ?? .zero
        present(sheet, animated: true)
    }

    private func applyTool() {
        canvas.selectionEditingEnabled = currentTool == 3 && !quickArmed
        canvas.isRulerActive = rulerEnabled && (currentTool == 0 || currentTool == 2) && !quickArmed
        if quickArmed {
            canvas.tool = PKEraserTool(eraserByPixel ? .bitmap : .vector)
        } else if currentTool == 3 {
            canvas.tool = PKLassoTool()
        } else if currentTool == 2 {
            canvas.tool = PKInkingTool(.marker, color: inkColors[currentInk], width: markerWidths[markerWidthIndex])
        } else {
            canvas.tool = PKInkingTool(.monoline, color: inkColors[currentInk], width: widths[widthIndex])
        }
    }

    private func drawingToolbar(position: ToolbarPosition) -> UIView {
        let symbols = ["chevron.left", "chevron.right", "square.grid.2x2", "plus.square", "square.dotted", "pencil.tip", "eraser.fill", "highlighter", "lasso", "ruler", "plus", "minus"]
        let names = ["Previous page", "Next page", "Page overview", "New page", "Change paper", "Pen", "Erase next stroke", "Highlighter", "Selection", "Ruler", "Thicker", "Thinner"]
        var controls: [UIView] = []
        for i in symbols.indices {
            let action = i >= 6 ? i + 1 : i // Keep action IDs stable after removing the persistent eraser.
            let b = button(symbols[i], label: names[i]) { [weak self] in self?.toolbarAction(action) }
            // Page navigation and paper templates live outside the pen strip.
            if i <= 4 { b.isHidden = true }
            if i == 8 { b.isHidden = !controlVisible("showSelectionControl") }
            if i == 9 { b.isHidden = !controlVisible("showRulerControl") }
            if i == 10 || i == 11 { b.isHidden = !controlVisible("showSizeControls") }
            if i == 6 {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(configureEraser(_:)))
                hold.minimumPressDuration = 0.45
                b.addGestureRecognizer(hold)
            }
            controls.append(b)
            buttons.append(b)
        }
        for i in inkColors.indices {
            let b = UIButton(type: .system)
            b.backgroundColor = .white
            let swatch = UIView()
            swatch.backgroundColor = inkColors[i]
            swatch.layer.cornerRadius = 10
            swatch.isUserInteractionEnabled = false
            swatch.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(swatch)
            NSLayoutConstraint.activate([
                swatch.centerXAnchor.constraint(equalTo: b.centerXAnchor),
                swatch.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                swatch.widthAnchor.constraint(equalToConstant: 20),
                swatch.heightAnchor.constraint(equalToConstant: 20)
            ])
            if i == 7 {
                let badge = UILabel()
                badge.text = "?"
                badge.font = .systemFont(ofSize: 15, weight: .bold)
                badge.textColor = .white
                badge.textAlignment = .center
                badge.isUserInteractionEnabled = false
                badge.translatesAutoresizingMaskIntoConstraints = false
                swatch.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.centerXAnchor.constraint(equalTo: swatch.centerXAnchor),
                    badge.centerYAnchor.constraint(equalTo: swatch.centerYAnchor)
                ])
            }
            b.accessibilityLabel = ["Black", "Blue", "Green", "Orange", "Yellow", "Red", "Ink blue", "Question"][i]
            b.addAction(UIAction { [weak self] _ in
                guard let self, #available(iOS 27.0, *) else { return }
                self.colorSelection = self.canvas.selection
            }, for: .touchDown)
            b.addAction(UIAction { [weak self] _ in self?.colorSelection = nil }, for: [.touchCancel, .touchUpOutside])
            b.addAction(UIAction { [weak self] _ in self?.selectInk(i) }, for: .touchUpInside)
            // Initial compact palette; keep original indices and stored strokes intact.
            if !UserDefaults.standard.bool(forKey: "showAllColors") && ![0, 2, 5, 6].contains(i) { b.isHidden = true }
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(configureInkColor(_:)))
            longPress.minimumPressDuration = 0.45
            b.tag = i
            b.addGestureRecognizer(longPress)
            colorSwatches[i] = swatch
            controls.append(b)
            buttons.append(b)
        }
        let ask = button("sparkles", label: "AI") { [weak self] in self?.askAI() }
        ask.accessibilityIdentifier = "askAI"
        aiButton = ask
        // Draw's reference AI endpoint is a placeholder, not a running service.
        ask.isHidden = true
        controls.append(ask)
        buttons.append(ask)
        for (i, symbol) in ["star", "arrow.uturn.backward", "arrow.uturn.forward"].enumerated() {
            let b = button(symbol, label: ["Star page", "Undo", "Redo"][i]) { [weak self] in self?.toolbarAction(20 + i) }
            if i == 0 { b.isHidden = true } // Hide page favorites, preserve existing data.
            controls.append(b)
            buttons.append(b)
        }
        let carry = button("doc.on.doc", label: "Carry to next page") { [weak self] in self?.toggleCarry() }
        carry.isHidden = !controlVisible("showCarryControl")
        controls.append(carry)
        buttons.append(carry)
        let shapes = button("square.on.circle", label: "Shapes: line, curve, triangle, rectangle, ellipse") { [weak self] in
            guard let self else { return }
            let enabled = !self.shapeModeEnabled
            self.selectTool(0)
            self.shapeModeEnabled = enabled
            self.refreshToolbar()
        }
        shapes.accessibilityIdentifier = "shapeMode"
        shapes.isHidden = !controlVisible("showShapesControl")
        controls.append(shapes)
        buttons.append(shapes)
        let strip = row(controls, height: position.isVertical ? 0 : 44)
        strip.axis = position.isVertical ? .vertical : .horizontal
        let base = UIView()
        base.accessibilityIdentifier = "drawingToolbar"
        base.backgroundColor = UIColor(white: 0.96, alpha: 1)
        base.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: base.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: base.trailingAnchor),
            strip.topAnchor.constraint(equalTo: base.topAnchor)
        ])
        if position.isVertical {
            base.widthAnchor.constraint(equalToConstant: 44).isActive = true
            strip.bottomAnchor.constraint(lessThanOrEqualTo: base.bottomAnchor).isActive = true
            let height = strip.heightAnchor.constraint(equalToConstant: CGFloat(controls.filter { !$0.isHidden }.count) * 44)
            height.priority = .defaultHigh
            height.isActive = true
        } else {
            strip.bottomAnchor.constraint(equalTo: base.bottomAnchor).isActive = true
        }
        refreshToolbar()
        return base
    }

    private func refreshToolbar() {
        guard buttons.count == 12 + inkColors.count + 6 else { return }
        for (i, b) in buttons.enumerated() {
            b.layer.borderWidth = 0
            b.alpha = b.isEnabled ? 1 : 0.35
            let selected = !quickArmed && ((i == 5 && currentTool == 0) || (i == 7 && currentTool == 2) || (i == 8 && currentTool == 3))
                || (i == 6 && quickArmed) || (i == 9 && canvas.isRulerActive)
                || (i == 16 + inkColors.count && carryOverlay != nil)
                || (i == 17 + inkColors.count && shapeModeEnabled)
            b.isSelected = selected
            if selected {
                b.backgroundColor = UIColor(white: 0.86, alpha: 1)
            } else if i < 12 || i >= 12 + inkColors.count { b.backgroundColor = .clear }
        }
        buttons[5].accessibilityValue = String(format: "%g pt", Double(widths[widthIndex]))
        buttons[6].accessibilityValue = eraserByPixel ? "Pixel" : "Whole stroke"
        buttons[13 + inkColors.count].setImage(UIImage(systemName: activePage()?.starred == true ? "star.fill" : "star"), for: .normal)
        aiButton?.isEnabled = bookID.map { !busyDocuments.contains($0) } ?? false
        aiButton?.alpha = aiButton?.isEnabled == true ? 1 : 0.35
        for i in inkColors.indices {
            let b = buttons[12 + i]
            b.isSelected = i == currentInk
            b.layer.borderWidth = i == currentInk ? 3 : 0
            b.layer.borderColor = UIColor.black.cgColor
            b.layer.cornerRadius = 20
        }
    }

    private func cancelCarry() {
        carryOverlay?.removeFromSuperview()
        carryOverlay = nil
        refreshToolbar()
    }

    private func toggleCarry() {
        guard !usingTool, let viewport = pageViewport, pageID != nil else { return }
        if carryOverlay != nil { cancelCarry(); return }
        let overlay = CarryTapOverlay()
        overlay.onTap = { [weak self, weak overlay] point in
            guard let self, let overlay, self.carryOverlay === overlay else { return }
            self.carryPage(at: point)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: viewport.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: viewport.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: viewport.trailingAnchor)
        ])
        carryOverlay = overlay
        refreshToolbar()
    }

    // The overlay fills the untransformed parent viewport. Convert through the
    // surface transform, keeping negative source coordinates and full cut-crossing ink.
    func carryPage(at point: CGPoint) {
        guard !usingTool, let overlay = carryOverlay, let viewport = pageViewport,
              let bookID, let pageID else { return }
        let y = viewport.surface.convert(point, from: overlay).y
        cancelCarry() // One shot, including save/helper failures, before changing pages.
        mutate {
            try saveCanvasIfChanged()
            let next = try store.carryBelow(book: bookID, page: pageID, y: y)
            openPage(next)
        }
    }

    private func activePage() -> Page? {
        guard let bookID, let pageID else { return nil }
        return store.notebook(bookID)?.pages.first { $0.id == pageID }
    }

    private func toolbarAction(_ i: Int) {
        if usingTool && i != 7 { return }
        cancelCarry()
        guard let bookID, let pageID, let book = store.notebook(bookID),
              let index = book.pages.firstIndex(where: { $0.id == pageID }) else { return }
        switch i {
        case 0: if index > 0 { finishSave(); openPage(book.pages[index - 1].id) }
        case 1: if index + 1 < book.pages.count { finishSave(); openPage(book.pages[index + 1].id) }
        case 2: finishSave(); showOverview()
        case 3:
            finishSave()
            let page = Page()
            mutate { try store.update(bookID) { $0.pages.insert(page, at: index + 1); $0.currentPage = page.id } }
            openPage(page.id)
        case 4: break // No patterned-paper controls in DrawPort.
        case 5: selectTool(0)
        case 7:
            if usingTool { quickEraserQueued = true }
            else { quickArmed = true; applyTool(); refreshToolbar() }
        case 8: selectTool(2)
        case 9: selectTool(3)
        case 10:
            rulerEnabled = !canvas.isRulerActive
            if rulerEnabled && currentTool != 0 && currentTool != 2 { selectTool(lastInkTool) }
            else { applyTool(); refreshToolbar() }
        case 11, 12:
            let step = i == 11 ? 1 : -1
            if currentTool == 2 && !quickArmed {
                markerWidthIndex = min(markerWidths.count - 1, max(0, markerWidthIndex + step))
            } else if currentTool == 0 && !quickArmed {
                widthIndex = min(widths.count - 1, max(0, widthIndex + step))
            }
            applyTool()
            refreshToolbar()
        case 20: break // Existing favorite metadata remains, but there is no UI to change it.
        case 21, 22:
            mutate {
                try saveCanvasIfChanged()
                let drawing = i == 21 ? try store.undo(book: bookID, page: pageID)
                                      : try store.redo(book: bookID, page: pageID)
                if let drawing {
                    setDrawing(drawing)
                    if let page = activePage() { try aiObjects.load(store.objects(book: bookID, page: page), store: store) }
                }
            }
        default: break
        }
    }

    private func setDrawing(_ drawing: PKDrawing) {
        saveWork?.cancel()
        loadingDrawing = true
        // Reusing archived PKDrawing state in the live canvas can resurrect
        // removed strokes on the next contact. Rebuild from the visible strokes,
        // including masks and transforms. Our snapshots retain the undo branches.
        canvas.drawing = PKDrawing(strokes: drawing.strokes)
        // Use PencilKit's drawing equality, not serialized bytes. Assignment and
        // rendering can change the archive without changing the user's ink.
        savedDrawing = canvas.drawing
        loadingDrawing = false
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        handlePencilSqueeze(phase: squeeze.phase)
    }

    func handlePencilSqueeze(phase: UIPencilInteraction.Phase) {
        guard phase == .ended, pageViewport != nil else { return }
        if let squeezePalette {
            squeezePalette.removeFromSuperview()
            self.squeezePalette = nil
            return
        }
        guard !usingTool else { return }
        let menu = UIView(frame: CGRect(x: max(0, (view.bounds.width - 320) / 2),
                                      y: max(55, (view.bounds.height - 175) / 2),
                                      width: 320, height: 175))
        menu.accessibilityIdentifier = "pencilSqueezePalette"
        let arc = UIBezierPath()
        arc.move(to: CGPoint(x: 15, y: 150))
        arc.addArc(withCenter: CGPoint(x: 160, y: 150), radius: 145,
                   startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
        arc.close()
        let background = CAShapeLayer()
        background.path = arc.cgPath
        background.fillColor = UIColor(white: 0.08, alpha: 0.94).cgColor
        menu.layer.addSublayer(background)
        let actions: [(String, String, () -> Void)] = [
            ("pencil.tip", "Pen", { [weak self] in self?.selectTool(0) }),
            ("highlighter", "Highlighter", { [weak self] in self?.selectTool(2) }),
            ("eraser.fill", "Quick eraser", { [weak self] in self?.toolbarAction(7) }),
            ("lasso", "Selection", { [weak self] in self?.selectTool(3) }),
            ("paintpalette", "Change current color", { [weak self] in
                guard let self else { return }
                let picker = UIColorPickerViewController()
                picker.selectedColor = self.inkColors[self.currentInk]
                picker.supportsAlpha = false
                picker.delegate = self
                self.editingColorIndex = self.currentInk
                self.present(picker, animated: true)
            })
        ]
        for (index, entry) in actions.enumerated() {
            let b = button(entry.0, label: entry.1) { [weak self] in
                self?.squeezePalette?.removeFromSuperview()
                self?.squeezePalette = nil
                entry.2()
            }
            b.tintColor = .white
            b.backgroundColor = UIColor(white: 0.28, alpha: 1)
            b.layer.cornerRadius = 23
            let angle = CGFloat.pi + CGFloat(index) * CGFloat.pi / CGFloat(actions.count - 1)
            b.frame = CGRect(x: 160 + 105 * cos(angle) - 23,
                             y: 150 + 105 * sin(angle) - 23,
                             width: 46, height: 46)
            menu.addSubview(b)
        }
        view.addSubview(menu)
        squeezePalette = menu
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { usingTool = true }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false
        if shapeModeEnabled && currentTool == 0 && !quickArmed && pageViewport != nil,
           let last = canvas.drawing.strokes.last, let replacement = ShapeSnap.recognized(last) {
            loadingDrawing = true
            canvas.drawing = PKDrawing(strokes: Array(canvas.drawing.strokes.dropLast()) + [replacement])
            loadingDrawing = false
        }
        #if DEBUG && targetEnvironment(simulator)
        keyboardDebugToolEnds += 1
        #endif
        dismissSelectionKeyboard()
        if quickArmed || quickEraserQueued {
            quickArmed = quickEraserQueued
            quickEraserQueued = false
            if quickArmed {
                applyTool()
                refreshToolbar()
            } else {
                selectTool(0)
            }
        }
        scheduleSave()
    }
    func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
        #if DEBUG && targetEnvironment(simulator)
        keyboardDebugSelectionChanges += 1
        #endif
        dismissSelectionKeyboard()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !loadingDrawing && !usingTool && canvas.drawing != savedDrawing { scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.usingTool else { return }
            self.finishSave()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func saveCanvasIfChanged() throws {
        saveWork?.cancel()
        guard let bookID, let pageID, !loadingDrawing else { return }
        let drawing = canvas.drawing
        guard drawing != savedDrawing else { return }
        try store.commit(book: bookID, page: pageID, drawing: drawing)
        savedDrawing = drawing
    }

    func finishSave() {
        mutate { try saveCanvasIfChanged() }
    }

    // All pages in a scrollable overview: no batches of nine or hidden page numbers.
    func showOverview() {
        guard let bookID, let book = store.notebook(bookID), DocumentOrientation.saved().fits(book.orientation) else { showHome(); return }
        let previousOffset = overviewScroll?.contentOffset.y ?? 0
        pageID = nil
        documentOpened(bookID)
        clear()
        let pages = deletedMode ? book.deleted : book.pages
        let home = button("chevron.left", label: "Documents") { [weak self] in self?.deletedMode = false; self?.showHome() }
        let deleted = button(deletedMode ? "square.grid.2x2" : "trash", label: deletedMode ? "Pages" : "Deleted pages") { [weak self] in
            self?.deletedMode.toggle(); self?.selectedPage = nil; self?.overviewScroll = nil; self?.showOverview()
        }
        let add = button("plus", label: "New page") { [weak self] in
            guard let self, let bookID = self.bookID, self.store.notebook(bookID) != nil, !self.deletedMode else { return }
            let page = Page()
            self.mutate { try self.store.update(bookID) { $0.pages.append(page); $0.currentPage = page.id } }
            self.openPage(page.id)
        }
        add.isHidden = deletedMode
        let title = UILabel()
        title.textAlignment = .center
        title.font = .preferredFont(forTextStyle: .headline)
        title.text = deletedMode ? "Deleted pages (\(pages.count))" : "\(book.name) • \(pages.count) pages"
        let header = UIStackView(arrangedSubviews: [home, title, add, deleted])
        header.axis = .horizontal
        header.heightAnchor.constraint(equalToConstant: 48).isActive = true
        for control in [home, deleted] { control.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        if !deletedMode { add.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        let grid = UIStackView()
        grid.accessibilityIdentifier = "pageOverviewGrid"
        grid.axis = .vertical
        grid.distribution = .fill
        grid.spacing = 8
        grid.backgroundColor = UIColor(white: 0.96, alpha: 1)
        for r in 0..<max(1, (pages.count + 2) / 3) {
            var cells: [UIView] = []
            for c in 0..<3 {
                let n = r * 3 + c
                guard n < pages.count else { cells.append(UIView()); continue }
                let page = pages[n]
                let cell = UIButton(type: .custom)
                cell.backgroundColor = .white
                cell.layer.borderWidth = page.id == selectedPage ? 3 : 0
                cell.layer.borderColor = UIColor.systemBlue.cgColor
                cell.accessibilityLabel = "Page \(n + 1)"
                if let drawing = try? store.drawing(book: bookID, page: page) {
                    cell.setImage(try? PageComposite.image(drawing: drawing, objects: store.objects(book: bookID, page: page),
                        store: store, background: page.background,
                        size: DocumentOrientation(metadata: book.orientation).pageSize, scale: 0.18), for: .normal)
                } else {
                    cell.setTitle("Unreadable", for: .normal)
                }
                cell.imageView?.contentMode = .scaleAspectFit
                cell.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if self.deletedMode { self.selectedPage = page.id; self.showOverview() }
                    else { self.openPage(page.id) }
                }, for: .touchUpInside)
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(selectPage(_:)))
                hold.minimumPressDuration = 0.4
                cell.accessibilityIdentifier = page.id.uuidString
                cell.addGestureRecognizer(hold)
                let number = UILabel()
                number.text = "Page \(n + 1)"
                number.textAlignment = .center
                number.font = .preferredFont(forTextStyle: .footnote)
                number.textColor = .label
                number.heightAnchor.constraint(equalToConstant: 25).isActive = true
                let numberedCell = UIStackView(arrangedSubviews: [cell, number])
                numberedCell.axis = .vertical
                numberedCell.spacing = 2
                cells.append(numberedCell)
            }
            grid.addArrangedSubview(row(cells, height: 178))
        }
        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = "allPagesScrollView"
        scroll.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        overviewScroll = scroll
        let actions: [(String, String, () -> Void)] = deletedMode ? [
            ("arrow.uturn.backward", "Restore page", { [weak self] in self?.restorePage() })
        ] : [
            ("document.on.document", "Duplicate to left", { [weak self] in self?.duplicatePage() }),
            ("trash", "Move to Deleted", { [weak self] in self?.deletePage() }),
            ("arrow.left", "Move left", { [weak self] in self?.movePage(-1) }),
            ("arrow.right", "Move right", { [weak self] in self?.movePage(1) })
        ]
        let footer = row(actions.map { symbol, label, action in
            let b = button(symbol, label: label, action: action)
            b.isEnabled = selectedPage != nil
            return b
        }, height: 48)
        vertical([header, scroll, footer])
        DispatchQueue.main.async { [weak scroll] in
            guard let scroll else { return }
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(previousOffset, maximum)), animated: false)
        }
    }

    @objc private func selectPage(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let string = gesture.view?.accessibilityIdentifier,
              let id = UUID(uuidString: string) else { return }
        selectedPage = id
        showOverview()
    }

    private func duplicatePage() {
        guard let bookID, let selectedPage, let page = store.notebook(bookID)?.pages.first(where: { $0.id == selectedPage }) else { return }
        mutate { try store.duplicate(book: bookID, page: page) }
        showOverview()
    }

    private func deletePage() {
        guard let bookID, let selectedPage else { return }
        mutate { try store.update(bookID) { book in
            guard book.pages.count > 1, let i = book.pages.firstIndex(where: { $0.id == selectedPage }) else { return }
            book.deleted.append(book.pages.remove(at: i))
            if book.currentPage == selectedPage { book.currentPage = book.pages[min(i, book.pages.count - 1)].id }
        } }
        self.selectedPage = nil
        showOverview()
    }

    private func restorePage() {
        guard let bookID, let selectedPage else { return }
        mutate { try store.update(bookID) { book in
            guard let i = book.deleted.firstIndex(where: { $0.id == selectedPage }) else { return }
            book.pages.append(book.deleted.remove(at: i))
        } }
        self.selectedPage = nil
        showOverview()
    }

    private func movePage(_ delta: Int) {
        guard let bookID, let selectedPage else { return }
        mutate { try store.update(bookID) { book in
            guard let i = book.pages.firstIndex(where: { $0.id == selectedPage }), book.pages.indices.contains(i + delta) else { return }
            book.pages.swapAt(i, i + delta)
        } }
        showOverview()
    }
}
