import SwiftUI
import AppKit

enum WorkbenchTheme {
    // MARK: - Surfaces & Backgrounds
    static let darkBackground = Color(red: 0.05, green: 0.07, blue: 0.10)
    static let darkSurface = Color(red: 0.08, green: 0.11, blue: 0.16)
    static let darkElevated = Color(red: 0.12, green: 0.16, blue: 0.23)
    static let darkBorder = Color(red: 0.18, green: 0.23, blue: 0.33)
    
    static let lightBackground = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let lightSurface = Color(red: 1.0, green: 1.0, blue: 1.0)
    static let lightElevated = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let lightBorder = Color(red: 0.82, green: 0.86, blue: 0.92)

    // MARK: - High-Visibility Tool Tab Colors
    static func toolColor(_ tool: ToolTab) -> Color {
        switch tool {
        case .claude:
            return Color(red: 0.82, green: 0.45, blue: 0.98) // Claude Purple/Violet
        case .files:
            return Color(red: 0.14, green: 0.65, blue: 0.98) // Vivid Blue
        case .editor:
            return Color(red: 0.75, green: 0.45, blue: 1.00) // Electric Purple
        case .terminal:
            return Color(red: 0.15, green: 0.82, blue: 0.48) // Emerald Green
        case .browser:
            return Color(red: 0.06, green: 0.72, blue: 0.95) // Cyan
        case .simulator:
            return Color(red: 0.98, green: 0.38, blue: 0.58) // Vivid Pink
        }
    }

    // MARK: - File Extension Icons and Colors
    static func filePresentation(for name: String, isDirectory: Bool) -> (icon: String, color: Color) {
        if isDirectory {
            return ("folder.fill", Color(red: 0.98, green: 0.74, blue: 0.22))
        }
        
        let lower = name.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        
        // Specific filenames
        switch lower {
        case ".gitignore", ".gitattributes", ".gitmodules":
            return ("arrow.triangle.branch", Color(red: 0.95, green: 0.35, blue: 0.35))
        case "package.swift", "package.json", "cargo.toml", "go.mod", "gemfile":
            return ("shippingbox.fill", Color(red: 0.85, green: 0.45, blue: 0.95))
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml":
            return ("shippingbox", Color(red: 0.15, green: 0.65, blue: 0.95))
        case "readme.md", "readme.txt", "license", "license.md":
            return ("book.pages.fill", Color(red: 0.35, green: 0.75, blue: 0.95))
        default:
            break
        }
        
        switch ext {
        case "swift":
            return ("swift", Color(red: 0.98, green: 0.45, blue: 0.20))
        case "js", "mjs", "cjs":
            return ("curlybraces", Color(red: 0.96, green: 0.80, blue: 0.20))
        case "ts", "mts", "cts":
            return ("curlybraces", Color(red: 0.20, green: 0.65, blue: 0.95))
        case "jsx", "tsx":
            return ("atom", Color(red: 0.20, green: 0.80, blue: 0.90))
        case "py":
            return ("doc.text.fill", Color(red: 0.25, green: 0.65, blue: 0.95))
        case "json":
            return ("curlybraces.square.fill", Color(red: 0.30, green: 0.80, blue: 0.50))
        case "yaml", "yml", "toml":
            return ("slider.horizontal.3", Color(red: 0.90, green: 0.55, blue: 0.30))
        case "html", "htm":
            return ("chevron.left.forwardslash.chevron.right", Color(red: 0.95, green: 0.35, blue: 0.25))
        case "css", "scss", "sass", "less":
            return ("paintpalette.fill", Color(red: 0.95, green: 0.40, blue: 0.70))
        case "c", "h":
            return ("c.circle.fill", Color(red: 0.35, green: 0.60, blue: 0.95))
        case "cpp", "cc", "cxx", "hpp":
            return ("c.circle.fill", Color(red: 0.55, green: 0.45, blue: 0.95))
        case "rs":
            return ("gearshape.2.fill", Color(red: 0.95, green: 0.45, blue: 0.25))
        case "go":
            return ("arrow.triangle.2.circlepath", Color(red: 0.10, green: 0.75, blue: 0.85))
        case "sh", "zsh", "bash":
            return ("terminal.fill", Color(red: 0.20, green: 0.85, blue: 0.45))
        case "md", "markdown":
            return ("text.alignleft", Color(red: 0.65, green: 0.55, blue: 0.95))
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico":
            return ("photo.fill", Color(red: 0.65, green: 0.45, blue: 0.95))
        case "zip", "tar", "gz", "bz2", "xz":
            return ("archivebox.fill", Color(red: 0.80, green: 0.55, blue: 0.35))
        case "pdf":
            return ("doc.richtext.fill", Color(red: 0.95, green: 0.25, blue: 0.25))
        case "sql":
            return ("cylinder.split.1x2.fill", Color(red: 0.35, green: 0.75, blue: 0.85))
        default:
            return ("doc.text", Color.secondary)
        }
    }
    
    // MARK: - AppKit Colors for Syntax Highlighting
    struct SyntaxColors {
        let background: NSColor
        let text: NSColor
        let keyword: NSColor
        let string: NSColor
        let number: NSColor
        let comment: NSColor
        let type: NSColor
        let function: NSColor
        let attribute: NSColor
        let gutterBackground: NSColor
        let gutterText: NSColor
        let activeLineGutterText: NSColor
        let activeLineBackground: NSColor

        static let dark = SyntaxColors(
            background: NSColor(srgbRed: 0.07, green: 0.09, blue: 0.13, alpha: 1.0),
            text: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1.0),
            keyword: NSColor(srgbRed: 0.80, green: 0.50, blue: 1.00, alpha: 1.0),     // Vibrant Lilac
            string: NSColor(srgbRed: 0.32, green: 0.88, blue: 0.54, alpha: 1.0),      // Crisp Emerald
            number: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.28, alpha: 1.0),      // Vivid Amber/Orange
            comment: NSColor(srgbRed: 0.48, green: 0.58, blue: 0.68, alpha: 1.0),     // Readable Slate
            type: NSColor(srgbRed: 0.22, green: 0.78, blue: 0.98, alpha: 1.0),        // Bright Cyan
            function: NSColor(srgbRed: 0.98, green: 0.82, blue: 0.30, alpha: 1.0),    // Vibrant Gold
            attribute: NSColor(srgbRed: 0.98, green: 0.44, blue: 0.68, alpha: 1.0),   // Hot Pink
            gutterBackground: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1.0),
            gutterText: NSColor(srgbRed: 0.38, green: 0.46, blue: 0.56, alpha: 1.0),
            activeLineGutterText: NSColor(srgbRed: 0.30, green: 0.85, blue: 1.00, alpha: 1.0),
            activeLineBackground: NSColor(srgbRed: 0.14, green: 0.18, blue: 0.26, alpha: 0.5)
        )

        static let light = SyntaxColors(
            background: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
            text: NSColor(srgbRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0),
            keyword: NSColor(srgbRed: 0.58, green: 0.18, blue: 0.85, alpha: 1.0),
            string: NSColor(srgbRed: 0.12, green: 0.62, blue: 0.32, alpha: 1.0),
            number: NSColor(srgbRed: 0.82, green: 0.38, blue: 0.08, alpha: 1.0),
            comment: NSColor(srgbRed: 0.42, green: 0.50, blue: 0.58, alpha: 1.0),
            type: NSColor(srgbRed: 0.08, green: 0.52, blue: 0.82, alpha: 1.0),
            function: NSColor(srgbRed: 0.72, green: 0.48, blue: 0.05, alpha: 1.0),
            attribute: NSColor(srgbRed: 0.82, green: 0.15, blue: 0.48, alpha: 1.0),
            gutterBackground: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0),
            gutterText: NSColor(srgbRed: 0.58, green: 0.64, blue: 0.72, alpha: 1.0),
            activeLineGutterText: NSColor(srgbRed: 0.08, green: 0.45, blue: 0.85, alpha: 1.0),
            activeLineBackground: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 0.7)
        )

        static func current(isDark: Bool) -> SyntaxColors {
            isDark ? .dark : .light
        }
    }
}
