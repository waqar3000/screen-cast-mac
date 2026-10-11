import AppKit
import CoreWLAN
import ScreenCaptureKit

enum AppError: LocalizedError {
    case screenRecordingPermission
    case noDisplay
    case virtualDisplayFailed

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermission:
            "Screen Cast needs permission to record your screen. Turn it on in Privacy & Security › Screen & System Audio Recording, then quit and reopen the app."
        case .noDisplay:
            "Couldn't find a screen to cast."
        case .virtualDisplayFailed:
            "macOS didn't create the second display for the TV. Try Mirror instead."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, starting, casting, stopping }

    enum Mode: String {
        /// Show what's on one of the Mac's screens.
        case mirror
        /// Add the TV as an extra display that windows can be dragged onto.
        case extend
    }

    /// How long the TV waits before showing each frame. Shorter feels snappier; longer leaves time to
    /// resend anything Wi-Fi drops, so the picture stays smooth.
    enum Delay: Int, CaseIterable, Identifiable {
        case lowest = 50
        case low = 100
        case smooth = 250

        var id: Self { self }

        var label: String {
            switch self {
            case .lowest: "Lowest (0.05 s)"
            case .low: "Low (0.1 s)"
            case .smooth: "Smoothest (0.25 s)"
            }
        }
    }

    enum ConnectionQuality {
        case excellent, good, poor
    }

    struct WiFiLink {
        /// Link speed between the Mac and the Wi-Fi router, in Mbps.
        let rate: Int
        /// Signal strength in dBm (closer to 0 is stronger).
        let signal: Int
    }

    /// How big things look on the TV when it's a second display. Smaller sizes mean larger text.
    enum TVResolution: String, CaseIterable, Identifiable {
        case large = "1280x720"
        case medium = "1600x900"
        case full = "1920x1080"

        var id: Self { self }

        var size: VirtualDisplay.Size {
            switch self {
            case .large: VirtualDisplay.Size(width: 1280, height: 720)
            case .medium: VirtualDisplay.Size(width: 1600, height: 900)
            case .full: VirtualDisplay.Size(width: 1920, height: 1080)
            }
        }

        var label: String {
            switch self {
            case .large: "Larger text (1280 × 720)"
            case .medium: "Medium (1600 × 900)"
            case .full: "More space (1920 × 1080)"
            }
        }
    }

    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    @Published private(set) var devices: [CastDevice] = []
    @Published var selectedDeviceID: String? {
        didSet { if let selectedDeviceID { UserDefaults.standard.set(selectedDeviceID, forKey: "lastDeviceID") } }
    }
    @Published private(set) var displays: [Display] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .mirror {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var tvResolution = TVResolution(rawValue: UserDefaults.standard.string(forKey: "tvResolution") ?? "") ?? .large {
        didSet {
            UserDefaults.standard.set(tvResolution.rawValue, forKey: "tvResolution")
            if phase == .casting, virtualDisplay != nil { resizeTVDisplay() }  // takes effect right away
        }
    }
    @Published var delay = Delay(rawValue: UserDefaults.standard.integer(forKey: "delay")) ?? .low {
        didSet {
            UserDefaults.standard.set(delay.rawValue, forKey: "delay")
            session?.setTargetDelay(delay.rawValue)  // takes effect right away while casting
        }
    }
    @Published var includeAudio = true
    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var showsPermissionHelp = false
    @Published private(set) var statistics: CastStreamingSession.Statistics?
    @Published private(set) var wifi: WiFiLink?

    private let browser = DeviceBrowser()
    private var castTask: Task<Void, Never>?
    private var client: CastClient?
    private var session: CastStreamingSession?
    private var stopSource: (() -> Void)?
    private var virtualDisplay: VirtualDisplay?
    private var resizeTask: Task<Void, Never>?

    init() {
        browser.onChange = { [weak self] devices in self?.devicesChanged(devices) }
        browser.start()
        refreshDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
    }

    var isActive: Bool { phase != .idle }

    // MARK: - Casting

    func startCasting(testPattern: Bool = false) {
        guard phase == .idle, let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        errorMessage = nil
        showsPermissionHelp = false
        phase = .starting
        castTask = Task { await cast(to: device, testPattern: testPattern) }
    }

    /// Casts a test card to the first TV found for `seconds`, then quits. For testing the connection
    /// without Screen Recording permission: `open "Screen Cast.app" --args --test-cast 20`.
    func runTestCast(seconds: Int) {
        Task {
            for _ in 0..<100 where devices.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            startCasting(testPattern: true)
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            stopCasting { NSApp.terminate(nil) }
        }
    }

    func stopCasting(then completion: (() -> Void)? = nil) {
        guard phase == .starting || phase == .casting else {
            completion?()
            return
        }
        phase = .stopping
        status = "Stopping…"
        shutDown(stopTV: true) { [weak self] in
            self?.phase = .idle
            self?.status = ""
            completion?()
        }
    }

    private func cast(to device: CastDevice, testPattern: Bool) async {
        do {
            var size = CGSize(width: 1280, height: 720)
            var capture: (display: SCDisplay, excludedApps: [SCRunningApplication])?
            if !testPattern {
                guard CGPreflightScreenCaptureAccess() else {
                    CGRequestScreenCaptureAccess()
                    throw AppError.screenRecordingPermission
                }
                capture = mode == .extend ? try await makeTVDisplay(named: device.name) : try await chosenDisplay()
                size = ScreenStreamer.outputSize(for: capture!.display)
            }

            status = "Connecting to \(device.name)…"
            let client = CastClient(endpoint: device.endpoint)
            self.client = client
            client.onSessionEnded = { [weak self] reason in self?.sessionEnded(reason) }
            let address = try await client.connect()
            try Task.checkCancellation()
            try await client.launch(appID: CastClient.mirroringAppID)
            try Task.checkCancellation()

            status = "Starting the stream…"
            let session = try CastStreamingSession(configuration: .init(
                width: Int(size.width), height: Int(size.height),
                frameRate: ScreenStreamer.frameRate, includeAudio: includeAudio, targetDelay: delay.rawValue))
            self.session = session
            session.onFailure = { [weak self] error in self?.fail(error) }
            session.onStatistics = { [weak self] statistics in self?.statisticsChanged(statistics) }
            let answer = try await client.negotiate(offer: session.offer)
            try Task.checkCancellation()
            try session.start(answer: answer, receiverAddress: address)

            if let capture {
                try await startCapture(of: capture.display, excluding: capture.excludedApps, into: session)
            } else {
                let pattern = TestPattern(width: Int(size.width), height: Int(size.height))
                stopSource = pattern.stop
                pattern.onVideoFrame = session.sendVideoFrame
                pattern.onAudio = includeAudio ? session.sendAudio : nil
                pattern.start(frameRate: ScreenStreamer.frameRate)
            }
            try Task.checkCancellation()

            phase = .casting
            status = mode == .extend && !testPattern ? "\(device.name) is your second display" : "Casting to \(device.name)"
        } catch {
            guard !Task.isCancelled else { return }
            fail(error)
        }
    }

    private func startCapture(of display: SCDisplay, excluding excludedApps: [SCRunningApplication],
                              into session: CastStreamingSession) async throws {
        let streamer = ScreenStreamer()
        stopSource = streamer.stop
        streamer.onVideoFrame = session.sendVideoFrame
        streamer.onAudio = session.sendAudio
        streamer.onFailure = { [weak self] error in self?.captureStopped(error) }
        try await streamer.start(display: display, excluding: excludedApps, includeAudio: includeAudio)
    }

    /// The Mac screen picked for mirroring, leaving this app's window off the TV.
    private func chosenDisplay() async throws -> (display: SCDisplay, excludedApps: [SCRunningApplication]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selectedDisplayID })
                ?? content.displays.first else { throw AppError.noDisplay }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return (display, ownApp)
    }

    /// Adds a 1080p virtual display for the TV and waits for macOS to bring it online.
    private func makeTVDisplay(named name: String) async throws -> (display: SCDisplay, excludedApps: [SCRunningApplication]) {
        guard let virtualDisplay = VirtualDisplay(name: name, sizes: TVResolution.allCases.map(\.size)) else {
            throw AppError.virtualDisplayFailed
        }
        self.virtualDisplay = virtualDisplay
        return (try await tvDisplay(at: tvResolution.size), [])
    }

    /// Switches the TV display to `size` and waits until macOS reports it at that size. (Capturing it any
    /// earlier picks up a stale size, and the picture ends up small in the middle of the TV.)
    private func tvDisplay(at size: VirtualDisplay.Size) async throws -> SCDisplay {
        guard let virtualDisplay else { throw AppError.virtualDisplayFailed }
        for _ in 0..<50 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == virtualDisplay.displayID }) {
                if display.width == size.width, display.height == size.height { return display }
                virtualDisplay.use(size)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AppError.virtualDisplayFailed
    }

    /// Applies a new resolution while casting, restarting capture so it picks up the display's new size.
    private func resizeTVDisplay() {
        resizeTask?.cancel()
        resizeTask = Task {
            do {
                let display = try await tvDisplay(at: tvResolution.size)
                guard !Task.isCancelled, phase == .casting, let session else { return }
                stopSource?()
                try await startCapture(of: display, excluding: [], into: session)
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func shutDown(stopTV: Bool, completion: @escaping () -> Void = {}) {
        castTask?.cancel()
        castTask = nil
        stopSource?()
        stopSource = nil
        session?.stop()
        session = nil
        statistics = nil
        wifi = nil
        // Removing the TV display sends its windows back to the Mac's screen.
        virtualDisplay = nil
        let client = self.client
        self.client = nil
        if let client, stopTV {
            client.stop(completion: completion)
        } else {
            client?.stop()
            completion()
        }
    }

    private func fail(_ error: Error) {
        guard phase == .starting || phase == .casting else { return }
        if isPermissionError(error) {
            errorMessage = AppError.screenRecordingPermission.localizedDescription
            showsPermissionHelp = true
        } else {
            errorMessage = error.localizedDescription
        }
        phase = .idle
        status = ""
        shutDown(stopTV: true)
    }

    private func sessionEnded(_ reason: String) {
        guard phase == .starting || phase == .casting else { return }
        errorMessage = reason
        phase = .idle
        status = ""
        shutDown(stopTV: false)
    }

    private func captureStopped(_ error: Error) {
        let error = error as NSError
        // Stopping from the screen-sharing item in the menu bar is a normal way to end.
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userStopped.rawValue {
            stopCasting()
        } else {
            fail(error)
        }
    }

    // MARK: - Statistics

    /// An overall rating from what the TV reports: lost packets, late frames, and network round trip.
    var connectionQuality: ConnectionQuality? {
        guard let statistics else { return nil }
        let roundTrip = statistics.roundTrip ?? 0
        if statistics.packetLoss >= 0.05 || statistics.lateFrames >= 3 || roundTrip > 100 { return .poor }
        if statistics.packetLoss >= 0.01 || statistics.lateFrames >= 1 || roundTrip > 40 { return .good }
        return .excellent
    }

    private func statisticsChanged(_ statistics: CastStreamingSession.Statistics) {
        guard phase == .casting else { return }
        self.statistics = statistics
        if let interface = CWWiFiClient.shared().interface(), interface.transmitRate() > 0 {
            wifi = WiFiLink(rate: Int(interface.transmitRate()), signal: interface.rssiValue())
        } else {
            wifi = nil  // on Ethernet, or Wi-Fi is off
        }
    }

    private func isPermissionError(_ error: Error) -> Bool {
        if case AppError.screenRecordingPermission = error { return true }
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: - Devices and displays

    private func devicesChanged(_ devices: [CastDevice]) {
        self.devices = devices
        // Keep the current pick, and don't swap TVs mid-cast if one briefly drops off the network.
        if let selectedDeviceID, devices.contains(where: { $0.id == selectedDeviceID }) { return }
        guard phase == .idle else { return }
        let lastUsed = UserDefaults.standard.string(forKey: "lastDeviceID")
        selectedDeviceID = devices.first { $0.id == lastUsed }?.id ?? devices.first?.id
    }

    private func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return Display(id: id, name: screen.localizedName)
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }
    }
}
