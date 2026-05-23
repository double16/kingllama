import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Private API Loader Helpers

private let DiagTriedPathNote = Notification.Name("DiagTriedPath")
private let DiagResolvedPathNote = Notification.Name("DiagResolvedPath")
private let DiagTriedSymbolNote = Notification.Name("DiagTriedSymbol")
private let DiagResolvedSymbolNote = Notification.Name("DiagResolvedSymbol")

private struct DynamicSymbol<T> {
    let handle: UnsafeMutableRawPointer
    let symbol: T
    let path: String
    let name: String
}

@inline(__always)
private func openFirstAvailable(paths: [String]) -> (handle: UnsafeMutableRawPointer, path: String)? {
    for p in paths {
        NotificationCenter.default.post(name: DiagTriedPathNote, object: p)
        if let h = dlopen(p, RTLD_LAZY | RTLD_LOCAL) {
            NotificationCenter.default.post(name: DiagResolvedPathNote, object: p)
            return (h, p)
        } else if let err = dlerror() {
            NSLog("dlopen failed for \(p): \(String(cString: err))")
        } else {
            NSLog("dlopen failed for \(p): unknown error")
        }
    }
    return nil
}

@inline(__always)
private func loadFirstSymbol<T>(handle: UnsafeMutableRawPointer, handlePath: String, candidates: [String], as type: T.Type) -> DynamicSymbol<T>? {
    for name in candidates {
        NotificationCenter.default.post(name: DiagTriedSymbolNote, object: name)
        if let sym = dlsym(handle, name) {
            NotificationCenter.default.post(name: DiagResolvedSymbolNote, object: name)
            return DynamicSymbol(handle: handle, symbol: unsafeBitCast(sym, to: T.self), path: handlePath, name: name)
        } else {
            NSLog("dlsym failed in \(handlePath): \(name) not found")
        }
    }
    return nil
}

// C-compatible declarations for dynamic symbols
private struct RawMTLProcessListEntry {
    var pid: UInt32
    var taskRepresentation: UInt32
    var gpuUsage: Double
    var deviceRef: UInt64
}

private typealias MTLGetEntryCountFn = @convention(c) () -> UInt32
private typealias MTLGetEntriesFn = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UInt32

// MARK: - MTLProcessList dynamic loading (macOS 14+)

private let metalHandle: (handle: UnsafeMutableRawPointer, path: String)? = {
    let candidatePaths = [
        "/System/Library/Frameworks/Metal.framework/Metal",
        "/System/Library/Frameworks/Metal.framework/Versions/Current/Metal",
        "/System/Library/PrivateFrameworks/MetalTools.framework/MetalTools",
        "/System/Library/PrivateFrameworks/MetalTools.framework/Versions/Current/MetalTools",
        "/System/Library/PrivateFrameworks/MetalPerformanceShaders.framework/MetalPerformanceShaders",
        "/System/Library/PrivateFrameworks/MetalPerformanceShaders.framework/Versions/Current/MetalPerformanceShaders",
        "/System/Library/PrivateFrameworks/IOAccelerator.framework/IOAccelerator",
        "/System/Library/PrivateFrameworks/IOAccelerator.framework/Versions/Current/IOAccelerator"
    ]
    return openFirstAvailable(paths: candidatePaths)
}()

private let mtlProcessListGetEntryCount: MTLGetEntryCountFn? = {
    guard let (handle, path) = metalHandle else { return nil }
    let candidates = [
        "MTLProcessListGetEntryCount",
        "_MTLProcessListGetEntryCount",
        "MTLProcListGetEntryCount",
        "_MTLProcListGetEntryCount"
    ]
    if let loaded: DynamicSymbol<MTLGetEntryCountFn> = loadFirstSymbol(handle: handle, handlePath: path, candidates: candidates, as: MTLGetEntryCountFn.self) {
        NSLog("Using symbol: \(loaded.name) from \(loaded.path)")
        return loaded.symbol
    }
    return nil
}()

private let mtlProcessListGetEntries: MTLGetEntriesFn? = {
    guard let (handle, path) = metalHandle else { return nil }
    let candidates = [
        "MTLProcessListGetEntries",
        "_MTLProcessListGetEntries",
        "MTLProcListGetEntries",
        "_MTLProcListGetEntries"
    ]
    if let loaded: DynamicSymbol<MTLGetEntriesFn> = loadFirstSymbol(handle: handle, handlePath: path, candidates: candidates, as: MTLGetEntriesFn.self) {
        NSLog("Using symbol: \(loaded.name) from \(loaded.path)")
        return loaded.symbol
    }
    return nil
}()

struct MTLProcessListEntry {
    var pid: UInt32
    var taskRepresentation: UInt32
    var gpuUsage: Double
    var deviceRef: UInt64
}

// MARK: - Process Blacklist

private let processBlacklist: Set<String> = [
    "WindowServer",
    "kernel_task",
    "launchd",
    "loginwindow",
    "SystemUIServer",
    "Dock",
    "Xcode",
    "Finder",
]

// MARK: - Process Namespace

private func getProcessName(pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(PROC_PIDPATHINFO_SIZE))
    let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard ret > 0 else { return nil }
    return String(cString: buffer).split(separator: "/").last.map(String.init)
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
    return kill(pid, 0) == 0
}

// MARK: - GPU Manager Engine

@available(macOS 14.0, *)
class Engine: ObservableObject {

    // MARK: Configuration

    let pollInterval: TimeInterval = 1.0
    let ollamaActiveThreshold: Double = 0.50
    let processSuspendThreshold: Double = 0.05
    let processDisplayThreshold: Double = 0.0005
    let cooldownThreshold: Double = 0.30
    let cooldownDuration: TimeInterval = 30.0
    let stopTimeout: TimeInterval = 10.0

    // MARK: Published State

    @Published var processes: [GPUProcessInfo] = []
    @Published var ollamaGPUUsage: Double = 0
    @Published var totalGPUUsage: Double = 0
    @Published var isMonitoring = false
    @Published var managerState: ManagerState = .idle
    @Published var allowStop = false
    @Published var suspendedCount: Int = 0
    @Published var lastPollTime: Date?
    @Published var logEntries: [LogEntry] = []
    @Published var apiAvailable: Bool = true

    @Published var diagTriedPaths: [String] = []
    @Published var diagResolvedPath: String? = nil
    @Published var diagTriedSymbols: [String] = []
    @Published var diagResolvedSymbols: [String] = []

    var usingFallback: Bool { return !apiAvailable }

    // MARK: Internal State

    private var pollingTimer: Timer?
    private var coolingSince: Date?
    private var suspendedProcesses: [pid_t: SuspendedProcessInfo] = [:]
    private let appPID: pid_t
    private var lastSuspendedCheck: Date?

    private var activityScraper: ActivityMonitorScraper?
    private var fallbackTimer: Timer?

    // MARK: Lifecycle

    init() {
        self.appPID = ProcessInfo.processInfo.processIdentifier

        NotificationCenter.default.addObserver(forName: DiagTriedPathNote, object: nil, queue: .main) { [weak self] note in
            if let p = note.object as? String { self?.diagTriedPaths.append(p) }
        }
        NotificationCenter.default.addObserver(forName: DiagResolvedPathNote, object: nil, queue: .main) { [weak self] note in
            if let p = note.object as? String { self?.diagResolvedPath = p }
        }
        NotificationCenter.default.addObserver(forName: DiagTriedSymbolNote, object: nil, queue: .main) { [weak self] note in
            if let s = note.object as? String { self?.diagTriedSymbols.append(s) }
        }
        NotificationCenter.default.addObserver(forName: DiagResolvedSymbolNote, object: nil, queue: .main) { [weak self] note in
            if let s = note.object as? String { self?.diagResolvedSymbols.append(s) }
        }

        if mtlProcessListGetEntryCount == nil || mtlProcessListGetEntries == nil {
            self.apiAvailable = false
            addLog("MTLProcessList API not available on this system build (symbols not found).", level: .error)
            #if canImport(AppKit)
            self.activityScraper = ActivityMonitorScraper()
            #endif
        }
    }

    deinit {
        pollingTimer?.invalidate()
        fallbackTimer?.invalidate()
        resumeAllSuspended()
    }

    // MARK: Control

    func startMonitoring() {
        guard !isMonitoring else { return }

        isMonitoring = true
        managerState = .monitoring
        addLog("Monitoring started — polling GPU every \(Int(pollInterval))s")

        if apiAvailable {
            // Use Metal private API path
            pollNow()
            pollingTimer = Timer.scheduledTimer(timeInterval: pollInterval, target: self, selector: #selector(pollNow), userInfo: nil, repeats: true)
        } else {
            // Fallback: Activity Monitor scraping
            #if canImport(AppKit)
            startFallbackScraping()
            #else
            addLog("Fallback scraping not supported on this platform.", level: .error)
            #endif
        }
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        isMonitoring = false
        managerState = .idle
        coolingSince = nil

        resumeAllSuspended()
        addLog("Monitoring stopped — all processes resumed")
        DispatchQueue.main.async {
            self.processes = []
        }
    }

    // MARK: GPU Polling

    @objc private func pollNow() {
        guard let getCount = mtlProcessListGetEntryCount,
              let getEntries = mtlProcessListGetEntries else { return }

        let count = getCount()
        guard count > 0 else {
            updateProcessList(from: [], raw: [])
            return
        }

        var entries = [RawMTLProcessListEntry](
            repeating: RawMTLProcessListEntry(pid: 0, taskRepresentation: 0, gpuUsage: 0, deviceRef: 0),
            count: Int(count)
        )

        let written = entries.withUnsafeMutableBufferPointer { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr.baseAddress)
            return getEntries(rawPtr, count)
        }

        let rawActive = Array(entries.prefix(Int(written)))
        let mapped: [MTLProcessListEntry] = rawActive.map { e in
            MTLProcessListEntry(pid: e.pid, taskRepresentation: e.taskRepresentation, gpuUsage: e.gpuUsage, deviceRef: e.deviceRef)
        }
        updateProcessList(from: mapped, raw: mapped)
    }

    #if canImport(AppKit)
    private func startFallbackScraping() {
        guard let scraper = activityScraper else {
            addLog("Activity Monitor scraper unavailable.", level: .error)
            return
        }
        // Try to ensure Activity Monitor is running
        do {
            let pid = try scraper.ensureActivityMonitorRunning()
            addLog("Using Activity Monitor (PID: \(pid)) for GPU process scraping.")
        } catch {
            addLog("Failed to launch/find Activity Monitor: \(error.localizedDescription)", level: .error)
        }

        // Kick off immediately and schedule
        self.scrapeActivityMonitorOnce()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: max(2.0, pollInterval), repeats: true) { [weak self] _ in
            self?.scrapeActivityMonitorOnce()
        }
    }

    private func scrapeActivityMonitorOnce() {
        guard let scraper = activityScraper else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scraped = try scraper.scrapeProcesses()
                var infos: [GPUProcessInfo] = []
                var total: Double = 0
                var ollama: Double = 0
                var seen = Set<pid_t>()

                for s in scraped {
                    let pid = pid_t(s.pid)
                    guard pid > 100, pid != self.appPID else { continue }
                    let name = s.name.isEmpty ? (getProcessName(pid: pid) ?? "?") : s.name
                    let usage = s.gpuUsage ?? 0
                    total += usage
                    if name.lowercased().contains("ollama") { ollama += usage }
                    let info = GPUProcessInfo(pid: pid, name: name, gpuUsage: usage, isOllama: name.lowercased().contains("ollama"), state: .running)
                    infos.append(info)
                    seen.insert(pid)
                }

                // Add suspended processes not present in scraped list
                for (pid, sinfo) in self.suspendedProcesses where !seen.contains(pid) {
                    let name = getProcessName(pid: pid) ?? sinfo.name
                    infos.append(GPUProcessInfo(pid: pid, name: name, gpuUsage: 0, isOllama: false, state: .suspended))
                }

                DispatchQueue.main.async {
                    self.processes = infos
                        .filter { $0.gpuUsage >= self.processDisplayThreshold }
                        .sorted { $0.gpuUsage > $1.gpuUsage }
                    self.totalGPUUsage = total
                    self.ollamaGPUUsage = ollama
                    self.lastPollTime = Date()
                    self.suspendedCount = self.suspendedProcesses.count
                }

                // Decision logic using scraped data (no taskRepresentation available)
                self.evaluateGPUState(ollamaGPU: ollama, highUsageProcesses: [])
            } catch {
                self.addLog("Activity Monitor scraping failed: \(error.localizedDescription)", level: .error)
            }
        }
    }
    #endif

    private func updateProcessList(from newEntries: [MTLProcessListEntry], raw: [MTLProcessListEntry]) {
        var activeProcesses: [GPUProcessInfo] = []
        var ollamaTotal: Double = 0
        var totalGPU: Double = 0
        var highUsageNonOllama: [(GPUProcessInfo, MTLProcessListEntry)] = []

        var seenPIDs = Set<pid_t>()

        for entry in raw {
            let pid = pid_t(entry.pid)
            guard pid > 100, pid != appPID else { continue }
            let name = getProcessName(pid: pid) ?? "?"
            let usage = entry.gpuUsage
            let isOllama = name.lowercased().contains("ollama")

            seenPIDs.insert(pid)
            totalGPU += usage

            let info = GPUProcessInfo(
                pid: pid,
                name: name,
                gpuUsage: usage,
                isOllama: isOllama,
                state: .running
            )
            activeProcesses.append(info)

            if isOllama {
                ollamaTotal += usage
            } else if usage >= processSuspendThreshold && !processBlacklist.contains(name) {
                highUsageNonOllama.append((info, entry))
            }
        }

        // Add suspended processes that are no longer active (they were suspended, so no GPU usage)
        for (pid, sinfo) in suspendedProcesses {
            if !seenPIDs.contains(pid) {
                // Process is still alive but no longer appears in GPU list
                let name = getProcessName(pid: pid) ?? sinfo.name
                activeProcesses.append(GPUProcessInfo(
                    pid: pid,
                    name: name,
                    gpuUsage: 0,
                    isOllama: false,
                    state: .suspended
                ))
            }
        }

        // Clean up dead suspended processes
        for pid in suspendedProcesses.keys {
            if !isProcessAlive(pid) {
                if let info = suspendedProcesses.removeValue(forKey: pid) {
                    addLog("\(info.name) (PID: \(pid)) exited while suspended")
                }
            }
        }

        DispatchQueue.main.async {
            self.processes = activeProcesses
                .filter { $0.gpuUsage > self.processDisplayThreshold }
                .sorted { $0.gpuUsage > $1.gpuUsage }
            self.ollamaGPUUsage = ollamaTotal
            self.totalGPUUsage = totalGPU
            self.lastPollTime = Date()
            self.suspendedCount = self.suspendedProcesses.count
        }

        // Decision logic
        evaluateGPUState(
            ollamaGPU: ollamaTotal,
            highUsageProcesses: highUsageNonOllama
        )
    }

    // MARK: Decision Logic

    private func evaluateGPUState(ollamaGPU: Double, highUsageProcesses: [(GPUProcessInfo, MTLProcessListEntry)]) {
        let isOllamaActive = ollamaGPU >= ollamaActiveThreshold

        switch managerState {
        case .idle, .monitoring:
            if isOllamaActive {
                activateOllamaMode(highUsageProcesses: highUsageProcesses)
            }

        case .active:
            if !isOllamaActive && ollamaGPU < cooldownThreshold {
                // Cooldown phase
                if coolingSince == nil {
                    coolingSince = Date()
                    addLog("Ollama dropped below \(Int(cooldownThreshold * 100))% — cooling down for \(Int(cooldownDuration))s")
                } else if Date().timeIntervalSince(coolingSince!) >= cooldownDuration {
                    deactivateOllamaMode()
                }
            } else if isOllamaActive {
                // Reset cooldown
                coolingSince = nil
                activateOllamaMode(highUsageProcesses: highUsageProcesses)

                // If stop is allowed, check for processes where suspend didn't help
                if allowStop {
                    checkStopCandidates()
                }
            } else {
                // Ollama between cooldownThreshold and activeThreshold — maintain
                if coolingSince != nil {
                    // Reset if ollama went back up
                    if ollamaGPU >= ollamaActiveThreshold {
                        coolingSince = nil
                    }
                }
            }
        }
    }

    private func activateOllamaMode(highUsageProcesses: [(GPUProcessInfo, MTLProcessListEntry)]) {
        if managerState != .active {
            managerState = .active
            coolingSince = nil
            addLog("Ollama at \(Int(ollamaGPUUsage * 100))% GPU — suspending processes > \(Int(processSuspendThreshold * 100))%")
        }

        for (info, _) in highUsageProcesses {
            if !suspendedProcesses.keys.contains(info.pid) {
                if suspendProcess(info.pid, name: info.name) {
                    addLog("Suspended \(info.name) (PID: \(info.pid), GPU: \(Int(info.gpuUsage * 100))%)")
                }
            }
        }
    }

    private func deactivateOllamaMode() {
        managerState = .monitoring
        coolingSince = nil
        let count = suspendedProcesses.count
        addLog("Cooldown period ended — resuming \(count) suspended process(es)")
        resumeAllSuspended()
    }

    // MARK: Process Control

    private func suspendProcess(_ pid: pid_t, name: String) -> Bool {
        guard isProcessAlive(pid) else { return false }
        let r = kill(pid, SIGSTOP)
        if r == 0 {
            suspendedProcesses[pid] = SuspendedProcessInfo(pid: pid, name: name, suspendedAt: Date())
            return true
        }
        addLog("Failed to suspend \(name) (PID: \(pid)): \(String(cString: strerror(errno)))", level: .error)
        return false
    }

    private func resumeProcess(_ pid: pid_t) -> Bool {
        guard let info = suspendedProcesses[pid], isProcessAlive(pid) else {
            suspendedProcesses.removeValue(forKey: pid)
            return false
        }
        let r = kill(pid, SIGCONT)
        if r == 0 {
            suspendedProcesses.removeValue(forKey: pid)
            addLog("Resumed \(info.name) (PID: \(pid))")
            return true
        }
        return false
    }

    private func stopProcess(_ pid: pid_t, name: String) -> Bool {
        guard isProcessAlive(pid) else { return false }
        let r = kill(pid, SIGTERM)
        if r == 0 {
            addLog("Terminated \(name) (PID: \(pid)) — suspend was ineffective", level: .warning)
            suspendedProcesses.removeValue(forKey: pid)
            return true
        }
        return false
    }

    private func resumeAllSuspended() {
        for pid in suspendedProcesses.keys {
            _ = resumeProcess(pid)
        }
        suspendedProcesses.removeAll()
    }

    private func checkStopCandidates() {
        let now = Date()
        for (pid, info) in suspendedProcesses {
            guard isProcessAlive(pid) else {
                suspendedProcesses.removeValue(forKey: pid)
                continue
            }
            guard now.timeIntervalSince(info.suspendedAt) >= stopTimeout else { continue }

            // Check if this process is still appearing in the GPU list with significant usage
            if let proc = processes.first(where: { $0.pid == pid }), proc.gpuUsage >= processSuspendThreshold {
                addLog("\(info.name) (PID: \(pid)) still using GPU after suspend — sending SIGTERM", level: .warning)
                _ = stopProcess(pid, name: info.name)
            }
        }
    }

    // MARK: Logging

    private func addLog(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        DispatchQueue.main.async {
            self.logEntries.append(entry)
            if self.logEntries.count > 500 {
                self.logEntries.removeFirst(self.logEntries.count - 500)
            }
        }
    }
}
