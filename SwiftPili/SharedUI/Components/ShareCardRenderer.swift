import CoreImage.CIFilterBuiltins
import UIKit

enum ShareCardRenderer {
    struct Request: Sendable {
        let coverURL: String
        let title: String
        let uploader: String
        let description: String
        let linkURL: String
        let linkDisplay: String
        let accent: UIColor
    }

    @concurrent
    static func prepare(_ request: Request) async throws -> UIImage {
        var cover: UIImage?
        if let url = URL(string: request.coverURL.httpsURL) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                cover = UIImage(data: data)
            } catch {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        let image = autoreleasepool {
            render(cover: cover, title: request.title, uploader: request.uploader,
                   description: request.description, linkURL: request.linkURL,
                   linkDisplay: request.linkDisplay, accent: request.accent)
        }
        try Task.checkCancellation()
        return image
    }

    private static let ink = UIColor(white: 0.09, alpha: 1)
    private static let grey = UIColor(white: 0.42, alpha: 1)

    private static func render(
        cover: UIImage?,
        title: String,
        uploader: String,
        description: String,
        linkURL: String,
        linkDisplay: String,
        accent: UIColor
    ) -> UIImage {
        let width: CGFloat = 1080
        let pad: CGFloat = 64
        let content = width - pad * 2
        let coverH = (content * 9 / 16).rounded()

        let titleFont = UIFont.systemFont(ofSize: 48, weight: .bold)
        let upFont = UIFont.systemFont(ofSize: 33, weight: .semibold)
        let descFont = UIFont.systemFont(ofSize: 31, weight: .regular)
        let scanFont = UIFont.systemFont(ofSize: 34, weight: .bold)
        let linkFont = UIFont.systemFont(ofSize: 27, weight: .medium)

        let titlePara = paragraph(lineBreak: .byTruncatingTail, lineSpacing: 4)
        let descPara = paragraph(lineBreak: .byTruncatingTail, lineSpacing: 6)

        let titleH = height(title, font: titleFont, width: content, maxLines: 3, para: titlePara)
        let descTrimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDesc = !descTrimmed.isEmpty && descTrimmed != "-"
        let descH = hasDesc ? height(descTrimmed, font: descFont, width: content, maxLines: 5, para: descPara) : 0

        let upH = ceil(upFont.lineHeight)

        let gapAfterCover: CGFloat = 44
        let gapAfterTitle: CGFloat = 22
        let gapAfterUp: CGFloat = hasDesc ? 26 : 0
        let gapBeforeFooter: CGFloat = 40
        let qr: CGFloat = 200

        let totalH = pad + coverH + gapAfterCover + titleH + gapAfterTitle + upH
            + gapAfterUp + descH + gapBeforeFooter + qr + pad

        let size = CGSize(width: width, height: totalH.rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let coverRect = CGRect(x: pad, y: pad, width: content, height: coverH)
            let coverPath = UIBezierPath(roundedRect: coverRect, cornerRadius: 24)
            cg.saveGState()
            coverPath.addClip()
            if let cover, cover.size.width > 0, cover.size.height > 0 {
                let scale = max(coverRect.width / cover.size.width, coverRect.height / cover.size.height)
                let dw = cover.size.width * scale
                let dh = cover.size.height * scale
                cover.draw(in: CGRect(x: coverRect.midX - dw / 2, y: coverRect.midY - dh / 2, width: dw, height: dh))
            } else {
                UIColor(white: 0.92, alpha: 1).setFill()
                coverPath.fill()
            }
            cg.restoreGState()

            var y = coverRect.maxY + gapAfterCover

            draw(title, font: titleFont, color: ink, para: titlePara,
                 in: CGRect(x: pad, y: y, width: content, height: titleH))
            y += titleH + gapAfterTitle

            let dotR: CGFloat = 12
            accent.setFill()
            cg.fillEllipse(in: CGRect(x: pad, y: y + (upH - dotR) / 2, width: dotR, height: dotR))
            let upX = pad + dotR + 14
            draw(uploader, font: upFont, color: grey,
                 para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
                 in: CGRect(x: upX, y: y, width: content - dotR - 14, height: upH))
            y += upH + gapAfterUp

            if hasDesc {
                draw(descTrimmed, font: descFont, color: grey, para: descPara,
                     in: CGRect(x: pad, y: y, width: content, height: descH))
                y += descH
            }
            y += gapBeforeFooter

            let qrRect = CGRect(x: width - pad - qr, y: y, width: qr, height: qr)
            if let qrImage = Self.qrImage(from: linkURL, side: qr) {
                qrImage.draw(in: qrRect)
            }
            let textW = qrRect.minX - pad - 28
            let scanH = ceil(scanFont.lineHeight)
            let linkTextH = ceil(linkFont.lineHeight * 2)
            let block = scanH + 10 + linkTextH
            var ty = y + (qr - block) / 2
            draw(String(localized: "Scan to watch"), font: scanFont, color: ink,
                 para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
                 in: CGRect(x: pad, y: ty, width: textW, height: scanH))
            ty += scanH + 10
            draw(linkDisplay, font: linkFont, color: ink,
                 para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 2),
                 in: CGRect(x: pad, y: ty, width: textW, height: linkTextH))
        }
    }

    private static func qrImage(from string: String, side: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Helpers

    private static func paragraph(lineBreak: NSLineBreakMode, lineSpacing: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = lineBreak
        p.lineSpacing = lineSpacing
        return p
    }

    private static func height(
        _ s: String, font: UIFont, width: CGFloat, maxLines: Int, para: NSParagraphStyle
    ) -> CGFloat {
        let bounding = (s as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: para],
            context: nil
        ).height
        let cap = (font.lineHeight + para.lineSpacing) * CGFloat(maxLines)
        return ceil(min(bounding, cap))
    }

    private static func draw(
        _ s: String, font: UIFont, color: UIColor, para: NSParagraphStyle, in rect: CGRect
    ) {
        (s as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]
        )
    }
}
