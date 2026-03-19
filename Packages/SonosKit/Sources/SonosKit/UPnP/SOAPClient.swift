/// SOAPClient.swift — Sends UPnP SOAP requests and parses XML responses.
///
/// All Sonos control happens over SOAP/HTTP. This client builds the XML envelope,
/// sends it as a POST with the SOAPAction header, and returns parsed key-value
/// results. HTTP 500 responses are parsed for SOAP fault codes.
import Foundation

public enum SOAPError: Error, LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case networkError(Error)
    case parseError(String)
    case soapFault(String, String) // faultCode, faultString

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .soapFault(let code, let string): return "SOAP fault [\(code)]: \(string)"
        }
    }
}

public final class SOAPClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    public func send(
        to baseURL: URL,
        path: String,
        service: String,
        action: String,
        arguments: [(String, String)] = []
    ) async throws -> [String: String] {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SOAPError.invalidURL
        }

        let soapAction = "urn:schemas-upnp-org:service:\(service):1#\(action)"
        let body = buildEnvelope(service: service, action: action, arguments: arguments)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(soapAction, forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SOAPError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SOAPError.networkError(URLError(.badServerResponse))
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        if httpResponse.statusCode == 500 {
            // SOAP fault
            let fault = XMLResponseParser.parseFault(responseBody)
            throw SOAPError.soapFault(fault.code, fault.string)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SOAPError.httpError(httpResponse.statusCode, responseBody)
        }

        let parsed = XMLResponseParser.parseActionResponse(responseBody, action: action)
        return parsed
    }

    /// Constructs a SOAP XML envelope following the UPnP 1.0 schema conventions
    private func buildEnvelope(service: String, action: String, arguments: [(String, String)]) -> String {
        var args = ""
        for (name, value) in arguments {
            args += "<\(name)>\(xmlEscape(value))</\(name)>"
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\
        \(args)\
        </u:\(action)>
        </s:Body>
        </s:Envelope>
        """
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
