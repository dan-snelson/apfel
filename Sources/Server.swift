// ============================================================================
// Server.swift — OpenAI-compatible HTTP server
// Part of apfel — Apple Intelligence from the command line
// ============================================================================

import Foundation
import Hummingbird

/// Server configuration passed from CLI argument parsing.
struct ServerConfig: Sendable {
    let host: String
    let port: Int
    let cors: Bool
    let maxConcurrent: Int
    let debug: Bool
}

/// Shared server state accessible by all request handlers.
final class ServerState: Sendable {
    let logStore: LogStore
    let semaphore: AsyncSemaphore
    let config: ServerConfig

    init(config: ServerConfig) {
        self.logStore = LogStore(capacity: 1000)
        self.semaphore = AsyncSemaphore(value: config.maxConcurrent)
        self.config = config
    }
}

/// Global server state — set once at startup, read by handlers.
nonisolated(unsafe) var serverState: ServerState!

/// Start the OpenAI-compatible HTTP server.
func startServer(config: ServerConfig) async throws {
    serverState = ServerState(config: config)
    let router = Router()

    // Health
    router.get("/health") { _, _ -> Response in
        let active = await serverState.logStore.activeRequests
        return jsonResponse("{\"status\":\"ok\",\"model\":\"\(modelName)\",\"version\":\"\(version)\",\"active_requests\":\(active)}")
    }

    // Models
    router.get("/v1/models") { _, _ -> Response in
        jsonResponse(jsonString(ModelsListResponse(
            object: "list",
            data: [.init(id: modelName, object: "model", created: 1719792000, owned_by: "apple")]
        )))
    }

    // Chat completions (with logging, retry, concurrency)
    router.post("/v1/chat/completions") { request, context -> Response in
        let start = Date()
        let requestId = "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())"

        // Acquire semaphore (concurrency limit)
        do {
            try await serverState.semaphore.wait(timeout: .seconds(30))
        } catch {
            let log = RequestLog(
                id: requestId, timestamp: ISO8601DateFormatter().string(from: Date()),
                method: "POST", path: "/v1/chat/completions", status: 429,
                duration_ms: Int(Date().timeIntervalSince(start) * 1000),
                stream: false, estimated_tokens: nil,
                error: "Too many concurrent requests", request_body: nil, response_body: nil, events: ["semaphore timeout"]
            )
            await serverState.logStore.append(log)
            return openAIError(status: .tooManyRequests, message: "Server at max concurrent capacity (\(config.maxConcurrent)). Try again later.", type: "rate_limit_error")
        }

        await serverState.logStore.requestStarted()
        defer {
            Task { await serverState.semaphore.signal() }
            Task { await serverState.logStore.requestFinished() }
        }

        // Handle the request
        let result = try await handleChatCompletion(request, context: context)

        // Log it
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let log = RequestLog(
            id: requestId,
            timestamp: ISO8601DateFormatter().string(from: start),
            method: "POST", path: "/v1/chat/completions",
            status: result.response.status == .ok ? 200 : result.response.status.code,
            duration_ms: durationMs,
            stream: result.trace.stream,
            estimated_tokens: result.trace.estimatedTokens,
            error: result.trace.error,
            request_body: result.trace.requestBody,
            response_body: result.trace.responseBody,
            events: result.trace.events
        )
        await serverState.logStore.append(log)

        return result.response
    }

    // Logs query
    router.get("/v1/logs") { request, _ -> Response in
        let queryString = request.uri.query ?? ""
        let params = parseQueryParams(queryString)
        let statusFilter = params["status"].flatMap(Int.init)
        let pathFilter = params["path"]
        let errorsOnly = params["errors"] == "true"
        let limit = params["limit"].flatMap(Int.init) ?? 50
        let sinceStr = params["since"]
        let sinceDate = sinceStr.flatMap { ISO8601DateFormatter().date(from: $0) }

        let logs = await serverState.logStore.query(
            status: statusFilter, path: pathFilter,
            errorsOnly: errorsOnly, since: sinceDate, limit: limit
        )
        let response = LogListResponse(object: "list", count: logs.count, data: logs)
        return jsonResponse(jsonString(response))
    }

    // Logs stats
    router.get("/v1/logs/stats") { _, _ -> Response in
        let stats = await serverState.logStore.stats(maxConcurrent: config.maxConcurrent)
        return jsonResponse(jsonString(stats))
    }

    // Note: CORS headers are added via jsonResponse() helper when config.cors is true

    let app = Application(
        router: router,
        configuration: .init(
            address: .hostname(config.host, port: config.port)
        )
    )

    printStderr("""
    \(styled("apfel server", .cyan, .bold)) v\(version)
    \(styled("├", .dim)) endpoint: http://\(config.host):\(config.port)
    \(styled("├", .dim)) model:    \(modelName)
    \(styled("├", .dim)) cors:     \(config.cors ? "enabled" : "disabled")
    \(styled("├", .dim)) max concurrent: \(config.maxConcurrent)
    \(styled("├", .dim)) debug:    \(config.debug ? "on" : "off")
    \(styled("└", .dim)) ready
    """)

    printStderr("")
    printStderr(styled("Endpoints:", .yellow, .bold))
    printStderr("  POST http://\(config.host):\(config.port)/v1/chat/completions")
    printStderr("  GET  http://\(config.host):\(config.port)/v1/models")
    printStderr("  GET  http://\(config.host):\(config.port)/v1/logs")
    printStderr("  GET  http://\(config.host):\(config.port)/v1/logs/stats")
    printStderr("  GET  http://\(config.host):\(config.port)/health")
    printStderr("")

    try await app.run()
}

// MARK: - Query Parameter Parsing

/// Parse URL query string into key-value pairs.
func parseQueryParams(_ query: String) -> [String: String] {
    var params: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            params[key] = value
        }
    }
    return params
}

// MARK: - Helpers

/// Create a JSON Response with proper Content-Type header.
func jsonResponse(_ body: String, status: HTTPResponse.Status = .ok) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if serverState?.config.cors == true {
        headers[.init("Access-Control-Allow-Origin")!] = "*"
    }
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: .init(string: body))
    )
}
