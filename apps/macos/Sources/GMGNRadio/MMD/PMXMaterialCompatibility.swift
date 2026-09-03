import AppKit
import MMDSceneKit
@preconcurrency import SceneKit

enum PMXMaterialCompatibility {
    static func prepareForCurrentSceneKit(in root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            // MMDSceneKit creates additive PMX targets without the complete
            // backing descriptors required by current SceneKit. Some models
            // reach SCNMTLMorphDeformer and dereference a missing target array
            // on their first rendered frame. Keep body animation available,
            // but disable this unsafe facial-morph path for every PMX model.
            node.morpher = nil
            prepare(node.geometry)
        }
        root.morpher = nil
        if let mmdRoot = root as? MMDNode {
            mmdRoot.geometryMorpher = nil
        }
        prepare(root.geometry)
    }

    private static func prepare(_ geometry: SCNGeometry?) {
        guard let geometry else { return }
        for material in geometry.materials {
            let authoredTint = material.diffuse.contents as? NSColor
                ?? NSColor.white
            if let texture = material.multiply.contents as? NSImage {
                material.diffuse.contents = texture
                material.multiply.contents = authoredTint
            } else {
                material.multiply.contents = NSColor.white
            }
            // MMDSceneKit stores its toon ramp in `transparent`. Once the
            // legacy shader is removed SceneKit interprets that ramp as a
            // real opacity mask, which can hide the complete material.
            material.transparent.contents = nil
            material.shaderModifiers = nil
            // PMX base colours and textures were authored for the MMD toon
            // lighting equation. SceneKit PBR lifts the dark cloth values and
            // makes the model look grey. Blinn keeps the authored albedo/tint
            // while still accepting the stage lights.
            material.lightingModel = .blinn
            material.diffuse.intensity = 1
            material.ambient.contents = NSColor.black
            // Some PMX exporters bake a constant grey emission into every
            // material for their custom toon shader. SceneKit treats it as
            // real self-illumination, washing out textures under every light.
            material.emission.contents = NSColor.black
            material.emission.intensity = 0
            material.specular.contents = NSColor(
                calibratedWhite: 0.18,
                alpha: 1
            )
            material.specular.intensity = 0.18
            material.shininess = min(material.shininess, 0.22)
            material.transparency = 1
            material.transparencyMode = .aOne
            material.blendMode = .alpha
            material.isDoubleSided = true
            material.writesToDepthBuffer = true
        }
    }

    static func isRaw2BModel(_ root: SCNNode) -> Bool {
        let standardMMDBones = [
            "センター",
            "上半身",
            "左腕",
            "右腕",
            "左足",
            "右足",
        ]
        let standardBoneCount = standardMMDBones.reduce(into: 0) { count, name in
            if root.childNode(withName: name, recursively: true) != nil {
                count += 1
            }
        }
        guard standardBoneCount < standardMMDBones.count else {
            return false
        }
        return root.childNode(
            withName: "bone4094",
            recursively: true
        ) != nil
    }
}
