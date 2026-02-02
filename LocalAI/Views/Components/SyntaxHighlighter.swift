//
//  SyntaxHighlighter.swift
//  LocalAI
//
//  Created by ANTIGRAVITY on 01.02.2026.
//

import SwiftUI

struct SyntaxHighlighter {
    
    static func highlight(_ code: String, language: String?) -> AttributedString {
        var attributed = AttributedString(code)
        
        // Base style
        attributed.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        attributed.foregroundColor = Color(white: 0.2) // Dark grey base
        
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
                print("Regex error: \(error)")
            }
        }
        
        // Swift / Generics
        if ["swift", "c", "cpp", "java", "kotlin"].contains(language) {
            // Keywords
            let keywords = "\\b(func|var|let|if|else|guard|return|class|struct|enum|extension|import|public|private|static|init|try|catch|do|for|in|while|switch|case|break|continue|override|super|self|true|false|nil)\\b"
            updateColor(keywords, .purple)
            
            // Types (Capitalized words)
            updateColor("\\b[A-Z][a-zA-Z0-9_]*\\b", .teal)
            
            // Strings
            updateColor("\".*?\"", .red)
            
            // Numbers
            updateColor("\\b\\d+\\b", .blue)
            
            // Comments (Simple single line)
            updateColor("//.*", .gray)
        }
        
        // Python
        else if ["python", "py"].contains(language) {
             // Keywords
            let keywords = "\\b(def|class|if|elif|else|return|import|from|as|try|except|finally|for|in|while|break|continue|pass|lambda|yield|with|global|nonlocal|assert|del|True|False|None)\\b"
            updateColor(keywords, .purple)
            
            // Functions
            updateColor("(?<=def\\s)\\w+", .blue)
            
            // Strings
            updateColor("(\"\"\".*?\"\"\"|\".*?\"|'.*?')", .red) // Improve regex for triple quotes later if needed
             
            // Comments
            updateColor("#.*", .gray)
        }
        
        // Web (JS/TS)
        else if ["javascript", "js", "typescript", "ts"].contains(language) {
            let keywords = "\\b(function|const|let|var|if|else|return|import|export|from|class|extends|new|this|try|catch|finally|for|in|of|while|do|switch|case|break|continue|default|async|await|true|false|null|undefined)\\b"
            updateColor(keywords, .purple)
            
            updateColor("\".*?\"", .red)
            updateColor("'.*?'", .red)
            updateColor("`.*?`", .red)
            
            updateColor("//.*", .gray)
        }
        
        return attributed
    }
}
