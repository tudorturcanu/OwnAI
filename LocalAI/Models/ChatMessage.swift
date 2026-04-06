import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let thinkingContent: String?
    let sourceTitles: [String]
    let imageFileName: String?
    var isStreaming: Bool = false

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        thinkingContent: String? = nil,
        sourceTitles: [String] = [],
        imageFileName: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinkingContent = thinkingContent
        self.sourceTitles = sourceTitles
        self.imageFileName = imageFileName
        self.isStreaming = isStreaming
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case thinkingContent
        case sourceTitles
        case imageFileName
        case isStreaming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        thinkingContent = try container.decodeIfPresent(String.self, forKey: .thinkingContent)
        sourceTitles = try container.decodeIfPresent([String].self, forKey: .sourceTitles) ?? []
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
    }

    enum MessageRole: String, Codable {
        case user
        case assistant
    }
}
