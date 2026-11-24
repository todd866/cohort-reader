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

    public static let background = dynamicColor(light: (0.980, 0.969, 0.945), dark: (0.071, 0.067, 0.063))
    public static let surface = dynamicColor(light: (0.949, 0.925, 0.878), dark: (0.106, 0.098, 0.090))
    public static let elevated = dynamicColor(light: (1.000, 0.992, 0.976), dark: (0.133, 0.125, 0.114))
    public static let hairline = dynamicColor(light: (0.890, 0.855, 0.796), dark: (0.180, 0.169, 0.153))
    public static let deskCanvas = dynamicColor(light: (0.918, 0.890, 0.835), dark: (0.043, 0.039, 0.035))
    public static let label = dynamicColor(light: (0.106, 0.094, 0.082), dark: (0.949, 0.929, 0.894))
    public static let secondary = dynamicColor(light: (0.427, 0.392, 0.349), dark: (0.608, 0.584, 0.545))

    public static let accent = dynamicColor(light: (0.620, 0.204, 0.141), dark: (0.886, 0.451, 0.357))
    public static let cohortGreen = dynamicColor(light: (0.133, 0.525, 0.314), dark: (0.286, 0.745, 0.506))
    public static let radioBlue = dynamicColor(light: (0.173, 0.443, 0.718), dark: (0.376, 0.659, 0.925))
    public static let tvAmber = dynamicColor(light: (0.745, 0.459, 0.110), dark: (0.902, 0.651, 0.298))
    public static let neutralGauge = dynamicColor(light: (0.840, 0.800, 0.740), dark: (0.220, 0.210, 0.190))

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
        case .auto, .paper: return Color(red: 0.980, green: 0.969, blue: 0.945)
        case .sepia: return Color(red: 0.953, green: 0.918, blue: 0.847)
        case .ink: return Color(red: 0.071, green: 0.067, blue: 0.063)
        }
    }

    public static func themeSurface(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto, .paper: return Color(red: 0.949, green: 0.925, blue: 0.878)
        case .sepia: return Color(red: 0.914, green: 0.871, blue: 0.788)
        case .ink: return Color(red: 0.106, green: 0.098, blue: 0.090)
        }
    }

    public static func themeForeground(_ theme: ReaderTheme) -> Color {
        switch theme {
        case .auto, .paper: return Color(red: 0.106, green: 0.094, blue: 0.082)
        case .sepia: return Color(red: 0.173, green: 0.133, blue: 0.094)
        case .ink: return Color(red: 0.941, green: 0.922, blue: 0.886)
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

public struct KeycapBadge: View {
    public let text: String
    public var emphasized: Bool = false

    public init(_ text: String, emphasized: Bool = false) {
        self.text = text
        self.emphasized = emphasized
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(emphasized ? Color.white : ReaderPalette.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(minWidth: 20)
            .background(
                emphasized ? ReaderPalette.accent.opacity(0.9) : ReaderPalette.elevated,
                in: RoundedRectangle(cornerRadius: 4.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5)
                    .stroke(emphasized ? ReaderPalette.accent : ReaderPalette.hairline, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 0, x: 0, y: 1)
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
            Color(red: 0.420, green: 0.153, blue: 0.161), // Oxblood linen
            Color(red: 0.137, green: 0.251, blue: 0.353), // Midnight navy
            Color(red: 0.145, green: 0.267, blue: 0.212), // Deep forest
            Color(red: 0.490, green: 0.349, blue: 0.145), // Warm ochre
            Color(red: 0.298, green: 0.180, blue: 0.314), // Damson plum
            Color(red: 0.220, green: 0.227, blue: 0.239), // Archival slate
            Color(red: 0.478, green: 0.231, blue: 0.149), // Sienna buckram
            Color(red: 0.239, green: 0.282, blue: 0.196), // Moss cloth
        ]
        return cloths[abs(h) % cloths.count]
    }

    private var displayTitle: String {
        let dash = book.title.components(separatedBy: " — ").first ?? book.title
        let semi = dash.components(separatedBy: ";").first ?? dash
        return semi.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var authorSurname: String? {
        let trimmed = book.author.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Unknown") != .orderedSame else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? trimmed
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

    private func footerMark(for width: CGFloat) -> String {
        let yearStr = book.year.flatMap { $0 > 0 ? String($0) : nil }
        if width < 110 {
            return yearStr ?? authorSurname ?? monogram
        }
        let parts: [String] = [authorSurname, yearStr].compactMap { $0 }
        return parts.isEmpty ? monogram : parts.joined(separator: " · ")
    }

    public var body: some View {
        let w = width ?? 110
        let mini = w < 56
        let compact = w < 86
        let titleSize: CGFloat = mini ? 12 : (compact ? 10.0 : 14.0)
        let isSingleWord = !displayTitle.contains(where: { $0.isWhitespace })
        let colophonSize: CGFloat = compact ? 8.0 : 9.0
        let creamFoil = Color(red: 0.976, green: 0.953, blue: 0.902)
        let foreEdge = Color(red: 0.925, green: 0.894, blue: 0.831)

        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [clothColor, clothColor.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle directional binding sheen
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.clear, Color.black.opacity(0.14)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Vertical bookbinding hinge groove + paper fore-edge strip
            HStack(spacing: 0) {
                Color.clear.frame(width: mini ? 3.5 : 6.5)
                Rectangle()
                    .fill(Color.black.opacity(0.24))
                    .frame(width: 1)
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1)
                Spacer(minLength: 0)
                if !mini {
                    Rectangle()
                        .fill(foreEdge.opacity(0.82))
                        .frame(width: 2)
                }
            }

            if mini {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(monogram)
                        .font(.system(size: w < 40 ? 11.5 : 13.5, weight: .bold, design: .serif))
                        .foregroundStyle(creamFoil)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(creamFoil.opacity(0.24), lineWidth: 0.65)
                        .padding(.leading, compact ? 10 : 12)
                        .padding(.trailing, compact ? 4.5 : 5.5)
                        .padding(.vertical, compact ? 5 : 6)

                    VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                        Text(displayTitle)
                            .font(.system(size: titleSize, weight: .semibold, design: .serif))
                            .foregroundStyle(creamFoil)
                            .lineLimit(isSingleWord ? 1 : (compact ? 3 : 4))
                            .minimumScaleFactor(isSingleWord ? 0.52 : 0.68)
                            .allowsTightening(true)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)

                        Rectangle()
                            .fill(creamFoil.opacity(0.32))
                            .frame(width: compact ? 14 : 20, height: 0.75)

                        Text(footerMark(for: w))
                            .font(.system(size: colophonSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(creamFoil.opacity(0.76))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, compact ? 12 : 18)
                    .padding(.trailing, compact ? 6 : 10)
                    .padding(.vertical, compact ? 8 : 11)
                }
            }
        }
        .modifier(JacketFrameModifier(width: width, height: height))
        .clipShape(RoundedRectangle(cornerRadius: 5.5))
        .overlay(
            RoundedRectangle(cornerRadius: 5.5)
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
