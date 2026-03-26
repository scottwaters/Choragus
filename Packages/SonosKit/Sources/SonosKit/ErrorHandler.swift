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

    private init() {}

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

        // Always log
        sonosDebugLog("[\(context)] \(appError.errorDescription ?? error.localizedDescription)")

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
