import Foundation

/// BYOK agent brain — Anthropic Messages API with vision + tool-use. The model sees the
/// screenshot, hears the command, and either calls `run_applescript` (to act) or replies
/// with text (to answer). The user's key is read from the Keychain.
struct ClaudeBrain: AgentBrain {
    let apiKey: String
    var model: String = "claude-sonnet-4-6"

    static let systemPrompt = """
    You are Murmur, a voice agent that controls the user's Mac. You receive a screenshot of \
    their screen, the frontmost app, any selected text, and a spoken command.
    - To DO something, call run_applescript with working AppleScript, a one-sentence plain-English \
    `summary`, and a `risk` level.
    - To ANSWER a question about what's on screen, reply with a short spoken answer as plain text \
    (no tool call).

    Scripting strategy:
    - For apps with an AppleScript dictionary (Finder, Calendar, Reminders, Mail, Notes, Safari, \
    Music, System Settings, System Events), use their native commands — most reliable.
    - For apps WITHOUT a dictionary (WhatsApp, Slack, Discord, Telegram, Chrome/Arc and other \
    Electron or browser apps): drive them through the GUI with System Events. Pattern: \
    `tell application "AppName" to activate`, then `tell application "System Events"` use \
    `keystroke`, `key code`, and `keystroke return` to type/send, or `click` UI elements by their \
    accessibility role/title. Prefer keystrokes over guessing pixel coordinates.
    - Read the screenshot to ground your actions (which chat is open, what the selection refers to).

    Don't ask follow-up questions — make a reasonable assumption. Mark anything that deletes, sends a \
    message/email, quits, moves files, or is hard to undo as `risky`; everything else is `safe`.
    """

    private static let tools: [[String: Any]] = [[
        "name": "run_applescript",
        "description": "Execute AppleScript on the user's Mac to accomplish their request.",
        "input_schema": [
            "type": "object",
            "properties": [
                "script": ["type": "string", "description": "The AppleScript to run."],
                "summary": ["type": "string", "description": "One plain-English sentence describing what this does."],
                "risk": ["type": "string", "enum": ["safe", "risky"],
                         "description": "'risky' if it writes, deletes, sends, quits, or is hard to undo; otherwise 'safe'."],
            ],
            "required": ["script", "summary", "risk"],
        ],
    ]]

    func decide(_ context: AgentContext) async throws -> CommandDecision {
        guard !apiKey.isEmpty else { throw AgentError.noAPIKey }

        var content: [[String: Any]] = []
        if let png = context.screenshotPNG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()],
            ])
        }
        var info = "Command: \(context.command)"
        if let app = context.frontmostApp { info = "Frontmost app: \(app)\n" + info }
        if let sel = context.selection, !sel.isEmpty { info += "\nSelected text: \"\(sel)\"" }
        content.append(["type": "text", "text": info])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "tools": Self.tools,
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = (json?["content"] as? [[String: Any]]) ?? []
        return Self.parse(content: blocks)
    }

    /// Parses Anthropic response content blocks into a decision. Pure — unit-tested.
    static func parse(content: [[String: Any]]) -> CommandDecision {
        for block in content {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == "run_applescript",
                  let input = block["input"] as? [String: Any],
                  let script = (input["script"] as? String), !script.isEmpty else { continue }
            let summary = (input["summary"] as? String) ?? "Run a command"
            let risk = ActionRisk(rawValue: (input["risk"] as? String) ?? "risky") ?? .risky
            return .act(CommandAction(appleScript: script, summary: summary, risk: risk))
        }
        let text = content
            .compactMap { ($0["type"] as? String) == "text" ? ($0["text"] as? String) : nil }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .nothing : .answer(text)
    }
}
