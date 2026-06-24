import ApplicationServices
import Cocoa
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

let scriptPath = CommandLine.arguments[0]
let scriptURL = URL(fileURLWithPath: scriptPath)
let scriptDirectory = scriptURL.deletingLastPathComponent().path
let resourcesDir = scriptDirectory + "/../Resources"
let webDir = resourcesDir + "/web"
let indexPath = webDir + "/index.html"

var globalWebView: WKWebView?
var globalCoordinator: WebViewCoordinator?
weak var globalMenuController: AppDelegate?

struct Snippet: Codable, Hashable {
    var title: String
    var expansion: String
    var notes: String
    var hidden: Bool
    var subSnippets: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case keyword
        case expansion
        case notes
        case hidden
        case subSnippets
    }

    init(title: String, expansion: String, notes: String = "", hidden: Bool = false, subSnippets: [String] = []) {
        self.title = title
        self.expansion = expansion
        self.notes = notes
        self.hidden = hidden
        self.subSnippets = subSnippets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let trimmedTitle = (try container.decodeIfPresent(String.self, forKey: .title))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyKeyword = (try container.decodeIfPresent(String.self, forKey: .keyword))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        }
        else if !legacyKeyword.isEmpty {
            title = legacyKeyword
        }
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "Missing or empty title (or legacy keyword)."
            )
        }
        expansion = try container.decode(String.self, forKey: .expansion)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        subSnippets = (try container.decodeIfPresent([String].self, forKey: .subSnippets) ?? [])
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(expansion, forKey: .expansion)
        try container.encode(notes, forKey: .notes)
        if hidden {
            try container.encode(hidden, forKey: .hidden)
        }
        if !subSnippets.isEmpty {
            try container.encode(subSnippets, forKey: .subSnippets)
        }
    }
}

struct AppStatePayload {
    var snippets: [Snippet]
    var hasAccessibilityPermission: Bool
    var storagePath: String
    var opencodePath: String
}

func parseJSON(_ jsonString: String) -> [String: Any]? {
    guard let data = jsonString.data(using: .utf8) else {
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// JSONSerialization uses NSArray/NSDictionary; direct `as? [[String: Any]]` often fails on nested objects.
func jsonArrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
    guard let array = value as? [Any] else {
        return nil
    }
    let rows: [[String: Any]] = array.compactMap { item in
        if let dict = item as? [String: Any] {
            return dict
        }
        guard let untyped = item as? [AnyHashable: Any] else {
            return nil
        }
        var out: [String: Any] = [:]
        for (key, val) in untyped {
            if let stringKey = key as? String {
                out[stringKey] = val
            }
        }
        return out
    }
    return rows
}

func jsonStringAnyDictionary(_ value: Any?) -> [String: Any]? {
    if let dict = value as? [String: Any] {
        return dict
    }
    guard let untyped = value as? [AnyHashable: Any] else {
        return nil
    }
    var out: [String: Any] = [:]
    for (key, val) in untyped {
        if let stringKey = key as? String {
            out[stringKey] = val
        }
    }
    return out
}

func jsonStringValue(_ value: Any?) -> String? {
    switch value {
    case let s as String:
        return s
    case let ns as NSString:
        return ns as String
    default:
        return nil
    }
}

func stringifyJSON(_ object: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
        return nil
    }
    return String(data: data, encoding: .utf8)
}

func jsQuotedString(_ text: String) -> String {
    var out = "'"
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "'": out += "\\'"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                out += String(format: "\\u%04x", scalar.value)
            }
            else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "'"
    return out
}

func normalizedSubSnippets(_ raw: Any?) -> [String] {
    guard let array = raw as? [Any] else {
        return []
    }
    return array.compactMap { item -> String? in
        guard let text = jsonStringValue(item) else {
            return nil
        }
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

func statePayloadDictionary(_ payload: AppStatePayload) -> [String: Any] {
    [
        "snippets": payload.snippets.map {
            [
                "title": $0.title,
                "expansion": $0.expansion,
                "notes": $0.notes,
                "hidden": $0.hidden,
                "subSnippets": $0.subSnippets,
            ]
        },
        "hasAccessibilityPermission": payload.hasAccessibilityPermission,
        "storagePath": payload.storagePath,
        "opencodePath": payload.opencodePath,
    ]
}

func sendEventToJs(eventName: String, data: Any?, errorEventName: String) {
    let detailJSON: String
    if let data {
        guard let json = stringifyJSON(data) else {
            sendJsError(errorEventName: errorEventName, message: "Native response could not be encoded.")
            return
        }
        detailJSON = json
    }
    else {
        detailJSON = "null"
    }
    let js = "window.dispatchEvent(new CustomEvent('\(eventName)', { detail: \(detailJSON) }));"
    globalWebView?.evaluateJavaScript(js) { _, error in
        if let error {
            let errJs = "window.dispatchEvent(new CustomEvent('\(errorEventName)', { detail: \(jsQuotedString(error.localizedDescription)) }));"
            globalWebView?.evaluateJavaScript(errJs, completionHandler: nil)
        }
    }
}

func sendJsError(errorEventName: String, message: String) {
    let errJs = "window.dispatchEvent(new CustomEvent('\(errorEventName)', { detail: \(jsQuotedString(message)) }));"
    globalWebView?.evaluateJavaScript(errJs, completionHandler: nil)
}

/// `AXIsProcessTrusted`/`AXIsProcessTrustedWithOptions` must run on the main thread for a correct result.
/// WKScriptMessageHandler runs off the main thread, so naive checks mis-report "Not granted".
func evaluateAccessibilityTrusted(promptUser: Bool) -> Bool {
    let runCheck: () -> Bool = {
        if promptUser {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
    if Thread.isMainThread {
        return runCheck()
    }
    var trusted = false
    DispatchQueue.main.sync {
        trusted = runCheck()
    }
    return trusted
}

final class SnippetStore {
    private let snippetsURL: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "devxpander.snippet-store")
    private var snippets: [Snippet] = []

    init() {
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("Devxpander", isDirectory: true)
        if !fileManager.fileExists(atPath: appDir.path) {
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        snippetsURL = appDir.appendingPathComponent("snippets.json")
        snippets = loadFromDisk()
    }

    func storagePath() -> String {
        snippetsURL.path
    }

    func getSnippets() -> [Snippet] {
        queue.sync {
            snippets
        }
    }

    func setSnippets(_ incoming: [Snippet]) throws -> [Snippet] {
        let normalized = normalizedSnippets(incoming)
        return try queue.sync {
            snippets = normalized
            try persistLocked(snippets)
            return snippets
        }
    }

    func importFrom(url: URL) throws -> [Snippet] {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Snippet].self, from: data)
        return try setSnippets(decoded)
    }

    func exportTo(url: URL) throws {
        let current = getSnippets()
        let data = try JSONEncoder.prettyPrinted.encode(current)
        try data.write(to: url, options: [.atomic])
    }

    private func normalizedSnippets(_ input: [Snippet]) -> [Snippet] {
        var seen = Set<String>()
        var result = [Snippet]()
        for item in input {
            let label = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                continue
            }
            let lower = label.lowercased()
            if seen.contains(lower) {
                continue
            }
            seen.insert(lower)
            result.append(Snippet(title: label, expansion: item.expansion, notes: item.notes, hidden: item.hidden, subSnippets: item.subSnippets))
        }
        return result
    }

    private func loadFromDisk() -> [Snippet] {
        guard fileManager.fileExists(atPath: snippetsURL.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: snippetsURL) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else {
            return []
        }
        return normalizedSnippets(decoded)
    }

    private func persistLocked(_ snapshots: [Snippet]) throws {
        let data = try JSONEncoder.prettyPrinted.encode(snapshots)
        try data.write(to: snippetsURL, options: [.atomic])
    }
}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum AIImprover {
    private static let model = "opencode-go/deepseek-v4-pro"

    static func improve(text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        You are a prompt optimization assistant. Your job is to take a user's \
        raw prompt and rewrite it to be clearer, simpler, and more effective.

        When I give you a prompt, do the following:

        1. Fix all grammar, spelling, and punctuation errors.
        2. Simplify the wording so it's easy to understand—remove jargon, \
           redundancy, and vague phrasing.
        3. Make the intent and desired output explicit and unambiguous.
        4. Preserve the original meaning and goal. Do not add new requirements \
           the user didn't intend.
        5. Structure it logically (use steps, bullets, or sections if helpful).

        Return ONLY the improved prompt text — no preamble, no quotes, no markdown fences.

        Prompt to improve:
        \(text)
        """
        runOpencode(prompt: prompt, completion: completion)
    }

    private static func runOpencode(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()

            let environment = buildChildEnvironment()
            task.environment = environment

            if let resolvedURL = resolveOpencode(environment: environment) {
                task.executableURL = resolvedURL
                task.arguments = ["run", "-m", model, "--format", "json", prompt]
            }
            else {
                task.launchPath = "/usr/bin/env"
                task.arguments = ["opencode", "run", "-m", model, "--format", "json", prompt]
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            do {
                try task.run()
            }
            catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            let timeout = 120.0
            let deadline = Date().addingTimeInterval(timeout)
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.global(qos: .utility).async {
                while task.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if task.isRunning {
                    task.terminate()
                }
                semaphore.signal()
            }

            task.waitUntilExit()
            semaphore.wait()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: outData, encoding: .utf8) ?? ""
            let improved = extractText(from: raw)

            if task.terminationStatus != 0 || improved.isEmpty {
                var message = task.terminationStatus != 0
                    ? "opencode exited with status \(task.terminationStatus)"
                    : "AI returned no text."
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                    message += ": \(errStr)"
                }
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "AIImprover", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(improved))
            }
        }
    }

    /// Parses newline-delimited JSON emitted by `opencode run --format json` and
    /// concatenates every `{"type":"text", "part":{"text":"…"}}` fragment.
    private static func extractText(from raw: String) -> String {
        var pieces: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "text",
                  let part = object["part"] as? [String: Any],
                  let text = part["text"] as? String
            else {
                continue
            }
            pieces.append(text)
        }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var cachedOpencodeURL: URL?
    private static let cacheLock = NSLock()

    /// Builds an environment with PATH extended to cover common installation
    /// directories that GUI apps don't inherit (Homebrew, npm, cargo, go, etc.).
    private static func buildChildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "\(home)/go/bin",
            "\(home)/.asdf/shims",
        ]
        environment["PATH"] = (extraPaths + [existingPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }

    /// Resolves the real path of the `opencode` binary using multiple strategies:
    ///   1. Cached result from a previous call.
    ///   2. User-configured path (Settings).
    ///   3. Direct search of expanded PATH directories.
    ///   4. Login shell (`zsh -l` / `bash -l`) which sources the user's profile,
    ///      discovering binaries managed by version managers (nvm, fnm, asdf, …).
    ///
    /// Launching the resolved binary directly avoids repeated macOS TCC prompts
    /// that occur when going through `/usr/bin/env`.
    private static func resolveOpencode(environment: [String: String]) -> URL? {
        cacheLock.lock()
        if let cached = cachedOpencodeURL, FileManager.default.isExecutableFile(atPath: cached.path) {
            cacheLock.unlock()
            return cached
        }
        cachedOpencodeURL = nil
        cacheLock.unlock()

        let userPath = settings.opencodePath
        if !userPath.isEmpty {
            let expanded = NSString(string: userPath).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
                cacheResolved(url)
                return url
            }
        }

        if let url = searchPath(for: "opencode", environment: environment) {
            cacheResolved(url)
            return url
        }

        for shell in ["/bin/zsh", "/bin/bash"] {
            if let url = resolveViaLoginShell(shell) {
                cacheResolved(url)
                return url
            }
        }

        return nil
    }

    static func clearCachedPath() {
        cacheLock.lock()
        cachedOpencodeURL = nil
        cacheLock.unlock()
    }

    private static func searchPath(for name: String, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            guard fm.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    /// Runs a login shell (`shell -l -c "command -v opencode"`) to discover the
    /// binary via the user's full profile — handles nvm, fnm, asdf, Volta, etc.
    /// The shell itself is an Apple-signed system binary, so this does NOT trigger
    /// TCC prompts (it never executes `opencode`, only resolves its path).
    private static func resolveViaLoginShell(_ shell: String) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return nil
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-l", "-c", "command -v opencode 2>/dev/null"]
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return nil
            }
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            let path = raw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty }) ?? ""
            guard !path.isEmpty else {
                return nil
            }
            let expanded = NSString(string: path).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded) else {
                return nil
            }
            return URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        }
        catch {
            return nil
        }
    }

    private static func cacheResolved(_ url: URL) {
        cacheLock.lock()
        cachedOpencodeURL = url
        cacheLock.unlock()
    }
}

enum ClipboardInjector {
    /// macOS virtual key codes
    private static let kVK_Command: CGKeyCode = 0x37
    private static let kVK_ANSI_V: CGKeyCode = 0x09

    static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard content
        let oldString = pasteboard.string(forType: .string)
        var oldData: Data?
        if let oldString = oldString {
            oldData = oldString.data(using: .utf8)
        }

        // 2. Copy snippet to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Simulate Cmd+V
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: true)!
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: true)!
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_ANSI_V, keyDown: false)!
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: kVK_Command, keyDown: false)!

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)

        // 4. Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let oldData = oldData {
                pasteboard.setData(oldData, forType: .string)
            }
        }
    }
}

final class Settings {
    private let defaults = UserDefaults.standard
    private let opencodePathKey = "opencodePath"

    var opencodePath: String {
        get { defaults.string(forKey: opencodePathKey) ?? "" }
        set { defaults.set(newValue, forKey: opencodePathKey) }
    }

    func clearOpencodePath() {
        defaults.removeObject(forKey: opencodePathKey)
    }
}

let settings = Settings()

final class AppController {
    private let store = SnippetStore()
    var onStateChange: (() -> Void)?

    func makePayload() -> AppStatePayload {
        AppStatePayload(
            snippets: store.getSnippets(),
            hasAccessibilityPermission: evaluateAccessibilityTrusted(promptUser: false),
            storagePath: store.storagePath(),
            opencodePath: settings.opencodePath
        )
    }

    func snippets() -> [Snippet] {
        store.getSnippets()
    }

    func saveSnippets(_ snippets: [Snippet]) throws -> [Snippet] {
        let saved = try store.setSnippets(snippets)
        notifyStateChanged()
        return saved
    }

    func importSnippets(from url: URL) throws -> [Snippet] {
        let imported = try store.importFrom(url: url)
        notifyStateChanged()
        return imported
    }

    func exportSnippets(to url: URL) throws {
        try store.exportTo(url: url)
    }

    func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        evaluateAccessibilityTrusted(promptUser: prompt)
    }

    func insertSnippet(_ snippet: Snippet, targetApp: NSRunningApplication?) -> String? {
        if !evaluateAccessibilityTrusted(promptUser: false) {
            return "Accessibility permission is required to insert snippets."
        }
        guard let targetApp else {
            return nil
        }
        guard targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        targetApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ClipboardInjector.pasteText(snippet.expansion)
        }
        return nil
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async {
            self.onStateChange?()
            globalCoordinator?.broadcastStateUpdate()
        }
    }
}

let appController = AppController()

final class WebViewCoordinator: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "swiftBridge" else {
            return
        }
        let json: [String: Any]?
        if let jsonString = message.body as? String {
            json = parseJSON(jsonString)
        }
        else if let dictBody = jsonStringAnyDictionary(message.body) {
            json = dictBody
        }
        else {
            return
        }
        guard let json,
              let action = jsonStringValue(json["action"]),
              let data = jsonStringAnyDictionary(json["data"]),
              let eventName = jsonStringValue(data["_eventName"]),
              let errorEventName = jsonStringValue(data["_errorEventName"]) else {
            return
        }

        if action == "get-app-state" {
            sendEventToJs(
                eventName: eventName,
                data: statePayloadDictionary(appController.makePayload()),
                errorEventName: errorEventName
            )
            return
        }

        if action == "request-accessibility" {
            let granted = appController.ensureAccessibilityPermission(prompt: true)
            sendEventToJs(
                eventName: eventName,
                data: ["granted": granted],
                errorEventName: errorEventName
            )
            globalMenuController?.rebuildMenu()
            return
        }

        if action == "set-snippets" {
            guard let raw = jsonArrayOfDictionaries(data["snippets"]) else {
                sendJsError(errorEventName: errorEventName, message: "Missing snippets")
                return
            }
            let snippets: [Snippet] = raw.compactMap { row in
                let trimmedTitle = (jsonStringValue(row["title"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let legacy = (jsonStringValue(row["keyword"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedTitle = (!trimmedTitle.isEmpty) ? trimmedTitle : legacy
                guard !resolvedTitle.isEmpty,
                      let expansion = jsonStringValue(row["expansion"]) else {
                    return nil
                }
                let notes = jsonStringValue(row["notes"]) ?? ""
                let hidden = (row["hidden"] as? Bool) ?? false
                let subSnippets = normalizedSubSnippets(row["subSnippets"])
                return Snippet(title: resolvedTitle, expansion: expansion, notes: notes, hidden: hidden, subSnippets: subSnippets)
            }
            do {
                _ = try appController.saveSnippets(snippets)
                sendEventToJs(
                    eventName: eventName,
                    data: statePayloadDictionary(appController.makePayload()),
                    errorEventName: errorEventName
                )
            }
            catch {
                sendJsError(errorEventName: errorEventName, message: "Failed to save snippets: \(error.localizedDescription)")
            }
            return
        }

        if action == "export-snippets" {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType.json]
            panel.nameFieldStringValue = "devxpander-snippets.json"
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    do {
                        try appController.exportSnippets(to: url)
                        sendEventToJs(eventName: eventName, data: ["path": url.path], errorEventName: errorEventName)
                    }
                    catch {
                        sendJsError(errorEventName: errorEventName, message: "Export failed: \(error.localizedDescription)")
                    }
                }
                else {
                    sendEventToJs(eventName: eventName, data: nil, errorEventName: errorEventName)
                }
            }
            return
        }

        if action == "ai-improve" {
            guard let text = jsonStringValue(data["text"]), !text.isEmpty else {
                sendJsError(errorEventName: errorEventName, message: "Missing snippet text to improve.")
                return
            }
            AIImprover.improve(text: text) { result in
                switch result {
                case .success(let improved):
                    sendEventToJs(
                        eventName: eventName,
                        data: ["improved": improved],
                        errorEventName: errorEventName
                    )
                case .failure(let error):
                    sendJsError(errorEventName: errorEventName, message: error.localizedDescription)
                }
            }
            return
        }

        if action == "set-opencode-path" {
            if let raw = jsonStringValue(data["path"])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                let expanded = NSString(string: raw).expandingTildeInPath
                if FileManager.default.isExecutableFile(atPath: expanded) {
                    settings.opencodePath = expanded
                    AIImprover.clearCachedPath()
                    sendEventToJs(
                        eventName: eventName,
                        data: statePayloadDictionary(appController.makePayload()),
                        errorEventName: errorEventName
                    )
                }
                else {
                    sendJsError(errorEventName: errorEventName, message: "Not a valid executable: \(expanded)")
                }
            }
            else {
                sendJsError(errorEventName: errorEventName, message: "Missing path.")
            }
            return
        }

        if action == "browse-opencode-path" {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Select the opencode executable"
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    let path = url.resolvingSymlinksInPath().path
                    if FileManager.default.isExecutableFile(atPath: path) {
                        settings.opencodePath = path
                        AIImprover.clearCachedPath()
                        sendEventToJs(
                            eventName: eventName,
                            data: statePayloadDictionary(appController.makePayload()),
                            errorEventName: errorEventName
                        )
                    }
                    else {
                        sendJsError(errorEventName: errorEventName, message: "Selected file is not executable.")
                    }
                }
                else {
                    sendEventToJs(eventName: eventName, data: nil, errorEventName: errorEventName)
                }
            }
            return
        }

        if action == "reset-opencode-path" {
            settings.clearOpencodePath()
            AIImprover.clearCachedPath()
            sendEventToJs(
                eventName: eventName,
                data: statePayloadDictionary(appController.makePayload()),
                errorEventName: errorEventName
            )
            return
        }

        if action == "import-snippets" {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType.json]
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    do {
                        _ = try appController.importSnippets(from: url)
                        sendEventToJs(
                            eventName: eventName,
                            data: statePayloadDictionary(appController.makePayload()),
                            errorEventName: errorEventName
                        )
                    }
                    catch {
                        sendJsError(errorEventName: errorEventName, message: "Import failed: \(error.localizedDescription)")
                    }
                }
                else {
                    sendEventToJs(eventName: eventName, data: nil, errorEventName: errorEventName)
                }
            }
            return
        }

        sendJsError(errorEventName: errorEventName, message: "Unknown native action: \(action)")
    }

    func broadcastStateUpdate() {
        let eventName = "swift:state-updated"
        let js = """
        window.dispatchEvent(new CustomEvent('\(eventName)', { detail: \(stringifyJSON(statePayloadDictionary(appController.makePayload())) ?? "null") }));
        """
        globalWebView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

struct WebView: NSViewRepresentable {
    func makeCoordinator() -> WebViewCoordinator {
        let coordinator = WebViewCoordinator()
        globalCoordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        configuration.userContentController.add(context.coordinator, name: "swiftBridge")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let payload = appController.makePayload()
        let payloadJSON = stringifyJSON(statePayloadDictionary(payload)) ?? "null"
        let initScript = WKUserScript(
            source: "window.__devxpanderInitialState__ = \(payloadJSON);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(initScript)

        if #available(macOS 11.0, *) {
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            configuration.defaultWebpagePreferences = preferences
        }
        else {
            configuration.preferences.javaScriptEnabled = true
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(macOS 10.14, *) {
            webView.appearance = NSAppearance(named: .darkAqua)
        }
        if FileManager.default.fileExists(atPath: indexPath) {
            let indexURL = URL(fileURLWithPath: indexPath)
            let readAccess = URL(fileURLWithPath: webDir, isDirectory: true)
            webView.loadFileURL(indexURL, allowingReadAccessTo: readAccess)
        }
        else {
            webView.loadHTMLString("<h3>Missing UI at \(indexPath)</h3>", baseURL: nil)
        }
        globalWebView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

extension NSApplication {
    func runDevxpander() {
        let appDelegate = AppDelegate()
        setActivationPolicy(.regular)
        delegate = appDelegate
        run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static func loadMenuBarTemplateImage() -> NSImage? {
        guard let rp = Bundle.main.resourcePath else {
            return nil
        }
        let retinaPath = rp + "/MenuBarTemplate@2x.png"
        let standardPath = rp + "/MenuBarTemplate.png"
        let prefersRetinaPath = NSScreen.main?.backingScaleFactor ?? 1 > 1.25
        let orderedCandidates: [String]
        if prefersRetinaPath {
            orderedCandidates = [retinaPath, standardPath]
        }
        else {
            orderedCandidates = [standardPath, retinaPath]
        }

        let fm = FileManager.default
        for path in orderedCandidates where fm.fileExists(atPath: path) {
            guard let image = NSImage(contentsOfFile: path) else {
                continue
            }
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusMenu = NSMenu()
    private var window: NSWindow?
    private var lastTargetApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalMenuController = self
        appController.onStateChange = { [weak self] in
            self?.rebuildMenu()
        }
        setupMainMenu()
        configureStatusItem()
        rebuildMenu()
        openManager()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openManager()
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Devxpander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        rebuildMenu()
        globalCoordinator?.broadcastStateUpdate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        rebuildMenu()
        globalCoordinator?.broadcastStateUpdate()
    }

    func configureStatusItem() {
        if let button = statusItem.button {
            if let icon = Self.compositeMenuBarIcon() {
                button.image = icon
                button.imagePosition = .imageOnly
                button.toolTip = "Devxpander"
            }
            else if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Devxpander")
                button.imagePosition = .imageOnly
                button.toolTip = "Devxpander"
            }
            else {
                button.title = "DX"
                button.toolTip = "Devxpander"
            }
        }
        statusMenu.delegate = self
        // We manage item enable-state ourselves (submenus rely on parent items staying enabled).
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
    }

    private static func compositeMenuBarIcon() -> NSImage? {
        guard let robotTemplate = loadMenuBarTemplateImage() else {
            return nil
        }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size, flipped: false) { _ in
            robotTemplate.draw(in: NSRect(origin: .zero, size: size),
                               from: NSRect(origin: .zero, size: size),
                               operation: .sourceOver, fraction: 1.0)
            NSColor.black.setFill()
            let eyeSize: CGFloat = 2.5
            NSBezierPath(ovalIn: NSRect(x: 4.25, y: 11.25, width: eyeSize, height: eyeSize)).fill()
            NSBezierPath(ovalIn: NSRect(x: 8.25, y: 11.25, width: eyeSize, height: eyeSize)).fill()
            if #available(macOS 10.15, *) {
                NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5.5, width: 5.0, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
            } else {
                NSBezierPath(rect: NSRect(x: 4.5, y: 5.5, width: 5.0, height: 2.5)).fill()
            }
            return true
        }
        return composite
    }

    func rebuildMenu() {
        statusMenu.removeAllItems()

        let manageItem = NSMenuItem(title: "Manage Snippets...", action: #selector(openManager), keyEquivalent: "")
        manageItem.target = self
        statusMenu.addItem(manageItem)

        let permissionTitle = appController.ensureAccessibilityPermission(prompt: false)
            ? "Accessibility: Granted"
            : "Grant Accessibility Permission..."
        let permissionItem = NSMenuItem(title: permissionTitle, action: #selector(requestAccessibilityPermission), keyEquivalent: "")
        permissionItem.target = self
        statusMenu.addItem(permissionItem)

        statusMenu.addItem(NSMenuItem.separator())

        let snippets = appController.snippets()
        let visibleSnippets = snippets.filter { !$0.hidden }
        if visibleSnippets.isEmpty {
            let emptyItem = NSMenuItem(title: "No snippets yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            statusMenu.addItem(emptyItem)
        }
        else {
            for snippet in visibleSnippets {
                let menuTitle = "\(snippet.title)  →  \(shortPreview(snippet.expansion))"
                let item = NSMenuItem(title: menuTitle, action: #selector(insertSnippetFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = snippet
                item.isEnabled = true

                let collapsedSubSnippets = snippet.subSnippets.filter { !$0.isEmpty }
                if !collapsedSubSnippets.isEmpty {
                    // First item of submenu = parent snippet; remaining = sub-snippets.
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false

                    let parentItem = NSMenuItem(title: "\(snippet.title)  →  \(shortPreview(snippet.expansion))", action: #selector(insertSnippetFromMenu(_:)), keyEquivalent: "")
                    parentItem.target = self
                    parentItem.representedObject = snippet
                    parentItem.isEnabled = true
                    submenu.addItem(parentItem)
                    submenu.addItem(NSMenuItem.separator())

                    for sub in collapsedSubSnippets {
                        let subItem = NSMenuItem(title: shortPreview(sub), action: #selector(insertSnippetFromMenu(_:)), keyEquivalent: "")
                        subItem.target = self
                        subItem.representedObject = Snippet(title: snippet.title, expansion: sub, notes: "", hidden: false, subSnippets: [])
                        subItem.isEnabled = true
                        submenu.addItem(subItem)
                    }

                    item.submenu = submenu
                    // Keep the action set (autoenables is off); an enabled item with a submenu
                    // still shows the secondary menu on hover. We retain representedObject so
                    // a click on the parent row that doesn't traverse the submenu still inserts.
                    item.isEnabled = true
                }

                statusMenu.addItem(item)
            }
        }

        statusMenu.addItem(NSMenuItem.separator())

        let importItem = NSMenuItem(title: "Import Snippets...", action: #selector(importFromMenu), keyEquivalent: "")
        importItem.target = self
        statusMenu.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export Snippets...", action: #selector(exportFromMenu), keyEquivalent: "")
        exportItem.target = self
        statusMenu.addItem(exportItem)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Devxpander", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let current = NSWorkspace.shared.frontmostApplication
        if let current, current.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastTargetApp = current
        }
    }

    @objc func openManager() {
        if window == nil {
            createManagerWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func requestAccessibilityPermission() {
        _ = appController.ensureAccessibilityPermission(prompt: true)
        rebuildMenu()
        globalCoordinator?.broadcastStateUpdate()
    }

    @objc func insertSnippetFromMenu(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? Snippet else {
            return
        }
        if let error = appController.insertSnippet(snippet, targetApp: lastTargetApp) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot insert snippet"
            alert.informativeText = error
            alert.runModal()
        }
    }

    @objc func importFromMenu() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    _ = try appController.importSnippets(from: url)
                }
                catch {
                    self.showErrorAlert(title: "Import failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc func exportFromMenu() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "devxpander-snippets.json"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try appController.exportSnippets(to: url)
                }
                catch {
                    self.showErrorAlert(title: "Export failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func createManagerWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Devxpander - Snippet Manager"
        window.center()
        window.minSize = NSSize(width: 1000, height: 520)
        window.maxSize = NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)
        if #available(macOS 10.14, *) {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.contentView = NSHostingView(rootView: WebView().frame(maxWidth: .infinity, maxHeight: .infinity))
        window.delegate = self
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func shortPreview(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 36 {
            return trimmed
        }
        return String(trimmed.prefix(33)) + "..."
    }
}

NSApplication.shared.runDevxpander()
