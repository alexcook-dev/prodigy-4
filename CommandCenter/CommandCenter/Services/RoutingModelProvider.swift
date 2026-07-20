import Foundation

// MARK: - RoutingModelProvider

/// Routes each turn to Claude Code CLI or Grok CLI based on the request model id.
///
/// Shared app-wide so LRU / teardown stay consistent across both backends.
final class RoutingModelProvider: ModelProvider, @unchecked Sendable {
    let claude: ClaudeCLIProvider
    let grok: GrokCLIProvider

    init(
        claude: ClaudeCLIProvider = .shared,
        grok: GrokCLIProvider = .shared
    ) {
        self.claude = claude
        self.grok = grok
    }

    static let shared = RoutingModelProvider()

    func streamTurn(_ request: ModelTurnRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        provider(for: request.model).streamTurn(request)
    }

    func cancelTurn(projectID: UUID) {
        claude.cancelTurn(projectID: projectID)
        grok.cancelTurn(projectID: projectID)
    }

    func setFocusedProject(_ projectID: UUID?) {
        claude.setFocusedProject(projectID)
        grok.setFocusedProject(projectID)
    }

    func teardown(projectID: UUID) {
        claude.teardown(projectID: projectID)
        grok.teardown(projectID: projectID)
    }

    func teardownAll() {
        claude.teardownAll()
        grok.teardownAll()
    }

    /// Model ids that start with `grok` go to Grok; everything else → Claude.
    private func provider(for model: String?) -> ModelProvider {
        let key = (model ?? "").lowercased()
        if key.hasPrefix("grok") {
            return grok
        }
        return claude
    }
}
