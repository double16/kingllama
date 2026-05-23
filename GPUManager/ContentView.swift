import SwiftUI
import AppKit

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 0) {
            if engine.apiAvailable || engine.usingFallback {
                HeaderView
                    .padding()
                Divider()
                ProcessListView
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()
                ControlsView
                    .padding()
                DiagnosticsView
                Divider()
                LogView
            } else {
                VStack(spacing: 0) {
                    APIUnavailableView
                    Divider()
                    DiagnosticsView
                }
            }
        }
        .frame(width: 580, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - API Unavailable

    private var APIUnavailableView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("GPU Monitoring Unavailable")
                .font(.title2)
                .bold()
            Text("GPU process monitoring is unavailable on this system build. The required Metal symbols couldn't be found.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var HeaderView: some View {
        HStack(spacing: 16) {
            if let nsImage = NSImage(named: "Logo") {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("KingLlama")
                    .font(.title2)
                    .bold()
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(engine.managerState.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if engine.usingFallback {
                        Text("(Fallback: Activity Monitor)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                GPUBarView(
                    label: "Ollama GPU",
                    usage: engine.ollamaGPUUsage,
                    color: ollamaColor
                )
                GPUBarView(
                    label: "Total GPU",
                    usage: engine.totalGPUUsage,
                    color: totalColor
                )
            }
            .frame(width: 200)
        }
    }

    private var statusColor: Color {
        switch engine.managerState {
        case .idle: return .gray
        case .monitoring: return .green
        case .active: return .orange
        }
    }

    private var ollamaColor: Color {
        if engine.ollamaGPUUsage >= engine.ollamaActiveThreshold {
            return .red
        } else if engine.ollamaGPUUsage >= engine.cooldownThreshold {
            return .orange
        }
        return .green
    }

    private var totalColor: Color {
        engine.totalGPUUsage > 0.8 ? .red : .blue
    }

    // MARK: - Process List

    private var ProcessListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GPU Processes")
                    .font(.headline)
                Spacer()
                if engine.isMonitoring {
                    Text("\(engine.processes.count) process(es)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if engine.processes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No GPU-using processes detected")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(engine.processes) { process in
                            ProcessRow(process: process)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Controls

    private var ControlsView: some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle(isOn: $engine.allowStop) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow process termination")
                        .font(.subheadline)
                    Text("If suspend doesn't free GPU, send SIGTERM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            if let lastPoll = engine.lastPollTime {
                Text("Updated \(Int(-lastPoll.timeIntervalSinceNow))s ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if engine.suspendedCount > 0 {
                Text("Suspended: \(engine.suspendedCount)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .bold()
            }

            Button(engine.isMonitoring ? "Stop" : "Start") {
                if engine.isMonitoring {
                    engine.stopMonitoring()
                } else {
                    engine.startMonitoring()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isMonitoring ? .red : .green)
        }
    }

    // MARK: - Diagnostics View

    private var DiagnosticsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button("Copy Diagnostics") {
                    copyToClipboard(buildDiagnosticsSummary())
                }
                .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.usingFallback ? "Mode: Activity Monitor Fallback" : "Mode: Metal API")
                    .font(.caption)
                    .foregroundColor(engine.usingFallback ? .orange : .secondary)
                #if canImport(AppKit)
                if engine.usingFallback {
                    Text(ActivityMonitorScraper.trustStatusDescription)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .help("Click to copy executable path")
                        .onTapGesture {
                            copyToClipboard(ActivityMonitorScraper.executablePath)
                        }
                }
                #endif

                #if canImport(AppKit)
                if engine.usingFallback {
                    Button {
                        // Try to open System Settings > Privacy & Security > Accessibility
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Fix Accessibility…", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                #endif

                Group {
                    Text("Resolved Path: \(engine.diagResolvedPath ?? "—")")
                        .font(.caption)
                    Text("Resolved Symbols: \(engine.diagResolvedSymbols.isEmpty ? "—" : engine.diagResolvedSymbols.joined(separator: ", "))")
                        .font(.caption)
                }
                Group {
                    Text("Tried Paths: \(engine.diagTriedPaths.isEmpty ? "—" : engine.diagTriedPaths.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text("Tried Symbols: \(engine.diagTriedSymbols.isEmpty ? "—" : engine.diagTriedSymbols.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Log

    private var LogView: some View {
        DisclosureGroup {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(engine.logEntries) { entry in
                            HStack(alignment: .top, spacing: 4) {
                                Text(entry.level.symbol)
                                    .font(.caption)
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .leading)
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundColor(entry.level == .error ? .red : (entry.level == .warning ? .orange : .primary))
                                    .lineLimit(1)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 100)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: engine.logEntries.count) { _, _ in
                    if let last = engine.logEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                Text("Activity Log")
                    .font(.subheadline)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func buildDiagnosticsSummary() -> String {
        var lines: [String] = []
        lines.append("Resolved Path: \(engine.diagResolvedPath ?? "—")")
        let resolvedSyms = engine.diagResolvedSymbols.isEmpty ? "—" : engine.diagResolvedSymbols.joined(separator: ", ")
        lines.append("Resolved Symbols: \(resolvedSyms)")
        let triedPaths = engine.diagTriedPaths.isEmpty ? "—" : engine.diagTriedPaths.joined(separator: ", ")
        lines.append("Tried Paths: \(triedPaths)")
        let triedSyms = engine.diagTriedSymbols.isEmpty ? "—" : engine.diagTriedSymbols.joined(separator: ", ")
        lines.append("Tried Symbols: \(triedSyms)")
        #if canImport(AppKit)
        lines.append("")
        lines.append("Activity Monitor UI Tree:")
        lines.append(ActivityMonitorScraper().activityMonitorUITreeDiagnostics())
        #endif
        return lines.joined(separator: "\n")
    }
}

// MARK: - GPU Bar

struct GPUBarView: View {
    let label: String
    let usage: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(geo.size.width * CGFloat(min(usage, 1.0)), 2), height: 10)
                }
            }
            .frame(height: 10)
            Text("\(Int(usage * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Process Row

struct ProcessRow: View {
    let process: GPUProcessInfo

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)

            // PID
            Text("\(process.pid)")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)

            // Name
            Text(process.name)
                .font(.body)
                .lineLimit(1)
                .frame(minWidth: 100, alignment: .leading)

            Spacer()

            // GPU Usage
            Text("\(Int(process.gpuUsage * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(usageColor)
                .frame(width: 40, alignment: .trailing)

            // Status badge
            Text(process.state.rawValue.capitalized)
                .font(.caption2)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateColor)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(process.state == .suspended ? Color.orange.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var stateColor: Color {
        switch process.state {
        case .running: return process.isOllama ? .blue : .green
        case .suspended: return .orange
        case .stopping: return .red
        }
    }

    private var usageColor: Color {
        if process.gpuUsage >= 0.5 { return .red }
        if process.gpuUsage >= 0.1 { return .orange }
        return .secondary
    }
}

