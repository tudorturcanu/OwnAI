//
//  WebSearchEngine.swift
//  LocalAI
//
//  Which site "Search on Web" opens. The app is otherwise fully on-device, so
//  the one action that leaves the phone should at least be the user's choice.
//

import Foundation

enum WebSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing

    nonisolated static let storageKey = "webSearchEngine"

    var id: String { rawValue }

    /// Brand names, deliberately not localized.
    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(encoded)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(encoded)")
        }
    }
}
