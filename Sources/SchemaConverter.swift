// ============================================================================
// SchemaConverter.swift — Convert OpenAI JSON schemas to native FoundationModels types
// Part of apfel — Apple Intelligence from the command line
//
// Converts OpenAI tool definitions to Transcript.ToolDefinition using
// DynamicGenerationSchema. Falls back to text injection for unsupported schemas.
// ============================================================================

import Foundation
import FoundationModels
import ApfelCore

enum SchemaConverter {

    /// Convert OpenAI tools to native ToolDefinitions.
    /// Returns native definitions for tools that converted successfully,
    /// and ToolDef fallbacks for tools that failed (for text injection).
    static func convert(tools: [OpenAITool]) -> (native: [Transcript.ToolDefinition], fallback: [ToolDef]) {
        var native: [Transcript.ToolDefinition] = []
        var fallback: [ToolDef] = []

        for tool in tools {
            let fn = tool.function
            do {
                let schema: GenerationSchema
                if let paramsJSON = fn.parameters?.value {
                    let dynSchema = try convertJSONSchema(json: paramsJSON, name: fn.name)
                    schema = try GenerationSchema(root: dynSchema, dependencies: [])
                } else {
                    // No parameters — empty object schema
                    let dynSchema = DynamicGenerationSchema(name: fn.name, properties: [])
                    schema = try GenerationSchema(root: dynSchema, dependencies: [])
                }
                native.append(Transcript.ToolDefinition(
                    name: fn.name,
                    description: fn.description ?? fn.name,
                    parameters: schema
                ))
            } catch {
                // Conversion failed — fall back to text injection for this tool
                fallback.append(ToolDef(
                    name: fn.name,
                    description: fn.description,
                    parametersJSON: fn.parameters?.value
                ))
            }
        }

        return (native, fallback)
    }

    /// Convert a tool call's arguments JSON string to GeneratedContent.
    /// Returns empty content on failure.
    static func makeArguments(_ json: String) -> GeneratedContent {
        (try? GeneratedContent(json: json)) ?? (try! GeneratedContent(json: "{}"))
    }

    // MARK: - Private

    /// Recursively convert an OpenAI JSON Schema string to DynamicGenerationSchema.
    private static func convertJSONSchema(json: String, name: String) throws -> DynamicGenerationSchema {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConversionError.invalidJSON
        }
        return try convertObject(obj, name: name)
    }

    /// Recursively convert a JSON Schema dictionary to DynamicGenerationSchema.
    private static func convertObject(_ schema: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let type = schema["type"] as? String ?? "object"
        let description = schema["description"] as? String

        switch type {
        case "object":
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])

            var dynProps: [DynamicGenerationSchema.Property] = []
            for (propName, propValue) in properties.sorted(by: { $0.key < $1.key }) {
                guard let propSchema = propValue as? [String: Any] else { continue }
                let propDyn = try convertObject(propSchema, name: propName)
                let propDesc = propSchema["description"] as? String
                dynProps.append(.init(
                    name: propName,
                    description: propDesc,
                    schema: propDyn,
                    isOptional: !required.contains(propName)
                ))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: dynProps)

        case "string":
            if let enumValues = schema["enum"] as? [String] {
                return DynamicGenerationSchema(name: name, description: description, anyOf: enumValues)
            }
            // Plain string — empty properties object acts as a leaf
            return DynamicGenerationSchema(name: name, description: description, properties: [])

        case "integer", "number":
            return DynamicGenerationSchema(name: name, description: description, properties: [])

        case "boolean":
            return DynamicGenerationSchema(name: name, description: description, properties: [])

        case "array":
            if let items = schema["items"] as? [String: Any] {
                let itemSchema = try convertObject(items, name: "\(name)_item")
                return DynamicGenerationSchema(arrayOf: itemSchema)
            }
            throw ConversionError.unsupportedType("array without items")

        default:
            throw ConversionError.unsupportedType(type)
        }
    }

    enum ConversionError: Error {
        case invalidJSON
        case unsupportedType(String)
    }
}
