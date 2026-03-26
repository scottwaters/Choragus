/// AppError.swift — Typed error enum for SonosController.
///
/// Provides structured, user-facing error descriptions for all common failure
/// modes. Bridges from SOAPError and SMAPIError for unified error handling.
import Foundation

public enum AppError: Error, LocalizedError {
    case networkUnavailable
    case speakerNotFound(String)
    case soapFault(code: String, message: String)
    case serviceAuthRequired(String)
    case playbackFailed(String)
    case cacheFailed(String)
    case timeout
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "The network is unavailable. Check your Wi-Fi connection."
        case .speakerNotFound(let name):
            return "Speaker \"\(name)\" was not found on the network."
        case .soapFault(let code, let message):
            return "Speaker returned error [\(code)]: \(message)"
        case .serviceAuthRequired(let service):
            return "\(service) requires sign-in. Open the Sonos app to re-authenticate."
        case .playbackFailed(let detail):
            return "Playback failed: \(detail)"
        case .cacheFailed(let detail):
            return "Cache error: \(detail)"
        case .timeout:
            return "The request timed out. The speaker may be unresponsive."
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }

    // MARK: - Conversions

    /// Creates an AppError from a SOAPError
    public static func from(_ error: SOAPError) -> AppError {
        switch error {
        case .invalidURL:
            return .networkUnavailable
        case .httpError(let code, let body):
            return .soapFault(code: "\(code)", message: body)
        case .networkError(let underlying):
            if (underlying as? URLError)?.code == .timedOut {
                return .timeout
            }
            return .networkUnavailable
        case .parseError(let msg):
            return .soapFault(code: "parse", message: msg)
        case .soapFault(let code, let message):
            if code == "402" || code == "714" || code == "800" {
                return .serviceAuthRequired(message)
            }
            return .soapFault(code: code, message: message)
        }
    }

    /// Creates an AppError from an SMAPIError
    public static func from(_ error: SMAPIError) -> AppError {
        switch error {
        case .invalidURL:
            return .networkUnavailable
        case .soapFault(let detail):
            return .soapFault(code: "SMAPI", message: detail)
        case .notAuthenticated:
            return .serviceAuthRequired("Music service")
        case .authFailed(let reason):
            return .serviceAuthRequired(reason)
        }
    }
}
