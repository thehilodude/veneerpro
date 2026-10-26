import AppKit
import UniformTypeIdentifiers

/// A saved CMF variant of one model: every material's graph and texture mapping.
struct Colorway: Identifiable {
    struct Look: Equatable {
        var graph: MaterialGraph.Snapshot
        var mapping: TextureMapping
    }

    var id = UUID()
    var name: String
    /// Keyed by `MaterialEntry.id`. Materials added after saving aren't included and keep their look.
    var looks: [UUID: Look]
    /// Base-color swatches in material order, for the colorway list.
    var swatches: [CGImage]
}

extension ModelDocument {
    /// Every material's current look.
    var currentLooks: [UUID: Colorway.Look] {
        Dictionary(uniqueKeysWithValues: materials.map { ($0.id, Colorway.Look(graph: $0.graph.snapshot, mapping: $0.mapping)) })
    }

    var activeColorway: Colorway? { colorways.first { $0.id == activeColorwayID } }

    /// True when the materials have been edited since the active colorway was applied or saved.
    var colorwayIsModified: Bool {
        guard let active = activeColorway else { return false }
        return materials.contains { entry in
            active.looks[entry.id].map { $0 != Colorway.Look(graph: entry.graph.snapshot, mapping: entry.mapping) } ?? false
        }
    }

    /// Puts `looks` on the materials (no undo steps of their own).
    @MainActor
    func applyLooks(_ looks: [UUID: Colorway.Look]) {
        for entry in materials {
            if let look = looks[entry.id] { entry.applyLook(look) }
        }
    }

    /// The colorways re-keyed for a duplicate whose materials map old → new IDs.
    func colorways(remapping ids: [UUID: UUID]) -> [Colorway] {
        colorways.map { colorway in
            var copy = colorway
            copy.looks = Dictionary(uniqueKeysWithValues: colorway.looks.compactMap { key, look in ids[key].map { ($0, look) } })
            return copy
        }
    }

    fileprivate var currentSwatches: [CGImage] { materials.compactMap(\.swatch) }
}

extension AppModel {
    // MARK: Colorways

    /// Saves the selected model's current materials as a new colorway and makes it the active one.
    func saveColorway() {
        guard let document = selectedDocument else { return }
        EditHistory.shared.flush()
        var n = document.colorways.count + 1
        while document.colorways.contains(where: { $0.name == "Colorway \(n)" }) { n += 1 }
        let colorway = Colorway(name: "Colorway \(n)", looks: document.currentLooks, swatches: document.currentSwatches)
        let previousActive = document.activeColorwayID
        noteProjectEdit()
        document.colorways.append(colorway)
        document.activeColorwayID = colorway.id
        EditHistory.shared.record("Save “\(colorway.name)”",
                                  undo: { [weak document] in
                                      document?.colorways.removeAll { $0.id == colorway.id }
                                      document?.activeColorwayID = previousActive
                                  },
                                  redo: { [weak document] in
                                      document?.colorways.append(colorway)
                                      document?.activeColorwayID = colorway.id
                                  })
    }

    /// Switches `document`'s materials to `colorway`, as one undo step.
    func applyColorway(_ colorway: Colorway, in document: ModelDocument? = nil) {
        guard let document = document ?? selectedDocument else { return }
        EditHistory.shared.flush()
        let before = document.currentLooks, previousActive = document.activeColorwayID
        document.applyLooks(colorway.looks)
        document.activeColorwayID = colorway.id
        EditHistory.shared.record("Apply “\(colorway.name)”",
                                  undo: { [weak document] in
                                      document?.applyLooks(before)
                                      document?.activeColorwayID = previousActive
                                  },
                                  redo: { [weak document] in
                                      document?.applyLooks(colorway.looks)
                                      document?.activeColorwayID = colorway.id
                                  })
    }

    /// Overwrites `colorway` with the current materials.
    func updateColorway(_ colorway: Colorway) {
        guard let document = selectedDocument, let i = document.colorways.firstIndex(where: { $0.id == colorway.id }) else { return }
        EditHistory.shared.flush()
        let old = document.colorways[i]
        var updated = old
        updated.looks = document.currentLooks
        updated.swatches = document.currentSwatches
        document.colorways[i] = updated
        document.activeColorwayID = colorway.id
        noteProjectEdit()
        EditHistory.shared.record("Update “\(colorway.name)”",
                                  undo: { [weak document] in document?.replaceColorway(old) },
                                  redo: { [weak document] in document?.replaceColorway(updated) })
    }

    func renameColorway(_ colorway: Colorway, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let document = selectedDocument,
              let i = document.colorways.firstIndex(where: { $0.id == colorway.id }) else { return }
        document.colorways[i].name = name
        noteProjectEdit()
    }

    func duplicateColorway(_ colorway: Colorway) {
        guard let document = selectedDocument, let i = document.colorways.firstIndex(where: { $0.id == colorway.id }) else { return }
        var copy = colorway
        copy.id = UUID()
        copy.name = colorway.name + " Copy"
        document.colorways.insert(copy, at: i + 1)
        noteProjectEdit()
    }

    func deleteColorway(_ colorway: Colorway) {
        guard let document = selectedDocument, let i = document.colorways.firstIndex(where: { $0.id == colorway.id }) else { return }
        let wasActive = document.activeColorwayID == colorway.id
        document.colorways.remove(at: i)
        noteProjectEdit()
        if wasActive { document.activeColorwayID = nil }
        EditHistory.shared.record("Delete “\(colorway.name)”",
                                  undo: { [weak document] in
                                      document?.colorways.insert(colorway, at: min(i, document?.colorways.count ?? 0))
                                      if wasActive { document?.activeColorwayID = colorway.id }
                                  },
                                  redo: { [weak document] in
                                      document?.colorways.removeAll { $0.id == colorway.id }
                                      if wasActive { document?.activeColorwayID = nil }
                                  })
    }

    /// Shows a copy of the selected model wearing `colorway` beside it.
    func compareColorway(_ colorway: Colorway) {
        guard let document = selectedDocument else { return }
        compareWithCopy(named: "\(document.name) – \(colorway.name)")
        guard let copy = comparison.flatMap({ pair in documents.first { $0.id == pair[1] } }),
              let copied = copy.colorways.first(where: { $0.name == colorway.name }) else { return }
        copy.applyLooks(copied.looks)
        copy.activeColorwayID = copied.id
    }

    /// Exports one file per colorway of the selected model into a folder, then restores its materials.
    func presentExportColorwaysPanel() {
        guard let document = selectedDocument, !document.colorways.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Colorways"
        panel.message = "Each colorway of “\(document.name)” is exported as its own USDZ."
        panel.directoryURL = document.sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            isBusy = true
            suppressChangeTracking = true
            defer { isBusy = false; status = nil; suppressChangeTracking = false }
            EditHistory.shared.flush()
            let current = document.currentLooks, active = document.activeColorwayID
            defer {
                document.applyLooks(current)
                document.applyMappingsNow()
                document.activeColorwayID = active
            }
            for colorway in document.colorways {
                status = "Exporting “\(colorway.name)”"
                document.applyLooks(colorway.looks)
                document.applyMappingsNow()
                let name = "\(document.name) – \(colorway.name)".replacingOccurrences(of: "/", with: "-")
                do {
                    var options = exportOptions
                    options.colorwayVariants = false   // each file is one colorway
                    _ = try await Exporter.export(document, to: folder.appendingPathComponent(name + ".usdz"), options: options)
                } catch {
                    errorMessage = "\(colorway.name): \(error.localizedDescription)"
                    return
                }
            }
        }
    }
}

private extension ModelDocument {
    func replaceColorway(_ colorway: Colorway) {
        if let i = colorways.firstIndex(where: { $0.id == colorway.id }) { colorways[i] = colorway }
    }
}
