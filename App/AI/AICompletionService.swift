import Foundation

/// Routes inline completion requests from the editor to the model picked in Settings → AI.
/// Only one request runs at a time; a new one (or more typing) cancels the last.
final class AICompletionService {
    static let shared = AICompletionService()

    private var engine: LlamaCompletionEngine?
    private var currentCancel: CompletionCancel?
    private var appleTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.selectionMayHaveChanged()
        }
        NotificationCenter.default.addObserver(forName: ModelDownloadManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.selectionMayHaveChanged()
        }
    }

    /// The AI Suggestions model can be asked right now.
    var isReady: Bool { isReady(AppSettings.shared.aiModel) }

    /// The model picked for merge conflicts can be asked right now.
    var isMergeReady: Bool { isReady(AppSettings.shared.effectiveMergeModel) }

    func isReady(_ choice: AIModelChoice) -> Bool {
        switch choice {
        case .off:
            return false
        case .appleIntelligence:
            return AppleIntelligenceEngine.unavailableReason == nil
        default:
            // Suggestions and merges fill in the middle, which only code models do.
            guard let model = AIModelCatalog.model(for: choice), model.completes else { return false }
            return model.isSupported && model.isDownloaded
        }
    }

    /// Call once at launch so a local model starts loading before the first keystroke.
    func start() {
        selectionMayHaveChanged()
    }

    /// Frees the local model (memory warning, or a game needs the memory). It reloads on the next request.
    func unload() {
        cancel()
        cancelResolve()
        mergeEngine = nil
        engine = nil
    }

    private func selectionMayHaveChanged() {
        let choice = AppSettings.shared.aiModel
        if engine?.model.choice != choice || !isReady {
            cancel()
            engine = nil
        }
        if mergeEngine?.model.choice != AppSettings.shared.effectiveMergeModel { mergeEngine = nil }
        // While a merge runs on a different model, or a chat model is loaded, the suggestions model stays unloaded.
        if engine == nil, mergeEngine == nil, !AIChatService.shared.hasEngine, let engine = localEngine() {
            engine.preload()
        }
    }

    /// The engine for the selected local model, created (not yet loaded) on first use.
    private func localEngine() -> LlamaCompletionEngine? {
        if engine == nil, isReady, let model = AIModelCatalog.model(for: AppSettings.shared.aiModel) {
            engine = LlamaCompletionEngine(model: model)
        }
        return engine
    }

    func cancel() {
        currentCancel?.cancel()
        currentCancel = nil
        appleTask?.cancel()
        appleTask = nil
    }

    /// Calls back on the main queue with the text to insert, or nil for no suggestion.
    func complete(prefix: String, suffix: String, path: String, completion: @escaping (String?) -> Void) {
        cancel()
        // No suggestions while a merge has a different model loaded.
        guard isReady, mergeEngine == nil else { return completion(nil) }
        // One local model in memory at a time: a chat model that isn't answering makes way.
        if AppSettings.shared.aiModel.isLocal {
            guard !AIChatService.shared.isBusy else { return completion(nil) }
            AIChatService.shared.releaseIdleEngine()
        }

        let cancel = CompletionCancel()
        currentCancel = cancel
        let lineBefore = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        // Mid-line: finish the line. On an empty line: a few lines (a loop body, a function).
        let singleLine = !lineBefore.trimmingCharacters(in: .whitespaces).isEmpty
        let maxLines = singleLine ? 1 : 6
        let finish: (String?) -> Void = { text in
            DispatchQueue.main.async {
                guard !cancel.isCancelled else { return completion(nil) }
                completion(text.flatMap { Self.clean($0, lineBefore: lineBefore, suffix: suffix, maxLines: maxLines) })
            }
        }

        switch AppSettings.shared.aiModel {
        case .off:
            completion(nil)
        case .appleIntelligence:
            appleTask = Task {
                let text = try? await AppleIntelligenceEngine.complete(prefix: prefix, suffix: suffix, path: path,
                                                                     maxTokens: singleLine ? 48 : 160)
                finish(text)
            }
        default:
            guard let engine = localEngine() else { return completion(nil) }
            engine.complete(prefix: prefix, suffix: suffix, maxTokens: singleLine ? 48 : 128, maxLines: maxLines,
                            cancel: cancel) { result in
                finish(try? result.get())
            }
        }
    }

    // MARK: - Merge conflicts

    // Kept apart from completions, so the editor cancelling a ghost suggestion doesn't stop a merge.
    private var resolveCancel: CompletionCancel?
    private var resolveTask: Task<Void, Never>?
    /// The merge model, when it's a different local model from the suggestions one.
    private var mergeEngine: LlamaCompletionEngine?

    /// The engine for merging with `choice`: the suggestions engine if it's the same model, otherwise
    /// its own, with the suggestions model unloaded first so two models never fill memory at once.
    private func engineForMerge(_ choice: AIModelChoice) -> LlamaCompletionEngine? {
        if choice == AppSettings.shared.aiModel { return localEngine() }
        guard isReady(choice), let model = AIModelCatalog.model(for: choice) else { return nil }
        if mergeEngine?.model.choice != choice { mergeEngine = LlamaCompletionEngine(model: model) }
        cancel()
        engine = nil
        return mergeEngine
    }

    /// The review is over: stop, free a separate merge model and bring the suggestions model back.
    func endResolveSession() {
        cancelResolve()
        guard mergeEngine != nil else { return }
        mergeEngine = nil
        selectionMayHaveChanged()
    }

    func cancelResolve() {
        resolveCancel?.cancel()
        resolveCancel = nil
        resolveTask?.cancel()
        resolveTask = nil
    }

    /// Asks the selected model to merge one conflict. Calls back on the main queue with the
    /// replacement code, or nil when there's no model or no usable answer.
    func resolveConflict(_ request: ConflictRequest, completion: @escaping (String?) -> Void) {
        cancelResolve()
        let choice = AppSettings.shared.effectiveMergeModel
        guard isReady(choice) else { return completion(nil) }
        let cancel = CompletionCancel()
        resolveCancel = cancel
        let finish: (String?) -> Void = { text in
            DispatchQueue.main.async {
                guard !cancel.isCancelled else { return completion(nil) }
                completion(text.flatMap { ConflictResolver.clean($0, for: request) })
            }
        }
        let maxTokens = ConflictResolver.maxTokens(request)

        switch choice {
        case .off:
            completion(nil)
        case .appleIntelligence:
            resolveTask = Task {
                finish(try? await AppleIntelligenceEngine.resolve(request, maxTokens: maxTokens))
            }
        default:
            guard let engine = engineForMerge(choice) else { return completion(nil) }
            let prompt = ConflictResolver.fillInPrompt(request)
            engine.complete(prefix: prompt.prefix, suffix: prompt.suffix, maxTokens: maxTokens, maxLines: 400,
                            cancel: cancel) { result in
                finish(try? result.get())
            }
        }
    }

    /// Trims a model's answer to what should actually be inserted.
    static func clean(_ raw: String, lineBefore: String, suffix: String, maxLines: Int) -> String? {
        // Chat models sometimes wrap code in fences anyway.
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if maxLines == 1 {
            // A suggestion that starts with a newline means the line is already complete.
            lines = [lines.first ?? ""]
        } else {
            lines = Array(lines.prefix(maxLines))
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        }
        var text = lines.joined(separator: "\n")

        // A model that repeats the start of the current line: drop the repeat.
        let typed = lineBefore.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, text.trimmingCharacters(in: .whitespaces).hasPrefix(typed) {
            text = String(text.trimmingCharacters(in: .whitespaces).dropFirst(typed.count))
        }

        // Don't duplicate what's already after the cursor on this line, e.g. a closing ")".
        let rest = suffix.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
        if !restTrimmed.isEmpty {
            for k in stride(from: min(restTrimmed.count, text.count), through: 1, by: -1) where text.hasSuffix(String(restTrimmed.prefix(k))) {
                text = String(text.dropLast(k))
                break
            }
        }

        let trimmedRight = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmedRight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmedRight
    }
}
