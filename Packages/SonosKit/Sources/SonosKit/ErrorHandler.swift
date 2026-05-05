/// ErrorHandler.swift — Centralised error handling for the application.
///
/// All errors flow through here for consistent logging and user feedback.
/// Views observe `currentError` to display error banners.
import Foundation

@MainActor
public final class ErrorHandler: ObservableObject {
    public static let shared = ErrorHandler()

    /// Current user-facing error message, auto-clears after duration
    @Published public var currentError: String?

    /// Whether to show the error as a banner
    @Published public var showError = false

    /// Transient informational message (e.g. "Added 5 tracks to queue").
    /// Auto-dismisses after a few seconds. Uses a separate banner style
    /// from errors so failures stay visually distinct.
    @Published public var currentInfo: String?
    @Published public var showInfo = false

    private init() {}

    /// Shows a transient info banner (used for successful actions the user
    /// needs visible confirmation of — e.g. "Added to queue" from a context
    /// menu that has no other on-screen feedback).
    public func info(_ message: String) {
        currentInfo = message
        showInfo = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Timing.errorAutoDismiss)
            // Only clear if the same message is still showing — otherwise
            // a newer info would be cut short by this earlier timer.
            if self.currentInfo == message {
                self.showInfo = false
                self.currentInfo = nil
            }
        }
    }

    public func dismissInfo() {
        showInfo = false
        currentInfo = nil
    }

    /// Handles an error — logs it and optionally shows to user
    public func handle(_ error: Error, context: String, userFacing: Bool = false) {
        let appError: AppError
        if let soap = error as? SOAPError {
            appError = AppError.from(soap)
        } else if let smapi = error as? SMAPIError {
            appError = AppError.from(smapi)
        } else if let app = error as? AppError {
            appError = app
        } else {
            appError = .unknown(error)
        }

        // Always log — centralised error sink, so route to diagnostics.
        sonosDiagLog(.error, tag: context,
                     appError.errorDescription ?? error.localizedDescription)

        // Show to user if requested
        if userFacing {
            currentError = appError.errorDescription
            showError = true
            // Auto-dismiss after 5 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Timing.errorAutoDismiss)
                if self.showError {
                    self.showError = false
                    self.currentError = nil
                }
            }
        }
    }

    /// Convenience for handling errors from async operations with user feedback
    public func handleAsync(_ context: String, userFacing: Bool = false, operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            handle(error, context: context, userFacing: userFacing)
        }
    }

    /// Dismisses the current error
    public func dismiss() {
        showError = false
        currentError = nil
    }
}
