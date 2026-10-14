import AppKit
import SwiftUI

/// Coordinates the full capture pipeline: hide window -> capture -> sound -> preview/editor.
@MainActor
@Observable
final class CaptureOrchestrator {
    static let shared = CaptureOrchestrator()

    private(set) var lastCaptureURL: URL?
    private(set) var captureInProgress = false
    private var pendingCaptures: [(ShortcutService.Action, NSScreen?)] = []
    private var captureScreen: NSScreen?
    /// An area already selected in the region selector, for the next OCR to read instead of asking again.
    var pendingOCRRegion: CGRect?

    private init() {}

    func performCapture(_ action: ShortcutService.Action, on screen: NSScreen? = nil) async {
        if action == .scrollCapture, ScrollCaptureSessionPresenter.shared.isActive {
            ScrollCaptureSessionPresenter.shared.stop()
            return
        }
        guard action == .colorPicker || ScreenCapturePermission.isReadyToCapture() else { return }
        if captureInProgress {
            pendingCaptures.append((action, screen))
            return
        }
        captureInProgress = true
        captureScreen = screen
        await executeCapture(action)
        await finishCaptures()
    }

    private func finishCaptures() async {
        while let (next, nextScreen) = pendingCaptures.first {
            pendingCaptures.removeFirst()
            captureScreen = nextScreen
            await executeCapture(next)
        }
        captureScreen = nil
        captureInProgress = false
    }

    func captureLastRegion(on screen: NSScreen? = nil) async {
        guard !captureInProgress, AppPreferences.lastRegionRect != nil,
              ScreenCapturePermission.isReadyToCapture() else { return }
        captureInProgress = true
        captureScreen = screen
        await RecordingBarPresenter.shared.hidePickerForCapture()
        await captureAndProcess { try await ScreenCapture.shared.captureLastRegion() }
        await finishCaptures()
    }

    private func performScrollCapture() async {
        let outcome = await RegionSelectionOverlay().selectRegion(allowsWindowSelection: false)
        guard case .region(let selection) = outcome,
              let selectedScreen = ActiveDisplayResolver.screen(for: selection.displayID) else { return }
        captureScreen = selectedScreen
        let rect = RegionGeometry.pointsRect(global: selection.pointsRect,
            primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        switch await ScrollCaptureSessionPresenter.shared.capture(rect: rect, on: selectedScreen) {
        case .completed(let image):
            do {
                let url = try await Self.writeScrollImage(image)
                ScreenCapture.shared.playShutterSound()
                await processCapturedImage(url, action: .scrollCapture)
            } catch {
                ToastWindow.shared.show(isError: true, title: "Couldn’t finish scrolling capture",
                    message: "The image could not be prepared. Select the area and try again. \(error.localizedDescription)",
                    systemIcon: "exclamationmark.triangle", duration: 10, on: selectedScreen)
            }
        case .failed:
            ToastWindow.shared.show(isError: true, title: "Couldn’t capture scrolling area",
                message: "Check Screen & System Audio Recording permission, then select the area and try again.",
                systemIcon: "exclamationmark.triangle", duration: 10, on: selectedScreen)
        case .cancelled:
            break
        }
    }

    private nonisolated static func writeScrollImage(_ image: CGImage) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bettershot_scroll_\(UUID().uuidString).png")
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    private func executeCapture(_ action: ShortcutService.Action) async {
        if action != .recording {
            await RecordingBarPresenter.shared.hidePickerForCapture()
        }
        switch action {
        case .region, .timedRegion, .regionCopy, .regionSave, .regionEdit, .regionPin:
            await captureAndProcess(action: action) { try await ScreenCapture.shared.captureRegion() }
        case .fullscreen:
            await captureAndProcess(action: action) { try await ScreenCapture.shared.captureFullscreen(on: captureScreen) }
        case .window:
            await captureAndProcess(action: action) { try await ScreenCapture.shared.captureWindow() }
        case .scrollCapture:
            await performScrollCapture()
        case .ocr, .ocrSingleLine:
            await performOCR(singleLine: action == .ocrSingleLine)
        case .colorPicker:
            await performColorPick()
        default:
            break
        }
    }

    // MARK: - Private

    private func captureAndProcess(action: ShortcutService.Action = .region, _ capture: () async throws -> URL?) async {
        let delay = action == .timedRegion ? max(3, AppPreferences.selfTimerDelay.rawValue) : AppPreferences.selfTimerDelay.rawValue
        if delay > 0 {
            await CountdownOverlay.shared.showCountdown(seconds: delay, on: captureScreen)
        }

        do {
            guard let url = try await capture() else { return }

            ScreenCapture.shared.playShutterSound()

            await processCapturedImage(url, action: action)
        } catch {
            ToastWindow.shared.show(isError: true, title: "Couldn’t capture screenshot", message: error.localizedDescription,
                systemIcon: "exclamationmark.triangle", duration: 10, on: captureScreen)
        }
    }


    private func performColorPick() async {
        do {
            let overlay = ColorPickerOverlay()
            guard let components = try await overlay.pickColor() else { return }
            completeTextCapture(ColorPickerOverlay.Format.current.string(components), action: .colorPicker,
                                color: components)
        } catch {
            ToastWindow.shared.show(isError: true, title: "Couldn’t pick color", message: error.localizedDescription,
                systemIcon: "eyedropper", on: captureScreen)
        }
    }

    private func performOCR(singleLine: Bool = false) async {
        var progress: Task<Void, Never>?
        defer { progress?.cancel() }
        do {
            let region = pendingOCRRegion
            pendingOCRRegion = nil
            let text = try await ScreenCapture.shared.captureAndOCR(in: region) {
                progress = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    ToastWindow.shared.show(title: "Recognizing text…", message: "This can take a moment.",
                        systemIcon: "doc.text.viewfinder", duration: 120, on: captureScreen)
                }
            }
            progress?.cancel()
            guard let text else { return }
            completeTextCapture(text, action: singleLine ? .ocrSingleLine : .ocr)
        } catch {
            ToastWindow.shared.show(isError: true, title: "Couldn’t recognize text", message: error.localizedDescription,
                systemIcon: "doc.text.viewfinder", on: captureScreen)
        }
    }

    /// Copy recognized text or a picked color without changing an empty clipboard result.
    func completeTextCapture(_ text: String, action: ShortcutService.Action,
                             color: ColorPickerOverlay.Components? = nil, pasteboard: NSPasteboard = .general) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastWindow.shared.show(isError: true, title: "No text found", message: "Try selecting a clearer text area.",
                systemIcon: "doc.text.viewfinder", on: captureScreen)
            return
        }
        let value = action == .ocrSingleLine ? text.split(whereSeparator: \.isNewline).joined(separator: " ") : text
        let isColor = action == .colorPicker
        let copied = Self.copyText(value, to: pasteboard)
        ScreenCapture.shared.playShutterSound()
        if !isColor {
            // Replaces the "Recognizing text…" toast with what was read.
            ToastWindow.shared.dismiss(animated: false)
            CaptureResultPanel.shared.show(RecognizedTextView(text: value, copied: copied),
                                           takesFocus: true, on: captureScreen)
            return
        }
        if let color {
            CaptureResultPanel.shared.show(PickedColorView(components: color, copied: copied),
                                           takesFocus: false, autoHide: .seconds(5), on: captureScreen)
            return
        }
        ToastWindow.shared.show(isError: !copied, title: copied ? "Copied" : "Couldn’t copy",
            message: copied ? (isColor ? "\(value) copied to clipboard" : "Text copied to clipboard") : "Try Copy again.",
            systemIcon: isColor ? "eyedropper" : "doc.text.viewfinder", on: captureScreen)
    }

    @discardableResult
    static func copyText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Every screenshot starts privately; normal captures follow the automatic saving setting.
    func processCapturedImage(_ url: URL, action: ShortcutService.Action = .region) async {
        let (stagedURL, thumbnail) = await stageCapture(url)
        var displayURL = AppPreferences.keepInDeckUntilSaved ? stagedURL : DeckStaging.retain(stagedURL)
        if displayURL != stagedURL { DeckStaging.discard(stagedURL) }
        let allowsAutomaticSave: Bool = switch action {
        case .region, .fullscreen, .window, .previousRegion, .timedRegion, .scrollCapture: true
        default: false
        }
        var saveFailed = false
        if allowsAutomaticSave && AfterCaptureActions.isEnabled(.save, for: .screenshot) {
            do {
                // A staging failure leaves only the original; keep it available for retry.
                guard DeckStaging.isStaged(stagedURL) else { throw CocoaError(.fileWriteUnknown) }
                let savedURL = try ScreenshotFileActions.saveCapture(from: displayURL)
                DeckStaging.discard(displayURL)
                displayURL = savedURL
            } catch {
                saveFailed = true
            }
        }
        lastCaptureURL = displayURL

        if action == .regionCopy || (action != .regionSave && AppPreferences.copyAfterSave) {
            do {
                try ScreenshotFileActions.copyImageToClipboard(from: displayURL)
            } catch {
                ToastWindow.shared.show(isError: true, title: "Copy Failed", message: error.localizedDescription,
                    systemIcon: "exclamationmark.triangle", on: captureScreen)
            }
        }

        PreviewOverlay.shared.show(url: displayURL, on: captureScreen, thumbnail: thumbnail)
        if saveFailed {
            PreviewOverlay.shared.showSaveFailure(for: displayURL)
            return
        }
        if action == .regionSave {
            PreviewOverlay.shared.save(displayURL)
        } else if action == .regionPin {
            let retainedURL = DeckStaging.retain(displayURL)
            guard !DeckStaging.isStaged(retainedURL) else { return }
            PinnedScreenshotController.shared.pin(url: retainedURL, on: captureScreen)
            PreviewOverlay.shared.remove(displayURL)
        } else if action == .regionEdit || (AppPreferences.openEditorAfterCapture && action != .regionCopy) {
            PreviewOverlay.shared.openAnnotateEditor(for: displayURL)
        }
    }

    private func stageCapture(_ url: URL) async -> (URL, NSImage?) {
        let config = AppPreferences.defaultBeautifierConfig
        let thumbnailEdge = OverlayCardSize.large.thumbnailSize.width * 2
        // The capture is named once, here. Its raw source, library copy, and
        // every later Copy or Save keep this name.
        let fileName = ScreenshotFileNaming.currentFileName(extension: AppPreferences.exportFormat.fileExtension)
        let staging = await Task.detached { () -> (URL, CGImage)? in
            guard let folder = try? DeckStaging.makeCaptureDirectory() else { return nil }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let rendered = BeautifierRenderer.render(image: cgImage, config: config),
                  let staged = Self.saveImage(rendered, named: fileName, in: folder.path) else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            let scale = min(1, thumbnailEdge / CGFloat(max(rendered.width, rendered.height)))
            let colorSpace = rendered.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            let thumbnail = (try? AnnotationScenePreviewRenderer.downscaled(rendered, scale: scale, colorSpace: colorSpace)) ?? rendered
            return (staged, thumbnail)
        }.value

        guard let (stagedURL, thumbnail) = staging else {
            ToastWindow.shared.show(isError: true, title: "Couldn’t prepare capture",
                message: "The original screenshot is still available in the preview.",
                systemIcon: "exclamationmark.triangle", on: captureScreen)
            return (Self.unstagedCapture(url, named: fileName), nil)
        }
        do {
            try FileManager.default.moveItem(at: url, to: DeckStaging.rawURL(for: stagedURL))
            return (stagedURL, NSImage(cgImage: thumbnail, size: .zero))
        } catch {
            DeckStaging.discard(stagedURL)
            return (Self.unstagedCapture(url, named: fileName), nil)
        }
    }

    /// When staging fails the original is shown as-is; it still carries the
    /// capture's name, in a private folder of its own.
    private static func unstagedCapture(_ url: URL, named fileName: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterShot-Unstaged", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let named = folder.appendingPathComponent(
            ScreenshotFileNaming.fileName(of: URL(fileURLWithPath: fileName), extension: url.pathExtension))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: named)
            return named
        } catch {
            return url
        }
    }

    /// Writes `cgImage` as `fileName` (numbered if taken) in `dir`. Captures
    /// taken in the same second render the same name, so the hidden staging
    /// file is unique per call and the final rename retries on a taken name.
    nonisolated static func saveImage(_ cgImage: CGImage, named fileName: String, in dir: String) -> URL? {
        let format = AppPreferences.exportFormat
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        let fileName = ScreenshotFileNaming.fileName(of: URL(fileURLWithPath: fileName), extension: format.fileExtension)
        let stagingURL = directory.appendingPathComponent(".\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            stagingURL as CFURL,
            format.utType as CFString,
            1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = AppPreferences.exportQuality
        }

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        // Rename only a complete image. `RENAME_EXCL` fails atomically when the
        // name exists (moveItem checks, then overwrites), so a name taken since
        // `uniqueURL` looked is retried with the next number.
        for _ in 0..<100 {
            let url = ScreenshotFileNaming.uniqueURL(for: fileName, in: directory, separator: "-")
            if renamex_np(stagingURL.path, url.path, UInt32(RENAME_EXCL)) == 0 { return url }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// Legacy home of duplicated raw copies. Nothing writes here any more; kept so old captures still resolve.
    static var baseStorageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("BetterShot/bases", isDirectory: true)
    }

    static func baseImageURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return baseStorageDir.appendingPathComponent("\(name).base.png")
    }

    /// Maps a saved/beautified image back to the untouched capture the editor should load.
    static func resolveRawSource(for url: URL) -> URL {
        let baseURL = baseImageURL(for: url)
        if FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        // Legacy: check alongside the file for old .base.png files
        let legacyDir = url.deletingLastPathComponent()
        let legacyName = url.deletingPathExtension().lastPathComponent
        let legacyURL = legacyDir.appendingPathComponent("\(legacyName).base.png")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        if let record = HistoryStore.shared.records.first(where: { $0.beautifiedPath == url.path }) {
            let rawURL = HistoryStore.shared.urlForRecord(record)
            if FileManager.default.fileExists(atPath: rawURL.path) {
                return rawURL
            }
        }
        return url
    }

}

// MARK: - Capture Result Panel

/// Floats an OCR or color-picker result at the toast position. Text results
/// take the keyboard for editing; quick results float without stealing focus
/// and hide on their own unless the pointer is over them.
@MainActor
final class CaptureResultPanel {
    static let shared = CaptureResultPanel()

    private var panel: NSPanel?
    /// The app that had focus before the panel took the keyboard.
    private var previousApp: NSRunningApplication?
    private var autoHide: Duration?
    private var hideTask: Task<Void, Never>?

    private static let shadowSlack: CGFloat = 18

    private init() {}

    func show<Content: View>(_ content: Content, takesFocus: Bool, autoHide: Duration? = nil, on preferredScreen: NSScreen?) {
        removePanel()
        // The padding is room for glassSurface's shadow, which the window edge would otherwise cut square.
        let hostingView = NSHostingView(rootView: content
            .onHover { [weak self] in self?.setHovering($0) }
            .padding(Self.shadowSlack))
        let panel = CaptureResultWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // glassSurface draws the rounded shadow; AppKit's window shadow is a
        // square outline around the transparent corners once the panel is key.
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.close() }
        // Left out of PreviewWindowCaptureExclusion on purpose: a result is
        // something people screenshot, so it stays visible to captures.

        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let origin = ToastWindow.origin(for: panel.frame.size, in: screen.visibleFrame)
        panel.setFrameOrigin(CGPoint(x: origin.x, y: origin.y + Self.shadowSlack))
        if takesFocus {
            if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
        self.autoHide = autoHide
        scheduleHide()
    }

    func close() {
        removePanel()
        previousApp?.activate()
        previousApp = nil
    }

    private func removePanel() {
        hideTask?.cancel()
        hideTask = nil
        autoHide = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func setHovering(_ hovering: Bool) {
        if hovering { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard let autoHide else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: autoHide)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
}

private final class CaptureResultWindow: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The text view turns Esc into completion, so the panel takes it first.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel()
            return
        }
        super.sendEvent(event)
    }
}

/// Drags the panel from any spot no control claims. SwiftUI content is not
/// window background to AppKit, so `isMovableByWindowBackground` alone never fires.
private struct CaptureResultDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private struct CaptureResultCloseButton: View {
    var body: some View {
        Button { CaptureResultPanel.shared.close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

// MARK: Recognized Text

@Observable
@MainActor
private final class RecognizedTextModel {
    var text: String
    private var copiedText: String?

    init(text: String, copied: Bool) {
        self.text = text
        copiedText = copied ? text : nil
    }

    var status: String {
        switch copiedText {
        case text: "Copied to clipboard"
        case nil: "Not copied yet"
        default: "Edited. Copy again to update the clipboard."
        }
    }

    func copy() {
        if CaptureOrchestrator.copyText(text) { copiedText = text }
    }
}

/// Shows what OCR read, so it can be checked, corrected, and copied again.
private struct RecognizedTextView: View {
    @State private var model: RecognizedTextModel
    @FocusState private var isEditing: Bool

    init(text: String, copied: Bool) {
        _model = State(initialValue: RecognizedTextModel(text: text, copied: copied))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.viewfinder")
                    .foregroundStyle(.secondary)
                Text("Recognized Text")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                CaptureResultCloseButton()
            }

            TextEditor(text: $model.text)
                .focused($isEditing)
                // AppKit's focus ring is square and ignores the clip; the rounded border below shows focus instead.
                .focusEffectDisabled()
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .padding(6)
                .frame(height: 180)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isEditing ? Color.accentColor : Color.primary.opacity(0.1),
                                      lineWidth: isEditing ? 1.5 : 0.5)
                }
                .accessibilityLabel("Recognized text")

            HStack(spacing: 8) {
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc", action: model.copy)
                    .controlSize(.small)
                    .disabled(model.text.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(CaptureResultDragArea())
        .glassSurface(cornerRadius: 14, depth: .raised)
    }
}

// MARK: Picked Color

/// The picked color with a HEX/RGB switch; switching copies the new format.
private struct PickedColorView: View {
    let components: ColorPickerOverlay.Components
    @AppStorage(ColorPickerOverlay.Format.storageKey) private var format: ColorPickerOverlay.Format = .hex
    @State private var copied: Bool

    init(components: ColorPickerOverlay.Components, copied: Bool) {
        self.components = components
        _copied = State(initialValue: copied)
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(.sRGB, red: Double(components.red) / 255, green: Double(components.green) / 255,
                            blue: Double(components.blue) / 255))
                .frame(width: 32, height: 32)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(format.string(components))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(copied ? "Copied to clipboard" : "Couldn’t copy. Try again.")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
            .frame(minWidth: 150, alignment: .leading)

            Picker("Color format", selection: $format) {
                ForEach(ColorPickerOverlay.Format.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            CaptureResultCloseButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(CaptureResultDragArea())
        .glassSurface(cornerRadius: 14, depth: .raised)
        .onChange(of: format) { _, newFormat in
            copied = CaptureOrchestrator.copyText(newFormat.string(components))
        }
    }
}
