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
                if oldValue { endEditing(true) }
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
        // Match the sheet in the letterbox area; avoid a dark strip below the page.
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        surface.backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
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
        backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
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
        ctx.setFillColor(UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

final class DrawController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver, UIColorPickerViewControllerDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
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
    private weak var pageArea: UIStackView?
    private weak var overviewPanel: UIView?
    private var overviewVisible = false
    private var bottomPaperFill: UIView?
    private var selectedPage: UUID?
    private var selectedPages = Set<UUID>()
    private var selectingPages = false
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
    // Use Apple's picker only. It is never registered as a visible/docked toolbar.
    private let nativeToolPicker = PKToolPicker()
    private var syncingNativeToolPicker = false
    private var eraserByPixel = UserDefaults.standard.bool(forKey: "eraserByPixel")
    private var shapeModeEnabled = false
    private var shapeStartStrokeCount = 0
    private var shapeFinalizeWork: DispatchWorkItem?
    private var shapeCandidatePage: UUID?
    private var lastProcessedShape: Date?
    private var heldShapeCandidate = false
    private var selectedStrokeIndex: Int?
    private var selectedStrokePage: UUID?
    private var selectionOutline: CAShapeLayer?
    private var editingStrokeColorIndex: Int?
    private weak var strokeTapRecognizer: UITapGestureRecognizer?
    private weak var resizeRecognizer: UIPanGestureRecognizer?
    private var resizeStart: (index: Int, stroke: PKStroke, anchor: CGPoint, corner: CGPoint)?
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


    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
        if let saved = UserDefaults.standard.array(forKey: "customInkColors") as? [[Double]], saved.count == inkColors.count {
            for (index, components) in saved.enumerated() where index != 7 && components.count == 3 && components.allSatisfy({ (0...1).contains($0) }) {
                inkColors[index] = UIColor(red: components[0], green: components[1], blue: components[2], alpha: 1)
            }
        }
        // Purple is semantic question/context ink, not an editable cosmetic slot.
        inkColors[7] = QuestionInk.color
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
        let shapeHold = PencilShapeHold(target: nil, action: nil)
        shapeHold.delegate = self
        shapeHold.onHold = { [weak self] in
            guard let self, self.usingTool, self.currentTool == 0, !self.quickArmed,
                  self.pageViewport != nil else { return }
            self.heldShapeCandidate = true
        }
        shapeHold.onMoveAfterHold = { [weak self] in self?.heldShapeCandidate = false }
        canvas.addGestureRecognizer(shapeHold)
        let strokeTap = UITapGestureRecognizer(target: self, action: #selector(selectStrokeAtTap(_:)))
        strokeTap.cancelsTouchesInView = false
        strokeTap.delegate = self
        canvas.addGestureRecognizer(strokeTap)
        strokeTapRecognizer = strokeTap
        let resize = UIPanGestureRecognizer(target: self, action: #selector(resizeUsingHandle(_:)))
        resize.delegate = self
        canvas.addGestureRecognizer(resize)
        resizeRecognizer = resize
        canvas.addInteraction(UIEditMenuInteraction(delegate: self))
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is PencilShapeHold || gestureRecognizer === strokeTapRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === resizeRecognizer else { return true }
        guard currentTool == 3, let stroke = selectedStroke() else { return false }
        let location = gestureRecognizer.location(in: canvas)
        return stroke.renderBounds.insetBy(dx: -9, dy: -9).corners.contains { hypot($0.x - location.x, $0.y - location.y) < 24 }
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
        shapeFinalizeWork?.cancel()
        shapeFinalizeWork = nil
        shapeCandidatePage = nil
        heldShapeCandidate = false
        clearStrokeSelection()
        pageArea = nil
        overviewPanel = nil
        overviewVisible = false
        bottomPaperFill?.removeFromSuperview()
        bottomPaperFill = nil
        nativeToolPicker.setVisible(false, forFirstResponder: canvas)
        nativeToolPicker.removeObserver(canvas)
        nativeToolPicker.removeObserver(self)
        canvas.resignFirstResponder()
        selectedPages.removeAll()
        selectingPages = false
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
        b.tintColor = UIColor(white: 0.96, alpha: 1)
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
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
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
            b.tintColor = UIColor(white: 0.96, alpha: 1)
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
            b.tintColor = UIColor(white: 0.96, alpha: 1)
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
                UIMenu(title: "Move to", image: UIImage(systemName: "folder"), children: destinations),
                UIAction(title: "Delete notebook", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmNotebookDeletion(book.id)
                }
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

    private func confirmNotebookDeletion(_ id: UUID) {
        guard let book = store.notebook(id) else { return }
        let alert = UIAlertController(title: "Delete notebook?",
            message: "Delete \"\(book.name)\" and its \(book.pages.count) pages? This cannot be undone in the app.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete notebook", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.store.deleteNotebook(id)
                self.showHome()
            } catch {
                DispatchQueue.main.async { [weak self] in self?.failure(error) }
            }
        })
        present(alert, animated: true)
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
        let endpoint = DrawEndpoints.configured("ai")
        if endpoint.host?.hasSuffix(".example.invalid") == true || DrawEndpoints.token.isEmpty {
            let alert = UIAlertController(title: "AI suggestions need a server",
                message: "The original Draw AI workflow and purple context ink are available, but this port has no configured AI service. No page or private note was uploaded.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
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
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
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
            ("Notebook tabs", "showNotebookTabs"),
            ("Page overview shortcut", "showOverviewShortcut"),
            ("Selection tool", "showSelectionControl"), ("Ruler", "showRulerControl"),
            ("Carry to next page", "showCarryControl"),
            ("Shapes tool", "showShapesControl"), ("AI suggestions", "showAIControl")
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
                var configuration = UIButton.Configuration.plain()
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
                configuration.baseForegroundColor = active ? .white : UIColor(white: 0.82, alpha: 1)
                tab.configuration = configuration
                tab.backgroundColor = active ? UIColor(white: 0.25, alpha: 1) : .clear
                tab.layer.cornerRadius = 9
                tab.titleLabel?.font = .systemFont(ofSize: 15, weight: active ? .semibold : .regular)
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
        let home = button("chevron.left", label: "Notebooks") { [weak self] in
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
        let previous = button("chevron.left", label: "Previous page") { [weak self] in self?.toolbarAction(0) }
        let next = button("chevron.right", label: "Next page") { [weak self] in self?.toolbarAction(1) }
        let addPage = button("plus", label: "New following page") { [weak self] in self?.toolbarAction(3) }
        if let index = book.pages.firstIndex(where: { $0.id == page.id }) {
            previous.isEnabled = index > 0
            next.isEnabled = index + 1 < book.pages.count
        }
        let overview = button("rectangle.split.2x1", label: "Page overview sidebar") { [weak self] in self?.toolbarAction(2) }
        overview.isHidden = !controlVisible("showOverviewShortcut")
        let more = button("ellipsis", label: "Notebook options") {}
        more.menu = UIMenu(children: [
            UIAction(title: "New page", image: UIImage(systemName: "plus")) { [weak self] _ in self?.toolbarAction(3) },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.finishSave()
                self?.showSettings()
            },
            UIAction(title: "Delete notebook", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmNotebookDeletion(book.id)
            }
        ])
        more.showsMenuAsPrimaryAction = true
        let header = UIStackView(arrangedSubviews: [home, notebooks, previous, next, addPage, overview, more])
        header.axis = .horizontal
        header.alignment = .fill
        header.spacing = 4
        header.backgroundColor = UIColor(white: 0.105, alpha: 1)
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        home.widthAnchor.constraint(equalToConstant: 44).isActive = true
        for control in [previous, next, addPage, more] {
            control.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        if !overview.isHidden { overview.widthAnchor.constraint(equalToConstant: 44).isActive = true }
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
        let keepOverview = overviewVisible
        clear()
        // The status-bar safe area and notebook header form one dark top bar.
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
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
        let pagesAndCanvas = UIStackView(arrangedSubviews: [work])
        pagesAndCanvas.axis = .horizontal
        pageArea = pagesAndCanvas
        let workArea = UIStackView(arrangedSubviews: position.comesFirst ? [bar, pagesAndCanvas] : [pagesAndCanvas, bar])
        workArea.axis = position.isVertical ? .horizontal : .vertical
        vertical([drawingHeader(book: book, page: page), workArea])
        if keepOverview { displayOverviewPanel() }
        updateBottomSafeAreaChrome()
        // Experiment: briefly activate Apple's picker, then hide it. On iPadOS
        // 18 the never-activated hidden picker only yielded system Undo/Redo.
        // No custom squeeze handler/UI is installed. Real Pencil testing will
        // tell us whether the system retains its native tool arc after hiding.
        nativeToolPicker.overrideUserInterfaceStyle = .dark
        nativeToolPicker.colorUserInterfaceStyle = .light
        nativeToolPicker.showsDrawingPolicyControls = false
        nativeToolPicker.addObserver(canvas)
        nativeToolPicker.addObserver(self)
        nativeToolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
        syncNativeToolSelection()
        applyTool()
        let openedPage = page.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.pageID == openedPage, self.pageViewport != nil else { return }
            self.nativeToolPicker.setVisible(false, forFirstResponder: self.canvas)
        }
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
        shapeFinalizeWork?.cancel()
        shapeCandidatePage = nil
        heldShapeCandidate = false
        clearStrokeSelection()
        UserDefaults.standard.set(tool, forKey: "tool")
        if tool == 0 || tool == 2 {
            lastInkTool = tool
            UserDefaults.standard.set(tool, forKey: "lastInkTool")
        } else { rulerEnabled = false }
        quickArmed = false
        quickEraserQueued = false
        applyTool()
        if pageViewport != nil { syncNativeToolSelection(); applyTool() }
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
        let keepShapes = shapeModeEnabled && lastInkTool == 0
        selectTool(lastInkTool)
        if keepShapes { shapeModeEnabled = true; refreshToolbar() }
    }

    @objc private func configureInkColor(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton,
              inkColors.indices.contains(button.tag), presentedViewController == nil else { return }
        if button.tag == 7 {
            let alert = UIAlertController(title: "Context ink", message: "Purple marks questions and context for AI suggestions. Its exact shade must stay fixed so the ink remains recognizable.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let index = button.tag
        editingColorIndex = index
        let picker = InkPaletteController(color: inkColors[index],
            favorites: [inkColors[0], inkColors[5], inkColors[2], inkColors[6]]) { [weak self] color in
            self?.updateInkColor(index: index, color: color)
        }
        picker.onWidth = { [weak self] width in
            guard let self else { return }
            self.widthIndex = self.widths.indices.min(by: { abs(self.widths[$0] - width) < abs(self.widths[$1] - width) }) ?? self.widthIndex
            self.applyTool()
            self.refreshToolbar()
        }
        picker.popoverPresentationController?.sourceView = button
        picker.popoverPresentationController?.sourceRect = button.bounds
        picker.popoverPresentationController?.permittedArrowDirections = [.left, .right]
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        if let index = editingStrokeColorIndex {
            recolorSelectedStroke(at: index, color: viewController.selectedColor)
        } else if let index = editingColorIndex {
            updateInkColor(index: index, color: viewController.selectedColor)
        }
    }

    private func updateInkColor(index: Int, color rawColor: UIColor) {
        guard inkColors.indices.contains(index), index != 7 else { return }
        let color = rawColor.resolvedColor(with: traitCollection)
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
        if currentInk != index { selectInk(index) }
        else { applyTool(); refreshToolbar() }
    }

    @objc private func configureStrokeWidth(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let source = gesture.view, presentedViewController == nil else { return }
        let isMarker = source.tag == 2
        let choices = isMarker ? markerWidths : widths
        let picker = StrokeWidthController(name: isMarker ? "Highlighter" : (source.accessibilityIdentifier == "shapeMode" ? "Shapes" : "Pen"),
                                           sizes: choices, selected: isMarker ? markerWidthIndex : widthIndex) { [weak self] index in
            guard let self else { return }
            if isMarker { self.markerWidthIndex = index }
            else { self.widthIndex = index }
            if (isMarker && self.currentTool == 2 || !isMarker && self.currentTool == 0) && !self.quickArmed {
                self.applyTool()
            }
            self.refreshToolbar()
        }
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = source
        picker.popoverPresentationController?.sourceRect = source.bounds
        picker.popoverPresentationController?.permittedArrowDirections = [.left, .right, .up, .down]
        present(picker, animated: true)
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
        } else if currentTool == 1 {
            canvas.tool = PKEraserTool(eraserByPixel ? .bitmap : .vector)
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
            if i <= 4 { b.isHidden = true } // Page navigation/overview appear once, in the top bar.
            if i == 8 { b.isHidden = !controlVisible("showSelectionControl") }
            if i == 9 { b.isHidden = !controlVisible("showRulerControl") }
            if i == 10 || i == 11 { b.isHidden = true } // Width lives in tool long-press menus.
            if i == 6 {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(configureEraser(_:)))
                hold.minimumPressDuration = 0.45
                b.addGestureRecognizer(hold)
            } else if i == 5 || i == 7 {
                b.tag = i == 7 ? 2 : 0
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(configureStrokeWidth(_:)))
                hold.minimumPressDuration = 0.45
                b.addGestureRecognizer(hold)
            }
            controls.append(b)
            buttons.append(b)
        }
        for i in inkColors.indices {
            let b = UIButton(type: .system)
            b.backgroundColor = .clear
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
                badge.textColor = .black
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
            if !UserDefaults.standard.bool(forKey: "showAllColors") && ![0, 2, 5, 6, 7].contains(i) { b.isHidden = true }
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(configureInkColor(_:)))
            longPress.minimumPressDuration = 0.45
            b.tag = i
            b.addGestureRecognizer(longPress)
            colorSwatches[i] = swatch
            controls.append(b)
            buttons.append(b)
        }
        // Present four familiar swatches plus the reserved purple context ink.
        let originalSwatches = Array(controls[12..<(12 + inkColors.count)])
        controls.replaceSubrange(12..<(12 + inkColors.count), with: [0, 5, 2, 6, 7, 1, 3, 4].map { originalSwatches[$0] })
        let ask = button("sparkles", label: "AI suggestions") { [weak self] in self?.askAI() }
        ask.accessibilityIdentifier = "askAI"
        aiButton = ask
        ask.isHidden = !controlVisible("showAIControl")
        // Restore the upstream control, but never submit private notes to a placeholder host.
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
        shapes.tag = 0
        let shapeWidthHold = UILongPressGestureRecognizer(target: self, action: #selector(configureStrokeWidth(_:)))
        shapeWidthHold.minimumPressDuration = 0.45
        shapes.addGestureRecognizer(shapeWidthHold)
        shapes.isHidden = !controlVisible("showShapesControl")
        controls.append(shapes)
        buttons.append(shapes)
        let strip = row(controls, height: position.isVertical ? 0 : 44)
        strip.axis = position.isVertical ? .vertical : .horizontal
        let base = UIView()
        base.accessibilityIdentifier = "drawingToolbar"
        base.backgroundColor = UIColor(white: 0.105, alpha: 1)
        if position.isVertical {
            base.widthAnchor.constraint(equalToConstant: 46).isActive = true
            let scroll = UIScrollView()
            scroll.showsVerticalScrollIndicator = false
            scroll.addSubview(strip)
            base.addSubview(scroll)
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: base.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: base.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: base.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: base.bottomAnchor),
                strip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                strip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                strip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                strip.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                strip.heightAnchor.constraint(equalToConstant: CGFloat(controls.filter { !$0.isHidden }.count) * 44)
            ])
        } else {
            base.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: base.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: base.trailingAnchor),
                strip.topAnchor.constraint(equalTo: base.topAnchor),
                strip.bottomAnchor.constraint(equalTo: base.bottomAnchor)
            ])
        }
        refreshToolbar()
        return base
    }

    private func refreshToolbar() {
        guard buttons.count == 12 + inkColors.count + 6 else { return }
        for (i, b) in buttons.enumerated() {
            b.layer.borderWidth = 0
            b.alpha = b.isEnabled ? 1 : 0.65
            let selected = !quickArmed && ((i == 5 && currentTool == 0) || (i == 7 && currentTool == 2) || (i == 8 && currentTool == 3))
                || (i == 6 && quickArmed) || (i == 9 && canvas.isRulerActive)
                || (i == 16 + inkColors.count && carryOverlay != nil)
                || (i == 17 + inkColors.count && shapeModeEnabled)
            b.isSelected = selected
            if selected {
                b.backgroundColor = UIColor(white: 0.29, alpha: 1)
            } else if i < 12 || i >= 12 + inkColors.count { b.backgroundColor = .clear }
        }
        buttons[5].accessibilityValue = String(format: "%g pt", Double(widths[widthIndex]))
        buttons[7].accessibilityValue = String(format: "%g pt", Double(markerWidths[markerWidthIndex]))
        buttons[6].accessibilityValue = eraserByPixel ? "Pixel" : "Whole stroke"
        buttons[13 + inkColors.count].setImage(UIImage(systemName: activePage()?.starred == true ? "star.fill" : "star"), for: .normal)
        aiButton?.isEnabled = bookID.map { !busyDocuments.contains($0) } ?? false
        aiButton?.alpha = aiButton?.isEnabled == true ? 1 : 0.65
        for i in inkColors.indices {
            let b = buttons[12 + i]
            b.isSelected = i == currentInk
            b.layer.borderWidth = i == currentInk ? 3 : 0
            b.layer.borderColor = UIColor.systemBlue.cgColor
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
        clearStrokeSelection()
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


    private func syncNativeToolSelection() {
        let match = nativeToolPicker.toolItems.first { item in
            if currentTool == 3 { return item is PKToolPickerLassoItem }
            if currentTool == 1 { return item is PKToolPickerEraserItem }
            guard let ink = item as? PKToolPickerInkingItem else { return false }
            return (ink.inkingTool.ink.inkType == .marker) == (currentTool == 2)
        }
        guard let match else { return }
        syncingNativeToolPicker = true
        nativeToolPicker.selectedToolItemIdentifier = match.identifier
        syncingNativeToolPicker = false
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        guard pageViewport != nil, !syncingNativeToolPicker else { return }
        let item = toolPicker.selectedToolItem
        if let ink = item as? PKToolPickerInkingItem {
            currentTool = ink.inkingTool.ink.inkType == .marker ? 2 : 0
            lastInkTool = currentTool
            UserDefaults.standard.set(currentTool, forKey: "tool")
            UserDefaults.standard.set(currentTool, forKey: "lastInkTool")
        } else if item is PKToolPickerLassoItem {
            currentTool = 3
            UserDefaults.standard.set(3, forKey: "tool")
        } else if let eraser = item as? PKToolPickerEraserItem {
            currentTool = 1
            eraserByPixel = eraser.eraserTool.eraserType == .bitmap
            UserDefaults.standard.set(eraserByPixel, forKey: "eraserByPixel")
            UserDefaults.standard.set(1, forKey: "tool")
        }
        quickArmed = false
        shapeModeEnabled = false
        clearStrokeSelection()
        canvas.selectionEditingEnabled = currentTool == 3
        refreshToolbar()
    }

    private func clearStrokeSelection() {
        selectionOutline?.removeFromSuperlayer()
        selectionOutline = nil
        selectedStrokeIndex = nil
        selectedStrokePage = nil
        editingStrokeColorIndex = nil
        resizeStart = nil
    }

    private func selectedStroke() -> PKStroke? {
        guard pageID == selectedStrokePage, let selectedStrokeIndex,
              canvas.drawing.strokes.indices.contains(selectedStrokeIndex) else { return nil }
        return canvas.drawing.strokes[selectedStrokeIndex]
    }

    private func showSelectedStrokeOutline() {
        selectionOutline?.removeFromSuperlayer()
        guard let stroke = selectedStroke() else { clearStrokeSelection(); return }
        let rect = stroke.renderBounds.insetBy(dx: -9, dy: -9)
        guard rect.width.isFinite, rect.height.isFinite, rect.width < 10_000, rect.height < 10_000 else { return }
        let outline = CAShapeLayer()
        outline.path = UIBezierPath(roundedRect: rect, cornerRadius: 10).cgPath
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.lineWidth = 2
        outline.lineDashPattern = [6, 5]
        for point in rect.corners {
            let handle = CAShapeLayer()
            handle.path = UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).cgPath
            handle.fillColor = UIColor.systemBlue.cgColor
            handle.strokeColor = UIColor.white.cgColor
            handle.lineWidth = 1.5
            outline.addSublayer(handle)
        }
        canvas.layer.addSublayer(outline)
        selectionOutline = outline
    }

    @objc private func selectStrokeAtTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, currentTool == 3, !usingTool, pageID != nil else { return }
        let location = gesture.location(in: canvas)
        var best: (index: Int, distance: CGFloat)?
        for (index, stroke) in canvas.drawing.strokes.enumerated() {
            guard stroke.renderBounds.insetBy(dx: -25, dy: -25).contains(location) else { continue }
            let path = Array(stroke.path)
            guard path.count > 1 else { continue }
            let strideLength = max(1, path.count / 100)
            let points = Swift.stride(from: 0, to: path.count, by: strideLength).map { path[$0].location.applying(stroke.transform) }
            guard points.count > 1 else { continue }
            for n in 1..<points.count {
                let a = points[n - 1], b = points[n], dx = b.x - a.x, dy = b.y - a.y
                let length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, ((location.x - a.x) * dx + (location.y - a.y) * dy) / length)) : 0
                let distance = hypot(location.x - a.x - t * dx, location.y - a.y - t * dy)
                if distance < 21 && (best == nil || distance < best!.distance) { best = (index, distance) }
            }
        }
        guard let best else { clearStrokeSelection(); return }
        selectedStrokeIndex = best.index
        selectedStrokePage = pageID
        showSelectedStrokeOutline()
        if let menu = canvas.interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
        }
    }

    private func imageOfSelectedStroke() -> UIImage? {
        guard let stroke = selectedStroke() else { return nil }
        let rect = stroke.renderBounds.insetBy(dx: -16, dy: -16)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              rect.width < 2000, rect.height < 2000 else { return nil }
        return PKDrawing(strokes: [stroke]).image(from: rect, scale: 2)
    }

    private func removeSelectedStroke() {
        guard let selectedStrokeIndex, selectedStroke() != nil else { return }
        var strokes = canvas.drawing.strokes
        strokes.remove(at: selectedStrokeIndex)
        clearStrokeSelection()
        loadingDrawing = true
        canvas.drawing = PKDrawing(strokes: strokes)
        loadingDrawing = false
        scheduleSave()
    }

    private func duplicateSelectedStroke() {
        guard let stroke = selectedStroke() else { return }
        let copy = PKDrawing(strokes: [stroke]).transformed(using: CGAffineTransform(translationX: 22, y: 22))
        var strokes = canvas.drawing.strokes
        strokes.append(contentsOf: copy.strokes)
        loadingDrawing = true
        canvas.drawing = PKDrawing(strokes: strokes)
        loadingDrawing = false
        self.selectedStrokeIndex = strokes.count - 1
        showSelectedStrokeOutline()
        scheduleSave()
    }

    @objc private func resizeUsingHandle(_ gesture: UIPanGestureRecognizer) {
        guard currentTool == 3, let index = selectedStrokeIndex else { return }
        let point = gesture.location(in: canvas)
        if gesture.state == .began {
            guard let stroke = selectedStroke() else { return }
            let rect = stroke.renderBounds.insetBy(dx: -9, dy: -9)
            guard let corner = rect.corners.min(by: { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }) else { return }
            let anchor = CGPoint(x: corner.x == rect.minX ? rect.maxX : rect.minX,
                                 y: corner.y == rect.minY ? rect.maxY : rect.minY)
            resizeStart = (index, stroke, anchor, corner)
        } else if gesture.state == .changed, let start = resizeStart,
                  canvas.drawing.strokes.indices.contains(start.index) {
            let dx = start.corner.x - start.anchor.x, dy = start.corner.y - start.anchor.y
            guard abs(dx) > 10, abs(dy) > 10 else { return }
            let fx = abs((point.x - start.anchor.x) / dx), fy = abs((point.y - start.anchor.y) / dy)
            let factor = max(0.25, min(4, max(fx, fy)))
            let transform = CGAffineTransform(translationX: start.anchor.x, y: start.anchor.y)
                .scaledBy(x: factor, y: factor).translatedBy(x: -start.anchor.x, y: -start.anchor.y)
            guard let scaled = PKDrawing(strokes: [start.stroke]).transformed(using: transform).strokes.first else { return }
            var strokes = canvas.drawing.strokes
            strokes[start.index] = scaled
            loadingDrawing = true
            canvas.drawing = PKDrawing(strokes: strokes)
            loadingDrawing = false
            showSelectedStrokeOutline()
        } else if gesture.state == .ended || gesture.state == .cancelled {
            resizeStart = nil
            scheduleSave()
        }
    }

    private func resizeSelectedStroke(_ factor: CGFloat) {
        guard let stroke = selectedStroke(), let selectedStrokeIndex else { return }
        let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: factor, y: factor).translatedBy(x: -center.x, y: -center.y)
        guard let scaled = PKDrawing(strokes: [stroke]).transformed(using: transform).strokes.first else { return }
        var strokes = canvas.drawing.strokes
        strokes[selectedStrokeIndex] = scaled
        loadingDrawing = true
        canvas.drawing = PKDrawing(strokes: strokes)
        loadingDrawing = false
        showSelectedStrokeOutline()
        scheduleSave()
    }

    private func recolorSelectedStroke(at index: Int, color: UIColor) {
        guard selectedStrokeIndex == index, let stroke = selectedStroke() else { return }
        let recolored = PKStroke(ink: PKInk(stroke.ink.inkType, color: color), path: stroke.path,
            transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
        var strokes = canvas.drawing.strokes
        strokes[index] = recolored
        loadingDrawing = true
        canvas.drawing = PKDrawing(strokes: strokes)
        loadingDrawing = false
        showSelectedStrokeOutline()
        scheduleSave()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selectedStroke() != nil, currentTool == 3 else { return nil }
        return UIMenu(children: [
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in
                guard let self, let image = self.imageOfSelectedStroke() else { return }
                UIPasteboard.general.image = image
                self.removeSelectedStroke()
            },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                if let image = self?.imageOfSelectedStroke() { UIPasteboard.general.image = image }
            },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelectedStroke() },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.removeSelectedStroke() },
            UIMenu(title: "Resize", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), children: [
                UIAction(title: "Smaller") { [weak self] _ in self?.resizeSelectedStroke(0.85) },
                UIAction(title: "Larger") { [weak self] _ in self?.resizeSelectedStroke(1.15) }
            ]),
            UIAction(title: "Style", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                guard let self, let index = self.selectedStrokeIndex, let stroke = self.selectedStroke() else { return }
                self.editingColorIndex = nil
                self.editingStrokeColorIndex = index
                let picker = UIColorPickerViewController()
                picker.overrideUserInterfaceStyle = .dark
                picker.selectedColor = stroke.ink.color
                picker.supportsAlpha = false
                picker.delegate = self
                self.present(picker, animated: true)
            },
            UIAction(title: "Take Screenshot", image: UIImage(systemName: "camera")) { [weak self] _ in
                guard let self, let image = self.imageOfSelectedStroke() else { return }
                let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = self.canvas
                share.popoverPresentationController?.sourceRect = self.selectedStroke()?.renderBounds ?? .zero
                self.present(share, animated: true)
            }
        ])
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        usingTool = true
        shapeFinalizeWork?.cancel()
        shapeStartStrokeCount = canvas.drawing.strokes.count
        shapeCandidatePage = pageID
        heldShapeCandidate = false
        lastProcessedShape = nil
    }

    private func scheduleShapeFinalize() {
        guard (shapeModeEnabled || heldShapeCandidate), currentTool == 0, !quickArmed, !usingTool,
              shapeCandidatePage == pageID, pageViewport != nil else { return }
        shapeFinalizeWork?.cancel()
        let startedWith = shapeStartStrokeCount
        let page = pageID
        let finalize = DispatchWorkItem { [weak self] in
            guard let self, self.pageID == page, self.shapeModeEnabled || self.heldShapeCandidate,
                  !self.usingTool, self.currentTool == 0, !self.quickArmed else { return }
            // PencilKit may publish the final stroke AFTER didEndUsingTool.
            let strokes = self.canvas.drawing.strokes
            guard strokes.count > startedWith, let last = strokes.last,
                  self.lastProcessedShape != last.path.creationDate else { return }
            self.lastProcessedShape = last.path.creationDate
            self.heldShapeCandidate = false
            guard let replacement = ShapeSnap.recognized(last) else { return }
            self.loadingDrawing = true
            self.canvas.drawing = PKDrawing(strokes: Array(strokes.dropLast()) + [replacement])
            self.loadingDrawing = false
            self.scheduleSave()
        }
        shapeFinalizeWork = finalize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: finalize)
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false
        scheduleShapeFinalize()
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
        if !loadingDrawing && !usingTool && canvas.drawing != savedDrawing {
            scheduleShapeFinalize()
            scheduleSave()
        }
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

    // Keep the active page visible while browsing page previews in a right sidebar.
    func showOverview() {
        guard let bookID, let book = store.notebook(bookID), DocumentOrientation.saved().fits(book.orientation) else { showHome(); return }
        if pageArea != nil {
            if overviewVisible { closeOverviewPanel() }
            else { displayOverviewPanel() }
            return
        }
        let offset = overviewScroll?.contentOffset.y ?? 0
        pageID = nil
        documentOpened(bookID)
        clear()
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
        vertical([overviewView(book: book, offset: offset)])
    }

    private func closeOverviewPanel() {
        overviewPanel?.removeFromSuperview()
        overviewPanel = nil
        overviewVisible = false
        selectedPages.removeAll()
        selectingPages = false
        updateBottomSafeAreaChrome()
    }

    private func displayOverviewPanel() {
        guard let pageArea, let bookID, let book = store.notebook(bookID), !overviewVisible else { return }
        let panel = overviewView(book: book, offset: 0)
        panel.backgroundColor = UIColor(white: 0.105, alpha: 1)
        pageArea.addArrangedSubview(panel)
        panel.widthAnchor.constraint(equalToConstant: max(250, min(370, view.bounds.width * 0.29))).isActive = true
        overviewPanel = panel
        overviewVisible = true
        updateBottomSafeAreaChrome()
    }

    /// Paint only beneath the page, leaving the dark left/right tool strip to
    /// continue all the way through the home-indicator safe area.
    private func updateBottomSafeAreaChrome() {
        bottomPaperFill?.removeFromSuperview()
        bottomPaperFill = nil
        guard pageViewport != nil else { return }
        let position = ToolbarPosition.saved()
        if position == .bottom { return } // Bottom toolbar itself continues to the screen edge.
        let paper = UIView()
        paper.backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
        paper.isUserInteractionEnabled = false
        paper.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(paper, belowSubview: content)
        let left: CGFloat = position == .left ? 46 : 0
        let sidebar: CGFloat = overviewVisible ? max(250, min(370, view.bounds.width * 0.29)) : 0
        let right: CGFloat = (position == .right ? 46 : 0) + sidebar
        NSLayoutConstraint.activate([
            paper.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            paper.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            paper.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: left),
            paper.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -right)
        ])
        bottomPaperFill = paper
    }

    private func refreshOverview() {
        guard let bookID, let book = store.notebook(bookID) else { return }
        if let panel = overviewPanel, let pageArea {
            let offset = overviewScroll?.contentOffset.y ?? 0
            panel.removeFromSuperview()
            let refreshed = overviewView(book: book, offset: offset)
            refreshed.backgroundColor = UIColor(white: 0.105, alpha: 1)
            pageArea.addArrangedSubview(refreshed)
            refreshed.widthAnchor.constraint(equalToConstant: max(250, min(370, view.bounds.width * 0.29))).isActive = true
            overviewPanel = refreshed
        } else { showOverview() }
    }

    private func overviewView(book: Notebook, offset previousOffset: CGFloat) -> UIView {
        let bookID = book.id
        let pages = book.pages
        let home = button(pageArea == nil ? "chevron.left" : "ellipsis", label: "Overview options") { [weak self] in
            guard let self else { return }
            if self.pageArea == nil { self.showHome() }
        }
        if pageArea != nil {
            home.menu = UIMenu(children: [
                UIAction(title: "Close overview", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.closeOverviewPanel() },
                UIAction(title: "Documents", image: UIImage(systemName: "house")) { [weak self] _ in self?.finishSave(); self?.showHome() }
            ])
            home.showsMenuAsPrimaryAction = true
        }
        let add = button("plus", label: "New page") { [weak self] in
            guard let self, let bookID = self.bookID, self.store.notebook(bookID) != nil else { return }
            let page = Page()
            self.mutate { try self.store.update(bookID) { $0.pages.append(page); $0.currentPage = page.id } }
            self.openPage(page.id)
        }
        // The page editor already has New page in its top bar.
        add.isHidden = pageArea != nil
        let select = button(selectingPages ? "checkmark.circle.fill" : "checkmark.circle", label: selectingPages ? "Done selecting" : "Select pages") { [weak self] in
            guard let self else { return }
            self.selectingPages.toggle()
            self.selectedPages.removeAll()
            self.selectedPage = nil
            self.refreshOverview()
        }
        select.setImage(nil, for: .normal)
        select.setTitle(selectingPages ? "Done" : "Select", for: .normal)
        select.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        let title = UILabel()
        title.textAlignment = .center
        title.font = .preferredFont(forTextStyle: .headline)
        title.text = selectingPages ? "\(selectedPages.count) selected"
            : pageArea == nil ? "\(book.name) • \(pages.count) pages" : "Overview"
        title.textColor = .white
        let header = UIStackView(arrangedSubviews: [home, title, add, select])
        header.axis = .horizontal
        header.heightAnchor.constraint(equalToConstant: 48).isActive = true
        home.widthAnchor.constraint(equalToConstant: 48).isActive = true
        select.widthAnchor.constraint(equalToConstant: 64).isActive = true
        if !add.isHidden { add.widthAnchor.constraint(equalToConstant: 48).isActive = true }
        let modes = UISegmentedControl(items: [UIImage(systemName: "square.grid.2x2")!, UIImage(systemName: "list.bullet")!])
        modes.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "overviewListMode") ? 1 : 0
        modes.addAction(UIAction { [weak self] _ in
            UserDefaults.standard.set(modes.selectedSegmentIndex == 1, forKey: "overviewListMode")
            self?.refreshOverview()
        }, for: .valueChanged)
        modes.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let listMode = modes.selectedSegmentIndex == 1
        let columns = listMode ? 1 : pageArea == nil ? 3 : 2
        let grid = UIStackView()
        grid.accessibilityIdentifier = "pageOverviewGrid"
        grid.axis = .vertical
        grid.distribution = .fill
        grid.spacing = 8
        grid.backgroundColor = UIColor(white: 0.15, alpha: 1)
        for r in 0..<max(1, (pages.count + columns - 1) / columns) {
            var cells: [UIView] = []
            for c in 0..<columns {
                let n = r * columns + c
                guard n < pages.count else { cells.append(UIView()); continue }
                let page = pages[n]
                let cell = UIButton(type: .custom)
                cell.backgroundColor = UIColor(red: 1, green: 0.995, blue: 0.956, alpha: 1)
                let checked = selectingPages && selectedPages.contains(page.id)
                cell.layer.borderWidth = checked || (!selectingPages && page.id == (selectedPage ?? pageID)) ? 3 : 0
                cell.layer.borderColor = UIColor.systemBlue.cgColor
                cell.accessibilityLabel = "Page \(n + 1)"
                cell.accessibilityValue = checked ? "Selected" : "Not selected"
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
                    if self.selectingPages { self.togglePageSelection(page.id) }
                    else { self.openPage(page.id) }
                }, for: .touchUpInside)
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(selectPage(_:)))
                hold.minimumPressDuration = 0.4
                cell.accessibilityIdentifier = page.id.uuidString
                cell.addGestureRecognizer(hold)
                let number = UILabel()
                number.text = checked ? "✓ \(n + 1)" : selectingPages ? "○ \(n + 1)" : "\(n + 1) ▾"
                number.textAlignment = .center
                number.font = .preferredFont(forTextStyle: .footnote)
                number.textColor = .label
                number.heightAnchor.constraint(equalToConstant: 25).isActive = true
                let numberedCell = UIStackView(arrangedSubviews: [cell, number])
                numberedCell.axis = .vertical
                numberedCell.spacing = 2
                cells.append(numberedCell)
            }
            grid.addArrangedSubview(row(cells, height: listMode ? 96 : pageArea == nil ? 178 : 208))
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
        let actions: [(String, String, () -> Void)] = [
            ("document.on.document", "Duplicate to left", { [weak self] in self?.duplicatePage() }),
            ("trash", "Delete page", { [weak self] in self?.deletePage() }),
            ("arrow.left", "Move left", { [weak self] in self?.movePage(-1) }),
            ("arrow.right", "Move right", { [weak self] in self?.movePage(1) })
        ]
        let footer: UIStackView
        if selectingPages {
            let all = button("checkmark.rectangle.stack", label: "Select all pages") { [weak self] in
                guard let self, let book = self.bookID.flatMap(self.store.notebook) else { return }
                self.selectedPages = Set(book.pages.map(\.id))
                self.refreshOverview()
            }
            let apply = button("trash", label: "Delete \(selectedPages.count) selected pages") { [weak self] in
                self?.confirmBatchPageAction()
            }
            apply.isEnabled = !selectedPages.isEmpty
            footer = row([all, apply], height: 48)
        } else {
            footer = row(actions.map { symbol, label, action in
                let b = button(symbol, label: label, action: action)
                b.isEnabled = selectedPage != nil
                return b
            }, height: 48)
        }
        let panel = UIStackView(arrangedSubviews: selectingPages || selectedPage != nil ? [header, modes, scroll, footer] : [header, modes, scroll])
        panel.axis = .vertical
        panel.spacing = 8
        DispatchQueue.main.async { [weak scroll] in
            guard let scroll else { return }
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: min(previousOffset, maximum)), animated: false)
        }
        return panel
    }

    @objc private func selectPage(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let string = gesture.view?.accessibilityIdentifier,
              let id = UUID(uuidString: string) else { return }
        if selectingPages { togglePageSelection(id) }
        else { selectedPage = id; refreshOverview() }
    }

    private func togglePageSelection(_ id: UUID) {
        guard let bookID, let book = store.notebook(bookID),
              book.pages.contains(where: { $0.id == id }) else { return }
        if !selectedPages.insert(id).inserted { selectedPages.remove(id) }
        refreshOverview()
    }

    private func confirmBatchPageAction() {
        guard selectingPages, let bookID else { return }
        confirmPageDeletion(selectedPages, bookID: bookID)
    }

    private func confirmPageDeletion(_ requested: Set<UUID>, bookID: UUID) {
        guard let book = store.notebook(bookID) else { return }
        let ids = requested.intersection(Set(book.pages.map(\.id)))
        guard !ids.isEmpty else { return }
        let all = ids.count == book.pages.count
        let message = "Delete \(ids.count) page\(ids.count == 1 ? "" : "s") from this notebook? This cannot be undone in the app.\(all ? " A new blank page will be created." : "")"
        let alert = UIAlertController(title: "Delete pages", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.batchPageAction(ids: ids, bookID: bookID)
        })
        present(alert, animated: true)
    }

    private func batchPageAction(ids: Set<UUID>, bookID: UUID) {
        do {
            if pageArea != nil { try saveCanvasIfChanged() }
            try store.deletePages(book: bookID, selected: ids)
        } catch { failure(error); return }
        selectedPages.removeAll()
        selectingPages = false
        selectedPage = nil
        if let book = store.notebook(bookID), let current = book.currentPage,
           pageArea != nil, pageID != current { openPage(current) }
        else { refreshOverview() }
    }

    private func duplicatePage() {
        guard let bookID, let selectedPage, let page = store.notebook(bookID)?.pages.first(where: { $0.id == selectedPage }) else { return }
        if pageArea != nil { finishSave() }
        mutate { try store.duplicate(book: bookID, page: page) }
        refreshOverview()
    }

    private func deletePage() {
        guard let bookID, let selectedPage else { return }
        confirmPageDeletion([selectedPage], bookID: bookID)
    }

    private func movePage(_ delta: Int) {
        guard let bookID, let selectedPage else { return }
        if pageArea != nil { finishSave() }
        mutate { try store.update(bookID) { book in
            guard let i = book.pages.firstIndex(where: { $0.id == selectedPage }), book.pages.indices.contains(i + delta) else { return }
            book.pages.swapAt(i, i + delta)
        } }
        refreshOverview()
    }
}
