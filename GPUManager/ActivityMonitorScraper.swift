import Foundation
#if canImport(AppKit)
import AppKit
import ApplicationServices
import Darwin

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

    public static var executablePath: String {
        Bundle.main.executableURL?.path ?? (CommandLine.arguments.first ?? "<unknown>")
    }

    public static var trustStatusDescription: String {
        let trusted = AXIsProcessTrusted()
        let procPath = executablePath
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

    public func activityMonitorUITreeDiagnostics(maxDepth: Int = 4) -> String {
        do {
            _ = axDiagnostics(prefix: "[UI Tree]")
            let appAX = try activityMonitorAppElement()
            return buildUITreeDiagnostics(of: appAX, maxDepth: maxDepth)
        } catch {
            return "Activity Monitor UI Tree unavailable: \(error.localizedDescription)"
        }
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

        let titles = fetchColumnTitles(from: listContainer)
        let rows = fetchRows(from: listContainer)
        if rows.isEmpty {
            NSLog("[AXHint] Found process list container but no rows")
            dumpSubtree(listContainer, depth: 0, maxDepth: 3)
            return []
        }

        let processes = rows.compactMap { parseProcessRow($0, columnTitles: titles) }
        if processes.isEmpty {
            NSLog("[AXHint] Found \(rows.count) row(s), but none parsed as process stats")
            dumpSubtree(listContainer, depth: 0, maxDepth: 3)
        }

        return processes
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

    private func fetchRows(from container: AXUIElement) -> [AXUIElement] {
        let rowAttributes: [CFString] = [
            kAXRowsAttribute as CFString,
            "AXVisibleRows" as CFString,
            kAXChildrenAttribute as CFString
        ]

        for attribute in rowAttributes {
            guard let elements = attributeArray(container, attribute), !elements.isEmpty else { continue }
            let rows = elements.flatMap { rowCandidates(from: $0) }
            if !rows.isEmpty { return rows }
        }

        return []
    }

    private func rowCandidates(from element: AXUIElement) -> [AXUIElement] {
        let role = axRole(of: element)
        if role == String(kAXRowRole) {
            return [element]
        }

        guard let children = attributeArray(element, kAXChildrenAttribute as CFString) else {
            return role == String(kAXGroupRole) && !rowTextValues(from: element).isEmpty ? [element] : []
        }

        let childRows = children.flatMap { rowCandidates(from: $0) }
        if !childRows.isEmpty { return childRows }

        if role == String(kAXGroupRole), !rowTextValues(from: element).isEmpty {
            return [element]
        }

        return []
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
        let normalizedTitles = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for (index, title) in normalizedTitles.enumerated() {
            if candidates.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) {
                return index
            }
        }

        for (index, title) in normalizedTitles.enumerated() {
            if candidates.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                return index
            }
        }

        return nil
    }

    private func parseProcessRow(_ row: AXUIElement, columnTitles: [String]) -> ScrapedProcess? {
        let values = rowTextValues(from: row)
        guard !values.isEmpty else { return nil }

        if let process = parseProcessRowByColumns(values, columnTitles: columnTitles) {
            return process
        }

        return parseProcessRowByInference(values)
    }

    private func parseProcessRowByColumns(_ values: [String], columnTitles: [String]) -> ScrapedProcess? {
        guard !columnTitles.isEmpty else { return nil }
        let pidIndex = indexOfColumn(in: columnTitles, matchingAnyOf: ["PID", "Process ID"])
        let nameIndex = indexOfColumn(in: columnTitles, matchingAnyOf: ["Process Name", "Name"])
        let gpuIndex = indexOfColumn(in: columnTitles, matchingAnyOf: ["GPU", "GPU Usage", "GPU %", "% GPU"])

        guard let pid = pidIndex.flatMap({ value(at: $0, in: values) }).flatMap(parsePID) else { return nil }
        let name = nameIndex.flatMap { value(at: $0, in: values) } ?? inferProcessName(from: values, pid: pid)
        let gpuUsage = gpuIndex.flatMap { value(at: $0, in: values) }.flatMap(parseGPUUsage)

        return ScrapedProcess(pid: pid, name: name, gpuUsage: gpuUsage)
    }

    private func parseProcessRowByInference(_ values: [String]) -> ScrapedProcess? {
        let pidCandidates = values.compactMap(parsePID)
        guard let pid = pidCandidates.first(where: processExists) ?? pidCandidates.last else { return nil }

        let name = inferProcessName(from: values, pid: pid)
        let gpuUsage = values.compactMap(parseGPUUsage).last
        return ScrapedProcess(pid: pid, name: name, gpuUsage: gpuUsage)
    }

    private func rowTextValues(from element: AXUIElement) -> [String] {
        var values: [String] = []
        collectTextValues(from: element, into: &values)
        return values
    }

    private func collectTextValues(from element: AXUIElement, into values: inout [String]) {
        for attribute in [kAXValueAttribute as CFString, kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString] {
            if let value = axStringAttr(element, attribute) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && values.last != trimmed {
                    values.append(trimmed)
                }
            }
        }

        if let children = attributeArray(element, kAXChildrenAttribute as CFString) {
            for child in children {
                collectTextValues(from: child, into: &values)
            }
        }
    }

    private func value(at index: Int, in values: [String]) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func parsePID(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("%") else { return nil }

        let digitsOnly = trimmed.filter { $0.isNumber }
        guard !digitsOnly.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "," }) else { return nil }
        guard let pid = Int(digitsOnly), pid > 0 else { return nil }
        return pid
    }

    private func processExists(_ pid: Int) -> Bool {
        guard pid <= Int32.max else { return false }
        let result = kill(pid_t(pid), 0)
        return result == 0 || errno == EPERM
    }

    private func parseGPUUsage(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Double(numeric), percent >= 0, percent <= 100 else { return nil }
        return percent / 100.0
    }

    private func inferProcessName(from values: [String], pid: Int) -> String {
        return values.first { value in
            parsePID(value) != pid && parsePID(value) == nil && parseGPUUsage(value) == nil
        } ?? "<unknown>"
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

    private func buildUITreeDiagnostics(of app: AXUIElement, maxDepth: Int) -> String {
        var lines: [String] = []
        if let windows = attributeArray(app, kAXWindowsAttribute as CFString) {
            lines.append("Found \(windows.count) Activity Monitor window(s)")
            for (index, window) in windows.enumerated() {
                let role = axRole(of: window) ?? "<nil>"
                let title = axStringAttr(window, kAXTitleAttribute as CFString) ?? "<no title>"
                lines.append("Window[\(index)]: role=\(role) title=\(title)")
                appendSubtree(window, to: &lines, depth: 1, maxDepth: maxDepth)
            }
        } else {
            lines.append("No Activity Monitor windows attribute")
        }
        return lines.joined(separator: "\n")
    }

    private func appendSubtree(_ element: AXUIElement, to lines: inout [String], depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let role = axRole(of: element) ?? "<nil>"
        let title = axStringAttr(element, kAXTitleAttribute as CFString) ?? ""
        let value = axStringAttr(element, kAXValueAttribute as CFString) ?? ""
        let indent = String(repeating: "  ", count: depth)

        if !title.isEmpty || !value.isEmpty {
            lines.append("\(indent)- role=\(role) title=\(title) value=\(value)")
        } else {
            lines.append("\(indent)- role=\(role)")
        }

        if let children = attributeArray(element, kAXChildrenAttribute as CFString) {
            for child in children {
                appendSubtree(child, to: &lines, depth: depth + 1, maxDepth: maxDepth)
            }
        }
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

