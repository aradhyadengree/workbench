import AppKit
import Foundation

final class ANSIParser {
    // 16 ANSI Standard & Bright Colors
    private static let ansiColors: [NSColor] = [
        // Standard (0-7)
        NSColor(srgbRed: 0.15, green: 0.18, blue: 0.25, alpha: 1.0), // 0: Black
        NSColor(srgbRed: 0.95, green: 0.32, blue: 0.32, alpha: 1.0), // 1: Red
        NSColor(srgbRed: 0.22, green: 0.82, blue: 0.45, alpha: 1.0), // 2: Green
        NSColor(srgbRed: 0.98, green: 0.75, blue: 0.25, alpha: 1.0), // 3: Yellow
        NSColor(srgbRed: 0.28, green: 0.65, blue: 0.98, alpha: 1.0), // 4: Blue
        NSColor(srgbRed: 0.85, green: 0.45, blue: 0.98, alpha: 1.0), // 5: Magenta
        NSColor(srgbRed: 0.20, green: 0.85, blue: 0.95, alpha: 1.0), // 6: Cyan
        NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1.0), // 7: White
        
        // Bright (8-15)
        NSColor(srgbRed: 0.45, green: 0.52, blue: 0.65, alpha: 1.0), // 8: Bright Black
        NSColor(srgbRed: 1.00, green: 0.48, blue: 0.48, alpha: 1.0), // 9: Bright Red
        NSColor(srgbRed: 0.38, green: 0.95, blue: 0.58, alpha: 1.0), // 10: Bright Green
        NSColor(srgbRed: 1.00, green: 0.88, blue: 0.35, alpha: 1.0), // 11: Bright Yellow
        NSColor(srgbRed: 0.45, green: 0.75, blue: 1.00, alpha: 1.0), // 12: Bright Blue
        NSColor(srgbRed: 0.95, green: 0.55, blue: 1.00, alpha: 1.0), // 13: Bright Magenta
        NSColor(srgbRed: 0.40, green: 0.92, blue: 1.00, alpha: 1.0), // 14: Bright Cyan
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)  // 15: Bright White
    ]

    private static func colorFrom256(_ n: Int) -> NSColor {
        if n < 16 { return ansiColors[n] }
        if n >= 232 { // Grayscale 232-255
            let gray = CGFloat(n - 232) / 23.0 * 0.9 + 0.05
            return NSColor(white: gray, alpha: 1.0)
        }
        // 6x6x6 color cube 16-231
        let val = n - 16
        let r = CGFloat(val / 36) / 5.0
        let g = CGFloat((val % 36) / 6) / 5.0
        let b = CGFloat(val % 6) / 5.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    static func parse(_ raw: String, baseFont: NSFont, defaultColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentFg: NSColor = defaultColor
        var currentBg: NSColor? = nil
        var isBold = false
        var isUnderline = false

        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        func currentAttrs() -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: isBold ? boldFont : baseFont,
                .foregroundColor: currentFg
            ]
            if let bg = currentBg {
                attrs[.backgroundColor] = bg
            }
            if isUnderline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return attrs
        }

        var index = raw.startIndex

        while index < raw.endIndex {
            // Find next escape character \u{1B}
            if let escIndex = raw[index...].firstIndex(of: "\u{1B}") {
                // Append text preceding escape
                if escIndex > index {
                    let chunk = String(raw[index..<escIndex])
                    result.append(NSAttributedString(string: chunk, attributes: currentAttrs()))
                }

                // Check for sequence after \e
                let afterEsc = raw.index(after: escIndex)
                if afterEsc < raw.endIndex && raw[afterEsc] == "[" {
                    var seqEnd = raw.index(after: afterEsc)
                    // Seek end of ANSI command (letter)
                    while seqEnd < raw.endIndex {
                        let c = raw[seqEnd]
                        if (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") {
                            break
                        }
                        seqEnd = raw.index(after: seqEnd)
                    }

                    if seqEnd < raw.endIndex {
                        let cmd = raw[seqEnd]
                        let paramStart = raw.index(after: afterEsc)
                        let paramStr = String(raw[paramStart..<seqEnd])

                        if cmd == "m" { // SGR color / style command
                            let codes = paramStr.split(separator: ";").compactMap { Int($0) }
                            if codes.isEmpty {
                                // Reset
                                currentFg = defaultColor
                                currentBg = nil
                                isBold = false
                                isUnderline = false
                            } else {
                                var i = 0
                                while i < codes.count {
                                    let code = codes[i]
                                    switch code {
                                    case 0:
                                        currentFg = defaultColor
                                        currentBg = nil
                                        isBold = false
                                        isUnderline = false
                                    case 1:
                                        isBold = true
                                    case 2:
                                        currentFg = currentFg.withAlphaComponent(0.6)
                                    case 4:
                                        isUnderline = true
                                    case 22:
                                        isBold = false
                                    case 24:
                                        isUnderline = false
                                    case 30...37:
                                        currentFg = ansiColors[code - 30]
                                    case 38: // Extended foreground
                                        if i + 2 < codes.count && codes[i + 1] == 5 {
                                            currentFg = colorFrom256(codes[i + 2])
                                            i += 2
                                        } else if i + 4 < codes.count && codes[i + 1] == 2 {
                                            currentFg = NSColor(srgbRed: CGFloat(codes[i + 2]) / 255.0,
                                                                green: CGFloat(codes[i + 3]) / 255.0,
                                                                blue: CGFloat(codes[i + 4]) / 255.0,
                                                                alpha: 1.0)
                                            i += 4
                                        }
                                    case 39:
                                        currentFg = defaultColor
                                    case 40...47:
                                        currentBg = ansiColors[code - 40].withAlphaComponent(0.3)
                                    case 48: // Extended background
                                        if i + 2 < codes.count && codes[i + 1] == 5 {
                                            currentBg = colorFrom256(codes[i + 2]).withAlphaComponent(0.3)
                                            i += 2
                                        } else if i + 4 < codes.count && codes[i + 1] == 2 {
                                            currentBg = NSColor(srgbRed: CGFloat(codes[i + 2]) / 255.0,
                                                                green: CGFloat(codes[i + 3]) / 255.0,
                                                                blue: CGFloat(codes[i + 4]) / 255.0,
                                                                alpha: 0.3)
                                            i += 4
                                        }
                                    case 49:
                                        currentBg = nil
                                    case 90...97:
                                        currentFg = ansiColors[code - 90 + 8]
                                    case 100...107:
                                        currentBg = ansiColors[code - 100 + 8].withAlphaComponent(0.3)
                                    default:
                                        break
                                    }
                                    i += 1
                                }
                            }
                        }
                        index = raw.index(after: seqEnd)
                        continue
                    }
                }
                index = raw.index(after: escIndex)
            } else {
                // Remaining text
                let chunk = String(raw[index...])
                result.append(NSAttributedString(string: chunk, attributes: currentAttrs()))
                break
            }
        }

        return result
    }
}
