import RealityKit
import UIKit
import simd

/// Builds RealityKit entities for a `ShapeNode` with the glowing blue hologram
/// look. Centralized so the editor view and the camera-control path stay in sync.
enum ShapeFactory {
    static func mesh(for kind: ShapeKind) -> MeshResource {
        switch kind {
        case .box:      return .generateBox(size: 1.0, cornerRadius: 0.04)
        case .sphere:   return .generateSphere(radius: 0.6)
        case .cylinder: return .generateCylinder(height: 1.0, radius: 0.5)
        case .cone:     return .generateCone(height: 1.0, radius: 0.5)
        case .pyramid:  return .generateCone(height: 1.0, radius: 0.6)   // 4-side cone approximation
        case .torus:    return .generateSphere(radius: 0.5)              // torus unavailable pre-visionOS; sphere stand-in
        case .plane:    return .generatePlane(width: 1.2, depth: 1.2, cornerRadius: 0.05)
        }
    }

    /// Translucent, glowing "hologram" material. `UnlitMaterial` reads as
    /// projected light (no shading) and supports per-channel alpha for the
    /// see-through hologram look — and compiles across RealityKit versions.
    /// `saturation` lets shapes be any colour (0 = white) while keeping the glow.
    static func material(hue: Float, saturation: Float = 0.7) -> RealityKit.Material {
        let color = UIColor(hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: 1.0, alpha: 0.6)
        return UnlitMaterial(color: color)
    }

    /// Euler (radians) → quaternion orientation, applied yaw·pitch·roll.
    static func orientation(_ euler: SIMD3<Float>) -> simd_quatf {
        let qx = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return qy * qx * qz
    }

    /// Creates a positioned, scaled, rotated entity for a node, tagging it with
    /// the node id.
    static func entity(for node: ShapeNode) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh(for: node.kind),
                                 materials: [material(hue: node.hue, saturation: node.saturation)])
        entity.name = node.id.uuidString
        entity.position = node.position
        entity.scale = node.scale
        entity.orientation = orientation(node.rotation)
        entity.generateCollisionShapes(recursive: false)
        return entity
    }
}
