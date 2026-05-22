import Foundation

struct GPUProcessInfo: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    var gpuUsage: Double
    let isOllama: Bool
    var state: ProcessState
}

enum ProcessState: String {
    case running
    case suspended
    case stopping
}

enum ManagerState: String {
    case idle = "Idle"
    case monitoring = "Monitoring"
    case active = "Managing GPU"
}

struct SuspendedProcessInfo {
    let pid: pid_t
    let name: String
    let suspendedAt: Date
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: LogLevel
}

enum LogLevel {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}
