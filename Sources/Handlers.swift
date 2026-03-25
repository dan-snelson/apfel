// ============================================================================
// Handlers.swift — HTTP request handlers for OpenAI-compatible API
// Part of apfel — Apple Intelligence from the command line
// ============================================================================

import FoundationModels
import Foundation
import Hummingbird
import NIOCore

struct ChatRequestTrace: Sendable {
    let stream: Bool
    let estimatedTokens: Int?
    let error: String?
    let requestBody: String?
    let responseBody: String?
    let events: [String]
}

// MARK: - /v1/models

/// GET /v1/models — List available models (static response).
func handleListModels() -> Response {
    let response = ModelsListResponse(
        object: "list",
        data: [.init(
            id: modelName,
            object: "model",
            created: 1719792000,
            owned_by: "apple"
        )]
    )
    let body = jsonString(response)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(
        status: .ok,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(string: body))
    )
}

// MARK: - /v1/chat/completions

/// POST /v1/chat/completions — Main chat endpoint (streaming + non-streaming).
func handleChatCompletion(_ request: Request, context: some RequestContext) async throws -> (response: Response, trace: ChatRequestTrace) {
    var events: [String] = []
    // Decode request body
    let body = try await request.body.collect(upTo: 1024 * 1024)  // 1MB max
    let requestBodyString = body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""
    events.append("request bytes=\(body.readableBytes)")
    let decoder = JSONDecoder()
    let chatRequest: ChatCompletionRequest
    do {
        chatRequest = try decoder.decode(ChatCompletionRequest.self, from: body)
    } catch {
        let message = "Invalid JSON: \(error.localizedDescription)"
        return (
            openAIError(
                status: .badRequest,
                message: message,
                type: "invalid_request_error"
            ),
            ChatRequestTrace(
                stream: false,
                estimatedTokens: nil,
                error: message,
                requestBody: truncateForLog(requestBodyString),
                responseBody: message,
                events: events + ["decode failed: \(message)"]
            )
        )
    }

    // Validate: must have at least one message
    guard !chatRequest.messages.isEmpty else {
        let message = "'messages' must contain at least one message"
        return (
            openAIError(
                status: .badRequest,
                message: message,
                type: "invalid_request_error"
            ),
            ChatRequestTrace(
                stream: chatRequest.stream == true,
                estimatedTokens: nil,
                error: message,
                requestBody: truncateForLog(requestBodyString),
                responseBody: message,
                events: events + ["validation failed: empty messages"]
            )
        )
    }

    // Validate: last message should be from user
    guard chatRequest.messages.last?.role == "user" else {
        let message = "Last message must have role 'user'"
        return (
            openAIError(
                status: .badRequest,
                message: message,
                type: "invalid_request_error"
            ),
            ChatRequestTrace(
                stream: chatRequest.stream == true,
                estimatedTokens: nil,
                error: message,
                requestBody: truncateForLog(requestBodyString),
                responseBody: message,
                events: events + ["validation failed: last role != user"]
            )
        )
    }

    events.append("decoded messages=\(chatRequest.messages.count) stream=\(chatRequest.stream == true) model=\(chatRequest.model)")

    // Extract system prompt (first system message, if any)
    let systemPrompt = chatRequest.messages.first(where: { $0.role == "system" })?.content

    // Create session
    let session = makeSession(systemPrompt: systemPrompt)

    // Get user messages (excluding system)
    let userAssistantMessages = chatRequest.messages.filter { $0.role != "system" }

    // Replay history: feed all messages except the last one to build context
    if userAssistantMessages.count > 1 {
        for msg in userAssistantMessages.dropLast() {
            if msg.role == "user" {
                // Feed user message and discard response to build session context
                events.append("replay user chars=\(msg.content.count)")
                let _ = try await session.respond(to: msg.content)
            } else {
                events.append("replay assistant chars=\(msg.content.count)")
            }
            // Assistant messages are implicitly part of session history after respond()
        }
    }

    // The final user message
    let finalPrompt = userAssistantMessages.last!.content
    events.append("final prompt chars=\(finalPrompt.count)")
    let requestId = "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())"
    let created = Int(Date().timeIntervalSince1970)

    // Streaming or non-streaming?
    if chatRequest.stream == true {
        let result = streamingResponse(session: session, prompt: finalPrompt, id: requestId, created: created, requestBody: requestBodyString, events: events)
        return (result.response, result.trace)
    } else {
        let result = try await nonStreamingResponse(session: session, prompt: finalPrompt, id: requestId, created: created, requestBody: requestBodyString, events: events)
        return (result.response, result.trace)
    }
}

// MARK: - Non-Streaming Response

private func nonStreamingResponse(
    session: LanguageModelSession,
    prompt: String,
    id: String,
    created: Int,
    requestBody: String,
    events: [String]
) async throws -> (response: Response, trace: ChatRequestTrace) {
    let result = try await session.respond(to: prompt)
    let content = result.content

    let promptTokens = estimateTokens(prompt)
    let completionTokens = estimateTokens(content)

    let payload = ChatCompletionResponse(
        id: id,
        object: "chat.completion",
        created: created,
        model: modelName,
        choices: [.init(
            index: 0,
            message: OpenAIMessage(role: "assistant", content: content),
            finish_reason: "stop"
        )],
        usage: .init(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: promptTokens + completionTokens
        )
    )

    let body = jsonString(payload)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = Response(
        status: .ok,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(string: body))
    )
    return (
        response,
        ChatRequestTrace(
            stream: false,
            estimatedTokens: promptTokens + completionTokens,
            error: nil,
            requestBody: truncateForLog(requestBody),
            responseBody: truncateForLog(body),
            events: events + ["non-stream response chars=\(content.count)", "finish_reason=stop"]
        )
    )
}

// MARK: - Streaming Response (SSE)

private func streamingResponse(
    session: LanguageModelSession,
    prompt: String,
    id: String,
    created: Int,
    requestBody: String,
    events: [String]
) -> (response: Response, trace: ChatRequestTrace) {
    var headers = HTTPFields()
    headers[.contentType] = "text/event-stream"
    headers[.cacheControl] = "no-cache"
    headers[.init("Connection")!] = "keep-alive"
    let eventBox = TraceBuffer(events: events + ["stream start"])

    let responseStream = AsyncStream<ByteBuffer> { continuation in
        Task {
            let streamStart = Date()
            var responseLines: [String] = []
            var streamError: String?
            // Send role announcement
            let roleChunk = sseRoleChunk(id: id, created: created)
            let roleLine = sseDataLine(roleChunk)
            responseLines.append(roleLine.trimmingCharacters(in: .whitespacesAndNewlines))
            continuation.yield(ByteBuffer(string: roleLine))
            eventBox.append("sent role chunk")

            // Stream model response
            let stream = session.streamResponse(to: prompt)
            var prev = ""
            var chunkCount = 0

            do {
                for try await snapshot in stream {
                    let content = snapshot.content
                    if content.count > prev.count {
                        let idx = content.index(content.startIndex, offsetBy: prev.count)
                        let delta = String(content[idx...])
                        let chunk = sseContentChunk(id: id, created: created, content: delta)
                        let chunkLine = sseDataLine(chunk)
                        responseLines.append(chunkLine.trimmingCharacters(in: .whitespacesAndNewlines))
                        continuation.yield(ByteBuffer(string: chunkLine))
                        chunkCount += 1
                        eventBox.append("sent content chunk #\(chunkCount) delta_chars=\(delta.count) total_chars=\(content.count)")
                    }
                    prev = content
                }

                // Send stop chunk
                let stopChunk = sseStopChunk(id: id, created: created)
                let stopLine = sseDataLine(stopChunk)
                responseLines.append(stopLine.trimmingCharacters(in: .whitespacesAndNewlines))
                continuation.yield(ByteBuffer(string: stopLine))
                eventBox.append("sent stop chunk")

                // Send [DONE]
                continuation.yield(ByteBuffer(string: sseDone))
                responseLines.append("data: [DONE]")
                eventBox.append("sent [DONE] total_chars=\(prev.count)")
            } catch {
                // On error, send an error event and close
                let errMsg = "data: {\"error\":\"\(error.localizedDescription)\"}\n\n"
                responseLines.append(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
                continuation.yield(ByteBuffer(string: errMsg))
                streamError = error.localizedDescription
                eventBox.append("stream error: \(error.localizedDescription)")
            }

            let completionLog = RequestLog(
                id: "\(id)-stream",
                timestamp: ISO8601DateFormatter().string(from: streamStart),
                method: "POST",
                path: "/v1/chat/completions/stream",
                status: streamError == nil ? 200 : 500,
                duration_ms: Int(Date().timeIntervalSince(streamStart) * 1000),
                stream: true,
                estimated_tokens: estimateTokens(prev),
                error: streamError,
                request_body: truncateForLog(requestBody),
                response_body: truncateForLog(responseLines.joined(separator: "\n\n")),
                events: eventBox.snapshot()
            )
            await serverState.logStore.append(completionLog)
            continuation.finish()
        }
    }

    let response = Response(
        status: .ok,
        headers: headers,
        body: .init(asyncSequence: responseStream)
    )
    return (
        response,
        ChatRequestTrace(
            stream: true,
            estimatedTokens: estimateTokens(prompt),
            error: nil,
            requestBody: truncateForLog(requestBody),
            responseBody: "Streaming response in progress. See /v1/chat/completions/stream log entry for final SSE transcript.",
            events: events + ["stream request accepted", "final stream completion logged separately"]
        )
    )
}

final class TraceBuffer: @unchecked Sendable {
    private var events: [String]
    private let lock = NSLock()

    init(events: [String]) {
        self.events = events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

// MARK: - Error Helpers

/// Create an OpenAI-formatted error response.
func openAIError(status: HTTPResponse.Status, message: String, type: String, code: String? = nil) -> Response {
    let error = OpenAIErrorResponse(
        error: .init(message: message, type: type, param: nil, code: code)
    )
    let body = jsonString(error)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(string: body))
    )
}
