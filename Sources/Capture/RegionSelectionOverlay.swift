import AppKit
import ScreenCaptureKit

struct RegionSelection {
    let pointsRect: CGRect  // In global display points (top-left origin, matching SCK coordinates)
    let scaleFactor: CGFloat
    let displayID: CGDirectDisplayID
}

enum RegionSelectionOutcome {
    case region(RegionSelection)
    case window
    case cancelled
}

@MainActor
final class RegionSelectionOverlay {

    private var allowsWindowSelection = true
    private var controlScreen: NSScreen?
    private var onControlSelection: ((RegionSelectionOutcome) -> Void)?

    func beginControlDrag(at point: CGPoint, completion: @escaping (RegionSelectionOutcome) -> Void) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { completion(.cancelled); return }
        controlScreen = screen
        onControlSelection = completion
        allowsWindowSelection = false
        showOverlays()
        selectionViews.first?.beginDrag(at: CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY))
    }

    func updateControlDrag(at point: CGPoint, ended: Bool = false) {
        guard let screen = controlScreen else { return }
        let local = CGPoint(x: min(max(point.x - screen.frame.minX, 0), screen.frame.width),
                            y: min(max(point.y - screen.frame.minY, 0), screen.frame.height))
        if ended { selectionViews.first?.endDrag(at: local) }
        else { selectionViews.first?.updateDrag(at: local) }
    }

    func cancelControlDrag() { if controlScreen != nil { finish(.cancelled) } }

    private var overlayWindows: [NSWindow] = []
    private var selectionViews: [SelectionView] = []
    private var continuation: CheckedContinuation<RegionSelectionOutcome, Never>?
    private var previousApp: NSRunningApplication?
    private var frozenFrames: [CGDirectDisplayID: FrozenScreenFrame] = [:]
    /// An area to start with, in global AppKit points, regardless of the remembered one.
    private var initialRect: CGRect?
    /// The area is for scrolling capture, so S confirms it as it does from a screenshot selection.
    private var isForScrollCapture = false
    /// The screenshot selection on screen, so the capture bar shown over it can back out of it.
    private static weak var active: RegionSelectionOverlay?

    /// Ends the selection and hands back the area that was selected in it, if any.
    @discardableResult
    static func cancelActive() -> RegionSelection? {
        guard let overlay = active else { return nil }
        let selection = overlay.selectionViews.lazy.compactMap { view in
            view.currentSelection.map { overlay.regionSelection(rect: $0, screen: view.screen) }
        }.first
        overlay.finish(.cancelled)
        return selection
    }

    /// Confirms the area selected on screen as Return does; false when nothing is selected yet.
    @discardableResult
    static func confirmActive() -> Bool {
        guard let overlay = active,
              let view = overlay.selectionViews.first(where: { $0.currentSelection != nil }),
              let rect = view.currentSelection else { return false }
        overlay.finishSelection(rect: rect, screen: view.screen)
        return true
    }

    /// Returns once the app that was frontmost is active again, so captures show its windows as focused.
    func selectRegion(allowsWindowSelection: Bool = true, frozenFrames: [CGDirectDisplayID: FrozenScreenFrame] = [:],
                      initialRect: CGRect? = nil, forScrollCapture: Bool = false) async -> RegionSelectionOutcome {
        self.allowsWindowSelection = allowsWindowSelection
        self.isForScrollCapture = forScrollCapture
        self.frozenFrames = frozenFrames
        self.initialRect = initialRect
        defer {
            self.frozenFrames = [:]
            self.initialRect = nil
        }
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        let outcome = await withCheckedContinuation { cont in
            self.continuation = cont
            showOverlays()
            if allowsWindowSelection {
                Self.active = self
                RecordingBarPresenter.shared.showOverRegionSelection(
                    on: ActiveDisplayResolver.activeDisplayID(preferPointer: true),
                    level: Self.overlayLevel.rawValue + 1)
            }
        }
        if let app = previousApp {
            previousApp = nil
            app.activate()
            for _ in 0..<25 where !app.isActive { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return outcome
    }

    private func showOverlays() {
        let crosshair = NSCursor.crosshair
        let capturesOnRelease = controlScreen != nil || AppPreferences.captureRegionOnRelease
        // Read before the overlays exist so they are not in the list.
        let windowRects = controlScreen == nil && allowsWindowSelection ? Self.visibleWindowRects() : []

        for screen in controlScreen.map({ [$0] }) ?? NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = Self.overlayLevel
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]

            let previousRegion = (controlScreen != nil ? nil
                : initialRect ?? (AppPreferences.preselectPreviousRegion ? AppPreferences.lastRegionRect : nil))
                .flatMap { screen.frame.contains($0) ? RegionGeometry.localRect(global: $0, screenFrame: screen.frame) : nil }
            let overlayView = SelectionView(
                screen: screen,
                cursor: crosshair,
                selection: previousRegion,
                capturesOnRelease: capturesOnRelease,
                windowRects: windowRects.compactMap {
                    let local = RegionGeometry.localRect(global: $0, screenFrame: screen.frame)
                        .intersection(CGRect(origin: .zero, size: screen.frame.size))
                    return local.width > 3 && local.height > 3 ? local : nil
                }
            ) { [weak self] rect in
                self?.finishSelection(rect: rect, screen: screen)
            } onCancel: { [weak self] in
                self?.finish(.cancelled)
            } onWindow: { [weak self] in
                if self?.allowsWindowSelection == true { self?.finish(.window) }
            }

            overlayView.onBeginSelection = { [weak self, weak overlayView] in
                self?.selectionViews.forEach { if $0 !== overlayView { $0.clearSelection() } }
            }
            if controlScreen == nil && allowsWindowSelection {
                overlayView.onScroll = { [weak self] rect in self?.startScrollCapture(rect: rect, screen: screen) }
            } else if controlScreen == nil && isForScrollCapture {
                overlayView.onScroll = { [weak self] rect in self?.finishSelection(rect: rect, screen: screen) }
            }
            if let frozenImage = ActiveDisplayResolver.displayID(for: screen).flatMap({ frozenFrames[$0]?.image }) {
                let backdrop = FrozenBackdropView(image: frozenImage, frame: NSRect(origin: .zero, size: screen.frame.size))
                overlayView.frame = backdrop.bounds
                overlayView.autoresizingMask = [.width, .height]
                backdrop.addSubview(overlayView)
                window.contentView = backdrop
            } else {
                window.contentView = overlayView
            }
            if controlScreen != nil { window.orderFrontRegardless() }
            else { window.makeKeyAndOrderFront(nil) }
            overlayWindows.append(window)
            selectionViews.append(overlayView)
        }

        // The non-activating panel takes keys without activating BetterShot, so the target window keeps focus.
        if controlScreen == nil {
            selectionViews.first(where: \.hasSelection)?.window?.makeKeyAndOrderFront(nil)
        }
        crosshair.push()
        crosshair.set()
    }

    private static let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))

    /// Normal windows in global AppKit points, frontmost first. BetterShot's own
    /// windows count only when captures can see them, such as an OCR result panel.
    private static func visibleWindowRects() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let isOwn = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID
            let isShared = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue != 0
            guard isOwn ? isShared && (layer == 0 || layer == NSWindow.Level.floating.rawValue) : layer == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width > 1, bounds.height > 1 else { return nil }
            // The top-left/bottom-left flip is its own inverse.
            return RegionGeometry.pointsRect(global: bounds, primaryHeight: primaryHeight)
        }
    }

    private func finishSelection(rect: CGRect, screen: NSScreen) {
        AppPreferences.lastRegionRect = RegionGeometry.globalRect(local: rect, screenFrame: screen.frame)
        finish(.region(regionSelection(rect: rect, screen: screen)))
    }

    /// Ends the screenshot selection and scrolls the selected area instead, without selecting it again.
    private func startScrollCapture(rect: CGRect, screen: NSScreen) {
        CaptureOrchestrator.shared.pendingScrollRegion = regionSelection(rect: rect, screen: screen)
        finish(.cancelled)
        Task { await CaptureOrchestrator.shared.performCapture(.scrollCapture, on: screen) }
    }

    private func regionSelection(rect: CGRect, screen: NSScreen) -> RegionSelection {
        let globalRect = RegionGeometry.globalRect(local: rect, screenFrame: screen.frame)
        return RegionSelection(
            pointsRect: RegionGeometry.pointsRect(global: globalRect, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height),
            scaleFactor: screen.backingScaleFactor,
            displayID: ActiveDisplayResolver.displayID(for: screen) ?? CGMainDisplayID()
        )
    }

    private func finish(_ outcome: RegionSelectionOutcome) {
        if Self.active === self {
            Self.active = nil
            RecordingBarPresenter.shared.endRegionSelection()
        }
        NSCursor.pop()
        closeOverlays()
        continuation?.resume(returning: outcome)
        continuation = nil
        let callback = onControlSelection
        onControlSelection = nil
        controlScreen = nil
        callback?(outcome)
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        selectionViews.removeAll()
    }
}

// MARK: - Overlay Window (prevents AppKit cursor resets)

private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        // Swallow cursor updates — we manage the cursor ourselves in SelectionView
    }
}

// MARK: - Frozen Backdrop

private final class FrozenBackdropView: NSView {
    private let image: CGImage

    init(image: CGImage, frame: NSRect) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
    }
}

// MARK: - Selection View

private final class SelectionView: NSView {
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var mouseLocation: NSPoint?
    private var hoveredWindow: CGRect?
    private let windowRects: [CGRect]
    private var selection: CGRect?
    private var movesSelection: Bool
    var hasSelection: Bool { selection != nil }
    var currentSelection: CGRect? { selection }
    private var activeHandle: RegionHandle?
    private var handleDragOrigin: NSPoint?
    private var handleDragRect: CGRect?
    var onBeginSelection: () -> Void = {}
    /// Set for screenshots: S hands the selected area to scrolling capture.
    var onScroll: ((CGRect) -> Void)?
    private var trackingArea: NSTrackingArea?
    let screen: NSScreen
    private let crosshairCursor: NSCursor
    private let capturesOnRelease: Bool
    private let onSelect: (CGRect) -> Void
    private let onCancel: () -> Void
    private let onWindow: () -> Void

    init(
        screen: NSScreen,
        cursor: NSCursor,
        selection: CGRect?,
        capturesOnRelease: Bool,
        windowRects: [CGRect],
        onSelect: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void,
        onWindow: @escaping () -> Void
    ) {
        self.screen = screen
        self.crosshairCursor = cursor
        self.selection = selection
        self.movesSelection = selection == nil
        self.capturesOnRelease = capturesOnRelease
        self.windowRects = windowRects
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onWindow = onWindow
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingAreas()
        if let window {
            let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(loc) { updateHover(at: loc) }
        }
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: crosshairCursor)
        crosshairCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        crosshairCursor.set()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if let start = dragStart, let current = dragCurrent {
            drawSelection(start: start, current: current)
        } else if let selection {
            drawAdjustableSelection(selection)
        } else if let hoveredWindow {
            drawHoveredWindow(hoveredWindow)
        } else if let mouse = mouseLocation {
            drawGuideLines(at: mouse)
        }
    }

    private func drawGuideLines(at point: NSPoint) {
        let lineColor = NSColor.white.withAlphaComponent(0.4)
        lineColor.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 0.5

        // Vertical guide line
        path.move(to: NSPoint(x: point.x, y: bounds.minY))
        path.line(to: NSPoint(x: point.x, y: bounds.maxY))

        // Horizontal guide line
        path.move(to: NSPoint(x: bounds.minX, y: point.y))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y))

        path.stroke()
    }

    private func drawSelection(start: NSPoint, current: NSPoint) {
        let selectionRect = rectFromPoints(start, current)
        guard selectionRect.width > 2, selectionRect.height > 2 else { return }

        NSColor.clear.setFill()
        selectionRect.fill(using: .copy)

        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        drawLabel(pixelSize(selectionRect), below: selectionRect)
    }

    private func drawHoveredWindow(_ rect: CGRect) {
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        let borderPath = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        borderPath.lineWidth = 2
        borderPath.stroke()

        drawLabel("\(pixelSize(rect))  ·  \(NSLocalizedString("click to capture window", comment: ""))  ·  \(NSLocalizedString("drag to select area", comment: ""))", below: rect)
    }

    private func drawAdjustableSelection(_ rect: CGRect) {
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        for handle in RegionHandle.allCases where handle != .move {
            let p = handle.point(in: rect)
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }

        let hint = NSLocalizedString(movesSelection ? "drag to adjust" : "drag the edges to resize, or draw a new area", comment: "")
        let scroll = onScroll == nil ? "" : "  ·  \(NSLocalizedString("S to scroll capture", comment: ""))"
        drawLabel("\(pixelSize(rect))  ·  \(NSLocalizedString("space to capture", comment: ""))\(scroll)  ·  \(hint)  ·  esc", below: rect)
    }

    private func pixelSize(_ rect: CGRect) -> String {
        "\(Int(rect.width * screen.backingScaleFactor)) × \(Int(rect.height * screen.backingScaleFactor))"
    }

    private func drawLabel(_ text: String, below rect: CGRect) {
        let label = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let width = labelSize.width + 12
        let height = labelSize.height + 4
        let labelRect = CGRect(
            x: min(max(rect.midX - width / 2, bounds.minX + 8), bounds.maxX - width - 8),
            y: max(rect.minY - height - 4, bounds.minY + 8),
            width: width,
            height: height
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attrs)
    }

    // MARK: - Mouse Events

    func clearSelection() {
        selection = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    /// The frontmost other-app window under the pointer, while nothing is selected or being drawn.
    private func updateHover(at point: NSPoint) {
        let hovered = selection == nil && dragStart == nil ? windowRects.first { $0.contains(point) } : nil
        if hovered != hoveredWindow {
            hoveredWindow = hovered
            needsDisplay = true
        }
    }

    /// The previous area only resizes from its edges, so a drag inside it can draw a new area.
    private func adjustmentHandle(at point: NSPoint) -> RegionHandle? {
        guard let selection, let handle = RegionAdjustment.handle(at: point, in: selection) else { return nil }
        return handle == .move && !movesSelection ? nil : handle
    }

    private func updateCursor(at point: NSPoint) {
        guard let handle = adjustmentHandle(at: point) else {
            crosshairCursor.set()
            return
        }
        Self.cursor(for: handle, dragging: false).set()
    }

    private static func cursor(for handle: RegionHandle, dragging: Bool) -> NSCursor {
        guard #available(macOS 15.0, *) else {
            switch handle {
            case .move: return dragging ? .closedHand : .openHand
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
            }
        }
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .move: return dragging ? .closedHand : .openHand
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return .frameResize(position: position, directions: .all)
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        mouseLocation = loc
        updateHover(at: loc)
        updateCursor(at: loc)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        beginDrag(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    func beginDrag(at loc: CGPoint, clickCount: Int = 1) {
        mouseLocation = nil
        if clickCount == 2, let selection, selection.contains(loc) {
            onSelect(selection)
            return
        }
        if let selection, let handle = adjustmentHandle(at: loc) {
            activeHandle = handle
            handleDragOrigin = loc
            handleDragRect = selection
            Self.cursor(for: handle, dragging: true).set()
            return
        }
        crosshairCursor.set()
        dragStart = loc
        dragCurrent = loc
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil))
    }

    func updateDrag(at loc: CGPoint) {
        if let handle = activeHandle, let origin = handleDragOrigin, let base = handleDragRect {
            let delta = CGSize(width: loc.x - origin.x, height: loc.y - origin.y)
            selection = RegionAdjustment.apply(handle, delta: delta, to: base, within: bounds)
        } else {
            crosshairCursor.set()
            dragCurrent = loc
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(at: convert(event.locationInWindow, from: nil))
    }

    func endDrag(at end: CGPoint) {
        if activeHandle != nil {
            activeHandle = nil
            handleDragOrigin = nil
            handleDragRect = nil
            updateCursor(at: end)
            return
        }
        guard let start = dragStart else { return }
        dragStart = nil
        dragCurrent = nil
        var rect = rectFromPoints(start, end)
        // A click without a drag takes the highlighted window's area.
        if rect.width <= 3 || rect.height <= 3, selection == nil, let window = windowRects.first(where: { $0.contains(start) }) {
            rect = window
            hoveredWindow = nil
        }

        if rect.width > 3, rect.height > 3 {
            if capturesOnRelease {
                onSelect(rect)
                return
            }
            onBeginSelection()
            selection = rect
            movesSelection = true
            updateCursor(at: end)
        } else if selection == nil {
            onCancel()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel()
        case 49:
            // Space confirms a drawn area; with nothing selected it still switches to window capture.
            if let selection { onSelect(selection) } else { onWindow() }
        case 36, 76:
            if let selection { onSelect(selection) }
        default:
            // Matched by character so S works on any keyboard layout.
            if event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
               event.charactersIgnoringModifiers?.lowercased() == "s",
               let selection, let onScroll {
                onScroll(selection)
            }
        }
    }

    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
