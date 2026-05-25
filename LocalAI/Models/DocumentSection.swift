import Foundation

struct DocumentSection: Equatable, Codable, Sendable {
    let title: String
    let lowerBound: Int
    let upperBound: Int

    nonisolated init(title: String, lowerBound: Int, upperBound: Int) {
        self.title = title
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}
