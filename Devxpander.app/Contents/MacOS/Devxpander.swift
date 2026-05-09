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

    enum CodingKeys: String, CodingKey {
        case title
        case keyword
        case expansion
    }

    init(title: String, expansion: String) {
        self.title = title
        self.expansion = expansion
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(expansion, forKey: .expansion)
    }
}

struct AppStatePayload {
    var snippets: [Snippet]
    var hasAccessibilityPermission: Bool
    var storagePath: String
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
            let escaped = error.localizedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let errJs = "window.dispatchEvent(new CustomEvent('\(errorEventName)', { detail: '\(escaped)' }));"
            globalWebView?.evaluateJavaScript(errJs, completionHandler: nil)
        }
    }
}

func sendJsError(errorEventName: String, message: String) {
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
    let errJs = "window.dispatchEvent(new CustomEvent('\(errorEventName)', { detail: '\(escaped)' }));"
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
        var result: [Snippet] = []
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
            result.append(Snippet(title: label, expansion: item.expansion))
        }
        return result.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
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

enum TextInjector {
    private static let marker: Int64 = 0x44565850

    static func postText(_ text: String) {
        let collapsedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard !collapsedLineEndings.isEmpty else {
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }
        func postCharacters(_ utf16Units: [UInt16]) {
            guard !utf16Units.isEmpty else {
                return
            }
            var buffer = utf16Units
            buffer.withUnsafeMutableBufferPointer { uniBuffer in
                guard let uniPtr = uniBuffer.baseAddress else {
                    return
                }
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return
                }
                let length = uniBuffer.count
                keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: uniPtr)
                keyUp.keyboardSetUnicodeString(stringLength: length, unicodeString: uniPtr)
                keyDown.setIntegerValueField(.eventSourceUserData, value: marker)
                keyUp.setIntegerValueField(.eventSourceUserData, value: marker)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }

        let fullRange = collapsedLineEndings.startIndex..<collapsedLineEndings.endIndex
        collapsedLineEndings.enumerateSubstrings(in: fullRange, options: [.byComposedCharacterSequences]) { substring, _, _, _ in
            guard let cluster = substring, !cluster.isEmpty else {
                return
            }
            postCharacters(Array(cluster.utf16))
        }
    }
}

final class AppController {
    private let store = SnippetStore()
    var onStateChange: (() -> Void)?

    func makePayload() -> AppStatePayload {
        AppStatePayload(
            snippets: store.getSnippets(),
            hasAccessibilityPermission: evaluateAccessibilityTrusted(promptUser: false),
            storagePath: store.storagePath()
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
        if let targetApp {
            targetApp.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            TextInjector.postText(snippet.expansion)
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
                data: payloadDictionary(appController.makePayload()),
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
                return Snippet(title: resolvedTitle, expansion: expansion)
            }
            do {
                _ = try appController.saveSnippets(snippets)
                sendEventToJs(
                    eventName: eventName,
                    data: payloadDictionary(appController.makePayload()),
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
                            data: self.payloadDictionary(appController.makePayload()),
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
        window.dispatchEvent(new CustomEvent('\(eventName)', { detail: \(stringifyJSON(payloadDictionary(appController.makePayload())) ?? "null") }));
        """
        globalWebView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func payloadDictionary(_ payload: AppStatePayload) -> [String: Any] {
        [
            "snippets": payload.snippets.map { ["title": $0.title, "expansion": $0.expansion] },
            "hasAccessibilityPermission": payload.hasAccessibilityPermission,
            "storagePath": payload.storagePath,
        ]
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

        if #available(macOS 11.0, *) {
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            configuration.defaultWebpagePreferences = preferences
        }
        else {
            configuration.preferences.javaScriptEnabled = true
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
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
        setActivationPolicy(.accessory)
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
        configureStatusItem()
        rebuildMenu()
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
            if let custom = Self.loadMenuBarTemplateImage() {
                button.image = custom
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
        statusItem.menu = statusMenu
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
        if snippets.isEmpty {
            let emptyItem = NSMenuItem(title: "No snippets yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            statusMenu.addItem(emptyItem)
        }
        else {
            for snippet in snippets {
                let menuTitle = "\(snippet.title)  →  \(shortPreview(snippet.expansion))"
                let item = NSMenuItem(title: menuTitle, action: #selector(insertSnippetFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = snippet
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
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Devxpander - Snippet Manager"
        window.center()
        window.minSize = NSSize(width: 620, height: 520)
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
