import AppKit
import SceneKit
import SwiftUI

/// The viewer bar's scene menu: setting, toggles and placement.
struct ScaleSceneMenu: View {
    @Binding var scene: ScaleScene

    var body: some View {
        Menu {
            Picker("Scene", selection: $scene.kind) {
                ForEach(ScaleScene.Kind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            if scene.kind != .none {
                ScaleSceneToggles(scene: $scene)
            }
        } label: {
            Image(systemName: scene.kind == .none ? "square.split.bottomrightquarter" : scene.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(scene.kind == .none ? Color.primary : Color.accentColor)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("True-scale scene: place the model on a desk or in a bedroom")
    }
}

/// Toggles shared by the menu and the inspector.
struct ScaleSceneToggles: View {
    @Binding var scene: ScaleScene

    var body: some View {
        if scene.kind == .desk {
            Toggle("Props (monitor, laptop, phone, mug)", isOn: $scene.props)
        }
        if scene.kind == .bedroom {
            Toggle("Bed & Nightstands", isOn: $scene.furniture)
        }
        Toggle("Person (175 cm)", isOn: $scene.person)
        if scene.surfaces.count > 1 {
            Picker("Place On", selection: Binding(get: { scene.effectiveSurface ?? .floor }, set: { scene.surface = $0 })) {
                ForEach(scene.surfaces) { Text($0.rawValue).tag($0) }
            }
        }
    }
}

/// The model's (or selected object's) real-world size, with a nudge when the units look wrong.
struct SizeReadout: View {
    let document: ModelDocument
    let node: SCNNode?
    var onCheckUnits: () -> Void
    @AppStorage("SizeReadoutInches") private var inches = false

    var body: some View {
        // Re-measure when objects move, hide or change, and when units change.
        let _ = document.sceneRevision
        let _ = document.metadata.metersPerUnit
        if let size = document.size(of: node) {
            let longest = size.max()
            let suspicious = longest > 25 || longest < 0.003
            HStack(spacing: 8) {
                if let node, node !== document.root {
                    Text(node.name?.isEmpty == false ? node.name! : "Selection")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120)
                }
                dimension("W", size.x)
                dimension("D", size.z)
                dimension("H", size.y)
                Text(inches ? "in" : "cm").foregroundStyle(.secondary)
                if suspicious {
                    Button {
                        onCheckUnits()
                    } label: {
                        Label("Check units", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("This size looks unlikely for a real object. Set the model's base units in the Properties tab.")
                }
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
            .contentShape(Capsule())
            .onTapGesture { inches.toggle() }
            .help("Real-world size (click to switch cm / inches)")
        }
    }

    private func dimension(_ axis: String, _ meters: Float) -> some View {
        let value = inches ? Double(meters) / 0.0254 : Double(meters) * 100
        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return HStack(spacing: 3) {
            Text(axis).foregroundStyle(.tertiary)
            Text(text)
        }
    }
}
