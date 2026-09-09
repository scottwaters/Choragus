/// AppError.swift — Typed error enum for Choragus.
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
            return L10n.errAppNetworkUnavailable
        case .speakerNotFound(let name):
            return L10n.errAppSpeakerNotFound(name)
        case .soapFault(let code, _):
            return Self.sanitizedSOAPMessage(code: code)
        case .serviceAuthRequired(let service):
            return L10n.errAppServiceAuthRequired(service)
        case .playbackFailed(let detail):
            return L10n.errAppPlaybackFailed(detail)
        case .cacheFailed(let detail):
            return L10n.errAppCacheFailed(detail)
        case .timeout:
            return L10n.errAppTimeout
        case .unknown:
            return L10n.errAppUnknown
        }
    }

    // MARK: - SOAP Error Sanitization

    /// Maps known SOAP fault codes to user-friendly messages.
    /// Unknown codes get a generic message — raw fault detail is never shown.
    private static func sanitizedSOAPMessage(code: String) -> String {
        switch code {
        case "401": return L10n.errSoapInvalidAction
        case "402", "714": return L10n.errSoapItemNotFound
        case "701": return L10n.errSoapCannotTransition
        case "711": return L10n.errSoapNotSupportedInState
        case "712": return L10n.errSoapQueueFull
        case "718": return L10n.errSoapInvalidSeek
        case "800": return L10n.errSoapAuthRequired
        case "parse": return L10n.errSoapUnexpectedResponse
        case "SMAPI": return L10n.errSoapServiceError
        default: return L10n.errSoapGenericCode(code)
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
            return .serviceAuthRequired(L10n.errMusicServiceGeneric)
        case .authFailed(let reason):
            return .serviceAuthRequired(reason)
        }
    }
}
