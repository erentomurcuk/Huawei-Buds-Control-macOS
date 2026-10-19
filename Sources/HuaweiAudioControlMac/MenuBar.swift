import SwiftUI

// MARK: - Menu bar panel

/// The popover the menu bar icon opens.
///
/// The outer frame is fixed. Content can scroll, change tab, or show an error
/// toast without ever asking the menu-bar window to resize. This is what keeps
/// the panel edge-to-edge when an error is dismissed.
struct MenuPanel: View {
    @EnvironmentObject private var state: DeviceState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    @State private var panel: Panel = .sound
    @Namespace private var tabNamespace

    init(initialPanel: Panel = .sound) {
        _panel = State(initialValue: initialPanel)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PanelBackdrop()

            VStack(spacing: 0) {
                header
                tabBar
                content
                footer
            }

            if let error = state.lastError {
                ErrorToast(message: error) {
                    withAnimation(Theme.spring) { state.lastError = nil }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 58)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight)
        .fixedSize()
        .animation(Theme.spring, value: state.lastError)
        .task {
            // Reconnect on open if the earbuds dropped, but never mid-session
            // and never after the user chose Disconnect explicitly.
            if state.phase == .idle, !state.manuallyDisconnected {
                await state.connect()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HeaderMark(connected: state.isConnected, size: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.snapshot.modelName ?? "Huawei Audio Control")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusDot(color: state.isConnected ? Theme.connected : .secondary,
                              pulsing: state.phase == .connecting)
                    Text(statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if state.isConnected, let level = state.snapshot.weakestBud {
                BatteryRing(level: level, charging: state.snapshot.isCharging, size: 38)
                    .help("Lowest earbud battery")
            }

            IconButton(systemImage: "gearshape", help: "Settings") {
                openWindow(id: AppSettings.windowID)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 13)
    }

    private var statusText: String {
        switch state.phase {
        case .connected:
            return state.snapshot.isCharging ? "Connected · charging" : "Connected"
        case .connecting:
            return "Connecting…"
        case .idle:
            return state.lastError == nil ? "Not connected" : "Disconnected"
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Panel.allCases) { item in
                let isSelected = item == panel
                Button {
                    withAnimation(Theme.spring) { panel = item }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.accent)
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                switch panel {
                case .sound:
                    SoundPanel(state: state)
                case .gestures:
                    GesturesPanel(state: state)
                case .device:
                    DevicePanel(state: state)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.visible)
        .animation(Theme.spring, value: panel)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            HStack(spacing: 9) {
                StatusDot(color: state.isConnected ? Theme.connected : .secondary,
                          pulsing: state.phase == .connecting)
                Text(footerText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if state.isConnected {
                    CompactButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await state.refreshAll() }
                    }
                } else {
                    CompactButton(title: state.phase == .connecting ? "Connecting…" : "Connect",
                                  systemImage: "link",
                                  prominent: state.phase != .connecting,
                                  disabled: state.phase == .connecting) {
                        Task { await state.connect() }
                    }
                }

                CompactButton(title: "Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }

    private var footerText: String {
        if state.isConnected {
            return "Ready"
        }
        if state.phase == .connecting {
            return "Opening control channel"
        }
        return "Huawei Audio Control"
    }
}

// MARK: - Settings

/// User preferences, stored in standard defaults.
@MainActor
final class AppSettings: ObservableObject {
    static let windowID = "settings"

    @Published var pollInterval: Int {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
            NotificationCenter.default.post(name: .pollIntervalDidChange, object: nil)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            let success = LoginItem.setEnabled(launchAtLogin)
            if !success {
                // Registration only works from a signed app in /Applications.
                // Keep the switch honest instead of silently doing nothing.
                launchAtLogin = LoginItem.isEnabled
                loginItemError = "macOS could not update the login item. This requires a Developer ID-signed app in /Applications; ad-hoc development builds cannot register."
            } else {
                UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
                loginItemError = LoginItem.needsApproval
                    ? "Approve “Huawei Audio Control” in System Settings › General › Login Items."
                    : nil
            }
        }
    }

    @Published var showBatteryInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showBatteryInMenuBar, forKey: "showBatteryInMenuBar") }
    }

    /// `auto` or one of `DeviceProfile.all`. This is the escape hatch for a
    /// pair that has been renamed, since Bluetooth names are the only generic
    /// identification the protocol offers.
    @Published var deviceProfile: String {
        didSet {
            UserDefaults.standard.set(deviceProfile, forKey: "deviceProfile")
            NotificationCenter.default.post(name: .deviceProfileDidChange, object: nil)
        }
    }

    @Published var loginItemError: String?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pollInterval") == nil {
            defaults.set(25, forKey: "pollInterval")
        }
        // Keep a stale or hand-edited default inside the range the UI offers;
        // a zero or tiny interval would hammer the single-request channel.
        let storedInterval = defaults.object(forKey: "pollInterval") as? Int ?? 25
        let interval = min(120, max(10, storedInterval))
        pollInterval = interval
        // DeviceState reads this key directly for its polling timer, so persist
        // the clamped value rather than only showing it in Settings.
        defaults.set(interval, forKey: "pollInterval")
        let storedProfile = defaults.string(forKey: "deviceProfile") ?? DeviceProfile.automaticID
        deviceProfile = (storedProfile == DeviceProfile.automaticID
                         || DeviceProfile.all.contains(where: { $0.id == storedProfile }))
            ? storedProfile : DeviceProfile.automaticID
        launchAtLogin = LoginItem.isEnabled
        showBatteryInMenuBar = defaults.object(forKey: "showBatteryInMenuBar") as? Bool ?? true
        if LoginItem.needsApproval {
            loginItemError = "Approve “Huawei Audio Control” in System Settings › General › Login Items."
        }
    }
}

extension Notification.Name {
    static let pollIntervalDidChange = Notification.Name("pollIntervalDidChange")
    static let deviceProfileDidChange = Notification.Name("deviceProfileDidChange")
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        ZStack {
            PanelBackdrop()

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.hairline)
                settingsContent
                footer
            }
        }
        .frame(width: Theme.settingsWidth, height: Theme.settingsHeight)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Huawei Audio Control")
                    .font(.system(size: 15, weight: .semibold))
                Text("Settings")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            IconButton(systemImage: "xmark", help: "Close") {
                dismissWindow(id: AppSettings.windowID)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                PanelSectionCard(title: "General",
                                 caption: "Startup and menu-bar appearance",
                                 systemImage: "gearshape.fill") {
                    VStack(spacing: 13) {
                        ToggleRow(title: "Launch at login",
                                  caption: "Start the menu bar app when you sign in",
                                  isOn: $settings.launchAtLogin)

                        if let error = settings.loginItemError {
                            Text(error)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider().overlay(Theme.hairline)

                        ToggleRow(title: "Show battery in the menu bar",
                                  caption: "Displays the lower earbud level, or the device level",
                                  isOn: $settings.showBatteryInMenuBar)
                    }
                }

                PanelSectionCard(title: "Device",
                                 caption: "Model detection and manual override",
                                 systemImage: "earbuds") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledMenu(label: "Model",
                                    options: [("Automatic", DeviceProfile.automaticID)]
                                        + DeviceProfile.all.map { ($0.title, $0.id) },
                                    selection: $settings.deviceProfile)

                        Text("Automatic uses the Bluetooth name and hardware code. Set the model manually if the earbuds have a custom Bluetooth name.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PanelSectionCard(title: "Polling",
                                 caption: "How often the panel refreshes device state",
                                 systemImage: "arrow.triangle.2.circlepath") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Refresh every \(settings.pollInterval) seconds")
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Badge(text: "\(settings.pollInterval)s", systemImage: "timer",
                                  color: Theme.accent)
                        }

                        Slider(value: Binding(
                            get: { Double(settings.pollInterval) },
                            set: { settings.pollInterval = Int($0) }
                        ), in: 10...120, step: 5)

                        HStack {
                            Text("10s")
                            Spacer()
                            Text("120s")
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)

                        Text("The earbuds answer one request at a time, so very short intervals can make changes feel sluggish.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.visible)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            HStack {
                Text("Version \(version)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Done") {
                    dismissWindow(id: AppSettings.windowID)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}
