import Foundation

/// What the app should actually do with the agent's decision, after applying the
/// "auto-run safe, confirm risky" policy.
enum ResolvedCommand: Equatable {
    case run(CommandAction)      // safe — execute immediately
    case confirm(CommandAction)  // risky — ask first
    case answer(String)          // a spoken answer, no action
    case nothing                 // couldn't help
}

enum CommandModeService {
    static func resolve(_ decision: CommandDecision) -> ResolvedCommand {
        switch decision {
        case .answer(let text):
            return .answer(text)
        case .nothing:
            return .nothing
        case .act(let action):
            let risk = CommandRisk.resolve(modelRisk: action.risk, script: action.appleScript)
            let resolved = CommandAction(appleScript: action.appleScript, summary: action.summary, risk: risk)
            return risk == .safe ? .run(resolved) : .confirm(resolved)
        }
    }
}
