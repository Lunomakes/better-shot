//
//  RecordingPickerBar.swift
//  BetterShot
//
//  Shared screenshot controls and native recording setup for the capture bar.
//  The panel, chrome, and recording handoff live in RecordingBarPresenter.

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingPickerPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func toggle() {
        togglePicker()
    }

    func show() {
        showPicker()
    }
}

// MARK: - Controls

struct RecordingPickerControls: View {
    var showsCloseButton = true
    @AppStorage("bs_selfTimerDelay") private var screenshotDelay = 0
    @AppStorage(BetterShotPreferences.recordingStartDelaySecondsKey) private var recordingDelay = 0
    @Bindable private var presenter = RecordingBarPresenter.shared

    private static let timerOptions = [0, 1, 3, 5]

    private static let screenshotActions: [(BarTooltipID, ShortcutService.Action, String, String)] = [
        (.screenshotRegion, .region, "Area", "viewfinder"),
        (.screenshotFullscreen, .fullscreen, "Screen", "desktopcomputer"),
        (.screenshotWindow, .window, "Window", "macwindow"),
        (.screenshotScroll, .scrollCapture, "Scroll", "rectangle.expand.vertical"),
        (.ocr, .ocr, "Text", "doc.text.viewfinder"),
        (.colorPicker, .colorPicker, "Color", "eyedropper"),
    ]

    private func capture(_ action: ShortcutService.Action) {
        if presenter.isOverRegionSelection {
            // Already selecting an area; any other mode replaces the selection.
            guard action != .region else { return }
            let selection = RegionSelectionOverlay.cancelActive()
            // Text and Scroll use the area already selected rather than asking for another.
            if action == .ocr, let selection {
                CaptureOrchestrator.shared.pendingOCRRegion = selection.pointsRect
            } else if action == .scrollCapture, let selection {
                CaptureOrchestrator.shared.pendingScrollRegion = selection
            }
        }
        presenter.showsRecordingOptions = false
        let screen = ActiveDisplayResolver.activeScreen(preferPointer: true)
        Task { await CaptureOrchestrator.shared.performCapture(action, on: screen) }
    }

    var body: some View {
        HStack(spacing: 4) {
            Picker("Capture mode", selection: captureMode) {
                Image(systemName: "camera").accessibilityLabel("Screenshot").tag(false)
                Image(systemName: "video").accessibilityLabel("Recording").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between screenshots and recording")
            .padding(.horizontal, 4)
            BarDivider()
            if presenter.showsRecordingOptions {
                RecordingOptionsView()
            } else {
                screenshotControls
                BarDivider()
                editButton
            }
            // Its menu would open beneath the selection overlay.
            if !presenter.isOverRegionSelection { timerControl }
            if showsCloseButton {
                BarActionButton(id: .close, title: "Close", systemImage: "xmark",
                                accessibility: "Close capture bar — Esc") {
                    if presenter.isOverRegionSelection {
                        RegionSelectionOverlay.cancelActive()
                        return
                    }
                    presenter.dismiss()
                    Task { await CameraRecordingManager.shared.stopPreview() }
                }
            }
        }
    }

    @ViewBuilder
    private var screenshotControls: some View {
        ForEach(Array(Self.screenshotActions.enumerated()), id: \.element.0) { index, item in
            let (id, action, caption, icon) = item
            if action == .ocr { BarDivider() }
            let title = ShortcutService.shared.help(action == .ocr ? "Copy text from screen"
                : action == .scrollCapture ? "Scrolling Capture" : caption, for: action)
            BarActionButton(id: id, title: title, systemImage: icon, caption: caption) {
                capture(action)
            }
            .help(title)
        }
    }

    /// Over a region selection, recording ends the selection and reopens the
    /// full bar, because the recording menus would open beneath the overlay.
    private var captureMode: Binding<Bool> {
        Binding {
            presenter.showsRecordingOptions
        } set: { recording in
            guard presenter.isOverRegionSelection else {
                presenter.showsRecordingOptions = recording
                return
            }
            guard recording else { return }
            RegionSelectionOverlay.cancelActive()
            Task { await ShortcutService.shared.performGlobal(.recordingOptions) }
        }
    }

    /// Over a selection, captures that area into the editor; otherwise selects an area first.
    private var editButton: some View {
        let title = ShortcutService.shared.help("Capture Region & Annotate", for: .regionEdit)
        return BarActionButton(id: .edit, title: title, systemImage: "square.and.pencil", caption: "Edit") {
            guard presenter.isOverRegionSelection else { return capture(.regionEdit) }
            CaptureOrchestrator.shared.editsCurrentCapture = true
            if !RegionSelectionOverlay.confirmActive() { CaptureOrchestrator.shared.editsCurrentCapture = false }
        }
        .help(title)
    }

    @ViewBuilder
    private var timerControl: some View {
        BarDivider()
        Menu {
            Section("Screenshot timer") {
                ForEach(SelfTimerDelay.allCases, id: \.rawValue) { delay in
                    Button {
                        screenshotDelay = delay.rawValue
                    } label: {
                        menuSelectionLabel(delay.label, isSelected: screenshotDelay == delay.rawValue)
                    }
                }
            }
            Section("Recording timer") {
                ForEach(Self.timerOptions, id: \.self) { seconds in
                    Button {
                        recordingDelay = seconds
                    } label: {
                        menuSelectionLabel(timerLabel(seconds), isSelected: recordingDelay == seconds)
                    }
                }
            }
        } label: {
            BarActionLabel(id: .timer, title: timerTooltip, systemImage: "timer", caption: "Timer")
        }
        .menuStyle(.button).buttonStyle(BarButtonStyle()).menuIndicator(.hidden)
        .accessibilityLabel("Screenshot and recording timers")
    }

    private func timerLabel(_ seconds: Int) -> String {
        seconds == 0 ? "None" : "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private var timerTooltip: String {
        recordingDelay == 0 ? "Timer off" : "Recording timer \(recordingDelay)s"
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected { Label(LocalizedStringKey(title), systemImage: "checkmark") }
        else { Text(LocalizedStringKey(title)) }
    }
}

/// The compact 0.5.4 recording setup shown inline in the capture bar's recording mode.
struct RecordingOptionsView: View {
    @State private var sources = RecordingSourceCatalog.shared
    @AppStorage(BetterShotPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(BetterShotPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(BetterShotPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(BetterShotPreferences.recordingTeleprompterEnabledKey) private var teleprompterEnabled = false

    var body: some View {
        HStack(spacing: 4) {
            if sources.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading recording sources") }
            if let error = sources.errorMessage {
                BarActionButton(id: .recording, title: error, systemImage: "exclamationmark.triangle",
                    tint: .red, caption: "Try Again") {
                    Task { await sources.refresh() }
                }
                BarDivider()
            }
            recordingOptions.disabled(sources.isLoading)
        }
        .task { await sources.refresh() }
    }

    private var recordingOptions: some View {
        HStack(spacing: 8) {
            displaySource
            windowSource
            BarActionButton(id: .area, title: "Drag to select a region",
                systemImage: "rectangle.dashed", caption: "Area",
                accessibility: "Area - drag to select the region to record") {
                startAreaRecording()
            }
            BarDivider()
            inputToggle(id: .camera, caption: "Camera",
                title: cameraID.isEmpty ? "Camera off" : "Camera on",
                isOn: !cameraID.isEmpty, onIcon: "video.fill", offIcon: "video.slash",
                accessibility: cameraAccessibilityLabel) {
                toggleCamera()
            }
            .contextMenu { cameraDeviceMenu }
            microphonePicker
            inputToggle(id: .systemAudio, caption: "Audio",
                title: systemAudio ? "System audio on" : "System audio off",
                isOn: systemAudio, onIcon: "speaker.wave.2.fill", offIcon: "speaker.slash",
                accessibility: systemAudio
                    ? "System audio on - click to stop capturing what you hear"
                    : "System audio off - click to capture what you hear") {
                systemAudio.toggle()
            }
            inputToggle(id: .teleprompter, caption: "Script",
                title: teleprompterEnabled ? "Teleprompter on" : "Teleprompter off",
                isOn: teleprompterEnabled, onIcon: "doc.plaintext", offIcon: "doc.plaintext",
                accessibility: teleprompterEnabled
                    ? "Teleprompter on - click to edit the script"
                    : "Teleprompter off - click to write a script") {
                TeleprompterComposerPresenter.shared.toggle()
            }
        }
    }

    @ViewBuilder
    private var displaySource: some View {
        if sources.displays.count > 1 {
            Menu {
                ForEach(Array(sources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        startRecording { RecordingCaptureEntry.recordFullscreen(display) }
                    }
                }
            } label: {
                BarActionLabel(id: .display, title: "Pick a screen to record",
                    systemImage: "menubar.rectangle", caption: "Display")
            }
            .menuStyle(.button).buttonStyle(BarButtonStyle()).menuIndicator(.hidden)
            .accessibilityLabel("Display - choose which screen to record")
        } else {
            BarActionButton(id: .display, title: "Record the whole screen",
                systemImage: "menubar.rectangle", caption: "Display",
                accessibility: "Display - record the whole screen") {
                guard let display = sources.displays.first else { return }
                startRecording { RecordingCaptureEntry.recordFullscreen(display) }
            }
        }
    }

    private var windowSource: some View {
        Menu {
            if sources.windows.isEmpty { Text("No app windows found") }
            ForEach(sources.windows, id: \.windowID) { window in
                Button(RecordingSourceCatalog.windowTitle(window)) {
                    startRecording { RecordingCaptureEntry.recordWindow(window) }
                }
            }
            Divider()
            Button("Refresh Windows") { Task { await sources.refresh() } }
        } label: {
            BarActionLabel(id: .window, title: "Pick an app window",
                systemImage: "macwindow", caption: "Window")
        }
        .menuStyle(.button).buttonStyle(BarButtonStyle()).menuIndicator(.hidden)
        .accessibilityLabel("Window - choose an app window to record")
    }

    private func startAreaRecording() {
        RecordingBarPresenter.shared.hide()
        RecordingCaptureEntry.recordArea()
    }

    private func startRecording(_ start: () -> Void) {
        TeleprompterComposerPresenter.shared.hide()
        start()
    }

    private func toggleCamera() {
        if cameraID.isEmpty { selectCamera(RecordingDeviceCatalog.cameras().first?.uniqueID) }
        else {
            cameraID = ""
            Task { await CameraRecordingManager.shared.stopPreview() }
        }
    }

    private var cameraAccessibilityLabel: String {
        guard !cameraID.isEmpty else { return "Camera off - click to record your camera, right-click to pick one" }
        guard let camera = RecordingDeviceCatalog.cameras().first(where: { $0.uniqueID == cameraID }) else {
            return "Camera unavailable - right-click to choose another camera"
        }
        return "Camera on - \(camera.localizedName), right-click to switch"
    }

    private var microphoneOn: Bool {
        ScreenRecordingCaptureOptions.supportsMicrophone && !microphoneID.isEmpty
    }

    private var microphoneTooltip: String {
        guard ScreenRecordingCaptureOptions.supportsMicrophone else { return "Microphone requires macOS 15 or later" }
        guard !microphoneID.isEmpty else { return "Microphone off" }
        return RecordingDeviceCatalog.microphone(withID: microphoneID) == nil ? "Microphone unavailable" : "Microphone on"
    }

    private var microphoneAccessibilityLabel: String {
        guard ScreenRecordingCaptureOptions.supportsMicrophone else { return "Microphone requires macOS 15 or later" }
        guard !microphoneID.isEmpty else { return "Microphone off - click to choose an input" }
        guard let microphone = RecordingDeviceCatalog.microphone(withID: microphoneID) else {
            return "Microphone unavailable - choose another input"
        }
        return "Microphone on - \(microphone.localizedName)"
    }

    @ViewBuilder
    private var cameraDeviceMenu: some View {
        ForEach(RecordingDeviceCatalog.cameras(), id: \.uniqueID) { device in
            Toggle(isOn: Binding(
                get: { cameraID == device.uniqueID },
                set: { selected in
                    if selected { selectCamera(device.uniqueID) }
                    else {
                        cameraID = ""
                        Task { await CameraRecordingManager.shared.stopPreview() }
                    }
                }
            )) { Text(device.localizedName) }
        }
    }

    private var microphonePicker: some View {
        Menu {
            Button { microphoneID = "" } label: {
                menuSelectionLabel("Off", isSelected: microphoneID.isEmpty)
            }
            Divider()
            ForEach(RecordingDeviceCatalog.microphones(), id: \.uniqueID) { device in
                Button { selectMicrophone(device.uniqueID) } label: {
                    menuSelectionLabel(device.localizedName, isSelected: microphoneID == device.uniqueID)
                }
            }
        } label: {
            BarActionLabel(id: .microphone, title: microphoneTooltip,
                systemImage: microphoneOn ? "mic.fill" : "mic.slash",
                tint: microphoneOn ? BarMetrics.activeTint : BarMetrics.inactiveTint,
                caption: "Mic")
        }
        .menuStyle(.button).buttonStyle(BarButtonStyle()).menuIndicator(.hidden)
        .disabled(!ScreenRecordingCaptureOptions.supportsMicrophone)
        .accessibilityLabel(microphoneAccessibilityLabel)
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected { Label(LocalizedStringKey(title), systemImage: "checkmark") }
        else { Text(LocalizedStringKey(title)) }
    }

    private func selectCamera(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            let authorized = await RecordingInputAuthorization.ensureAccess(for: .camera)
            cameraID = authorized ? deviceID : ""
            if authorized {
                await CameraRecordingManager.shared.startPreview(deviceID: cameraID,
                    displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
            }
        }
    }

    private func selectMicrophone(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            microphoneID = await RecordingInputAuthorization.ensureAccess(for: .microphone) ? deviceID : ""
        }
    }

    private func inputToggle(id: BarTooltipID, caption: String, title: String, isOn: Bool,
        onIcon: String, offIcon: String, accessibility: String, action: @escaping () -> Void) -> some View {
        BarActionButton(id: id, title: title, systemImage: isOn ? onIcon : offIcon,
            tint: isOn ? BarMetrics.activeTint : BarMetrics.inactiveTint,
            caption: caption, accessibility: accessibility, action: action)
    }
}
