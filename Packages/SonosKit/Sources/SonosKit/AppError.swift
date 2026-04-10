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
        case .soapFault(let code, _):
            return Self.sanitizedSOAPMessage(code: code)
        case .serviceAuthRequired(let service):
            return "\(service) requires sign-in. Open the Sonos app to re-authenticate."
        case .playbackFailed(let detail):
            return "Playback failed: \(detail)"
        case .cacheFailed(let detail):
            return "Cache error: \(detail)"
        case .timeout:
            return "The request timed out. The speaker may be unresponsive."
        case .unknown:
            return "An unexpected error occurred."
        }
    }

    // MARK: - SOAP Error Sanitization

    /// Maps known SOAP fault codes to user-friendly messages.
    /// Unknown codes get a generic message — raw fault detail is never shown.
    private static func sanitizedSOAPMessage(code: String) -> String {
        switch code {
        case "401": return "Speaker reported an invalid action."
        case "402", "714": return "The requested item was not found."
        case "701": return "Cannot transition — the speaker may be in a different state."
        case "711": return "The operation is not supported in the current state."
        case "712": return "The queue is full."
        case "718": return "Invalid seek target."
        case "800": return "Service authentication required."
        case "parse": return "Received an unexpected response from the speaker."
        case "SMAPI": return "The music service returned an error."
        default: return "Speaker returned an error (code \(code))."
        }
    }

    // MARK: - Conversions

    /// Creates an AppError from a SOAPError
    public static func from(_ error: SOAPError) -> AppError {
        switch error {
        case .invalidURL:
            return .networkUnavailable
        case .httpError(let code, _):
            return .soapFault(code: "\(code)", message: "HTTP error")
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
