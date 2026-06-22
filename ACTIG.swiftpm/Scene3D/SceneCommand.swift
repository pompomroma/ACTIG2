import Foundation
import simd

/// The kinds of primitive a user can "call" into the 3D space.
enum ShapeKind: String, CaseIterable, Codable {
    case box, sphere, cylinder, cone, pyramid, torus, plane

    /// Map loose natural language to a kind ("cube" -> box, "ball" -> sphere…).
    static func detect(in text: String) -> ShapeKind? {
        let map: [String: ShapeKind] = [
            "cube": .box, "box": .box, "block": .box, "brick": .box, "crate": .box,
            "sphere": .sphere, "ball": .sphere, "orb": .sphere, "globe": .sphere,
            "cylinder": .cylinder, "tube": .cylinder, "can": .cylinder, "pillar": .cylinder, "pipe": .cylinder,
            "cone": .cone,
            "pyramid": .pyramid,
            "torus": .torus, "donut": .torus, "doughnut": .torus, "ring": .torus,
            "plane": .plane, "floor": .plane, "panel": .plane, "slab": .plane, "sheet": .plane
        ]
        for (k, v) in map where text.contains(k) { return v }
        return nil
    }
}

/// A serializable shape instance in the scene.
///
/// `scale` is per-axis (SIMD3) so the model can make slabs, thin legs, tall
/// towers etc. — essential for detailed modelling. `rotation` is euler radians.
/// Older saved scenes stored `scale` as a single `Float` and had no
/// `rotation`/`saturation`; the custom decoder below keeps them loading.
struct ShapeNode: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ShapeKind
    var position: SIMD3<Float>
    var scale: SIMD3<Float>
    var hue: Float          // 0...1 around the hologram palette
    var saturation: Float   // 0 = white, ~0.7 = vivid hologram blue
    var rotation: SIMD3<Float>   // euler radians (pitch, yaw, roll)

    init(id: UUID = UUID(),
         kind: ShapeKind,
         position: SIMD3<Float>,
         scale: SIMD3<Float> = SIMD3<Float>(repeating: 0.12),
         hue: Float = 0.55,
         saturation: Float = 0.7,
         rotation: SIMD3<Float> = .zero) {
        self.id = id
        self.kind = kind
        self.position = position
        self.scale = scale
        self.hue = hue
        self.saturation = saturation
        self.rotation = rotation
    }

    /// Convenience for a uniform scale.
    init(id: UUID = UUID(),
         kind: ShapeKind,
         position: SIMD3<Float>,
         uniformScale: Float,
         hue: Float = 0.55,
         saturation: Float = 0.7,
         rotation: SIMD3<Float> = .zero) {
        self.init(id: id, kind: kind, position: position,
                  scale: SIMD3<Float>(repeating: uniformScale),
                  hue: hue, saturation: saturation, rotation: rotation)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, position, scale, hue, saturation, rotation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ShapeKind.self, forKey: .kind)
        position = try c.decode(SIMD3<Float>.self, forKey: .position)
        // Back-compat: `scale` used to be a single Float.
        if let s = try? c.decode(SIMD3<Float>.self, forKey: .scale) {
            scale = s
        } else if let f = try? c.decode(Float.self, forKey: .scale) {
            scale = SIMD3<Float>(repeating: f)
        } else {
            scale = SIMD3<Float>(repeating: 0.12)
        }
        hue = try c.decode(Float.self, forKey: .hue)
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? 0.7
        rotation = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .rotation) ?? .zero
    }
}

/// A reversible edit. Each command knows how to apply and revert itself, which
/// is what powers automatic undo/redo and the "bring back previous actions"
/// requirement. Commands are recorded by `SceneStore` onto an undo/redo stack.
///
/// `.group` bundles several edits into one history step, so a whole modelled
/// object (e.g. a snowman) is built — and undone — in a single action.
enum SceneCommand: Equatable {
    case add(ShapeNode)
    case remove(ShapeNode)
    case move(id: UUID, from: SIMD3<Float>, to: SIMD3<Float>)
    case scale(id: UUID, from: SIMD3<Float>, to: SIMD3<Float>)
    case rotate(id: UUID, from: SIMD3<Float>, to: SIMD3<Float>)
    case recolor(id: UUID, fromHue: Float, fromSat: Float, toHue: Float, toSat: Float)
    case swap(a: UUID, b: UUID, posA: SIMD3<Float>, posB: SIMD3<Float>)
    indirect case group([SceneCommand])

    /// The inverse command used when undoing.
    var inverse: SceneCommand {
        switch self {
        case .add(let n): return .remove(n)
        case .remove(let n): return .add(n)
        case .move(let id, let from, let to): return .move(id: id, from: to, to: from)
        case .scale(let id, let from, let to): return .scale(id: id, from: to, to: from)
        case .rotate(let id, let from, let to): return .rotate(id: id, from: to, to: from)
        case .recolor(let id, let fh, let fs, let th, let ts):
            return .recolor(id: id, fromHue: th, fromSat: ts, toHue: fh, toSat: fs)
        case .swap(let a, let b, let pa, let pb): return .swap(a: a, b: b, posA: pb, posB: pa)
        case .group(let cmds): return .group(cmds.reversed().map { $0.inverse })
        }
    }
}
