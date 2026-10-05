import Foundation

// The plan's data shapes and the parsing shared by every planner: CLI agents
// and custom model providers both answer in the same JSON, and the streaming
// parser here turns their answers into cards as they are written.

// MARK: - The plan

/// How much judgement a plan item needs. ONE type owns the vocabulary the
/// schema declares, so the section a card appears in and whether it starts
/// ticked cannot be derived two different ways.
///
/// The two previously used opposing tests — `group != "ask"` for the section
/// and `group == "safe"` for the tick — so any value that was neither exact
/// literal (a capitalized "Safe", a stray "unsafe") landed under the
/// reassuring "Safe to remove" heading while staying unselected. The array is
/// what the model must answer in, but only the CLI agents enforce it: a custom
/// provider gets `response_format: json_object` and no enum, so a near-miss is
/// reachable in practice.
nonisolated enum PlanGroup: String, Decodable, Sendable, Equatable {
    /// Rebuilt or re-downloaded automatically; AppleTree may tick it.
    case safe
    /// The user decides; never ticked on the planner's word.
    case ask

    /// Trim surrounding whitespace, then require the documented literal.
    ///
    /// Deliberately NOT case-folded: only the two words the schema names are
    /// recognized, because the two outcomes are not symmetric. Mistaking a
    /// value for `safe` auto-ticks it, and a ticked card is one click from the
    /// Trash; mistaking it for `ask` merely asks the user. An unknown value
    /// therefore fails to `ask`, where the user still sees the card and can
    /// tick it themselves.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanGroup(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .ask
    }
}

/// What a plan item asks AppleTree to do. ONE type owns the vocabulary the
/// schema declares, so "is this a command?" is answered in one place instead
/// of by comparing a `String` against literals at each call site.
///
/// Failure direction, mirroring `PlanGroup`'s reasoning about the asymmetric
/// risk of guessing — with the opposite conclusion, because here there is no
/// safe fallback. Only the two words the schema names are recognized;
/// everything else is REJECTED, not defaulted to `trash`.
///
/// `PlanGroup` can fail to `ask` because that outcome still shows the card:
/// the user decides. An action has no equivalent resting place. `trash` is the
/// reversible step but still hands paths to the two-step deleter, and an item
/// that decodes as `.trash` is eligible to be auto-ticked and trashed; a
/// fallback to `.command` would instead hand the string to the command runner.
/// Leaving the item "unacted" is not available either: `PlanItem.init` treats
/// every non-command item as a trash candidate, so an unknown action would be
/// trashed by the fall-through. An unrecognized action therefore fails to
/// decode. For a CLI planner the schema's enum already makes this unreachable;
/// a custom provider gets `json_object` with no enum, so this is where a
/// near-miss ("Trash", "delete", "rm") is stopped: the plan does not decode
/// and `PlanJSON.decode` returns nil, which the callers already report as an
/// invalid plan. Nothing is trashed or run on a guessed action. Surrounding
/// whitespace is trimmed first, exactly as `PlanGroup` does it, so a padded but
/// otherwise exact literal still decodes.
nonisolated enum PlanAction: Decodable, Sendable, Equatable {
    /// Move paths to the Trash; the reversible step.
    case trash
    /// Run one of the allowlisted tool commands.
    case command

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "trash": self = .trash
        case "command": self = .command
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown plan action \(raw.debugDescription); expected \"trash\" or \"command\""))
        }
    }
}

nonisolated struct PlanItemSpec: Decodable, Sendable, Equatable {
    let title: String
    let detail: String
    let group: PlanGroup
    let bytes: Int64
    let paths: [String]
    let action: PlanAction
    let command: String
}

/// The JSON shape both agents must answer in (Claude: --json-schema, Codex:
/// --output-schema; strict, so every field is required).
nonisolated let planSchema = """
{"type":"object","additionalProperties":false,"required":["summary","items"],"properties":{\
"summary":{"type":"string"},"items":{"type":"array","items":{"type":"object","additionalProperties":false,\
"required":["title","detail","group","bytes","paths","action","command"],"properties":{\
"title":{"type":"string"},"detail":{"type":"string"},"group":{"type":"string","enum":["safe","ask"]},\
"bytes":{"type":"integer"},"paths":{"type":"array","items":{"type":"string"}},\
"action":{"type":"string","enum":["trash","command"]},"command":{"type":"string"}}}}}}
"""

/// Pulls finished item objects out of the plan JSON while it is still being
/// written, so cards appear one by one instead of all at the end.
nonisolated struct PartialPlanParser {
    private(set) var hasInput = false
    private static let itemsKey = Array("\"items\"".utf8)
    private var keyBytes = 0
    private var foundKey = false
    private var inItems = false
    private var finished = false
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var object: [UInt8] = []

    mutating func append(_ chunk: String) -> [PlanItemSpec] {
        hasInput = hasInput || !chunk.isEmpty
        guard !finished else { return [] }
        var fresh: [PlanItemSpec] = []
        // Only inspect the new bytes. State survives arbitrary delta
        // boundaries, including a key, escape, or unfinished item.
        for c in chunk.utf8 {
            if !foundKey {
                if c == Self.itemsKey[keyBytes] {
                    keyBytes += 1
                    if keyBytes == Self.itemsKey.count { foundKey = true }
                } else {
                    keyBytes = c == Self.itemsKey[0] ? 1 : 0
                }
                continue
            }
            if !inItems {
                if c == UInt8(ascii: "[") { inItems = true }
                continue
            }
            if depth > 0 { object.append(c) }
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                if depth == 0 {
                    object.removeAll(keepingCapacity: true)
                    object.append(c)
                }
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0, !object.isEmpty {
                    if let item = try? JSONDecoder().decode(PlanItemSpec.self, from: Data(object)) {
                        fresh.append(item)
                    }
                    object.removeAll(keepingCapacity: true)
                }
            } else if c == UInt8(ascii: "]"), depth == 0 {
                finished = true
                break
            }
        }
        return fresh
    }
}

// MARK: - Full-text plan decoding

/// Decodes a finished plan out of whatever a model actually sends. Real
/// models wrap the JSON in markdown fences or prose around it; endpoints
/// without streaming return the whole body at once. Everything here is
/// tolerant: the strict schema lives upstream of this point.
nonisolated enum PlanJSON {
    /// `(summary, items)` out of a decoded object, or nil when items fail.
    static func decode(_ obj: [String: Any]) -> (String, [PlanItemSpec])? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj["items"] ?? []),
              let items = try? JSONDecoder().decode([PlanItemSpec].self, from: data) else { return nil }
        return ((obj["summary"] as? String) ?? "", items)
    }

    /// Decodes the full text of a reply. Strips markdown fences, then takes
    /// the first `{` to the last `}` so prose around the object cannot break it.
    static func decode(text: String) -> (String, [PlanItemSpec])? {
        var body = text
        // Bounds can invert ("}") on malformed replies; require a sane span
        // or decoding would trap on the reversed range.
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start <= end {
            body = String(body[start...end])
        } else {
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return nil
        }
        return decode(obj)
    }
}
