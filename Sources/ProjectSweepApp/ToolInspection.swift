import CleanupCore
import Foundation

enum ToolScanPhase { case disconnected, pending, scanning, complete, partial, failed, cancelled }

struct ToolInspection {
    var phase: ToolScanPhase
    var report: ToolScanStatus?
    var message: String?
    var checkedAllSessions: Bool { report?.sessionRead == .complete && (phase == .complete || phase == .partial) }
    var title: String {
        switch phase {
        case .disconnected: "未连接"
        case .pending: "待扫描"
        case .scanning: "扫描中"
        case .complete: "检查完成"
        case .partial: report?.sessionRead == .unsupported ? "格式未支持" : "部分检查完成"
        case .failed: "检查失败"
        case .cancelled: "已取消"
        }
    }
    static func finished(_ result: ScanResult) -> ToolInspection {
        guard let report = result.toolStatus else {
            return ToolInspection(phase: .failed, message: "缺少工具检查状态，请重新扫描")
        }
        let phase: ToolScanPhase
        switch report.sessionRead {
        case .complete: phase = report.filesIncomplete ? .partial : .complete
        case .partial, .unsupported: phase = .partial
        case .failed: phase = .failed
        }
        return ToolInspection(phase: phase, report: report, message: report.message)
    }
}
