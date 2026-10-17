import AppKit
@testable import BetterShot

/// Opt-in check of scrolling capture's Adjust Area through the production
/// orchestrator, selector, and session bar. Events go straight to BetterShot's
/// own windows, so it needs Screen Recording but not Accessibility.
@main
struct ScrollAdjustAreaIntegration {
    @MainActor static var fixtureWindow: NSWindow?

    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["BETTERSHOT_TESTING"] == "1")
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let pointer = NSEvent.mouseLocation
            defer { warp(to: pointer) }
            do {
                try await checkScreenshotSelectorS()
                try await check()
                print("PASS ScrollAdjustAreaIntegration: S from the screenshot selector, scroll, Adjust Area, new area stitches")
                exit(0)
            }
            catch { print("FAIL ScrollAdjustAreaIntegration: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func check() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw failure("Requires existing Screen Recording permission") }
        let visible = NSScreen.main!.visibleFrame
        let windowFrame = CGRect(x: visible.minX + 160, y: visible.minY + 120, width: 520, height: 420)
        let window = NSWindow(contentRect: windowFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above other apps' windows, which come forward when the selector hands focus back, but below the outline.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: windowFrame.size))
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = Page(frame: CGRect(x: 0, y: 0, width: windowFrame.width, height: 1_600))
        window.contentView = scroll
        window.orderFrontRegardless()
        fixtureWindow = window

        // The first area is the remembered one, so Space confirms it.
        let firstArea = windowFrame.insetBy(dx: 20, dy: 20)
        AppPreferences.captureRegionOnRelease = false
        AppPreferences.preselectPreviousRegion = true
        AppPreferences.lastRegionRect = firstArea
        UserDefaults.standard.set(false, forKey: "scrollAutoScrollEnabled")
        // Keep the result private: no automatic save, clipboard, or editor.
        UserDefaults.standard.set(false, forKey: AfterCaptureAction.save.storageKey(for: .screenshot))
        UserDefaults.standard.set(false, forKey: "bs_copyAfterSave")
        UserDefaults.standard.set(false, forKey: "bs_openEditorAfterCapture")

        let capture = Task { await CaptureOrchestrator.shared.performCapture(.scrollCapture, on: NSScreen.main) }
        defer { capture.cancel() }
        try await confirm(in: await selectorWindow())
        try await waitFor("first outline") { outline(for: firstArea) != nil }

        // Adjust Area: the selector reopens on the current area; draw a smaller one and confirm.
        try click(.adjustArea)
        let selector = try await selectorWindow()
        try await waitFor("first session to end") { !ScrollCaptureSessionPresenter.shared.isActive }
        let newArea = CGRect(x: firstArea.minX + 40, y: firstArea.minY + 60, width: 300, height: 220)
        drag(in: selector, from: CGPoint(x: newArea.minX, y: newArea.maxY), to: CGPoint(x: newArea.maxX, y: newArea.minY))
        try await Task.sleep(for: .milliseconds(150))
        try await confirm(in: selector, key: "s")
        try await waitFor("new outline") { outline(for: newArea) != nil }
        guard outline(for: firstArea) == nil else { throw failure("The old outline is still on screen") }
        try await Task.sleep(for: .milliseconds(800))

        try await scrollAndCheck(area: newArea)
    }

    @MainActor static func scrollAndCheck(area: CGRect) async throws {
        // Scrolling inside the new area must stitch more rows.
        warp(to: CGPoint(x: area.midX, y: area.midY))
        let clip = (fixtureWindow!.contentView as! NSScrollView).contentView
        for _ in 0..<6 {
            // Move the page itself, then send the wheel event that BetterShot listens for.
            clip.scroll(to: CGPoint(x: 0, y: clip.bounds.minY + 60))
            fixtureWindow!.displayIfNeeded()
            postScroll(at: CGPoint(x: area.midX, y: area.midY), pixels: 0)
            try await Task.sleep(for: .milliseconds(450))
        }
        try click(.stop)
        try await waitFor("the stitched capture") { CaptureOrchestrator.shared.lastCaptureURL != nil }
        let staged = CaptureOrchestrator.shared.lastCaptureURL!
        // A retained capture keeps its untouched source beside the `.preview` copy in history.
        let raw = DeckStaging.isStaged(staged) ? DeckStaging.rawURL(for: staged)
            : staged.deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent.replacingOccurrences(of: ".preview.", with: "."))
        guard let source = CGImageSourceCreateWithURL(raw as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure("No raw capture at \(raw.path)") }
        let scale = NSScreen.main!.backingScaleFactor
        print("stitched \(image.width)×\(image.height) px for a \(Int(area.width))×\(Int(area.height)) pt area")
        guard image.width == Int(area.width * scale) else {
            throw failure("Stitched width \(image.width) px does not match the new area \(Int(area.width * scale)) px")
        }
        guard image.height > Int((area.height + 100) * scale) else {
            throw failure("Scrolling in the new area did not stitch more rows: \(image.height) px")
        }
    }

    /// S in the screenshot selector starts scrolling capture on the drawn area, on every display,
    /// with keys routed to the key window as the keyboard would.
    @MainActor static func checkScreenshotSelectorS() async throws {
        AppPreferences.captureRegionOnRelease = false
        AppPreferences.preselectPreviousRegion = false
        for (index, screen) in NSScreen.screens.enumerated() {
            let selecting = Task { await RegionSelectionOverlay().selectRegion() }
            var overlay: NSWindow?
            try await waitFor("selector on display \(index)") {
                overlay = NSApp.windows.first { $0.isVisible && $0.level.rawValue == Int(CGWindowLevelForKey(.maximumWindow)) && $0.screen == screen }
                return overlay != nil
            }
            try await Task.sleep(for: .milliseconds(200))
            let area = CGRect(x: screen.frame.minX + 200, y: screen.frame.minY + 200, width: 320, height: 200)
            drag(in: overlay!, from: CGPoint(x: area.minX, y: area.maxY), to: CGPoint(x: area.maxX, y: area.minY))
            try await Task.sleep(for: .milliseconds(150))
            if let view = overlay!.contentView {
                let rect = view.convert(CGRect(x: area.minX - 300 - screen.frame.minX, y: area.minY - 60 - screen.frame.minY, width: 920, height: 80), from: nil)
                if let rep = view.bitmapImageRepForCachingDisplay(in: rect) {
                    view.cacheDisplay(in: rect, to: rep)
                    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: ".build/editor-snapshots"), withIntermediateDirectories: true)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/editor-snapshots/selector-hint-\(index).png"))
                }
            }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                isARepeat: false, keyCode: 1)!
            let keyIsOverlay = NSApp.keyWindow === overlay
            NSApp.sendEvent(event)
            do {
                try await waitFor("S to start scrolling capture on display \(index) (selection window is key: \(keyIsOverlay))") {
                    ScrollCaptureSessionPresenter.shared.isActive
                }
            } catch {
                RegionSelectionOverlay.cancelActive()
                _ = await selecting.value
                throw error
            }
            _ = await selecting.value
            try click(.cancel)
            try await waitFor("session to cancel") { !ScrollCaptureSessionPresenter.shared.isActive }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    // MARK: - Driving BetterShot's own windows

    @MainActor static func selectorWindow() async throws -> NSWindow {
        let level = Int(CGWindowLevelForKey(.maximumWindow))
        var found: NSWindow?
        try await waitFor("selector") {
            found = NSApp.windows.first { $0.isVisible && $0.level.rawValue == level && $0.screen == NSScreen.main }
            return found != nil
        }
        try await Task.sleep(for: .milliseconds(200))
        return found!
    }

    /// Presses Space until the scrolling session starts; the selector may not take keys at once.
    @MainActor static func confirm(in window: NSWindow, key: String = " ") async throws {
        for _ in 0..<20 {
            try await press(key, in: window)
            try await Task.sleep(for: .milliseconds(150))
            if ScrollCaptureSessionPresenter.shared.isActive { return }
        }
        throw failure("\(key == " " ? "Space" : key.uppercased()) did not start the scrolling session")
    }

    @MainActor static func press(_ key: String, in window: NSWindow) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: key == " " ? 49 : 1)!
            window.sendEvent(event)
        }
    }

    @MainActor static func drag(in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        let local = { (p: CGPoint) in CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY) }
        let steps = [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)),
                     (.leftMouseDragged, end), (.leftMouseUp, end)]
        for (type, point) in steps {
            let event = NSEvent.mouseEvent(with: type, location: local(point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
        }
    }

    @MainActor static func postScroll(at point: CGPoint, pixels: Int32) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)!
        event.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        NSApp.postEvent(NSEvent(cgEvent: event)!, atStart: false)
    }

    @MainActor static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y))
    }

    @MainActor static func outline(for area: CGRect) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame == area.insetBy(dx: -1, dy: -1) && $0.ignoresMouseEvents }
    }

    @MainActor static var controls: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "BetterShot.ScrollCaptureControls" }
    }

    enum Control { case cancel, adjustArea, stop }

    /// Clicks a session-bar control at its place in the fixed-width bar (8 pt padding, 8 pt spacing, 20 pt icons, 56 pt Stop).
    @MainActor static func click(_ control: Control) throws {
        guard let window = controls else { throw failure("Session bar is not on screen") }
        let x: CGFloat = switch control {
        case .cancel: 18
        case .adjustArea: 46
        case .stop: ScrollCaptureSessionView.size.width - 8 - 28
        }
        let point = CGPoint(x: x, y: ScrollCaptureSessionView.size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
        }
    }

    @MainActor static func waitFor(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw failure("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ScrollAdjustAreaCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Rows of distinct colors and labels, so every scroll position registers.
private final class Page: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for row in 0..<Int(bounds.height / 40) {
            let rect = CGRect(x: 0, y: CGFloat(row) * 40, width: bounds.width, height: 40)
            NSColor(calibratedHue: CGFloat(row % 17) / 17, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
            rect.fill()
            ("Row \(row)" as NSString).draw(at: CGPoint(x: 12 + CGFloat(row * 7 % 200), y: rect.minY + 10),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.black])
        }
    }
}
