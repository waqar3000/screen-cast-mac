import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            settings
            castButton
            statusArea
            if let statistics = model.statistics, let quality = model.connectionQuality {
                StatisticsView(statistics: statistics, wifi: model.wifi, quality: quality)
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Cast").font(.title2.weight(.semibold))
                Text("Show your Mac on a Chromecast").foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 14) {
            GridRow {
                Text("TV").gridColumnAlignment(.trailing)
                if model.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Chromecasts…").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("TV", selection: $model.selectedDeviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isActive)
                }
            }
            GridRow {
                Text("Use TV as")
                Picker("Use TV as", selection: $model.mode) {
                    Text("Mirror").tag(AppModel.Mode.mirror)
                    Text("Second display").tag(AppModel.Mode.extend)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isActive)
            }
            if model.mode == .extend {
                GridRow {
                    Text("Resolution")
                    // Stays enabled while casting: changes apply to the TV right away.
                    Picker("Resolution", selection: $model.tvResolution) {
                        ForEach(AppModel.TVResolution.allCases) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                Text("Delay")
                // Stays enabled while casting: changes apply to the TV right away.
                Picker("Delay", selection: $model.delay) {
                    ForEach(AppModel.Delay.allCases) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.mode == .mirror, model.displays.count > 1 {
                GridRow {
                    Text("Screen")
                    Picker("Screen", selection: $model.selectedDisplayID) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isActive)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Play sound on the TV", isOn: $model.includeAudio)
                    .disabled(model.isActive)
            }
        }
    }

    private var castButton: some View {
        Button {
            model.isActive ? model.stopCasting() : model.startCasting()
        } label: {
            Label(model.isActive ? "Stop Casting" : "Start Casting",
                  systemImage: model.isActive ? "stop.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isActive ? .red : .accentColor)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(model.isActive ? model.phase == .stopping : model.selectedDeviceID == nil)
    }

    @ViewBuilder
    private var statusArea: some View {
        if model.isActive {
            HStack(spacing: 8) {
                if model.phase == .casting {
                    Circle().fill(.green).frame(width: 8, height: 8)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
            }
        }
        if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showsPermissionHelp {
                    Button("Open Privacy Settings") { model.openScreenRecordingSettings() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var footnote: String {
        if model.devices.isEmpty {
            return "Make sure your Mac and Chromecast are on the same Wi‑Fi, and that Screen Cast is allowed in Privacy & Security › Local Network."
        }
        if model.mode == .extend {
            return "The TV joins your Mac as an extra monitor. Drag windows onto it, and arrange it in System Settings › Displays."
        }
        return "If the picture stutters, choose a longer delay. A TV's game mode cuts its own lag too."
    }
}

/// Live numbers about the stream, mostly as the TV reports them.
private struct StatisticsView: View {
    let statistics: CastStreamingSession.Statistics
    let wifi: AppModel.WiFiLink?
    let quality: AppModel.ConnectionQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connection").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(qualityColor).frame(width: 8, height: 8)
                    Text(qualityLabel).foregroundStyle(qualityColor)
                }
                .font(.callout.weight(.medium))
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    stat("Delay", statistics.delay > 0 ? "\(statistics.delay) ms" : "—")
                    stat("Frame rate", "\(statistics.frameRate) fps")
                }
                GridRow {
                    stat("Resolution", "\(statistics.width) × \(statistics.height)")
                    stat("Bitrate", bitRate)
                }
                GridRow {
                    stat("Mac processing", statistics.sendTime.map { "\($0) ms" } ?? "—")
                    stat("Round trip", statistics.roundTrip.map { "\($0) ms" } ?? "—")
                }
                GridRow {
                    stat("Packet loss", String(format: "%.1f %%", statistics.packetLoss * 100))
                    stat("Late frames", "\(statistics.lateFrames) /s")
                }
                if let wifi {
                    GridRow {
                        stat("Wi-Fi speed", "\(wifi.rate) Mbps")
                        stat("Wi-Fi signal", "\(wifi.signal) dBm · \(signalLabel(wifi.signal))")
                    }
                }
            }
            if quality == .poor {
                Text("Frames are arriving late or getting lost. Choose a longer delay, or move closer to your Wi-Fi router.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("""
            Mac processing is the time to capture, encode and send a frame; the TV's delay has to be longer than \
            that plus the network. Only changes on screen are sent, so the frame rate drops when nothing moves.
            """)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }

    private var bitRate: String {
        statistics.bitRate >= 1_000_000
            ? String(format: "%.1f Mbps", Double(statistics.bitRate) / 1_000_000)
            : "\(statistics.bitRate / 1000) kbps"
    }

    private var qualityLabel: String {
        switch quality {
        case .excellent: "Excellent"
        case .good: "Good"
        case .poor: "Poor"
        }
    }

    private var qualityColor: Color {
        switch quality {
        case .excellent: .green
        case .good: .yellow
        case .poor: .orange
        }
    }

    private func signalLabel(_ dBm: Int) -> String {
        switch dBm {
        case (-55)...: "strong"
        case (-67)...: "good"
        case (-75)...: "fair"
        default: "weak"
        }
    }
}
