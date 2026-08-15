/// SupportSheet.swift — donation panel behind the toolbar heart (#79).
/// Present only when packaging injected the support keys. The address is
/// shown as text and QR as well as copied — clipboard hijackers swap
/// copied Bitcoin addresses, so donors need something to check against.
import SwiftUI
import SonosKit
import CoreImage.CIFilterBuiltins

struct SupportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let supportURL: URL?
    let bitcoinAddress: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.supportSheetTitle)
                .font(.title2.weight(.semibold))

            Text(L10n.supportBlurb)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let supportURL {
                Button {
                    NSWorkspace.shared.open(supportURL)
                } label: {
                    Label(L10n.supportOnKofi, systemImage: "cup.and.saucer.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            if let bitcoinAddress {
                Divider()

                HStack(alignment: .top, spacing: 16) {
                    if let qr = qrImage(for: bitcoinAddress) {
                        // Displayed at its natural size: the quiet zone and
                        // white ground are baked into the bitmap, and any
                        // view-layer rescale drops modules and stops it
                        // scanning while still looking like a QR code.
                        Image(nsImage: qr)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.bitcoin, systemImage: "bitcoinsign.circle")
                            .font(.body.weight(.medium))

                        // One line, selectable: a wrapped address can't be
                        // compared character-for-character.
                        Text(bitcoinAddress)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bitcoinAddress, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? L10n.copied : L10n.copyBitcoinAddress,
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button(L10n.close) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Builds the payment QR as a finished bitmap — white ground, four-module
    /// quiet zone, whole pixels per module. Returns nil rather than a
    /// placeholder if CoreImage fails; a QR that scans to the wrong thing is
    /// worse than none.
    private func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // Bare address, five points per module, four-module quiet zone —
        // what wallet apps emit and what scanners expect.
        let quietModules = 4
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let pointsPerModule: CGFloat = 5
        let pixelsPerModule = pointsPerModule * backingScale
        let modules = Int(output.extent.width.rounded())

        let scaled = output.transformed(by: CGAffineTransform(scaleX: pixelsPerModule,
                                                              y: pixelsPerModule))
        let context = CIContext()
        guard let symbol = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let side = (modules + quietModules * 2) * Int(pixelsPerModule)
        guard let canvas = CGContext(data: nil, width: side, height: side,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .none
        let inset = CGFloat(quietModules) * pixelsPerModule
        canvas.draw(symbol, in: CGRect(x: inset, y: inset,
                                       width: CGFloat(modules) * pixelsPerModule,
                                       height: CGFloat(modules) * pixelsPerModule))
        guard let bitmap = canvas.makeImage() else { return nil }
        let points = CGFloat(side) / backingScale
        return NSImage(cgImage: bitmap, size: NSSize(width: points, height: points))
    }
}
