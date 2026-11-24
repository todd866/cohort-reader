import ReaderModel
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private struct ReaderSnapshotModeKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var readerSnapshotMode: Bool {
        get { self[ReaderSnapshotModeKey.self] }
        set { self[ReaderSnapshotModeKey.self] = newValue }
    }
}

public enum ReaderPalette {
    private static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1.0) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2, opacity: alpha)
        #endif
    }

    public static let background = dynamicColor(light: (0.980, 0.973, 0.957), dark: (0.067, 0.067, 0.078))
    public static let surface = dynamicColor(light: (0.945, 0.929, 0.898), dark: (0.106, 0.106, 0.125))
    public static let elevated = dynamicColor(light: (0.996, 0.992, 0.984), dark: (0.145, 0.145, 0.173))
    public static let hairline = dynamicColor(light: (0.875, 0.847, 0.800), dark: (0.188, 0.188, 0.220))
    public static let label = dynamicColor(light: (0.094, 0.086, 0.078), dark: (0.949, 0.937, 0.914))
    public static let secondary = dynamicColor(light: (0.424, 0.400, 0.369), dark: (0.612, 0.596, 0.569))

    public static let accent = dynamicColor(light: (0.333, 0.235, 0.820), dark: (0.541, 0.451, 0.969))
    public static let cohortGreen = dynamicColor(light: (0.133, 0.569, 0.333), dark: (0.243, 0.749, 0.482))
    public static let radioBlue = dynamicColor(light: (0.169, 0.478, 0.788), dark: (0.345, 0.659, 0.949))
    public static let tvAmber = dynamicColor(light: (0.761, 0.475, 0.110), dark: (0.910, 0.651, 0.282))
    public static let neutralGauge = dynamicColor(light: (0.82, 0.79, 0.74), dark: (0.24, 0.24, 0.28))

    public static func domainColor(_ domain: String) -> Color {
        switch domain {
        case "tv": return tvAmber
        case "radio": return radioBlue
        case "cohort": return cohortGreen
        default: return accent
        }
    }

    public static func domainLabel(_ domain: String) -> String {
        switch domain {
        case "tv": return "Film"
        case "radio": return "Music"
        case "cohort": return "Study"
        default: return "Reader"
        }
    }

    public static func resolvedTheme(_ theme: ReaderTheme, colorScheme: ColorScheme) -> ReaderTheme {
        switch theme {
        case .auto: return colorScheme == .dark ? .ink : .paper
        case .paper, .sepia, .ink: return theme
        }
    }

    public static func themeBackground(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto, .paper: return Color(red: 0.980, green: 0.973, blue: 0.957)
        case .sepia: return Color(red: 0.953, green: 0.918, blue: 0.847)
        case .ink: return Color(red: 0.067, green: 0.067, blue: 0.078)
        }
    }

    public static func themeSurface(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto, .paper: return Color(red: 0.945, green: 0.929, blue: 0.898)
        case .sepia: return Color(red: 0.914, green: 0.871, blue: 0.788)
        case .ink: return Color(red: 0.106, green: 0.106, blue: 0.125)
        }
    }

    public static func themeForeground(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto, .paper: return Color(red: 0.094, green: 0.086, blue: 0.078)
        case .sepia: return Color(red: 0.173, green: 0.133, blue: 0.094)
        case .ink: return Color(red: 0.925, green: 0.910, blue: 0.875)
        }
    }
}

@MainActor
public enum ReaderHaptics {
    public static func light() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    public static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

public struct InstrumentGauge: View {
    public let ratio: Double
    public let tint: Color

    public init(ratio: Double, tint: Color = ReaderPalette.accent) {
        self.ratio = min(max(ratio, 0), 1)
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ReaderPalette.neutralGauge)
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: ratio > 0 ? max(3, geo.size.width * ratio) : 0)
            }
        }
        .frame(height: 4)
    }
}

/// Interactive `ScrollView` in live app; clipped pure SwiftUI stack during deterministic `ImageRenderer` snapshots.
public struct ReaderScrollContainer<Content: View>: View {
    @Environment(\.readerSnapshotMode) private var isSnapshot
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if isSnapshot {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .clipped()
        } else {
            ScrollView {
                content
            }
        }
    }
}

/// Bookshop cloth jacket for volumes without server artwork — zero raw file badges, crisp light & dark contrast.
public struct TypographicCoverView: View {
    public let book: BookItem
    public var width: CGFloat? = nil
    public var height: CGFloat? = nil

    public init(book: BookItem, width: CGFloat? = 56, height: CGFloat? = 78) {
        self.book = book
        self.width = width
        self.height = height
    }

    private var clothColor: Color {
        var h = 5381
        for byte in book.title.utf8 {
            h = ((h &<< 5) &+ h) &+ Int(byte)
        }
        let cloths: [Color] = [
            Color(red: 0.451, green: 0.161, blue: 0.176), // Oxblood
            Color(red: 0.129, green: 0.259, blue: 0.388), // Prussian blue
            Color(red: 0.149, green: 0.302, blue: 0.243), // Racing green
            Color(red: 0.569, green: 0.404, blue: 0.141), // Ochre cloth
            Color(red: 0.314, green: 0.180, blue: 0.380), // Plum
            Color(red: 0.176, green: 0.227, blue: 0.271), // Charcoal slate
            Color(red: 0.545, green: 0.259, blue: 0.161), // Terracotta
            Color(red: 0.153, green: 0.310, blue: 0.502), // Cobalt
        ]
        return cloths[abs(h) % cloths.count]
    }

    private var displayTitle: String {
        book.title.components(separatedBy: " — ").first ?? book.title
    }

    private var monogram: String {
        let stop: Set<String> = ["a", "an", "and", "of", "on", "or", "the", "to", "for", "in"]
        let words = displayTitle
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stop.contains($0.lowercased()) }
        let chosen = words.isEmpty ? [displayTitle] : words
        if chosen.count >= 2, let c1 = chosen[0].first, let c2 = chosen[1].first {
            return "\(c1)\(c2)".uppercased()
        }
        return String((chosen.first ?? "BK").prefix(2)).uppercased()
    }

    private var footerMark: String {
        if let year = book.year, year > 0 {
            return String(year)
        }
        return monogram
    }

    public var body: some View {
        let w = width ?? 110
        let mini = w < 82
        let titleSize: CGFloat = w < 96 ? 12.0 : 14.5
        let colophonSize: CGFloat = w < 96 ? 9.0 : 9.5

        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [clothColor, clothColor.opacity(0.84)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Vertical bookbinding hinge groove
            HStack(spacing: 0) {
                Color.clear.frame(width: mini ? 3.5 : 7)
                Rectangle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1)
                Spacer(minLength: 0)
            }

            if mini {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(monogram)
                        .font(.system(size: w < 40 ? 12 : 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color(red: 0.976, green: 0.957, blue: 0.914))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle()
                        .fill(Color(red: 0.94, green: 0.89, blue: 0.78).opacity(0.45))
                        .frame(width: w < 72 ? 16 : 22, height: 1)

                    Text(displayTitle)
                        .font(.system(size: titleSize, weight: .semibold, design: .serif))
                        .foregroundStyle(Color(red: 0.976, green: 0.957, blue: 0.914))
                        .lineLimit(4)
                        .minimumScaleFactor(0.70)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    Text(footerMark)
                        .font(.system(size: colophonSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0.94, green: 0.90, blue: 0.83).opacity(0.78))
                        .tracking(book.year != nil ? 0 : 1.0)
                        .lineLimit(1)
                }
                .padding(.leading, w < 72 ? 12 : 14)
                .padding(.trailing, w < 72 ? 6 : 8)
                .padding(.vertical, w < 72 ? 8 : 10)
            }
        }
        .modifier(JacketFrameModifier(width: width, height: height))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
        )
    }
}

private struct JacketFrameModifier: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let width, let height {
            content.frame(width: width, height: height)
        } else {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
    }
}
