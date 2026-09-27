import AppKit
import SceneKit

/// Explicitly authored support, separate from the generated Marble environment.
struct ResidentPropDisplayStand: Equatable, Sendable {
    let worldID: String
    let objectID: String
    let position: SIMD3<Float>
    let size: SIMD3<Float>
}

enum ResidentPropScene {
    @MainActor static func makeDisplayStand(_ descriptor: ResidentPropDisplayStand) -> SCNNode {
        let root=SCNNode()
        root.name=descriptor.objectID;root.simdPosition=descriptor.position
        let material=SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents=NSColor(calibratedWhite:0.48,alpha:1)
        material.metalness.contents=0.35;material.roughness.contents=0.55
        func box(size: SIMD3<Float>, at: SIMD3<Float>, name:String) {
            let shape=SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:0.008)
            shape.materials=[material]
            let node=SCNNode(geometry:shape);node.name=name;node.simdPosition=at;root.addChildNode(node)
        }
        let s=descriptor.size,thickness=min(Float(0.06),s.y/4)
        box(size:SIMD3(s.x,thickness,s.z),at:SIMD3(0,s.y-thickness/2,0),name:"display_stand.top")
        box(size:SIMD3(s.x*0.74,s.y-thickness,s.z*0.70),at:SIMD3(0,(s.y-thickness)/2,0),name:"display_stand.base")
        return root
    }
}
