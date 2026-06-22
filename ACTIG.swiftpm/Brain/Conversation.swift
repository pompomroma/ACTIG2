import Foundation

/// Owns the system prompt and persists the transcript to disk so a relaunch
/// resumes where you left off (the stock-iPad equivalent of "always running").
struct Conversation {
    /// A.C.T.I.G.'s persona + capability framing handed to the model each turn.
    static let systemPrompt = """
    You are A.C.T.I.G., a concise, capable on-device assistant on an iPad Pro M4. \
    You speak in a calm, precise, Jarvis-like manner. Keep spoken answers short and \
    natural unless asked for detail. You can open a 3D modelling workspace, enable \
    camera-based hand controls, and analyse objects shown to the camera. You run \
    fully offline and never claim access to other apps' private data or accounts.
    """

    /// Handed to the model when the user asks A.C.T.I.G. to *build* something in
    /// the 3D space. It must answer with ONLY a JSON scene plan we can execute.
    static let modelingSystemPrompt = """
    You are A.C.T.I.G.'s 3D modelling engine. Given a request, design the object \
    out of simple primitives and reply with ONLY a JSON object — no prose, no \
    code fences.

    Schema:
    {"commands":[{"shape":"box|sphere|cylinder|cone|pyramid|plane","x":<m>,"y":<m>,\
    "z":<m>,"scale":<m>,"sx":<m>,"sy":<m>,"sz":<m>,"color":"red|orange|yellow|green|\
    cyan|blue|purple|pink|white|brown|grey","rx":<deg>,"ry":<deg>,"rz":<deg>}]}

    Rules:
    - The scene is centred on the origin. Keep every x, y, z within -0.5...0.5 \
    metres. y is up, z is toward the viewer.
    - Sizes are in metres; use 0.02...0.4. "scale" sets a uniform size; "sx/sy/sz" \
    override per axis (use them for slabs, thin legs, tall parts).
    - x/y/z, color and rotation are optional (defaults: 0, blue, 0). "shape" is required.
    - Use 3 to 30 parts. Stack and place them so the result is recognisable.
    - Output the JSON object only.
    """

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("actig_transcript.json")
    }

    /// Persisted plain representation of a message.
    private struct Stored: Codable {
        let role: String
        let text: String
    }

    static func save(_ messages: [ChatMessage]) {
        let stored = messages
            .filter { $0.role != .system }
            .map { Stored(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else {
            return []
        }
        return stored.map {
            ChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text)
        }
    }
}
