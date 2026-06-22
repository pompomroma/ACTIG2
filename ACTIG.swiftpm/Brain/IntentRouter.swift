import Foundation
import simd

/// A command A.C.T.I.G. can act on locally, before (or instead of) consulting
/// the language model. Keeping these as fast keyword intents gives the snappy,
/// human-like reaction time the request asks for — control commands never wait
/// on token generation.
enum AssistantIntent: Equatable {
    case wake
    case shutdown
    case openSceneWorkspace
    case openConversation
    case openCamera
    case enableCameraControl
    case disableCameraControl
    case analyzeObject(question: String)
    case undo
    case redo
    case scene(SceneIntent)
    case modelScene(request: String)   // multi-part build, driven by the model
    case chat(String)                  // fall through to the LLM
}

/// 3D-space sub-commands parsed from natural language.
struct SceneIntent: Equatable {
    enum Action: Equatable {
        case add(ShapeKind)
        case addColored(ShapeKind, hue: Float, sat: Float)
        case multiply(ShapeKind, count: Int)
        case grow
        case shrink
        case delete
        case swap
        case clear
        case rotate(degrees: Float, axis: SIMD3<Float>)
        case moveDirection(SIMD3<Float>)
        case recolorSelection(hue: Float, sat: Float)
        case selectKind(ShapeKind)
    }
    let action: Action
}

/// Parses raw user text (typed or transcribed) into an intent. This is
/// deliberately simple and deterministic; recognised 3D edits act instantly,
/// open-ended "build me a …" requests go to the model, and anything else
/// becomes `.chat`.
enum IntentRouter {
    static func parse(_ raw: String) -> AssistantIntent {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Lifecycle
        if t.contains("wake up actig") || t == "wake up" { return .wake }
        if t.contains("shut down all systems") || t.contains("shutdown all systems") { return .shutdown }

        // Workspace switching
        if t.matchesAny("3d project", "3d space", "modeling", "modelling", "bring up the project", "open the project") {
            return .openSceneWorkspace
        }
        if t.matchesAny("conversation", "go back to chat", "close project") { return .openConversation }

        // Camera control (opt-in only)
        if t.matchesAny("enable camera control", "enable finger control", "enable hand control", "control with my hand", "use my fingers") {
            return .enableCameraControl
        }
        if t.matchesAny("disable camera control", "stop camera control", "stop hand control", "stop finger control") {
            return .disableCameraControl
        }
        if t.matchesAny("open camera", "camera mode") { return .openCamera }

        // Object analysis
        if t.matchesAny("scan this", "what is this", "analyze this", "analyse this", "identify this", "what am i holding") {
            return .analyzeObject(question: raw)
        }

        // Undo / redo
        if t.matchesAny("undo", "go back", "previous action", "revert") { return .undo }
        if t.matchesAny("redo", "do it again") { return .redo }

        // Deterministic scene edits (add primitive, colour, rotate, move, select…)
        if let scene = parseScene(t) { return .scene(scene) }

        // Open-ended 3D build → let the model construct it (template fallback).
        if isBuildRequest(t) { return .modelScene(request: raw) }

        return .chat(raw)
    }

    // MARK: - Build detection

    private static func isBuildRequest(_ t: String) -> Bool {
        if SceneTemplate.build(for: t) != nil { return true }
        return t.matchesAny("build", "construct", "assemble", "sculpt", "rebuild",
                            "model a", "model me", "make a", "make me", "create a",
                            "create me", "design a", "design me")
    }

    // MARK: - Deterministic scene parsing

    private static func parseScene(_ t: String) -> SceneIntent? {
        let color = ColorPalette.named(t)
        let kind = ShapeKind.detect(in: t)

        // Recolour the current selection: "make it red", "paint it blue", "turn it green".
        if let col = color,
           t.matchesAny("make it", "colour it", "color it", "paint it", "recolour", "recolor", "turn it") {
            return SceneIntent(action: .recolorSelection(hue: col.hue, sat: col.sat))
        }

        // Rotate the selection.
        if t.matchesAny("rotate", "spin") || (t.contains("turn") && color == nil && kind == nil) {
            return SceneIntent(action: .rotate(degrees: extractNumber(t) ?? 45, axis: rotationAxis(t)))
        }

        // Nudge the selection in a direction.
        if t.matchesAny("move", "nudge", "shift", "slide"), let delta = moveDelta(t) {
            return SceneIntent(action: .moveDirection(delta))
        }

        // Select a shape by kind.
        if t.matchesAny("select", "pick", "choose", "highlight"), let k = kind {
            return SceneIntent(action: .selectKind(k))
        }

        // Verbs acting on the selection (no specific shape kind).
        if kind == nil {
            if t.matchesAny("clear the scene", "clear scene", "remove everything", "delete everything", "start over", "wipe") {
                return SceneIntent(action: .clear)
            }
            if t.matchesAny("bigger", "grow", "enlarge", "scale up", "larger") { return SceneIntent(action: .grow) }
            if t.matchesAny("smaller", "shrink", "scale down") { return SceneIntent(action: .shrink) }
            if t.matchesAny("delete", "remove it") { return SceneIntent(action: .delete) }
            if t.matchesAny("swap", "switch places", "swap positions") { return SceneIntent(action: .swap) }
            return nil
        }

        // Shape creation (optionally multiplied / coloured). Any mention of a
        // known kind in the 3D context resolves to adding it.
        if let n = extractCount(t), t.matchesAny("multiply", "copies", "duplicate", "times") {
            return SceneIntent(action: .multiply(kind!, count: n))
        }
        if let col = color {
            return SceneIntent(action: .addColored(kind!, hue: col.hue, sat: col.sat))
        }
        return SceneIntent(action: .add(kind!))
    }

    // MARK: - Helpers

    private static func rotationAxis(_ t: String) -> SIMD3<Float> {
        if t.matchesAny("forward", "pitch", "tip", "tilt") { return SIMD3<Float>(1, 0, 0) }
        if t.matchesAny("roll", "sideways") { return SIMD3<Float>(0, 0, 1) }
        return SIMD3<Float>(0, 1, 0)   // yaw by default
    }

    private static func moveDelta(_ t: String) -> SIMD3<Float>? {
        let d: Float = 0.09
        if t.contains("left") { return SIMD3<Float>(-d, 0, 0) }
        if t.contains("right") { return SIMD3<Float>(d, 0, 0) }
        if t.matchesAny("up", "higher", "raise") { return SIMD3<Float>(0, d, 0) }
        if t.matchesAny("down", "lower", "drop it") { return SIMD3<Float>(0, -d, 0) }
        if t.matchesAny("forward", "closer", "nearer", "toward") { return SIMD3<Float>(0, 0, d) }
        if t.matchesAny("back", "backward", "away", "farther", "further") { return SIMD3<Float>(0, 0, -d) }
        return nil
    }

    /// First standalone number in the text (e.g. "spin 90 degrees" → 90).
    private static func extractNumber(_ t: String) -> Float? {
        t.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Float($0) }.first
    }

    private static func extractCount(_ t: String) -> Int? {
        let words: [String: Int] = ["two": 2, "three": 3, "four": 4, "five": 5,
                                    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        for (w, n) in words where t.contains(w) { return n }
        let digits = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return digits.first
    }
}

private extension String {
    func matchesAny(_ needles: String...) -> Bool {
        needles.contains { self.contains($0) }
    }
}
