#if ENABLE_RDP_2
import Foundation
import CoreFoundation

/// Validate the remote UIA tree before exposing it through MCP. This is a
/// bounded desktop-data response, not an arbitrary Companion JSON passthrough.
extension WindowsUIAQuery {
    func validatedResult(_ result: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(result),
              try JSONSerialization.data(withJSONObject: result).count <= 768 * 1_024 else {
            throw Self.invalidResult()
        }
        var count = 0
        switch operation {
        case .snapshot:
            guard Set(result.keys) == ["root", "truncated", "nodeCount"],
                  let truncated = Self.boolean(result["truncated"]),
                  let declaredCount = Self.integer(result["nodeCount"]),
                  let root = result["root"] as? [String: Any] else { throw Self.invalidResult() }
            try validateNode(root, depth: 0, count: &count)
            guard declaredCount == count else { throw Self.invalidResult() }
            return ["root": root, "nodeCount": count, "truncated": truncated]
        case .find:
            guard Set(result.keys) == ["value"], let elements = result["value"] as? [[String: Any]],
                  elements.count <= maximumNodes else { throw Self.invalidResult() }
            for element in elements { try validateNode(element, depth: 0, count: &count) }
            // The existing find protocol provides no total match count. Reaching
            // the limit means there may be more; never claim the list is complete.
            return ["elements": elements, "nodeCount": count, "mayHaveMore": count == maximumNodes]
        }
    }

    private func validateNode(_ node: [String: Any], depth: Int, count: inout Int) throws {
        count += 1
        let required: Set<String> = ["runtimeId", "controlType", "processId", "isEnabled", "isOffscreen", "bounds", "children"]
        let keys = Set(node.keys)
        guard count <= maximumNodes, depth <= maximumDepth,
              required.isSubset(of: keys), keys.isSubset(of: required.union(["automationId", "name"])),
              Self.boundedText(node["runtimeId"], nullable: false),
              Self.boundedText(node["automationId"], nullable: true),
              Self.boundedText(node["name"], nullable: true),
              Self.boundedText(node["controlType"], nullable: false),
              let pid = Self.integer(node["processId"]), (0...Int(Int32.max)).contains(pid),
              Self.boolean(node["isEnabled"]) != nil, Self.boolean(node["isOffscreen"]) != nil,
              let bounds = node["bounds"] as? [String: Any],
              Set(bounds.keys) == ["x", "y", "width", "height"],
              let children = node["children"] as? [[String: Any]], children.count <= maximumNodes else {
            throw Self.invalidResult()
        }
        for key in ["x", "y", "width", "height"] {
            guard let value = bounds[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  (key == "x" || key == "y" || value.doubleValue >= 0) else { throw Self.invalidResult() }
        }
        for child in children { try validateNode(child, depth: depth + 1, count: &count) }
    }

    private static func boundedText(_ value: Any?, nullable: Bool) -> Bool {
        // Companion's serializer omits null properties on the wire.
        if nullable, value == nil || value is NSNull { return true }
        guard let text = value as? String else { return false }
        return text.utf16.count <= 4_096 && !text.contains("\0")
    }

    private static func invalidResult() -> WindowsMCPToolError {
        WindowsMCPToolError(code: .runtimeFailure, message: "Windows returned an invalid or oversized UI Automation result.")
    }
}

extension WindowsMCPToolResponse {
    func validateUIAObservation(arguments: [String: Any]) throws {
        let query = try WindowsUIAQuery(arguments)
        guard structuredContent["operation"] as? String == query.operation.rawValue,
              let rawID = structuredContent["observationId"] as? String,
              let id = UUID(uuidString: rawID), id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
              WindowsUIAQuery.integer(structuredContent["validForSeconds"]) == 60,
              WindowsUIAQuery.unsignedInteger(structuredContent["stateRevision"]) != nil,
              let capturedAt = structuredContent["capturedAt"] as? String,
              ISO8601DateFormatter().date(from: capturedAt) != nil,
              let data = structuredContent["data"] as? [String: Any] else {
            throw WindowsMCPToolError(code: .runtimeFailure, message: "Invalid UI Automation observation metadata.")
        }
        switch query.operation {
        case .snapshot:
            _ = try query.validatedResult(data)
        case .find:
            guard Set(data.keys) == ["elements", "nodeCount", "mayHaveMore"],
                  let elements = data["elements"] as? [[String: Any]],
                  WindowsUIAQuery.integer(data["nodeCount"]) == elements.count,
                  WindowsUIAQuery.boolean(data["mayHaveMore"]) == (elements.count == query.maximumNodes) else {
                throw WindowsMCPToolError(code: .runtimeFailure, message: "Invalid UI Automation find result.")
            }
            _ = try query.validatedResult(["value": elements])
        }
    }
}
#endif
