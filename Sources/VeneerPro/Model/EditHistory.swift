import Foundation
import Observation

/// App-wide undo/redo. Each step holds closures that undo and redo one user action.
///
/// Continuous edits (slider drags, node drags, typing) arrive as many small changes; callers group
/// them with `beginGroup`, which keeps one step open until the edits pause, so ⌘Z undoes the whole
/// gesture rather than one tick of it.
@MainActor
@Observable
final class EditHistory {
    static let shared = EditHistory()
    struct Step {
        let name: String
        let undo: () -> Void
        let redo: () -> Void
    }

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    /// True while a step is being undone or redone; edits made then aren't recorded.
    private(set) var isReplaying = false

    /// Open coalescing groups, keyed by what they edit; each closes into one step.
    @ObservationIgnored private var openGroups: [AnyHashable: OpenGroup] = [:]
    private static let groupPause: Duration = .milliseconds(600)
    private static let limit = 200

    private struct OpenGroup {
        var close: () -> Step?
        var timer: Task<Void, Never>
    }

    var canUndo: Bool { !undoStack.isEmpty || !openGroups.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty && openGroups.isEmpty }
    var undoName: String? { openGroups.isEmpty ? undoStack.last?.name : "Edit" }
    var redoName: String? { redoStack.last?.name }

    /// Records a finished action.
    func record(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard !isReplaying else { return }
        undoStack.append(Step(name: name, undo: undo, redo: redo))
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }

    /// Starts (or extends) a coalesced step for `key`. `close` is called once the edits pause and
    /// returns the finished step (or nil if nothing really changed).
    func beginGroup(_ key: AnyHashable, close: @escaping () -> Step?) {
        guard !isReplaying else { return }
        if var group = openGroups[key] {
            group.timer.cancel()
            group.timer = makeTimer(key)
            openGroups[key] = group
        } else {
            openGroups[key] = OpenGroup(close: close, timer: makeTimer(key))
            redoStack.removeAll()
        }
    }

    private func makeTimer(_ key: AnyHashable) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: Self.groupPause)
            guard !Task.isCancelled else { return }
            self?.closeGroup(key)
        }
    }

    private func closeGroup(_ key: AnyHashable) {
        guard let group = openGroups.removeValue(forKey: key) else { return }
        group.timer.cancel()
        if let step = group.close() {
            undoStack.append(step)
            if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        }
    }

    /// Finishes any in-progress edits so they become undoable steps.
    func flush() {
        for key in Array(openGroups.keys) { closeGroup(key) }
    }

    func undo() {
        flush()
        guard let step = undoStack.popLast() else { return }
        replay { step.undo() }
        redoStack.append(step)
    }

    func redo() {
        flush()
        guard let step = redoStack.popLast() else { return }
        replay { step.redo() }
        undoStack.append(step)
    }

    private func replay(_ body: () -> Void) {
        isReplaying = true
        body()
        isReplaying = false
    }

    func clear() {
        for group in openGroups.values { group.timer.cancel() }
        openGroups.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
