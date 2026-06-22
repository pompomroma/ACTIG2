import Foundation
import simd

// MARK: - Colour palette

/// Named colours mapped to the (hue, saturation) pair used by `ShapeNode` and
/// `ShapeFactory.material`. Shared by the LLM plan parser and the deterministic
/// "make it red" recolour path so colours stay consistent.
enum ColorPalette {
    /// hue 0...1, saturation 0...1 (0 = white).
    static let map: [String: (hue: Float, sat: Float)] = [
        "red": (0.0, 0.85), "crimson": (0.98, 0.85), "scarlet": (0.01, 0.85),
        "orange": (0.07, 0.9), "amber": (0.11, 0.85),
        "yellow": (0.15, 0.9), "gold": (0.13, 0.85),
        "lime": (0.25, 0.85), "green": (0.33, 0.8), "emerald": (0.41, 0.8),
        "teal": (0.48, 0.7), "cyan": (0.52, 0.85), "turquoise": (0.5, 0.75),
        "blue": (0.6, 0.85), "azure": (0.57, 0.8), "navy": (0.66, 0.95),
        "indigo": (0.7, 0.85), "violet": (0.78, 0.8), "purple": (0.8, 0.8),
        "magenta": (0.85, 0.85), "pink": (0.92, 0.55), "rose": (0.95, 0.6),
        "white": (0.0, 0.0), "grey": (0.0, 0.0), "gray": (0.0, 0.0), "silver": (0.0, 0.05),
        "brown": (0.07, 0.7), "tan": (0.09, 0.5)
    ]

    /// First colour name found in `text`, if any.
    static func named(_ text: String) -> (hue: Float, sat: Float)? {
        for (name, c) in map where text.contains(name) { return c }
        return nil
    }
}

// MARK: - LLM scene plan

/// Structured build plan the on-device model emits as JSON, e.g.
/// `{"commands":[{"shape":"sphere","x":0,"y":0,"z":0,"scale":0.18,"color":"white"}, …]}`
struct ScenePlan: Codable {
    let commands: [PlanCommand]
}

/// One placed shape in a plan. Everything except `shape` is optional so partial
/// or loosely-formatted model output still decodes.
struct PlanCommand: Codable {
    var op: String?
    var shape: String?
    var x: Float?
    var y: Float?
    var z: Float?
    var scale: Float?           // uniform size
    var sx: Float?              // per-axis size overrides
    var sy: Float?
    var sz: Float?
    var color: String?
    var hue: Float?
    var sat: Float?
    var rx: Float?             // rotation in degrees
    var ry: Float?
    var rz: Float?
}

/// Turns raw model text into shape nodes, tolerating prose / code fences around
/// the JSON. Returns nil when no usable plan can be recovered.
enum ScenePlanParser {
    static func parse(_ text: String) -> [ShapeNode]? {
        guard let json = extractJSON(from: text),
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let plan = try? decoder.decode(ScenePlan.self, from: data) {
            return nodes(from: plan.commands)
        }
        if let arr = try? decoder.decode([PlanCommand].self, from: data) {
            return nodes(from: arr)
        }
        return nil
    }

    private static func nodes(from commands: [PlanCommand]) -> [ShapeNode]? {
        let nodes = commands.compactMap { node(from: $0) }
        return nodes.isEmpty ? nil : Array(nodes.prefix(80))
    }

    private static func node(from c: PlanCommand) -> ShapeNode? {
        // Only "add"-style ops contribute shapes; ignore anything else.
        if let op = c.op?.lowercased(), !op.isEmpty, op != "add", op != "shape" { return nil }
        guard let raw = c.shape?.lowercased(),
              let kind = ShapeKind(rawValue: raw) ?? ShapeKind.detect(in: raw) else { return nil }

        let pos = SIMD3<Float>(clampPos(c.x), clampPos(c.y), clampPos(c.z))
        let uni = c.scale.map(clampScale) ?? 0.12
        let scale = SIMD3<Float>(c.sx.map(clampScale) ?? uni,
                                 c.sy.map(clampScale) ?? uni,
                                 c.sz.map(clampScale) ?? uni)
        var hue: Float = 0.55
        var sat: Float = 0.7
        if let name = c.color?.lowercased(), let col = ColorPalette.named(name) { hue = col.hue; sat = col.sat }
        if let h = c.hue { hue = h.clamped01 }
        if let s = c.sat { sat = s.clamped01 }
        let rot = SIMD3<Float>(deg2rad(c.rx), deg2rad(c.ry), deg2rad(c.rz))
        return ShapeNode(kind: kind, position: pos, scale: scale, hue: hue, saturation: sat, rotation: rot)
    }

    private static func clampPos(_ v: Float?) -> Float { max(-0.6, min(0.6, v ?? 0)) }
    private static func clampScale(_ v: Float) -> Float { max(0.01, min(0.6, v)) }
    private static func deg2rad(_ d: Float?) -> Float { (d ?? 0) * .pi / 180 }

    /// Pull the first balanced `{…}` (preferred) or `[…]` block from the text.
    private static func extractJSON(from text: String) -> String? {
        balanced(in: text, open: "{", close: "}") ?? balanced(in: text, open: "[", close: "]")
    }

    private static func balanced(in text: String, open: Character, close: Character) -> String? {
        guard let start = text.firstIndex(of: open) else { return nil }
        var depth = 0
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == open { depth += 1 }
            else if ch == close {
                depth -= 1
                if depth == 0 { return String(text[start...idx]) }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

// MARK: - Built-in templates (offline / fallback)

/// Hand-authored multi-part models. Used when the engine is the offline stub or
/// the model's JSON can't be parsed, so a recognisable object always appears.
enum SceneTemplate {
    /// Best-matching template for a request, or nil if none matches.
    static func build(for request: String) -> (name: String, nodes: [ShapeNode])? {
        let t = request.lowercased()
        for entry in catalog where entry.keys.contains(where: { t.contains($0) }) {
            return (entry.name, entry.builder())
        }
        return nil
    }

    private typealias Entry = (keys: [String], name: String, builder: () -> [ShapeNode])

    private static let catalog: [Entry] = [
        (["snowman"], "snowman", snowman),
        (["house", "home", "cottage", "hut"], "house", house),
        (["skyscraper", "tower"], "tower", tower),
        (["christmas tree", "tree", "pine"], "tree", tree),
        (["table", "desk"], "table", table),
        (["chair", "stool", "seat"], "chair", chair),
        (["car", "vehicle", "truck", "auto"], "car", car),
        (["rocket", "spaceship", "missile"], "rocket", rocket),
        (["robot", "android", "mech"], "robot", robot),
        (["archway", "arch", "gate", "gateway"], "arch", arch),
        (["wall", "fence", "brick"], "wall", wall),
        (["step pyramid", "pyramid"], "pyramid", pyramid)
    ]

    // Concise node helper. Position/size in metres; rotation in degrees.
    private static func n(_ kind: ShapeKind,
                          _ x: Float, _ y: Float, _ z: Float,
                          _ sx: Float, _ sy: Float, _ sz: Float,
                          _ color: String = "blue",
                          rx: Float = 0, ry: Float = 0, rz: Float = 0) -> ShapeNode {
        let c = ColorPalette.map[color] ?? (0.55, 0.7)
        return ShapeNode(kind: kind,
                         position: SIMD3<Float>(x, y, z),
                         scale: SIMD3<Float>(sx, sy, sz),
                         hue: c.hue, saturation: c.sat,
                         rotation: SIMD3<Float>(rx * .pi / 180, ry * .pi / 180, rz * .pi / 180))
    }

    private static func snowman() -> [ShapeNode] {
        [
            n(.sphere, 0, -0.16, 0, 0.16, 0.16, 0.16, "white"),
            n(.sphere, 0,  0.00, 0, 0.12, 0.12, 0.12, "white"),
            n(.sphere, 0,  0.13, 0, 0.09, 0.09, 0.09, "white"),
            n(.cone,   0,  0.13, 0.08, 0.03, 0.07, 0.03, "orange", rx: 90),
            n(.sphere,-0.03, 0.15, 0.07, 0.015, 0.015, 0.015, "navy"),
            n(.sphere, 0.03, 0.15, 0.07, 0.015, 0.015, 0.015, "navy"),
            n(.box,    0,  0.22, 0, 0.13, 0.04, 0.13, "indigo")
        ]
    }

    private static func house() -> [ShapeNode] {
        [
            n(.box,     0, -0.05, 0, 0.30, 0.25, 0.30, "white"),
            n(.pyramid, 0,  0.17, 0, 0.36, 0.20, 0.36, "red"),
            n(.box,     0, -0.12, 0.16, 0.08, 0.13, 0.02, "brown"),
            n(.box,   0.10, -0.03, 0.16, 0.05, 0.05, 0.02, "cyan"),
            n(.box,  -0.10, -0.03, 0.16, 0.05, 0.05, 0.02, "cyan")
        ]
    }

    private static func tower() -> [ShapeNode] {
        var nodes: [ShapeNode] = []
        var y: Float = -0.22
        var s: Float = 0.22
        for i in 0..<6 {
            nodes.append(n(.box, 0, y, 0, s, 0.09, s, i % 2 == 0 ? "azure" : "blue"))
            y += 0.09
            s = max(0.10, s - 0.02)
        }
        nodes.append(n(.cone, 0, y + 0.02, 0, 0.12, 0.12, 0.12, "red"))
        return nodes
    }

    private static func tree() -> [ShapeNode] {
        [
            n(.cylinder, 0, -0.16, 0, 0.06, 0.18, 0.06, "brown"),
            n(.cone, 0, 0.00, 0, 0.28, 0.18, 0.28, "green"),
            n(.cone, 0, 0.12, 0, 0.22, 0.16, 0.22, "green"),
            n(.cone, 0, 0.22, 0, 0.15, 0.14, 0.15, "green")
        ]
    }

    private static func table() -> [ShapeNode] {
        [
            n(.box, 0, 0.02, 0, 0.34, 0.03, 0.24, "brown"),
            n(.box, -0.14, -0.10, 0.09, 0.03, 0.20, 0.03, "brown"),
            n(.box,  0.14, -0.10, 0.09, 0.03, 0.20, 0.03, "brown"),
            n(.box, -0.14, -0.10, -0.09, 0.03, 0.20, 0.03, "brown"),
            n(.box,  0.14, -0.10, -0.09, 0.03, 0.20, 0.03, "brown")
        ]
    }

    private static func chair() -> [ShapeNode] {
        [
            n(.box, 0, -0.02, 0, 0.18, 0.03, 0.18, "tan"),
            n(.box, 0, 0.10, -0.08, 0.18, 0.18, 0.03, "tan"),
            n(.box, -0.07, -0.13, 0.07, 0.025, 0.16, 0.025, "brown"),
            n(.box,  0.07, -0.13, 0.07, 0.025, 0.16, 0.025, "brown"),
            n(.box, -0.07, -0.13, -0.07, 0.025, 0.16, 0.025, "brown"),
            n(.box,  0.07, -0.13, -0.07, 0.025, 0.16, 0.025, "brown")
        ]
    }

    private static func car() -> [ShapeNode] {
        [
            n(.box, 0, -0.05, 0, 0.34, 0.10, 0.16, "red"),
            n(.box, -0.02, 0.05, 0, 0.18, 0.09, 0.15, "red"),
            n(.cylinder, -0.12, -0.11, 0.09, 0.06, 0.05, 0.06, "grey", rz: 90),
            n(.cylinder,  0.12, -0.11, 0.09, 0.06, 0.05, 0.06, "grey", rz: 90),
            n(.cylinder, -0.12, -0.11, -0.09, 0.06, 0.05, 0.06, "grey", rz: 90),
            n(.cylinder,  0.12, -0.11, -0.09, 0.06, 0.05, 0.06, "grey", rz: 90)
        ]
    }

    private static func rocket() -> [ShapeNode] {
        [
            n(.cylinder, 0, 0.0, 0, 0.10, 0.34, 0.10, "white"),
            n(.cone, 0, 0.23, 0, 0.10, 0.12, 0.10, "red"),
            n(.box, -0.09, -0.16, 0, 0.02, 0.10, 0.06, "red", rz: 20),
            n(.box,  0.09, -0.16, 0, 0.02, 0.10, 0.06, "red", rz: -20),
            n(.cone, 0, -0.22, 0, 0.07, 0.10, 0.07, "orange", rx: 180)
        ]
    }

    private static func robot() -> [ShapeNode] {
        [
            n(.box, 0, -0.02, 0, 0.18, 0.22, 0.12, "cyan"),
            n(.box, 0, 0.16, 0, 0.10, 0.10, 0.10, "azure"),
            n(.sphere, -0.025, 0.17, 0.05, 0.02, 0.02, 0.02, "red"),
            n(.sphere,  0.025, 0.17, 0.05, 0.02, 0.02, 0.02, "red"),
            n(.cylinder, -0.13, -0.02, 0, 0.04, 0.18, 0.04, "blue"),
            n(.cylinder,  0.13, -0.02, 0, 0.04, 0.18, 0.04, "blue"),
            n(.cylinder, -0.05, -0.22, 0, 0.045, 0.14, 0.045, "blue"),
            n(.cylinder,  0.05, -0.22, 0, 0.045, 0.14, 0.045, "blue")
        ]
    }

    private static func arch() -> [ShapeNode] {
        [
            n(.box, -0.15, -0.05, 0, 0.06, 0.30, 0.06, "azure"),
            n(.box,  0.15, -0.05, 0, 0.06, 0.30, 0.06, "azure"),
            n(.box, 0, 0.14, 0, 0.40, 0.06, 0.06, "blue")
        ]
    }

    private static func wall() -> [ShapeNode] {
        var nodes: [ShapeNode] = []
        for row in 0..<3 {
            for col in 0..<5 {
                let offset: Float = row % 2 == 0 ? 0 : 0.04
                let x = -0.16 + Float(col) * 0.08 + offset
                let y = -0.14 + Float(row) * 0.08
                nodes.append(n(.box, x, y, 0, 0.075, 0.07, 0.06, "brown"))
            }
        }
        return nodes
    }

    private static func pyramid() -> [ShapeNode] {
        var nodes: [ShapeNode] = []
        var y: Float = -0.18
        var s: Float = 0.34
        for i in 0..<5 {
            nodes.append(n(.box, 0, y, 0, s, 0.07, s, i % 2 == 0 ? "gold" : "amber"))
            y += 0.07
            s = max(0.08, s - 0.06)
        }
        return nodes
    }
}
