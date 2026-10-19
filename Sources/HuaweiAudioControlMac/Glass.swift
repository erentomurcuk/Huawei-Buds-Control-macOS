import AppKit
import SwiftUI

// MARK: - Design system
//
// The panel has a fixed geometry. Nothing that appears or disappears inside it
// (error banners, connection state, optional controls) is allowed to change the
// window's intrinsic size. Cards are the only elevated surfaces; the panel
// itself is always painted edge-to-edge.

enum Theme {
    /// Follows the user's system accent rather than hard-coding a brand hue.
    static let accent = Color.accentColor

    static let noiseOff = Color(red: 0.34, green: 0.36, blue: 0.42)
    static let cancelling = Color(red: 0.04, green: 0.52, blue: 0.98)
    static let awareness = Color(red: 0.13, green: 0.72, blue: 0.42)
    static let connected = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let charging = Color(red: 1.00, green: 0.76, blue: 0.10)
    static let warning = Color(red: 0.98, green: 0.56, blue: 0.16)

    /// Explicit sRGB values rather than semantic colors: on macOS 26 the liquid
    /// glass effect applies vibrancy to semantic colors and turns them white
    /// inside a card. These keep the battery gauge readable on every surface.
    static func battery(_ level: Int) -> Color {
        switch level {
        case ..<15: return Color(red: 0.94, green: 0.27, blue: 0.24)
        case ..<35: return Color(red: 0.98, green: 0.58, blue: 0.16)
        case ..<60: return Color(red: 0.95, green: 0.78, blue: 0.15)
        default: return Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }

    static let hairline = Color.primary.opacity(0.08)
    static let fill = Color.primary.opacity(0.055)
    static let elevatedFill = Color.primary.opacity(0.075)

    // Fixed geometry. These values are deliberately not derived from content.
    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 640
    static let settingsWidth: CGFloat = 460
    static let settingsHeight: CGFloat = 600
    static let corner: CGFloat = 22
    static let cardCorner: CGFloat = 16
    static let spacing: CGFloat = 10

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.84)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension View {
    /// A stable frosted card surface.
    ///
    /// This intentionally does not use `glassEffect`: on macOS 26 that effect
    /// applies vibrancy to children, which turns semantic controls (menus,
    /// toggles, battery gauges) white inside a card. A material plus a soft
    /// highlight keeps the glass look without changing the content colors.
    func glassSurface(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        self.background {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.18))
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.045), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
    }
}

// MARK: - Panel background

/// The full-bleed panel background. The material is backed by an opaque base so
/// a menu-bar window can never show transparent strips at its top or bottom.
struct PanelBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.20))
            LinearGradient(
                colors: [
                    Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.11),
                    .clear,
                    Color.black.opacity(colorScheme == .dark ? 0.10 : 0.025),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Section header

/// A quiet uppercase label that heads a group of controls.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled card header with an icon, used to give every panel section a clear
/// visual anchor instead of a wall of controls.
struct SectionHeader: View {
    let title: String
    var caption: String?
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Glass card

/// A grouped, glass-backed area of related controls.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface()
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.07), radius: 8, y: 3)
    }
}

/// Standard section card with an icon header.
struct PanelSectionCard<Content: View>: View {
    let title: String
    var caption: String?
    var systemImage: String
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        GlassCard(padding: padding) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, caption: caption, systemImage: systemImage)
                content
            }
        }
    }
}

// MARK: - Choice chips

/// A row of selectable chips for a single-valued option (levels, presets).
struct ChoiceRow<T: Identifiable & Hashable>: View {
    let title: String
    let options: [T]
    @Binding var selection: T
    let titleFor: (T) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(title: title)
            HStack(spacing: 6) {
                ForEach(options, id: \.id) { option in
                    let isSelected = option.id == selection.id
                    Button {
                        withAnimation(Theme.spring) { selection = option }
                    } label: {
                        Text(titleFor(option))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? Theme.accent : Theme.fill)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: isSelected ? 0 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Toggle row

/// A labelled switch row with an optional supporting caption.
struct ToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let caption {
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

// MARK: - Status

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle()
                        .strokeBorder(color.opacity(0.5), lineWidth: 2)
                        .scaleEffect(phase ? 2.2 : 1)
                        .opacity(phase ? 0 : 1)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: phase)
                }
            }
            .onAppear { phase = pulsing }
            .onChange(of: pulsing) { _, isPulsing in phase = isPulsing }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color, pulsing: pulsing)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.fill))
    }
}

struct Badge: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }
}

// MARK: - Battery

/// A slim battery meter, optionally with a percentage caption.
struct BatteryMeter: View {
    let level: Int?
    var charging = false
    var showText = true
    var width: CGFloat = 96

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                let fill = CGFloat(max(0, min(100, level ?? 0))) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(level.map(Theme.battery) ?? Color.secondary.opacity(0.4))
                        .frame(width: max(6, proxy.size.width * fill))
                        .animation(Theme.spring, value: level)
                }
            }
            .frame(width: width, height: 6)

            if showText {
                if let level {
                    Text("\(level)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("--")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.charging)
            }
        }
    }
}

/// Circular battery gauge used in the panel header.
struct BatteryRing: View {
    let level: Int?
    var charging = false
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, level ?? 0))) / 100)
                .stroke(level.map(Theme.battery) ?? Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.spring, value: level)
            Text(level.map { "\($0)" } ?? "--")
                .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level.map { _ in Color.primary } ?? Color.secondary)
            if charging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.20, weight: .bold))
                    .foregroundStyle(Theme.charging)
                    .offset(x: size * 0.30, y: -size * 0.30)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(level.map { "Battery \($0) percent" } ?? "Battery unknown")
    }
}

/// Large battery tile used by the Sound panel.
struct BatteryTile<Icon: View>: View {
    let title: String
    let level: Int?
    let charging: Bool
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                icon
                    .frame(height: 19)
                Spacer(minLength: 0)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.charging)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(level.map { "\($0)" } ?? "--")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(level.map { _ in Color.primary } ?? Color.secondary)

            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let fill = CGFloat(max(0, min(100, level ?? 0))) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(level.map(Theme.battery) ?? Color.secondary.opacity(0.30))
                        .frame(width: level == nil ? proxy.size.width
                                                   : max(proxy.size.height, proxy.size.width * fill))
                        .animation(Theme.spring, value: level)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.fill)
        }
    }
}

// MARK: - Buttons

/// A wide glass button for the panel's primary actions.
struct GlassButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(prominent ? Theme.accent : Theme.fill)
            }
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Compact footer button.
struct CompactButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(prominent ? Theme.accent : Theme.fill)
            }
            .overlay {
                if !prominent {
                    Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Small circular icon button for header actions.
struct IconButton: View {
    let systemImage: String
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(hovering ? Theme.elevatedFill : Theme.fill)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { hovering = $0 }
    }
}

// MARK: - Menu picker

/// A compact labelled menu, used for per-earbud gesture assignments.
struct MenuPicker<T: Identifiable & Hashable>: View {
    let label: String
    let options: [T]
    @Binding var selection: T
    let titleFor: (T) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Picker("", selection: $selection) {
                ForEach(options, id: \.id) { option in
                    Text(titleFor(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 218, alignment: .trailing)
        }
    }
}

// MARK: - Setting row

/// A compact labelled menu for plain string values. `Picker` falls back to a
/// bright native control even in dark mode, so Settings uses the same menu
/// treatment as the rest of the panel.
struct LabeledMenu: View {
    let label: String
    let options: [(title: String, value: String)]
    @Binding var selection: String
    var maxWidth: CGFloat = 250

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))

            Spacer(minLength: 8)

            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: maxWidth, alignment: .trailing)
        }
    }
}

/// A label/value row used for read-only device details.
struct DetailRow: View {    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

// MARK: - Toast

/// Floating error toast. It is an overlay, not part of the layout, so showing or
/// dismissing it can never change the panel's height.
struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Theme.warning.opacity(0.16))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            }
            .frame(width: 26, height: 26)

            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Theme.warning.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
    }
}
