import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices

private var _lastAXTrustLogState: Bool? = nil

public struct ScrapedProcess: Hashable {
    public let pid: Int
    public let name: String
    public let gpuUsage: Double? // 0.0...1.0 if parsed from GPU column
}

public enum ActivityMonitorScraperError: Error, LocalizedError {
    case accessibilityNotEnabled
    case appNotFoundOrLaunched
    case windowOrTableNotFound

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotEnabled:
            return "Accessibility permission is not enabled for this app. Enable it in System Settings > Privacy & Security > Accessibility."
        case .appNotFoundOrLaunched:
            return "Failed to find or launch Activity Monitor."
        case .windowOrTableNotFound:
            return "Could not locate the process table in Activity Monitor."
        }
    }
}

public final class ActivityMonitorScraper {
    public init() {}

    public static var trustStatusDescription: String {
        let trusted = AXIsProcessTrusted()
        let procPath = Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "<unknown>")
        let bundlePath = Bundle.main.bundleURL.path
        return "AX trusted=\(trusted) exec=\(procPath) bundle=\(bundlePath)"
    }

    private func axDiagnostics(prefix: String) -> String {
        let trusted = AXIsProcessTrusted()
        let procPath = Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "<unknown>")
        let bundlePath = Bundle.main.bundleURL.path
        let msg = "\(prefix) AX trusted=\(trusted) exec=\(procPath) bundle=\(bundlePath)"
        // Only NSLog when trust state changes to reduce noise
        if _lastAXTrustLogState != trusted {
            _lastAXTrustLogState = trusted
            NSLog(msg)
        }
        return msg
    }

    // Launch Activity Monitor if not running and return its AXUIElement
    private func activityMonitorAppElement() throws -> AXUIElement {
        _ = axDiagnostics(prefix: "[Scraper]")
        guard AXIsProcessTrusted() else {
            throw ActivityMonitorScraperError.accessibilityNotEnabled
        }

        let ws = NSWorkspace.shared
        let bundleID = "com.apple.ActivityMonitor"

        if let running = ws.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return AXUIElementCreateApplication(running.processIdentifier)
        }

        // Launch it synchronously with a small timeout
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let config = NSWorkspace.OpenConfiguration()
        var launched: NSRunningApplication?
        let sema = DispatchSemaphore(value: 0)
        ws.openApplication(at: url, configuration: config) { app, _ in
            launched = app
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 8)

        guard let app = launched else { throw ActivityMonitorScraperError.appNotFoundOrLaunched }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    @discardableResult
    public func ensureActivityMonitorRunning() throws -> pid_t {
        _ = axDiagnostics(prefix: "[Scraper ensure]")
        let ws = NSWorkspace.shared
        let bundleID = "com.apple.ActivityMonitor"
        if let running = ws.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return running.processIdentifier
        }
        _ = try activityMonitorAppElement()
        // Re-query
        if let running = ws.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return running.processIdentifier
        }
        throw ActivityMonitorScraperError.appNotFoundOrLaunched
    }

    public func scrapeProcesses() throws -> [ScrapedProcess] {
        _ = axDiagnostics(prefix: "[Scrape]")
        let appAX = try activityMonitorAppElement()

        // Find a main window
        guard let mainWindow = firstWindow(of: appAX) else {
            dumpWindows(of: appAX)
            throw ActivityMonitorScraperError.windowOrTableNotFound
        }

        // Find the table/outline inside the window
        let roleCandidates: [String] = [String(kAXTableRole), String(kAXOutlineRole)]
        let container: AXUIElement? = roleCandidates.compactMap { role in
            return findFirstDescendant(of: mainWindow, role: role)
        }.first

        guard let listContainer = container else {
            dumpWindows(of: appAX)
            dumpSubtree(mainWindow, depth: 0, maxDepth: 4)
            NSLog("[AXHint] Could not find AXTable or AXOutline")
            throw ActivityMonitorScraperError.windowOrTableNotFound
        }

        if let r = axRole(of: listContainer), r == String(kAXOutlineRole) {
            NSLog("[AXHint] Using AXOutline as process list container")
        }

        // Fetch column titles and indices
        let titles = fetchColumnTitles(from: listContainer)
        let pidIndex = indexOfColumn(in: titles, matchingAnyOf: ["PID", "Process ID"]) // en variants
        let nameIndex = indexOfColumn(in: titles, matchingAnyOf: ["Process Name", "Name"]) // en variants
        let gpuIndex = indexOfColumn(in: titles, matchingAnyOf: ["GPU", "GPU Usage", "GPU %"]) // best-effort

        // Fetch rows
        guard let rows = attributeArray(listContainer, kAXRowsAttribute as CFString) ?? attributeArray(listContainer, kAXChildrenAttribute as CFString) else { return [] }

        var results: [ScrapedProcess] = []
        results.reserveCapacity(rows.count)

        for row in rows {
            guard let cells = attributeArray(row, kAXChildrenAttribute as CFString) else { continue }

            let name = nameIndex.flatMap { cellStringValue(cells, index: $0) } ?? ""
            let pidStr = pidIndex.flatMap { cellStringValue(cells, index: $0) } ?? ""
            let gpuStr = gpuIndex.flatMap { cellStringValue(cells, index: $0) }

            guard let pid = Int(pidStr) else { continue }

            let gpuUsage: Double?
            if let g = gpuStr {
                let digits = g.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                if let pct = Double(digits) {
                    gpuUsage = max(0, min(1, pct / 100.0))
                } else {
                    gpuUsage = nil
                }
            } else {
                gpuUsage = nil
            }

            results.append(ScrapedProcess(pid: pid, name: name, gpuUsage: gpuUsage))
        }

        return results
    }

    // MARK: - AX Helpers

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        if let windows = attributeArray(app, kAXWindowsAttribute as CFString), let first = windows.first {
            return first
        }
        return nil
    }

    private func attributeArray(_ element: AXUIElement, _ attr: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attr, &value)
        if result == .success, let array = value as? [AXUIElement] {
            return array
        }
        return nil
    }

    private func axRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard result == .success, let value else { return nil }

        // Prefer direct String, otherwise bridge from CFString
        if let s = value as? String {
            return s
        }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        return nil
    }

    private func findFirstDescendant(of element: AXUIElement, role: String) -> AXUIElement? {
        if let currentRole = axRole(of: element), currentRole == role { return element }
        guard let children = attributeArray(element, kAXChildrenAttribute as CFString) else { return nil }
        for child in children {
            if let found = findFirstDescendant(of: child, role: role) {
                return found
            }
        }
        return nil
    }

    private func fetchColumnTitles(from table: AXUIElement) -> [String] {
        var titles: [String] = []
        if let columns = attributeArray(table, kAXColumnsAttribute as CFString) {
            for col in columns {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(col, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let s = titleValue as? String {
                    titles.append(s)
                } else {
                    titles.append("")
                }
            }
        }
        return titles
    }

    private func indexOfColumn(in titles: [String], matchingAnyOf candidates: [String]) -> Int? {
        for (i, t) in titles.enumerated() {
            for c in candidates {
                if t.caseInsensitiveCompare(c) == .orderedSame {
                    return i
                }
            }
        }
        return nil
    }

    private func cellStringValue(_ cells: [AXUIElement], index: Int) -> String? {
        guard cells.indices.contains(index) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(cells[index], kAXValueAttribute as CFString, &value) == .success,
           let s = value as? String {
            return s
        }
        // Fallback: check children for static text values
        if let kids = attributeArray(cells[index], kAXChildrenAttribute as CFString) {
            for k in kids {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(k, kAXValueAttribute as CFString, &v) == .success,
                   let s = v as? String {
                    return s
                }
            }
        }
        return nil
    }

    // MARK: - Diagnostics Helpers

    private func axStringAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr, &value) == .success,
           let s = value as? String {
            return s
        }
        return nil
    }

    private func dumpWindows(of app: AXUIElement) {
        if let windows = attributeArray(app, kAXWindowsAttribute as CFString) {
            NSLog("[AXDump] Found \(windows.count) window(s)")
            for (i, w) in windows.enumerated() {
                let role = axRole(of: w) ?? "<nil>"
                let title = axStringAttr(w, kAXTitleAttribute as CFString) ?? "<no title>"
                NSLog("[AXDump] Window[\(i)]: role=\(role) title=\(title)")
            }
        } else {
            NSLog("[AXDump] No windows attribute")
        }
    }

    private func dumpSubtree(_ element: AXUIElement, depth: Int, maxDepth: Int = 4, prefix: String = "[AXTree]") {
        guard depth <= maxDepth else { return }
        let role = axRole(of: element) ?? "<nil>"
        let title = axStringAttr(element, kAXTitleAttribute as CFString) ?? ""
        var valueStr: String = ""
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            if let s = value as? String { valueStr = s }
        }
        let indent = String(repeating: "  ", count: depth)
        if !title.isEmpty || !valueStr.isEmpty {
            NSLog("\(prefix) \(indent)- role=\(role) title=\(title) value=\(valueStr)")
        } else {
            NSLog("\(prefix) \(indent)- role=\(role)")
        }
        if let children = attributeArray(element, kAXChildrenAttribute as CFString) {
            for child in children {
                dumpSubtree(child, depth: depth + 1, maxDepth: maxDepth, prefix: prefix)
            }
        }
    }
}
#endif

