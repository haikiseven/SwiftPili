import CoreImage.CIFilterBuiltins
import Kingfisher
import LinkPresentation
import Photos
import SwiftUI
import UIKit

// MARK: - SwiftPili Official Vector Brand Emblem

enum SwiftPiliBrandArt {
    nonisolated static func appIconImage(
        side: CGFloat = 128,
        accent: UIColor,
        isDark: Bool = false
    ) -> UIImage {
        let clampedSide = max(24, side)
        let size = CGSize(width: clampedSide, height: clampedSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            drawAppIcon(in: CGRect(origin: .zero, size: size), cg: ctx.cgContext, accent: accent, isDark: isDark)
        }
    }

    nonisolated static func drawAppIcon(
        in rect: CGRect,
        cg: CGContext,
        accent: UIColor,
        isDark: Bool
    ) {
        guard rect.width > 1, rect.height > 1 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }

        let radius = rect.width * 0.225
        let squircle = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        cg.saveGState()
        squircle.addClip()

        let topColor = isDark
            ? UIColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1)
            : UIColor(white: 1.0, alpha: 1)
        let bottomColor = isDark
            ? UIColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1)
            : UIColor(red: 0.95, green: 0.955, blue: 0.975, alpha: 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        } else {
            topColor.setFill()
            cg.fill(rect)
        }

        // Optical disc layer from AppIcon.icon/Assets/disc-light.svg (cx=512, cy=512, r=372 in 1024 space)
        let discRadius = rect.width * (372.0 / 1024.0)
        let discRect = CGRect(
            x: rect.midX - discRadius,
            y: rect.midY - discRadius,
            width: discRadius * 2,
            height: discRadius * 2
        )
        accent.withAlphaComponent(isDark ? 0.22 : 0.16).setFill()
        cg.fillEllipse(in: discRect)

        // Play glyph from AppIcon.icon/Assets/play-light.svg (1024x1024 viewBox)
        let playPath = makePlayGlyphPath(in: rect)
        accent.setFill()
        playPath.fill()

        cg.restoreGState()

        let strokeColor = isDark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.black.withAlphaComponent(0.08)
        strokeColor.setStroke()
        squircle.lineWidth = max(1, rect.width * 0.018)
        squircle.stroke()
    }

    nonisolated private static func makePlayGlyphPath(in rect: CGRect) -> UIBezierPath {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x / 1024.0) * rect.width,
                y: rect.minY + (y / 1024.0) * rect.height
            )
        }
        let path = UIBezierPath()
        path.move(to: pt(345.28, 346.51))
        path.addCurve(
            to: pt(417.36, 304.99),
            controlPoint1: pt(345.28, 309.52),
            controlPoint2: pt(385.36, 286.43)
        )
        path.addLine(to: pt(702.69, 470.48))
        path.addCurve(
            to: pt(702.69, 553.52),
            controlPoint1: pt(734.58, 488.97),
            controlPoint2: pt(734.58, 535.03)
        )
        path.addLine(to: pt(417.36, 719.01))
        path.addCurve(
            to: pt(345.28, 677.49),
            controlPoint1: pt(385.36, 737.57),
            controlPoint2: pt(345.28, 714.48)
        )
        path.close()
        return path
    }
}

// MARK: - Branded Share Card Renderer

enum ShareCardStyle: String, CaseIterable, Identifiable, Sendable {
    case editorialLight = "editorial_light"
    case ambientDark = "ambient_dark"

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .editorialLight: "Light Card"
        case .ambientDark: "Dark Glow"
        }
    }

    var symbolName: String {
        switch self {
        case .editorialLight: "sun.max.fill"
        case .ambientDark: "sparkles"
        }
    }
}

enum ShareCardRenderer {
    struct Request: Sendable {
        let coverURL: String
        var avatarURL: String = ""
        let title: String
        let uploader: String
        let description: String
        var bvid: String = ""
        var durationSeconds: Int = 0
        var viewCount: Int = 0
        var likeCount: Int = 0
        var isPortraitCover: Bool = false
        let linkURL: String
        let linkDisplay: String
        let accent: UIColor
        var style: ShareCardStyle = .editorialLight
        var includesDescription: Bool = true
    }

    @concurrent
    static func prepare(_ request: Request) async throws -> UIImage {
        async let fetchedCover = fetchImage(urlString: request.coverURL)
        async let fetchedAvatar = fetchImage(urlString: request.avatarURL)
        let cover = await fetchedCover
        let avatar = await fetchedAvatar
        try Task.checkCancellation()
        let image = autoreleasepool {
            render(request: request, cover: cover, avatar: avatar)
        }
        try Task.checkCancellation()
        return image
    }

    nonisolated static func renderSynchronously(
        request: Request,
        cover: UIImage?,
        avatar: UIImage? = nil
    ) -> UIImage {
        autoreleasepool {
            render(request: request, cover: cover, avatar: avatar)
        }
    }

    private nonisolated static func fetchImage(urlString: String) async -> UIImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed.httpsURL) else { return nil }
        if let cached = try? await KingfisherManager.shared.retrieveImage(with: url).image {
            return cached
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func render(
        request: Request,
        cover: UIImage?,
        avatar: UIImage?
    ) -> UIImage {
        let isDark = request.style == .ambientDark
        let accent = request.accent

        let canvasW: CGFloat = 1080
        let outerPad: CGFloat = 44
        let cardW = canvasW - outerPad * 2
        let innerPad: CGFloat = 48
        let contentW = cardW - innerPad * 2

        let coverIsPortrait: Bool = {
            if let cover, cover.size.width > 0, cover.size.height > 0 {
                return cover.size.height > cover.size.width * 1.05
            }
            return request.isPortraitCover
        }()
        let coverH = coverIsPortrait
            ? (contentW * 1.06).rounded()
            : (contentW * 9.0 / 16.0).rounded()

        let brandBarH: CGFloat = 68
        let gapAfterBrand: CGFloat = 32
        let gapAfterCover: CGFloat = 38

        let titleFont = UIFont.systemFont(ofSize: 44, weight: .bold)
        let upFont = UIFont.systemFont(ofSize: 30, weight: .semibold)
        let statFont = UIFont.monospacedDigitSystemFont(ofSize: 25, weight: .medium)
        let descFont = UIFont.systemFont(ofSize: 28, weight: .regular)
        let scanFont = UIFont.systemFont(ofSize: 31, weight: .bold)
        let linkFont = UIFont.monospacedSystemFont(ofSize: 23, weight: .medium)
        let viaFont = UIFont.systemFont(ofSize: 23, weight: .semibold)

        let titlePara = paragraph(lineBreak: .byTruncatingTail, lineSpacing: 6)
        let descPara = paragraph(lineBreak: .byTruncatingTail, lineSpacing: 6)

        let safeTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "SwiftPili"
            : request.title
        let titleH = height(safeTitle, font: titleFont, width: contentW, maxLines: 3, para: titlePara)

        let creatorRowH: CGFloat = 54
        let gapAfterTitle: CGFloat = 24

        let normalizedDesc = request.description
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let hasDesc = request.includesDescription && !normalizedDesc.isEmpty && normalizedDesc != "-"
        let descInnerW = contentW - 44
        let descTextH = hasDesc
            ? height(normalizedDesc, font: descFont, width: descInnerW, maxLines: 4, para: descPara)
            : 0
        let descBoxH = hasDesc ? (descTextH + 36) : 0
        let gapBeforeDesc: CGFloat = hasDesc ? 26 : 0

        let gapBeforeDivider: CGFloat = 36
        let dividerGapAfter: CGFloat = 34
        let qrBoxSide: CGFloat = 204

        let cardH = innerPad
            + brandBarH
            + gapAfterBrand
            + coverH
            + gapAfterCover
            + titleH
            + gapAfterTitle
            + creatorRowH
            + gapBeforeDesc
            + descBoxH
            + gapBeforeDivider
            + 2
            + dividerGapAfter
            + qrBoxSide
            + innerPad

        let canvasH = (cardH + outerPad * 2).rounded()
        let canvasSize = CGSize(width: canvasW, height: canvasH)

        let primaryInk = isDark ? UIColor(white: 0.97, alpha: 1) : UIColor(white: 0.09, alpha: 1)
        let secondaryInk = isDark ? UIColor(white: 0.70, alpha: 1) : UIColor(white: 0.42, alpha: 1)
        let subtleFill = isDark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.045)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { ctx in
            let cg = ctx.cgContext
            let fullRect = CGRect(origin: .zero, size: canvasSize)

            // 1. Outer Canvas & Ambient Glow
            drawOuterBackdrop(in: fullRect, cg: cg, cover: cover, accent: accent, isDark: isDark)

            // 2. Elevated Main Card Surface
            let cardRect = CGRect(x: outerPad, y: outerPad, width: cardW, height: cardH)
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 44)
            cg.saveGState()
            cg.setShadow(
                offset: CGSize(width: 0, height: 14),
                blur: 34,
                color: UIColor.black.withAlphaComponent(isDark ? 0.42 : 0.09).cgColor
            )
            let cardFill = isDark
                ? UIColor(red: 0.09, green: 0.10, blue: 0.135, alpha: 0.90)
                : UIColor(white: 1.0, alpha: 0.97)
            cardFill.setFill()
            cardPath.fill()
            cg.restoreGState()

            let cardBorder = isDark
                ? UIColor.white.withAlphaComponent(0.13)
                : UIColor.black.withAlphaComponent(0.06)
            cardBorder.setStroke()
            cardPath.lineWidth = 2
            cardPath.stroke()

            let leftX = cardRect.minX + innerPad
            var y = cardRect.minY + innerPad

            // 3. Top SwiftPili Brand Header Row
            let iconRect = CGRect(x: leftX, y: y + 2, width: 64, height: 64)
            SwiftPiliBrandArt.drawAppIcon(in: iconRect, cg: cg, accent: accent, isDark: isDark)

            let brandNameFont = UIFont.systemFont(ofSize: 33, weight: .bold)
            let brandTagFont = UIFont.systemFont(ofSize: 21, weight: .medium)
            let brandX = iconRect.maxX + 18
            draw(
                "SwiftPili",
                font: brandNameFont,
                color: primaryInk,
                para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
                in: CGRect(x: brandX, y: y + 2, width: 360, height: 38)
            )
            draw(
                String(localized: "Video Share Card"),
                font: brandTagFont,
                color: secondaryInk,
                para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
                in: CGRect(x: brandX, y: y + 40, width: 380, height: 28)
            )

            let bvidDisplay = request.bvid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bvidDisplay.isEmpty {
                let bvFont = UIFont.monospacedSystemFont(ofSize: 23, weight: .semibold)
                let bvSize = (bvidDisplay as NSString).size(withAttributes: [.font: bvFont])
                let pillW = ceil(bvSize.width) + 32
                let pillH: CGFloat = 44
                let pillRect = CGRect(
                    x: leftX + contentW - pillW,
                    y: y + (brandBarH - pillH) * 0.5,
                    width: pillW,
                    height: pillH
                )
                let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: pillH * 0.5)
                accent.withAlphaComponent(isDark ? 0.20 : 0.12).setFill()
                pillPath.fill()
                draw(
                    bvidDisplay,
                    font: bvFont,
                    color: accent,
                    para: centeredParagraph(),
                    in: CGRect(
                        x: pillRect.minX,
                        y: pillRect.minY + (pillH - ceil(bvFont.lineHeight)) * 0.5,
                        width: pillW,
                        height: ceil(bvFont.lineHeight)
                    )
                )
            }

            y += brandBarH + gapAfterBrand

            // 4. Hero Video Cover with Adaptive Framing & Duration Pill
            let coverRect = CGRect(x: leftX, y: y, width: contentW, height: coverH)
            drawHeroCover(
                cover: cover,
                in: coverRect,
                durationSeconds: request.durationSeconds,
                accent: accent,
                isDark: isDark,
                cg: cg
            )

            y += coverH + gapAfterCover

            // 5. Video Title
            draw(
                safeTitle,
                font: titleFont,
                color: primaryInk,
                para: titlePara,
                in: CGRect(x: leftX, y: y, width: contentW, height: titleH)
            )
            y += titleH + gapAfterTitle

            // 6. Creator Avatar + Name + Stats Pills
            drawCreatorAndStatsRow(
                uploader: request.uploader,
                avatar: avatar,
                viewCount: request.viewCount,
                likeCount: request.likeCount,
                upFont: upFont,
                statFont: statFont,
                primaryInk: primaryInk,
                secondaryInk: secondaryInk,
                subtleFill: subtleFill,
                accent: accent,
                in: CGRect(x: leftX, y: y, width: contentW, height: creatorRowH),
                cg: cg
            )
            y += creatorRowH

            // 7. Optional Description Quote Card
            if hasDesc {
                y += gapBeforeDesc
                let boxRect = CGRect(x: leftX, y: y, width: contentW, height: descBoxH)
                let boxPath = UIBezierPath(roundedRect: boxRect, cornerRadius: 22)
                subtleFill.setFill()
                boxPath.fill()

                let quoteBarRect = CGRect(
                    x: boxRect.minX + 16,
                    y: boxRect.minY + 18,
                    width: 6,
                    height: max(20, boxRect.height - 36)
                )
                accent.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: quoteBarRect, cornerRadius: 3).fill()

                draw(
                    normalizedDesc,
                    font: descFont,
                    color: secondaryInk,
                    para: descPara,
                    in: CGRect(
                        x: boxRect.minX + 34,
                        y: boxRect.minY + 18,
                        width: descInnerW,
                        height: descTextH
                    )
                )
                y += descBoxH
            }

            // 8. Hairline Divider
            y += gapBeforeDivider
            let dividerColor = isDark
                ? UIColor.white.withAlphaComponent(0.10)
                : UIColor.black.withAlphaComponent(0.07)
            dividerColor.setFill()
            cg.fill(CGRect(x: leftX, y: y, width: contentW, height: 2))
            y += 2 + dividerGapAfter

            // 9. Branded QR Footer with Embedded SwiftPili Emblem
            let qrPadRect = CGRect(
                x: leftX + contentW - qrBoxSide,
                y: y,
                width: qrBoxSide,
                height: qrBoxSide
            )
            let qrPadPath = UIBezierPath(roundedRect: qrPadRect, cornerRadius: 26)
            UIColor.white.setFill()
            qrPadPath.fill()
            if !isDark {
                UIColor.black.withAlphaComponent(0.06).setStroke()
                qrPadPath.lineWidth = 1.5
                qrPadPath.stroke()
            }

            let qrInset: CGFloat = 14
            let qrDrawRect = qrPadRect.insetBy(dx: qrInset, dy: qrInset)
            if let qrImg = qrImage(from: request.linkURL, side: qrDrawRect.width) {
                qrImg.draw(in: qrDrawRect)
                let badgeSide: CGFloat = 44
                let badgePadRect = CGRect(
                    x: qrDrawRect.midX - (badgeSide + 8) * 0.5,
                    y: qrDrawRect.midY - (badgeSide + 8) * 0.5,
                    width: badgeSide + 8,
                    height: badgeSide + 8
                )
                UIColor.white.setFill()
                UIBezierPath(roundedRect: badgePadRect, cornerRadius: (badgeSide + 8) * 0.25).fill()
                let badgeRect = badgePadRect.insetBy(dx: 4, dy: 4)
                SwiftPiliBrandArt.drawAppIcon(in: badgeRect, cg: cg, accent: accent, isDark: false)
            }

            let footerTextW = qrPadRect.minX - leftX - 28
            let scanLineH = ceil(scanFont.lineHeight)
            let linkLineH = ceil(linkFont.lineHeight * 1.4)
            let viaPillH: CGFloat = 40
            let footerStackH = scanLineH + 12 + linkLineH + 18 + viaPillH
            var fy = y + max(0, (qrBoxSide - footerStackH) * 0.5)

            draw(
                String(localized: "Scan to watch"),
                font: scanFont,
                color: primaryInk,
                para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
                in: CGRect(x: leftX, y: fy, width: footerTextW, height: scanLineH)
            )
            fy += scanLineH + 12

            draw(
                request.linkDisplay,
                font: linkFont,
                color: secondaryInk,
                para: paragraph(lineBreak: .byTruncatingMiddle, lineSpacing: 0),
                in: CGRect(x: leftX, y: fy, width: footerTextW, height: linkLineH)
            )
            fy += linkLineH + 18

            let viaText = String(localized: "Shared via SwiftPili")
            let viaTextSize = (viaText as NSString).size(withAttributes: [.font: viaFont])
            let viaPillW = min(footerTextW, ceil(viaTextSize.width) + 36)
            let viaPillRect = CGRect(x: leftX, y: fy, width: viaPillW, height: viaPillH)
            accent.withAlphaComponent(isDark ? 0.20 : 0.12).setFill()
            UIBezierPath(roundedRect: viaPillRect, cornerRadius: viaPillH * 0.5).fill()
            draw(
                viaText,
                font: viaFont,
                color: accent,
                para: centeredParagraph(),
                in: CGRect(
                    x: viaPillRect.minX + 12,
                    y: viaPillRect.minY + (viaPillH - ceil(viaFont.lineHeight)) * 0.5,
                    width: viaPillW - 24,
                    height: ceil(viaFont.lineHeight)
                )
            )
        }
    }

    // MARK: - Sub-Renderers

    nonisolated private static func drawOuterBackdrop(
        in rect: CGRect,
        cg: CGContext,
        cover: UIImage?,
        accent: UIColor,
        isDark: Bool
    ) {
        let base = isDark
            ? UIColor(red: 0.045, green: 0.05, blue: 0.075, alpha: 1)
            : UIColor(red: 0.955, green: 0.96, blue: 0.978, alpha: 1)
        base.setFill()
        cg.fill(rect)

        if isDark, let cover, let blurred = blurredCoverImage(from: cover) {
            cg.saveGState()
            cg.setAlpha(0.45)
            let scale = max(rect.width / blurred.size.width, rect.height / blurred.size.height)
            let dw = blurred.size.width * scale
            let dh = blurred.size.height * scale
            blurred.draw(in: CGRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh))
            cg.restoreGState()
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let glowAlpha: CGFloat = isDark ? 0.28 : 0.14
        if let glow = CGGradient(
            colorsSpace: colorSpace,
            colors: [accent.withAlphaComponent(glowAlpha).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            cg.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: rect.maxX * 0.85, y: rect.minY + 140),
                startRadius: 0,
                endCenter: CGPoint(x: rect.maxX * 0.85, y: rect.minY + 140),
                endRadius: rect.width * 0.72,
                options: []
            )
        }
    }

    nonisolated private static func blurredCoverImage(from image: UIImage) -> UIImage? {
        guard let ciInput = CIImage(image: image) else { return nil }
        let maxDim: CGFloat = 240
        let scale = min(1.0, maxDim / max(ciInput.extent.width, ciInput.extent.height, 1))
        let downsampled = ciInput.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let clamped = downsampled.clampedToExtent()
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = clamped
        blur.radius = 22
        guard let output = blur.outputImage?.cropped(to: downsampled.extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(output, from: downsampled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    nonisolated private static func drawHeroCover(
        cover: UIImage?,
        in coverRect: CGRect,
        durationSeconds: Int,
        accent: UIColor,
        isDark: Bool,
        cg: CGContext
    ) {
        let path = UIBezierPath(roundedRect: coverRect, cornerRadius: 28)
        cg.saveGState()
        path.addClip()

        if let cover, cover.size.width > 0, cover.size.height > 0 {
            let scale = max(coverRect.width / cover.size.width, coverRect.height / cover.size.height)
            let dw = cover.size.width * scale
            let dh = cover.size.height * scale
            cover.draw(in: CGRect(
                x: coverRect.midX - dw * 0.5,
                y: coverRect.midY - dh * 0.5,
                width: dw,
                height: dh
            ))
        } else {
            let fallback = isDark ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.92, alpha: 1)
            fallback.setFill()
            cg.fill(coverRect)
            let emblemSide: CGFloat = 132
            SwiftPiliBrandArt.drawAppIcon(
                in: CGRect(
                    x: coverRect.midX - emblemSide * 0.5,
                    y: coverRect.midY - emblemSide * 0.5,
                    width: emblemSide,
                    height: emblemSide
                ),
                cg: cg,
                accent: accent,
                isDark: isDark
            )
        }

        if durationSeconds > 0 {
            let durText = FormatUtils.duration(durationSeconds)
            let durFont = UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
            let durSize = (durText as NSString).size(withAttributes: [.font: durFont])
            let badgeW = ceil(durSize.width) + 28
            let badgeH: CGFloat = 40
            let badgeRect = CGRect(
                x: coverRect.maxX - badgeW - 20,
                y: coverRect.maxY - badgeH - 18,
                width: badgeW,
                height: badgeH
            )
            UIColor.black.withAlphaComponent(0.68).setFill()
            UIBezierPath(roundedRect: badgeRect, cornerRadius: badgeH * 0.5).fill()
            draw(
                durText,
                font: durFont,
                color: .white,
                para: centeredParagraph(),
                in: CGRect(
                    x: badgeRect.minX,
                    y: badgeRect.minY + (badgeH - ceil(durFont.lineHeight)) * 0.5,
                    width: badgeW,
                    height: ceil(durFont.lineHeight)
                )
            )
        }

        cg.restoreGState()
    }

    nonisolated private static func drawCreatorAndStatsRow(
        uploader: String,
        avatar: UIImage?,
        viewCount: Int,
        likeCount: Int,
        upFont: UIFont,
        statFont: UIFont,
        primaryInk: UIColor,
        secondaryInk: UIColor,
        subtleFill: UIColor,
        accent: UIColor,
        in rowRect: CGRect,
        cg: CGContext
    ) {
        let avatarSide: CGFloat = 50
        let avatarRect = CGRect(
            x: rowRect.minX,
            y: rowRect.minY + (rowRect.height - avatarSide) * 0.5,
            width: avatarSide,
            height: avatarSide
        )
        cg.saveGState()
        UIBezierPath(ovalIn: avatarRect).addClip()
        if let avatar, avatar.size.width > 0, avatar.size.height > 0 {
            avatar.draw(in: avatarRect)
        } else {
            accent.withAlphaComponent(0.18).setFill()
            cg.fill(avatarRect)
            let initial = String(uploader.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
            let initFont = UIFont.systemFont(ofSize: 24, weight: .bold)
            draw(
                initial.isEmpty ? "U" : initial,
                font: initFont,
                color: accent,
                para: centeredParagraph(),
                in: CGRect(
                    x: avatarRect.minX,
                    y: avatarRect.minY + (avatarSide - ceil(initFont.lineHeight)) * 0.5,
                    width: avatarSide,
                    height: ceil(initFont.lineHeight)
                )
            )
        }
        cg.restoreGState()

        var rightCursor = rowRect.maxX
        if likeCount > 0 {
            let text = "♥ \(FormatUtils.viewCount(likeCount))"
            rightCursor = drawStatPill(
                text: text,
                font: statFont,
                textColor: secondaryInk,
                fillColor: subtleFill,
                rightEdge: rightCursor,
                midY: rowRect.midY
            ) - 12
        }
        if viewCount > 0 {
            let text = "▶ \(FormatUtils.viewCount(viewCount))"
            rightCursor = drawStatPill(
                text: text,
                font: statFont,
                textColor: secondaryInk,
                fillColor: subtleFill,
                rightEdge: rightCursor,
                midY: rowRect.midY
            ) - 12
        }

        let nameX = avatarRect.maxX + 16
        let maxNameW = max(120, rightCursor - nameX - 12)
        let displayUp = uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedUp = displayUp.hasPrefix("@") || displayUp.isEmpty ? displayUp : "@\(displayUp)"
        let upLineH = ceil(upFont.lineHeight)
        draw(
            formattedUp,
            font: upFont,
            color: primaryInk,
            para: paragraph(lineBreak: .byTruncatingTail, lineSpacing: 0),
            in: CGRect(
                x: nameX,
                y: rowRect.minY + (rowRect.height - upLineH) * 0.5,
                width: maxNameW,
                height: upLineH
            )
        )
    }

    nonisolated private static func drawStatPill(
        text: String,
        font: UIFont,
        textColor: UIColor,
        fillColor: UIColor,
        rightEdge: CGFloat,
        midY: CGFloat
    ) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let w = ceil(size.width) + 26
        let h: CGFloat = 42
        let rect = CGRect(x: rightEdge - w, y: midY - h * 0.5, width: w, height: h)
        fillColor.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: h * 0.5).fill()
        draw(
            text,
            font: font,
            color: textColor,
            para: centeredParagraph(),
            in: CGRect(
                x: rect.minX,
                y: rect.minY + (h - ceil(font.lineHeight)) * 0.5,
                width: w,
                height: ceil(font.lineHeight)
            )
        )
        return rect.minX
    }

    nonisolated private static func qrImage(from string: String, side: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    nonisolated private static func paragraph(lineBreak: NSLineBreakMode, lineSpacing: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = lineBreak
        p.lineSpacing = lineSpacing
        return p
    }

    nonisolated private static func centeredParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    nonisolated private static func height(
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

    nonisolated private static func draw(
        _ s: String, font: UIFont, color: UIColor, para: NSParagraphStyle, in rect: CGRect
    ) {
        (s as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]
        )
    }
}

// MARK: - Rich UIActivityItemSource with SwiftPili LinkPresentation Header

final class SwiftPiliPosterActivityItemSource: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let title: String
    private let appIcon: UIImage

    init(image: UIImage, title: String, accent: UIColor) {
        self.image = image
        self.title = title
        self.appIcon = SwiftPiliBrandArt.appIconImage(side: 120, accent: accent)
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? "SwiftPili" : trimmed
        metadata.iconProvider = NSItemProvider(object: appIcon)
        metadata.imageProvider = NSItemProvider(object: image)
        return metadata
    }
}

final class SwiftPiliLinkActivityItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String
    private let uploader: String
    private let previewImage: UIImage?
    private let appIcon: UIImage

    init(
        url: URL,
        title: String = "",
        uploader: String = "",
        previewImage: UIImage? = nil,
        accent: UIColor? = nil
    ) {
        self.url = url
        self.title = title
        self.uploader = uploader
        self.previewImage = previewImage
        let resolvedAccent = accent ?? UIColor(red: 0.984, green: 0.447, blue: 0.600, alpha: 1)
        self.appIcon = SwiftPiliBrandArt.appIconImage(side: 120, accent: resolvedAccent)
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SwiftPili" : trimmed
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUp = uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, !trimmedUp.isEmpty {
            metadata.title = "\(trimmedTitle) (@\(trimmedUp)) — SwiftPili"
        } else if !trimmedTitle.isEmpty {
            metadata.title = "\(trimmedTitle) — SwiftPili"
        } else {
            metadata.title = "SwiftPili"
        }
        metadata.originalURL = url
        metadata.url = url
        metadata.iconProvider = NSItemProvider(object: appIcon)
        metadata.imageProvider = NSItemProvider(object: previewImage ?? appIcon)
        return metadata
    }
}

// MARK: - Unified SwiftPili Branded Share Studio Sheet

struct VideoSharePayload: Identifiable, Equatable, Sendable {
    let id = UUID()
    let bvid: String
    let aid: Int
    let title: String
    let uploader: String
    let avatarURL: String
    let coverURL: String
    let description: String
    let durationSeconds: Int
    let viewCount: Int
    let likeCount: Int
    let isPortraitCover: Bool

    var shareURLString: String {
        if !bvid.isEmpty {
            return "https://www.bilibili.com/video/\(bvid)"
        }
        if aid > 0 {
            return "https://www.bilibili.com/video/av\(aid)"
        }
        return "https://www.bilibili.com"
    }

    var linkDisplay: String {
        if !bvid.isEmpty {
            return "bilibili.com/video/\(bvid)"
        }
        if aid > 0 {
            return "bilibili.com/video/av\(aid)"
        }
        return "bilibili.com"
    }

    static func from(info: VideoInfo) -> Self {
        Self(
            bvid: info.bvid,
            aid: info.aid,
            title: info.title,
            uploader: info.owner.name,
            avatarURL: info.owner.face,
            coverURL: info.pic,
            description: info.desc,
            durationSeconds: info.duration,
            viewCount: info.stat.view,
            likeCount: info.stat.like,
            isPortraitCover: info.dimension?.isPortrait ?? false
        )
    }
}

struct VideoShareStudioSheet: View {
    let payload: VideoSharePayload
    var onShared: (@MainActor () async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppMotion private var motion
    @AppStorage("share_card_style") private var styleRaw = ShareCardStyle.ambientDark.rawValue
    @AppStorage("share_card_includes_desc") private var includesDescription = true

    @State private var renderedPoster: UIImage?
    @State private var isRendering = false
    @State private var saveSucceeded = false
    @State private var toastMessage: ToastMessage?

    private var selectedStyle: ShareCardStyle {
        ShareCardStyle(rawValue: styleRaw) ?? .ambientDark
    }

    private var hasDescription: Bool {
        let trimmed = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "-"
    }

    private var resolvedAccentUIColor: UIColor {
        UIColor(Color.biliAccent).resolvedColor(with: UITraitCollection.current)
    }

    private var renderFingerprint: String {
        "\(payload.bvid)-\(payload.aid)-\(selectedStyle.rawValue)-\(includesDescription)"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 14) {
                headerBar
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                styleToolbar
                    .padding(.horizontal, 18)

                posterPreviewStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)

                actionDock
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }

            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion.feedbackAnimation(normal: .spring(duration: 0.28)), value: toastMessage)
        .accentContentBoundary()
        .appAdaptiveSheet(compactDetents: [.fraction(0.82), .large], padSizing: .form)
        .task(id: renderFingerprint) {
            await renderCurrentPoster()
        }
    }

    // MARK: - Header & Style Controls

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(uiImage: SwiftPiliBrandArt.appIconImage(
                side: 60,
                accent: resolvedAccentUIColor,
                isDark: selectedStyle == .ambientDark
            ))
            .resizable()
            .frame(width: 28, height: 28)

            Text("Share Video")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(AppFill.inset, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
    }

    private var styleToolbar: some View {
        HStack(spacing: 8) {
            ForEach(ShareCardStyle.allCases) { style in
                let isSelected = selectedStyle == style
                Button {
                    guard styleRaw != style.rawValue else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    styleRaw = style.rawValue
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: style.symbolName)
                            .font(.caption2.weight(.semibold))
                        Text(style.labelKey)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Color.biliAccent : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        isSelected ? Color.biliAccent.opacity(0.15) : AppFill.inset,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                isSelected ? Color.biliAccent.opacity(0.45) : Color.primary.opacity(0.08),
                                lineWidth: 0.8
                            )
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if hasDescription {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    includesDescription.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: includesDescription ? "checkmark" : "text.quote")
                            .font(.caption2.weight(.semibold))
                        Text("Include Intro")
                            .font(.caption.weight(includesDescription ? .semibold : .medium))
                    }
                    .foregroundStyle(includesDescription ? Color.biliAccent : .secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        includesDescription ? Color.biliAccent.opacity(0.15) : AppFill.inset,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                includesDescription ? Color.biliAccent.opacity(0.45) : Color.primary.opacity(0.08),
                                lineWidth: 0.8
                            )
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Live Poster Preview Stage

    private var posterPreviewStage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                .fill(AppFill.inset.opacity(0.65))

            if let renderedPoster {
                Image(uiImage: renderedPoster)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(14)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }

            if isRendering, renderedPoster != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(20)
            }
        }
        .animation(motion.animation(normal: .easeOut(duration: 0.2)), value: renderedPoster != nil)
    }

    // MARK: - Action Dock

    private var actionDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    sharePosterImage()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Text("Share Poster")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.biliAccent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.appControl)
                .disabled(renderedPoster == nil)
                .opacity(renderedPoster == nil ? 0.55 : 1.0)
                .accessibilityIdentifier("shareStudio.sharePoster")

                Button {
                    shareRichLink()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("Share Link")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.biliAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.biliAccent.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.biliAccent.opacity(0.35), lineWidth: 0.8)
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.appControl)
                .accessibilityIdentifier("shareStudio.shareLink")
            }

            HStack(spacing: 8) {
                quickUtilityButton(
                    title: saveSucceeded ? "Saved" : "Save Poster",
                    symbol: saveSucceeded ? "checkmark" : "arrow.down.to.line",
                    isHighlighted: saveSucceeded,
                    disabled: renderedPoster == nil
                ) {
                    savePosterToPhotos()
                }

                quickUtilityButton(
                    title: "Copy Poster",
                    symbol: "photo.on.rectangle",
                    disabled: renderedPoster == nil
                ) {
                    guard let renderedPoster else { return }
                    UIPasteboard.general.image = renderedPoster
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast(String(localized: "Copied"), style: .success)
                    recordShareIfNeeded()
                }

                quickUtilityButton(
                    title: "Copy Link",
                    symbol: "link"
                ) {
                    UIPasteboard.general.string = payload.shareURLString
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showToast(String(localized: "Link copied"), style: .success)
                    recordShareIfNeeded()
                }

                if !payload.bvid.isEmpty {
                    quickUtilityButton(
                        title: "Copy BV ID",
                        symbol: "doc.on.doc"
                    ) {
                        UIPasteboard.general.string = payload.bvid
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showToast(String(localized: "Copied"), style: .success)
                    }
                    .contextMenu {
                        if payload.aid > 0 {
                            Button {
                                UIPasteboard.general.string = "av\(payload.aid)"
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showToast(String(localized: "Copied"), style: .success)
                            } label: {
                                Label("Copy AV ID", systemImage: "number")
                            }
                        }
                    }
                }
            }
        }
    }

    private func quickUtilityButton(
        title: LocalizedStringKey,
        symbol: String,
        isHighlighted: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.biliAccent : .primary)
                    .frame(height: 18)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isHighlighted ? Color.biliAccent : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(AppFill.inset, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        }
        .buttonStyle(.appControl)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }

    // MARK: - Actions

    private func renderCurrentPoster() async {
        isRendering = true
        let request = ShareCardRenderer.Request(
            coverURL: payload.coverURL,
            avatarURL: payload.avatarURL,
            title: payload.title,
            uploader: payload.uploader,
            description: payload.description,
            bvid: payload.bvid,
            durationSeconds: payload.durationSeconds,
            viewCount: payload.viewCount,
            likeCount: payload.likeCount,
            isPortraitCover: payload.isPortraitCover,
            linkURL: payload.shareURLString,
            linkDisplay: payload.linkDisplay,
            accent: resolvedAccentUIColor,
            style: selectedStyle,
            includesDescription: includesDescription
        )
        if let image = try? await ShareCardRenderer.prepare(request), !Task.isCancelled {
            renderedPoster = image
        }
        if !Task.isCancelled {
            isRendering = false
        }
    }

    private func sharePosterImage() {
        guard let renderedPoster else { return }
        let source = SwiftPiliPosterActivityItemSource(
            image: renderedPoster,
            title: payload.title,
            accent: resolvedAccentUIColor
        )
        ActivitySharePresenter.present(items: [source]) { completed in
            guard completed else { return }
            recordShareIfNeeded()
        }
    }

    private func shareRichLink() {
        guard let url = URL(string: payload.shareURLString) else { return }
        let source = SwiftPiliLinkActivityItemSource(
            url: url,
            title: payload.title,
            uploader: payload.uploader,
            previewImage: renderedPoster,
            accent: resolvedAccentUIColor
        )
        ActivitySharePresenter.present(items: [source]) { completed in
            guard completed else { return }
            recordShareIfNeeded()
        }
    }

    private func savePosterToPhotos() {
        guard let image = renderedPoster else { return }
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                saveSucceeded = true
                showToast(String(localized: "Saved to Photos"), style: .success)
                recordShareIfNeeded()
                try? await Task.sleep(for: .seconds(1.8))
                saveSucceeded = false
            } catch {
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    private func recordShareIfNeeded() {
        guard let onShared else { return }
        Task { await onShared() }
    }

    private func showToast(_ text: String, style: ToastMessage.Style) {
        let message = ToastMessage(text: text, style: style)
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}
