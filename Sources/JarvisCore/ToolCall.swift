import Foundation

public struct ToolCall: Equatable, Sendable {
    public var name: String
    public var command: String?
    public var filePath: String?
    public var description: String?

    public init(name: String, command: String?, filePath: String?, description: String?) {
        self.name = name
        self.command = command
        self.filePath = filePath
        self.description = description
    }

    public static func from(toolName: String, toolInput: [String: Any]) -> ToolCall {
        ToolCall(
            name: toolName,
            command: toolInput["command"] as? String,
            filePath: (toolInput["file_path"] as? String) ?? (toolInput["notebook_path"] as? String),
            description: toolInput["description"] as? String
        )
    }
}
