//
//  SyntaxHighlighter.swift
//  LocalAI
//
//  Created by ANTIGRAVITY on 01.02.2026.
//

import SwiftUI

enum CodeTheme: String, CaseIterable, Identifiable {
    case defaultTheme = "Default"
    case dracula = "Dracula"
    case solarizedLight = "Solarized Light"
    case midnight = "Midnight"
    
    var id: String { rawValue }
    
    var title: String { rawValue }
    
    var background: Color {
        switch self {
        case .defaultTheme: return Color(white: 0.98)
        case .dracula: return Color(red: 0.16, green: 0.16, blue: 0.18)
        case .solarizedLight: return Color(red: 0.99, green: 0.96, blue: 0.89)
        case .midnight: return Color(red: 0.05, green: 0.05, blue: 0.1)
        }
    }
    
    var headerBackground: Color {
        switch self {
        case .defaultTheme: return Color(white: 0.95)
        case .dracula: return Color(red: 0.13, green: 0.13, blue: 0.15)
        case .solarizedLight: return Color(red: 0.93, green: 0.91, blue: 0.83)
        case .midnight: return Color(red: 0.08, green: 0.08, blue: 0.15)
        }
    }
    
    var borderColor: Color {
        switch self {
        case .defaultTheme: return Color(white: 0.85)
        case .dracula: return Color(white: 0.3)
        case .solarizedLight: return Color(red: 0.8, green: 0.8, blue: 0.75)
        case .midnight: return Color(white: 0.2)
        }
    }
    
    var foreground: Color {
        switch self {
        case .defaultTheme: return Color(white: 0.2)
        case .dracula: return Color(white: 0.9)
        case .solarizedLight: return Color(red: 0.4, green: 0.48, blue: 0.5)
        case .midnight: return Color(white: 0.85)
        }
    }
    
    var keyword: Color {
        switch self {
        case .defaultTheme: return .purple
        case .dracula: return Color(red: 0.9, green: 0.4, blue: 0.6)
        case .solarizedLight: return Color(red: 0.52, green: 0.54, blue: 0.0)
        case .midnight: return .cyan
        }
    }
    
    var string: Color {
        switch self {
        case .defaultTheme: return .red
        case .dracula: return Color(red: 0.95, green: 0.96, blue: 0.55)
        case .solarizedLight: return Color(red: 0.16, green: 0.55, blue: 0.55)
        case .midnight: return .green
        }
    }
    
    var number: Color {
        switch self {
        case .defaultTheme: return .blue
        case .dracula: return Color(red: 0.74, green: 0.57, blue: 0.97)
        case .solarizedLight: return Color(red: 0.83, green: 0.21, blue: 0.18)
        case .midnight: return .orange
        }
    }
    
    var type: Color {
        switch self {
        case .defaultTheme: return .teal
        case .dracula: return Color(red: 0.54, green: 0.91, blue: 0.99)
        case .solarizedLight: return Color(red: 0.15, green: 0.4, blue: 0.82)
        case .midnight: return .indigo
        }
    }
    
    var comment: Color {
        switch self {
        case .defaultTheme: return .gray
        case .dracula: return Color(red: 0.38, green: 0.45, blue: 0.55)
        case .solarizedLight: return Color(red: 0.58, green: 0.63, blue: 0.63)
        case .midnight: return Color(white: 0.4)
        }
    }
}

struct SyntaxHighlighter {
    static func plainText(
        _ code: String,
        theme: CodeTheme = .defaultTheme,
        textScale: Double = 1.0,
        baseFontSize: CGFloat = 13
    ) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = .monospacedSystemFont(ofSize: baseFontSize * textScale, weight: .regular)
        attributed.foregroundColor = theme.foreground
        return attributed
    }
    
    static func highlight(
        _ code: String,
        language: String?,
        theme: CodeTheme = .defaultTheme,
        textScale: Double = 1.0,
        baseFontSize: CGFloat = 13
    ) -> AttributedString {
        var attributed = plainText(code, theme: theme, textScale: textScale, baseFontSize: baseFontSize)
        
        guard let language = language?.lowercased() else { return attributed }
        
        // Simple regex-based highlighting for common languages
        // This is a basic implementation. For production, a proper lexer is better.
        
        let updateColor = { (pattern: String, color: Color) in
            do {
                let regex = try Regex(pattern)
                for match in code.ranges(of: regex) {
                    if let range = Range(match, in: attributed) {
                        attributed[range].foregroundColor = color
                    }
                }
            } catch {
            }
        }
        
        // Swift / Generics
        if ["swift", "c", "cpp", "java", "kotlin"].contains(language) {
            // Keywords
            let keywords = "\\b(func|var|let|if|else|guard|return|class|struct|enum|extension|import|public|private|static|init|try|catch|do|for|in|while|switch|case|break|continue|override|super|self|true|false|nil)\\b"
            updateColor(keywords, theme.keyword)
            
            // Types (Capitalized words)
            updateColor("\\b[A-Z][a-zA-Z0-9_]*\\b", theme.type)
            
            // Strings
            updateColor("\".*?\"", theme.string)
            
            // Numbers
            updateColor("\\b\\d+\\b", theme.number)
            
            // Comments (Simple single line)
            updateColor("//.*", theme.comment)
        }
        
        // Python
        else if ["python", "py"].contains(language) {
             // Keywords
            let keywords = "\\b(def|class|if|elif|else|return|import|from|as|try|except|finally|for|in|while|break|continue|pass|lambda|yield|with|global|nonlocal|assert|del|True|False|None)\\b"
            updateColor(keywords, theme.keyword)
            
            // Functions
            updateColor("(?<=def\\s)\\w+", theme.type)
            
            // Strings
            updateColor("(\"\"\".*?\"\"\"|\".*?\"|'.*?')", theme.string) // Improve regex for triple quotes later if needed
             
            // Comments
            updateColor("#.*", theme.comment)
        }
        
        // Web (JS/TS)
        else if ["javascript", "js", "typescript", "ts"].contains(language) {
            let keywords = "\\b(function|const|let|var|if|else|return|import|export|from|class|extends|new|this|try|catch|finally|for|in|of|while|do|switch|case|break|continue|default|async|await|true|false|null|undefined)\\b"
            updateColor(keywords, theme.keyword)
            
            updateColor("\".*?\"", theme.string)
            updateColor("'.*?'", theme.string)
            updateColor("`.*?`", theme.string)
            
            updateColor("//.*", theme.comment)
        }
        
        return attributed
    }
}
