//
//  SchemaConverter.swift
//  FirebaseAI-Demo
//
//  Translates MCP JSON-Schema (MCP.Value) into Firebase AI `Schema` trees.
//

import MCP
import FirebaseAILogic

enum SchemaConverter {

    /// Top-level entry point for a tool's `inputSchema`, which is always a JSON-Schema
    /// *object*. Returns the property map plus the names of optional properties, matching
    /// `FunctionDeclaration(name:description:parameters:optionalParameters:)`.
    ///
    /// Note: Firebase treats every parameter as required unless listed in `optional`,
    /// so we derive `optional = properties − required`.
    static func functionParameters(_ value: MCP.Value?) -> (properties: [String: Schema], optional: [String]) {
        guard let value, case .object(let obj) = value else { return ([:], []) }
        return objectProperties(from: obj)
    }

    /// Recursive conversion of a single JSON-Schema node.
    static func convertValue(_ value: MCP.Value) -> Schema {
        guard case .object(let obj) = value else {
            // Non-object schema node (rare) — fall back to a permissive string.
            return .string()
        }

        let type = stringValue(obj["type"]) ?? "object"

        switch type {
        case "string":
            if let enumVals = arrayOfStrings(obj["enum"]) {
                return .enumeration(values: enumVals, description: description(obj))
            }
            return .string(description: description(obj))

        case "integer":
            return .integer(description: description(obj))

        case "number":
            return .double(description: description(obj))

        case "boolean":
            return .boolean(description: description(obj))

        case "array":
            let items: Schema = obj["items"].map { convertValue($0) } ?? .string()
            return .array(items: items, description: description(obj))

        case "object":
            fallthrough
        default:
            let (properties, optional) = objectProperties(from: obj)
            return .object(
                properties: properties,
                optionalProperties: optional,
                description: description(obj)
            )
        }
    }

    // MARK: - Helpers

    /// Builds the `(properties, optionalNames)` pair from a JSON-Schema object node,
    /// stripping meta keys Gemini rejects and guaranteeing every optional name exists
    /// in `properties` (otherwise `Schema.object` would `fatalError`).
    private static func objectProperties(from obj: [String: MCP.Value]) -> (properties: [String: Schema], optional: [String]) {
        var properties: [String: Schema] = [:]
        if case .object(let props)? = obj["properties"] {
            for (key, val) in props where !schemaMetaKeys.contains(key) {
                properties[key] = convertValue(val)
            }
        }
        let required = Set(arrayOfStrings(obj["required"]) ?? [])
        let optional = properties.keys.filter { !required.contains($0) }
        return (properties, Array(optional))
    }

    private static let schemaMetaKeys: Set<String> = [
        "$schema", "$id", "additionalProperties", "definitions",
        "$defs", "allOf", "anyOf", "oneOf", "not", "if", "then", "else"
    ]

    private static func description(_ obj: [String: MCP.Value]) -> String? {
        stringValue(obj["description"])
    }

    private static func stringValue(_ value: MCP.Value?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    private static func arrayOfStrings(_ value: MCP.Value?) -> [String]? {
        guard case .array(let arr)? = value else { return nil }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
