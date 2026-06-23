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

    enum CodingKeys: String, CodingKey {
        case title
        case keyword
        case expansion
        case notes
        case hidden
    }

    init(title: String, expansion: String, notes: String = "", hidden: Bool = false) {
        self.title = title
        self.expansion = expansion
        self.notes = notes
        self.hidden = hidden
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(expansion, forKey: .expansion)
        try container.encode(notes, forKey: .notes)
        if hidden {
            try container.encode(hidden, forKey: .hidden)
        }
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
            result.append(Snippet(title: label, expansion: item.expansion, notes: item.notes, hidden: item.hidden))
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
                let notes = jsonStringValue(row["notes"]) ?? ""
                let hidden = (row["hidden"] as? Bool) ?? false
                return Snippet(title: resolvedTitle, expansion: expansion, notes: notes, hidden: hidden)
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
            "snippets": payload.snippets.map { ["title": $0.title, "expansion": $0.expansion, "notes": $0.notes, "hidden": $0.hidden] },
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
