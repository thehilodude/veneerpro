import AppKit
import SceneKit
import simd

/// Pushes an evaluated graph onto a SceneKit material for the live viewport preview.
enum MaterialApplier {
    /// Applies to the first material, then shares the same contents with the rest.
    static func apply(_ result: MaterialResult, to materials: [SCNMaterial], evaluator: GraphEvaluator) {
        guard let first = materials.first else { return }
        apply(result, to: first, evaluator: evaluator)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for other in materials.dropFirst() {
            other.lightingModel = first.lightingModel
            for (from, to) in zip(properties(first), properties(other)) {
                to.contents = from.contents
                to.textureComponents = from.textureComponents
                to.wrapS = from.wrapS
                to.wrapT = from.wrapT
                to.intensity = from.intensity
            }
            other.transparency = first.transparency
            other.transparencyMode = first.transparencyMode
            other.blendMode = first.blendMode
        }
        SCNTransaction.commit()
    }

    private static func properties(_ m: SCNMaterial) -> [SCNMaterialProperty] {
        [m.diffuse, m.metalness, m.roughness, m.normal, m.emission, m.transparent,
         m.ambientOcclusion, m.clearCoat, m.clearCoatRoughness]
    }

    static func apply(_ result: MaterialResult, to material: SCNMaterial, evaluator: GraphEvaluator) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }

        material.lightingModel = .physicallyBased
        set(material.diffuse, result[.baseColor], color: true, evaluator)
        set(material.metalness, result[.metallic], color: false, evaluator)
        set(material.roughness, result[.roughness], color: false, evaluator)
        set(material.emission, result[.emissive], color: true, evaluator)
        set(material.clearCoat, result[.clearcoat], color: false, evaluator)
        set(material.clearCoatRoughness, result[.clearcoatRoughness], color: false, evaluator)

        if result.isConnected(.normal) {
            set(material.normal, result[.normal], color: false, evaluator)
        } else {
            material.normal.contents = nil
        }
        if result.isConnected(.occlusion) {
            set(material.ambientOcclusion, result[.occlusion], color: false, evaluator)
        } else {
            material.ambientOcclusion.contents = nil
        }

        // Opacity: SceneKit reads it from the alpha channel of `transparent`.
        switch result[.opacity] {
        case let .constant(c):
            // Carried in the alpha: SceneKit ignores `transparency` on physically based materials.
            material.transparent.contents = NSColor(white: 1, alpha: CGFloat(simd_clamp(c.x, 0, 1)))
            material.transparency = 1
        case let .image(bitmap, _):
            material.transparent.contents = bitmap.map { SIMD4(1, 1, 1, $0.x) }.cgImage(alpha: .straight)
            material.transparency = 1
        }
        material.transparencyMode = .aOne
        material.blendMode = .alpha
    }

    private static func set(_ property: SCNMaterialProperty, _ value: GraphValue, color: Bool, _ evaluator: GraphEvaluator) {
        property.textureComponents = .all
        property.wrapS = .repeat
        property.wrapT = .repeat
        property.intensity = 1
        switch value {
        case let .constant(c):
            if color {
                property.contents = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            } else {
                property.contents = NSNumber(value: c.x)
            }
        case .image:
            property.contents = evaluator.render(value, linear: !color)
        }
    }
}
