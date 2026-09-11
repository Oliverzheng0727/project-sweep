import Foundation

public enum SessionReadState: String, Sendable {
    case complete, partial, failed, unsupported
}

public enum SessionDeletionSupport: String, Sendable {
    case available, unavailable
}

/// Reading the inventory and supporting deletion are independent capabilities.
public struct ToolScanStatus: Sendable {
    public var sessionRead: SessionReadState
    public var sessionDeletion: SessionDeletionSupport
    public var requiresRecovery: Bool
    public var filesIncomplete: Bool
    public var message: String?
    public init(sessionRead: SessionReadState = .complete,
                sessionDeletion: SessionDeletionSupport = .unavailable,
                requiresRecovery: Bool = false, filesIncomplete: Bool = false, message: String? = nil) {
        self.sessionRead = sessionRead; self.sessionDeletion = sessionDeletion
        self.requiresRecovery = requiresRecovery; self.message = message
        self.filesIncomplete = filesIncomplete
    }
}
