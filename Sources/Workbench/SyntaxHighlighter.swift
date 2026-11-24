import AppKit
import Foundation

enum SyntaxLanguage: String {
    case swift = "Swift"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case python = "Python"
    case json = "JSON"
    case html = "HTML"
    case css = "CSS"
    case shell = "Shell"
    case c = "C"
    case cpp = "C++"
    case rust = "Rust"
    case go = "Go"
    case markdown = "Markdown"
    case plain = "Plain Text"

    static func detect(for url: URL) -> SyntaxLanguage {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        
        switch ext {
        case "swift": return .swift
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "mts", "cts", "tsx": return .typescript
        case "py", "pyw": return .python
        case "json": return .json
        case "html", "htm", "svg", "xml": return .html
        case "css", "scss", "sass", "less": return .css
        case "sh", "zsh", "bash": return .shell
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp": return .cpp
        case "rs": return .rust
        case "go": return .go
        case "md", "markdown": return .markdown
        default:
            if ["dockerfile", "makefile"].contains(name) { return .shell }
            return .plain
        }
    }
}

final class SyntaxHighlighter {
    private struct HighlightRule {
        let regex: NSRegularExpression
        let tokenType: TokenType
        let group: Int
    }

    private enum TokenType {
        case keyword
        case string
        case number
        case comment
        case type
        case function
        case attribute
    }

    private static var rulesCache: [SyntaxLanguage: [HighlightRule]] = [:]
    private static let lock = NSLock()

    private static func getRules(for lang: SyntaxLanguage) -> [HighlightRule] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = rulesCache[lang] { return cached }
        let rules = buildRules(for: lang)
        rulesCache[lang] = rules
        return rules
    }

    private static func buildRules(for lang: SyntaxLanguage) -> [HighlightRule] {
        var rules: [HighlightRule] = []

        func add(_ pattern: String, _ type: TokenType, group: Int = 0, options: NSRegularExpression.Options = []) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                rules.append(HighlightRule(regex: regex, tokenType: type, group: group))
            }
        }

        // 1. Strings
        add("\"(\\\\.|[^\"\\\\])*\"", .string)
        add("'(\\\\.|[^'\\\\])*'", .string)
        if lang == .javascript || lang == .typescript {
            add("`(\\\\.|[^`\\\\])*`", .string)
        }

        // 2. Comments
        switch lang {
        case .python, .shell:
            add("#.*$", .comment, options: [.anchorsMatchLines])
        case .html:
            add("<!--[\\s\\S]*?-->", .comment)
        default:
            add("//.*$", .comment, options: [.anchorsMatchLines])
            add("/\\*[\\s\\S]*?\\*/", .comment)
        }

        // 3. Numbers
        add("\\b(0x[0-9a-fA-F]+|0b[01]+|\\d+(\\.\\d+)?)\\b", .number)

        // 4. Attributes / Preprocessor
        switch lang {
        case .swift:
            add("@[A-Za-z_][A-Za-z0-9_]*", .attribute)
            add("#[A-Za-z_][A-Za-z0-9_]*", .attribute)
        case .c, .cpp:
            add("#[A-Za-z_][A-Za-z0-9_]*", .attribute)
        case .python:
            add("@[A-Za-z_][A-Za-z0-9_]*", .attribute)
        case .rust:
            add("#\\[[\\s\\S]*?\\]", .attribute)
        default:
            break
        }

        // 5. Language Keywords
        let keywords: String
        switch lang {
        case .swift:
            keywords = "func|let|var|class|struct|enum|protocol|extension|init|deinit|subscript|typealias|import|guard|if|else|switch|case|default|for|while|repeat|break|continue|return|throw|throws|rethrows|try|catch|defer|do|as|is|in|where|async|await|actor|some|any|self|Self|super|nil|true|false|public|private|fileprivate|internal|open|static|mutating|nonmutating|override|final|weak|unowned|lazy"
        case .javascript, .typescript:
            keywords = "function|const|let|var|class|interface|type|extends|implements|import|export|from|as|default|return|if|else|switch|case|break|continue|for|while|do|try|catch|finally|throw|new|this|typeof|instanceof|void|delete|in|of|async|await|yield|null|undefined|true|false"
        case .python:
            keywords = "def|class|lambda|return|yield|if|elif|else|for|while|break|continue|try|except|finally|raise|import|from|as|with|pass|assert|global|nonlocal|async|await|None|True|False|and|or|not|is|in"
        case .rust:
            keywords = "fn|let|mut|const|static|struct|enum|trait|impl|type|mod|use|pub|crate|self|Self|super|return|if|else|match|loop|while|for|in|break|continue|async|await|move|unsafe|where|true|false"
        case .go:
            keywords = "func|package|import|var|const|type|struct|interface|return|if|else|switch|case|default|for|range|break|continue|fallthrough|go|select|chan|defer|nil|true|false"
        case .c, .cpp:
            keywords = "auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|int|long|register|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|class|public|protected|private|template|typename|virtual|inline|override|nullptr|bool|true|false"
        case .json:
            keywords = "true|false|null"
        case .shell:
            keywords = "if|then|else|elif|fi|case|esac|for|select|while|until|do|done|in|function|time|return|exit"
        case .css:
            keywords = "important|media|keyframes|import|charset|font-face"
        default:
            keywords = ""
        }

        if !keywords.isEmpty {
            add("\\b(\(keywords))\\b", .keyword)
        }

        // 6. Types (CamelCase identifier starting with uppercase)
        if lang != .json && lang != .markdown {
            add("\\b([A-Z][A-Za-z0-9_]*)\\b", .type)
        }

        // 7. Function calls: foo(...)
        if lang != .json && lang != .markdown {
            add("\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*(?=\\()", .function, group: 1)
        }

        return rules
    }

    static func highlight(textStorage: NSTextStorage, language: SyntaxLanguage, isDark: Bool, font: NSFont) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length > 0 else { return }

        // Skip massive files > 2 MB for instant responsiveness
        if fullRange.length > 2_000_000 {
            textStorage.beginEditing()
            textStorage.setAttributes([
                .font: font,
                .foregroundColor: WorkbenchTheme.SyntaxColors.current(isDark: isDark).text
            ], range: fullRange)
            textStorage.endEditing()
            return
        }

        let colors = WorkbenchTheme.SyntaxColors.current(isDark: isDark)
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

        textStorage.beginEditing()
        textStorage.setAttributes([
            .font: font,
            .foregroundColor: colors.text
        ], range: fullRange)

        let rules = getRules(for: language)

        for rule in rules {
            rule.regex.enumerateMatches(in: string, options: [], range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound && range.length > 0 else { return }

                var attrs: [NSAttributedString.Key: Any] = [:]
                switch rule.tokenType {
                case .keyword:
                    attrs[.foregroundColor] = colors.keyword
                    attrs[.font] = boldFont
                case .string:
                    attrs[.foregroundColor] = colors.string
                case .number:
                    attrs[.foregroundColor] = colors.number
                case .comment:
                    attrs[.foregroundColor] = colors.comment
                    attrs[.font] = italicFont
                case .type:
                    attrs[.foregroundColor] = colors.type
                case .function:
                    attrs[.foregroundColor] = colors.function
                case .attribute:
                    attrs[.foregroundColor] = colors.attribute
                }

                textStorage.addAttributes(attrs, range: range)
            }
        }

        textStorage.endEditing()
    }
}
