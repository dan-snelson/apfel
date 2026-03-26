// ============================================================================
// main.swift — Entry point for apfel
// Apple Intelligence from the command line.
// https://github.com/Arthur-Ficial/apfel
// ============================================================================

import Foundation

// MARK: - Configuration

let version = "0.4.0"
let appName = "apfel"
let modelName = "apple-foundationmodel"

// MARK: - Exit Codes

let exitSuccess: Int32 = 0
let exitRuntimeError: Int32 = 1
let exitUsageError: Int32 = 2

// MARK: - Signal Handling

signal(SIGINT) { _ in
    if isatty(STDOUT_FILENO) != 0 {
        FileHandle.standardOutput.write(Data("\u{001B}[0m".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    _exit(130)
}

// MARK: - Argument Parsing

var args = Array(CommandLine.arguments.dropFirst())

// Stdin pipe with no args
if args.isEmpty {
    if isatty(STDIN_FILENO) == 0 {
        var lines: [String] = []
        while let line = readLine(strippingNewline: false) {
            lines.append(line)
        }
        let input = lines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            do {
                try await singlePrompt(input, systemPrompt: nil, stream: true)
                exit(exitSuccess)
            } catch {
                printError(error.localizedDescription)
                exit(exitRuntimeError)
            }
        }
    }
    printUsage()
    exit(exitUsageError)
}

// Parse flags
var systemPrompt: String? = nil
var mode: String = "single"
var prompt: String = ""
var serverPort: Int = 11434
var serverHost: String = "127.0.0.1"
var serverCORS: Bool = false
var serverMaxConcurrent: Int = 5
var serverDebug: Bool = false
var cliTemperature: Double? = nil
var cliSeed: UInt64? = nil
var cliMaxTokens: Int? = nil
var cliPermissive: Bool = false

var i = 0
while i < args.count {
    switch args[i] {
    case "-h", "--help":
        printUsage()
        exit(exitSuccess)

    case "-v", "--version":
        print("\(appName) v\(version)")
        exit(exitSuccess)

    case "-s", "--system":
        i += 1
        guard i < args.count else {
            printError("--system requires a value")
            exit(exitUsageError)
        }
        systemPrompt = args[i]

    case "-o", "--output":
        i += 1
        guard i < args.count else {
            printError("--output requires a value (plain or json)")
            exit(exitUsageError)
        }
        guard let fmt = OutputFormat(rawValue: args[i]) else {
            printError("unknown output format: \(args[i]) (use plain or json)")
            exit(exitUsageError)
        }
        outputFormat = fmt

    case "-q", "--quiet":
        quietMode = true

    case "--no-color":
        noColorFlag = true

    case "--chat":
        mode = "chat"

    case "--stream":
        mode = "stream"

    case "--serve":
        mode = "serve"

    case "--gui":
        mode = "gui"

    case "--port":
        i += 1
        guard i < args.count, let p = Int(args[i]), p > 0, p < 65536 else {
            printError("--port requires a valid port number (1-65535)")
            exit(exitUsageError)
        }
        serverPort = p

    case "--host":
        i += 1
        guard i < args.count else {
            printError("--host requires an address")
            exit(exitUsageError)
        }
        serverHost = args[i]

    case "--cors":
        serverCORS = true

    case "--max-concurrent":
        i += 1
        guard i < args.count, let n = Int(args[i]), n > 0 else {
            printError("--max-concurrent requires a positive number")
            exit(exitUsageError)
        }
        serverMaxConcurrent = n

    case "--debug":
        serverDebug = true

    case "--temperature":
        i += 1
        guard i < args.count, let t = Double(args[i]) else {
            printError("--temperature requires a number (e.g., 0.7)")
            exit(exitUsageError)
        }
        cliTemperature = t

    case "--seed":
        i += 1
        guard i < args.count, let s = UInt64(args[i]) else {
            printError("--seed requires a positive integer")
            exit(exitUsageError)
        }
        cliSeed = s

    case "--max-tokens":
        i += 1
        guard i < args.count, let n = Int(args[i]), n > 0 else {
            printError("--max-tokens requires a positive number")
            exit(exitUsageError)
        }
        cliMaxTokens = n

    case "--permissive":
        cliPermissive = true

    case "--model-info":
        mode = "model-info"

    default:
        if args[i].hasPrefix("-") {
            printError("unknown option: \(args[i])")
            exit(exitUsageError)
        }
        prompt = args[i...].joined(separator: " ")
        i = args.count
        continue
    }
    i += 1
}

// MARK: - Dispatch

let sessionOpts = SessionOptions(
    temperature: cliTemperature,
    maxTokens: cliMaxTokens,
    seed: cliSeed,
    permissive: cliPermissive
)

do {
    switch mode {
    case "gui":
        startGUI()

    case "serve":
        let config = ServerConfig(
            host: serverHost,
            port: serverPort,
            cors: serverCORS,
            maxConcurrent: serverMaxConcurrent,
            debug: serverDebug
        )
        try await startServer(config: config)

    case "model-info":
        await printModelInfo()

    case "chat":
        try await chat(systemPrompt: systemPrompt, options: sessionOpts)

    case "stream":
        guard !prompt.isEmpty else {
            printError("no prompt provided")
            exit(exitUsageError)
        }
        try await singlePrompt(prompt, systemPrompt: systemPrompt, stream: true, options: sessionOpts)

    default:
        guard !prompt.isEmpty else {
            printError("no prompt provided")
            exit(exitUsageError)
        }
        try await singlePrompt(prompt, systemPrompt: systemPrompt, stream: false, options: sessionOpts)
    }
} catch {
    printError(error.localizedDescription)
    exit(exitRuntimeError)
}
