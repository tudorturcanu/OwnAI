import Foundation

enum WatchConnectivityPayloadKey {
    static let request = "watchPromptRequest"
    static let response = "watchPromptResponse"
}

struct WatchPromptRequest: Codable, Sendable {
    let id: UUID
    let prompt: String
    let sentAt: Date

    init(id: UUID = UUID(), prompt: String, sentAt: Date = .now) {
        self.id = id
        self.prompt = prompt
        self.sentAt = sentAt
    }
}

struct WatchPromptResponse: Codable, Sendable {
    let requestID: UUID
    let prompt: String
    let reply: String
    let conversationID: UUID?
    let modelName: String?
    let isError: Bool
    let respondedAt: Date

    init(
        requestID: UUID,
        prompt: String,
        reply: String,
        conversationID: UUID? = nil,
        modelName: String? = nil,
        isError: Bool,
        respondedAt: Date = .now
    ) {
        self.requestID = requestID
        self.prompt = prompt
        self.reply = reply
        self.conversationID = conversationID
        self.modelName = modelName
        self.isError = isError
        self.respondedAt = respondedAt
    }
}

enum WatchCompanionRoute {
    static let scheme = "ownai"
    static let conversationHost = "conversation"

    static func conversationURL(for conversationID: UUID?) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = conversationHost

        if let conversationID {
            components.queryItems = [
                URLQueryItem(name: "id", value: conversationID.uuidString)
            ]
        }

        return components.url
    }

    static func conversationID(from url: URL) -> UUID? {
        guard url.scheme?.localizedCaseInsensitiveCompare(scheme) == .orderedSame else {
            return nil
        }

        guard url.host?.localizedCaseInsensitiveCompare(conversationHost) == .orderedSame else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idValue = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            return nil
        }

        return UUID(uuidString: idValue)
    }
}

enum WatchConnectivityCodec {
    static func encodeMessage<T: Encodable>(_ value: T, key: String) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return [key: data]
    }

    static func decodeMessage<T: Decodable>(_ type: T.Type, from message: [String: Any], key: String) throws -> T {
        guard let data = message[key] as? Data else {
            throw WatchConnectivityCodecError.missingPayload(key: key)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum WatchConnectivityCodecError: LocalizedError {
    case missingPayload(key: String)

    var errorDescription: String? {
        switch self {
        case .missingPayload(let key):
            return "Missing WatchConnectivity payload for key \(key)."
        }
    }
}
