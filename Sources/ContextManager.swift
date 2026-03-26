// ============================================================================
// ContextManager.swift — Convert OpenAI messages to LanguageModelSession
// Part of apfel — Apple Intelligence from the command line
//
// Uses FoundationModels Transcript API to reconstruct session state from
// OpenAI's stateless message history — NO re-inference on history.
// Uses native Transcript.ToolDefinition and Transcript.ToolCalls where possible.
// ============================================================================

import FoundationModels
import Foundation
import ApfelCore

enum ContextManager {

    // MARK: - Session Factory

    /// Build a LanguageModelSession from OpenAI messages + optional tools.
    /// Returns the session (with history baked in) + the final user prompt.
    ///
    /// Architecture:
    /// - system message → Transcript.Instructions (with native ToolDefinitions)
    /// - user messages in history → Transcript.Prompt
    /// - assistant tool_calls → Transcript.ToolCalls (native, not serialized JSON)
    /// - assistant text → Transcript.Response
    /// - tool result messages → Transcript.ToolOutput
    /// - last user message → returned as finalPrompt (caller sends it via respond())
    static func makeSession(
        messages: [OpenAIMessage],
        tools: [OpenAITool]?,
        options: SessionOptions,
        jsonMode: Bool = false
    ) async throws -> (session: LanguageModelSession, finalPrompt: String) {
        let conversation = messages.filter { $0.role != "system" }
        guard let finalPrompt = conversation.last?.textContent, !finalPrompt.isEmpty else {
            throw ApfelError.unknown("Last message has no text content")
        }
        let history = Array(conversation.dropLast())
        let model = makeModel(permissive: options.permissive)

        // Convert tools: native ToolDefinitions + text fallback for failures
        var nativeToolDefs: [Transcript.ToolDefinition] = []
        var fallbackTools: [ToolDef] = []
        if let tools = tools, !tools.isEmpty {
            let converted = SchemaConverter.convert(tools: tools)
            nativeToolDefs = converted.native
            fallbackTools = converted.fallback
        }

        // Build instruction text
        let instrText = buildInstructions(
            messages: messages,
            tools: tools,
            fallbackTools: fallbackTools,
            jsonMode: jsonMode
        )

        // Budget-aware history: count tokens and keep newest messages that fit
        let tc = TokenCounter.shared
        let budget = await tc.inputBudget(reservedForOutput: 512)
        var usedTokens = await tc.count(finalPrompt)
        if !instrText.isEmpty {
            usedTokens += await tc.count(instrText)
        }

        // Walk history newest-first, keep messages that fit within budget
        var keptHistory: [OpenAIMessage] = []
        for msg in history.reversed() {
            let text = msg.textContent ?? msg.tool_call_id ?? ""
            let tokens = await tc.count(text)
            if usedTokens + tokens > budget { break }
            usedTokens += tokens
            keptHistory.insert(msg, at: 0)
        }

        // Build transcript entries
        var entries: [Transcript.Entry] = []

        // Instructions with native tool definitions
        if !instrText.isEmpty || !nativeToolDefs.isEmpty {
            let segments: [Transcript.Segment] = instrText.isEmpty ? [] : [
                .text(Transcript.TextSegment(content: instrText))
            ]
            let instr = Transcript.Instructions(segments: segments, toolDefinitions: nativeToolDefs)
            entries.append(.instructions(instr))
        }

        // History entries
        for msg in keptHistory {
            switch msg.role {
            case "user":
                if let text = msg.textContent {
                    let seg = Transcript.TextSegment(content: text)
                    let genOpts = makeGenerationOptions(options)
                    let prompt = Transcript.Prompt(segments: [.text(seg)], options: genOpts)
                    entries.append(.prompt(prompt))
                }
            case "assistant":
                if let calls = msg.tool_calls, !calls.isEmpty {
                    // Native ToolCalls entry — semantically correct
                    let transcriptCalls = calls.map { call in
                        let args = SchemaConverter.makeArguments(call.function.arguments)
                        return Transcript.ToolCall(
                            id: call.id,
                            toolName: call.function.name,
                            arguments: args
                        )
                    }
                    let toolCalls = Transcript.ToolCalls(transcriptCalls)
                    entries.append(.toolCalls(toolCalls))
                } else {
                    let text = msg.textContent ?? ""
                    let seg = Transcript.TextSegment(content: text)
                    let resp = Transcript.Response(assetIDs: [], segments: [.text(seg)])
                    entries.append(.response(resp))
                }
            case "tool":
                let text = msg.textContent ?? ""
                let seg = Transcript.TextSegment(content: text)
                let output = Transcript.ToolOutput(
                    id: msg.tool_call_id ?? UUID().uuidString,
                    toolName: msg.name ?? "tool",
                    segments: [.text(seg)]
                )
                entries.append(.toolOutput(output))
            default:
                break
            }
        }

        let session: LanguageModelSession
        if entries.isEmpty {
            session = LanguageModelSession(model: model)
        } else {
            let transcript = Transcript(entries: entries)
            session = LanguageModelSession(model: model, transcript: transcript)
        }
        return (session, finalPrompt)
    }

    // MARK: - Instructions Builder

    private static func buildInstructions(
        messages: [OpenAIMessage],
        tools: [OpenAITool]?,
        fallbackTools: [ToolDef],
        jsonMode: Bool
    ) -> String {
        var parts: [String] = []

        // JSON mode instruction
        if jsonMode {
            parts.append("You must respond with valid JSON only. No markdown code fences, no explanation text, no preamble. Output raw JSON.")
        }

        // System prompt
        if let sys = messages.first(where: { $0.role == "system" })?.textContent {
            parts.append(sys)
        }

        // Tool output format instructions (always needed when tools are present)
        if let tools = tools, !tools.isEmpty {
            let names = tools.map(\.function.name)
            parts.append(ToolCallHandler.buildOutputFormatInstructions(toolNames: names))
        }

        // Text fallback for tools that failed native conversion
        if !fallbackTools.isEmpty {
            parts.append(ToolCallHandler.buildFallbackPrompt(tools: fallbackTools))
        }

        return parts.joined(separator: "\n\n")
    }
}
