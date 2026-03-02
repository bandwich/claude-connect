import Foundation

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Content Block Structs

struct TextBlock: Codable {
    let type: String
    let text: String
}

struct ThinkingBlock: Codable {
    let type: String
    let thinking: String
    let signature: String
}

struct ToolUseBlock: Codable {
    let type: String
    let id: String
    let name: String
    let input: [String: AnyCodable]
}

struct ToolResultBlock: Codable {
    let type: String
    let toolUseId: String
    let content: String
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

// MARK: - Content Block Enum

enum ContentBlock: Codable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case unknown

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .thinking(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        case .unknown:
            break
        }
    }
}

// MARK: - Assistant Response Message

struct AssistantResponseMessage: Codable {
    let type: String
    let contentBlocks: [ContentBlock]
    let timestamp: Double
    let sessionId: String?  // Session this message belongs to (for filtering)
    let branch: String?
    let seq: Int?  // Transcript line number for gap detection

    enum CodingKeys: String, CodingKey {
        case type
        case contentBlocks = "content_blocks"
        case timestamp
        case sessionId = "session_id"
        case branch
        case seq
    }
}

// MARK: - Resync Response

struct ResyncMessage: Codable {
    let seq: Int
    let role: String?
    let content: ResyncContent
    let timestamp: ResyncTimestamp

    enum CodingKeys: String, CodingKey {
        case seq, role, content, timestamp
    }
}

// Content can be a string or an array of content blocks
enum ResyncContent: Codable {
    case string(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

// Timestamp can be a string or a number
enum ResyncTimestamp: Codable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let str):
            try container.encode(str)
        case .number(let num):
            try container.encode(num)
        }
    }
}

struct ResyncResponse: Codable {
    let type: String
    let fromSeq: Int
    let messages: [ResyncMessage]

    enum CodingKeys: String, CodingKey {
        case type
        case fromSeq = "from_seq"
        case messages
    }
}
