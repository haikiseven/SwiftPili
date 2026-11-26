import Kingfisher
import UIKit

extension ImagePreviewPageCell {
    func cancelActiveLoads() {
        thumbTask?.cancel()
        thumbTask = nil
        fullTask?.cancel()
        fullTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        imageView.kf.cancelDownloadTask()
    }

    func startLoading(url: URL, generation: UInt64) {
        let canonicalURL = ImagePreviewRasterPolicy.originalURL(for: url)
        if ImagePreviewRasterPolicy.isGIF(canonicalURL) {
            loadGIF(url: canonicalURL, generation: generation)
        } else {
            loadStill(url: canonicalURL, generation: generation)
        }
    }

    func flushDeferredFullImageReveal() {
        defersFullReveal = false
        guard let pending = pendingFullReveal, pending.generation == loadGeneration else { return }
        pendingFullReveal = nil
        commitFullStillResult(
            pending.result, options: pending.options, url: pending.url, generation: pending.generation
        )
    }

    func upgradeResolutionForZoomIfNeeded() {
        guard hasFullImage,
              !hasUpgradedForZoom,
              let url = currentURL,
              !ImagePreviewRasterPolicy.isGIF(url),
              let originalPixels = originalPixelSize else { return }
        let originalMaxEdge = max(originalPixels.width, originalPixels.height)
        guard lastDecodedPixelEdge > 0, lastDecodedPixelEdge < originalMaxEdge * 0.99 else { return }

        let baseMax = max(imageView.bounds.width, imageView.bounds.height)
        guard baseMax.isFinite, baseMax > 0 else { return }
        let displayedMaxEdgePx = baseMax * scrollView.zoomScale * effectiveDisplayScale
        guard displayedMaxEdgePx > lastDecodedPixelEdge * 1.1 else { return }

        let targetEdge = ImagePreviewRasterPolicy.zoomedDecodePixelEdge(originalPixelSize: originalPixels)
        guard targetEdge > lastDecodedPixelEdge * 1.05,
              targetEdge > lastRequestedPixelEdge * 1.05 else { return }

        hasUpgradedForZoom = true
        requestFullStill(
            url: url,
            pixelEdge: targetEdge,
            generation: loadGeneration,
            isResolutionUpgrade: true
        )
    }

    static func validPixelSize(from size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    static func validPixelSize(from image: UIImage?) -> CGSize? {
        guard let image else { return nil }
        return ImagePreviewMetadata.pixelDimensions(of: image)
    }

    static func validAspect(from size: CGSize?) -> CGFloat? {
        guard let size = validPixelSize(from: size) else { return nil }
        let ratio = size.width / size.height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    static func validAspect(from image: UIImage?) -> CGFloat? {
        validAspect(from: validPixelSize(from: image))
    }
}

private extension ImagePreviewPageCell {
    func loadGIF(url: URL, generation: UInt64) {
        let options: KingfisherOptionsInfo = [.transition(.none)]
        fullTask = imageView.kf.setImage(with: url, placeholder: imageView.image, options: options) { [weak self] res in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                switch res {
                case .success(let value):
                    self.hasFullImage = true
                    self.isShowingServerCroppedThumb = false
                    self.spinner.stopAnimating()
                    self.errorButton.isHidden = true
                    self.imageView.alpha = 1
                    if let gifPixels = Self.validPixelSize(from: value.image) {
                        self.originalPixelSize = gifPixels
                        self.lastDecodedPixelEdge = max(gifPixels.width, gifPixels.height)
                        if let aspect = Self.validAspect(from: gifPixels) {
                            self.targetMetadataAspect = aspect
                            self.applyAspect(aspect, authoritative: true, animated: false)
                        }
                    }
                    self.updateZoomBoundsForCurrentMetrics()
                case .failure:
                    self.fullFailed = true
                    self.spinner.stopAnimating()
                    if self.imageView.image == nil { self.errorButton.isHidden = false }
                }
            }
        }
    }

    func loadStill(url: URL, generation: UInt64) {
        let viewport = effectiveViewportSize
        let displayScale = effectiveDisplayScale
        let requestAspect = targetMetadataAspect ?? resolvedAspect
        let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: requestAspect, viewport: viewport)
        let initialPixelEdge = ImagePreviewRasterPolicy.initialDecodePixelEdge(
            originalPixelSize: originalPixelSize,
            aspect: requestAspect,
            viewport: viewport,
            displayScale: displayScale,
            mode: mode
        )
        lastRequestedPixelEdge = initialPixelEdge

        let thumbURL = ImagePreviewRasterPolicy.thumbnailURL(
            for: url,
            viewportWidth: viewport.width,
            displayScale: displayScale
        )
        if thumbURL != url, imageView.image == nil {
            let thumbOpts = ImagePreviewRasterPolicy.stillOptions(
                pixelEdge: initialPixelEdge,
                displayScale: displayScale,
                cacheOriginal: false
            )
            thumbTask = KingfisherManager.shared.retrieveImage(with: thumbURL, options: thumbOpts) { [weak self] res in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation, !self.hasFullImage else { return }
                    switch res {
                    case .success(let value):
                        self.installInitialImage(value.image)
                        if !self.hasAuthoritativeAspect, let aspect = Self.validAspect(from: value.image) {
                            self.applyAspect(aspect, authoritative: false, animated: false)
                        }
                    case .failure:
                        self.thumbFailed = true
                        self.updateFailureVisibility()
                    }
                }
            }
        } else {
            thumbFailed = true
        }
        requestFullStill(url: url, pixelEdge: initialPixelEdge, generation: generation)
    }

    func requestFullStill(
        url: URL,
        pixelEdge: CGFloat,
        generation: UInt64,
        isResolutionUpgrade: Bool = false
    ) {
        let displayScale = effectiveDisplayScale
        let options = ImagePreviewRasterPolicy.stillOptions(
            pixelEdge: pixelEdge,
            displayScale: displayScale,
            cacheOriginal: true
        )
        let parsed = KingfisherParsedOptionsInfo(options)
        lastRequestedPixelEdge = max(lastRequestedPixelEdge, pixelEdge)
        fullTask = KingfisherManager.shared.retrieveImage(with: url, options: options) { [weak self] res in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                switch res {
                case .success(let value):
                    if isResolutionUpgrade {
                        self.commitResolutionUpgrade(value, generation: generation)
                        return
                    }
                    if self.defersFullReveal, self.isShowingServerCroppedThumb {
                        self.pendingFullReveal = PendingFullReveal(
                            generation: generation, result: value, options: parsed, url: url
                        )
                        return
                    }
                    self.commitFullStillResult(value, options: parsed, url: url, generation: generation)
                case .failure:
                    guard !isResolutionUpgrade else { return }
                    self.fullFailed = true
                    self.updateFailureVisibility()
                }
            }
        }
    }

    func commitFullStillResult(
        _ value: RetrieveImageResult, options: KingfisherParsedOptionsInfo, url: URL, generation: UInt64
    ) {
        let wasEmpty = imageView.image == nil
        let wasServerCropped = isShowingServerCroppedThumb
        hasFullImage = true
        isShowingServerCroppedThumb = false
        spinner.stopAnimating()
        errorButton.isHidden = true
        if let decodedPixels = Self.validPixelSize(from: value.image) {
            lastDecodedPixelEdge = max(lastDecodedPixelEdge, max(decodedPixels.width, decodedPixels.height))
        }

        let newAspect = targetMetadataAspect ?? Self.validAspect(from: value.image)
        let aspectDiffers = newAspect.flatMap { next in
            resolvedAspect.map { abs($0 / next - 1) > 0.02 }
        } ?? false

        if wasEmpty {
            if let newAspect { applyAspect(newAspect, authoritative: false, animated: false) }
            installInitialImage(value.image)
        } else if aspectDiffers {
            if newAspect != nil {
                imageView.contentMode = .scaleAspectFill
            }
            imageView.image = value.image
            imageView.alpha = 1
            if let newAspect {
                applyAspect(newAspect, authoritative: false, animated: true) { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.imageView.contentMode = .scaleAspectFit
                }
            }
        } else if wasServerCropped {
            if !UIAccessibility.isReduceMotionEnabled {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                imageView.layer.add(fade, forKey: "imageUpgradeFade")
            }
            imageView.image = value.image
            imageView.alpha = 1
        } else {
            imageView.image = value.image
            imageView.alpha = 1
        }
        updateZoomBoundsForCurrentMetrics()
        resolveOriginalMetadata(result: value, options: options, url: url, generation: generation)
    }

    func commitResolutionUpgrade(_ value: RetrieveImageResult, generation: UInt64) {
        guard loadGeneration == generation else { return }
        if let decodedPixels = Self.validPixelSize(from: value.image) {
            lastDecodedPixelEdge = max(lastDecodedPixelEdge, max(decodedPixels.width, decodedPixels.height))
        }
        imageView.image = value.image
        imageView.alpha = 1
        upgradeResolutionForZoomIfNeeded()
    }

    func installInitialImage(_ image: UIImage) {
        spinner.stopAnimating()
        errorButton.isHidden = true
        imageView.image = image
        guard imageView.alpha < 0.99 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            imageView.alpha = 1
        } else {
            UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseOut) {
                self.imageView.alpha = 1
            }
        }
    }

    func resolveOriginalMetadata(
        result: RetrieveImageResult, options: KingfisherParsedOptionsInfo, url: URL, generation: UInt64
    ) {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            let originalSize = await ImagePreviewMetadata.originalSize(result: result, options: options)
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            let resolvedPixels = Self.validPixelSize(from: originalSize)
                ?? self.originalPixelSize
                ?? Self.validPixelSize(from: result.image)
            guard let resolvedPixels, let aspect = Self.validAspect(from: resolvedPixels) else { return }

            self.originalPixelSize = resolvedPixels
            self.targetMetadataAspect = aspect
            self.applyAspect(aspect, authoritative: true, animated: true)
            self.updateZoomBoundsForCurrentMetrics()

            let viewport = self.effectiveViewportSize
            let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: aspect, viewport: viewport)
            let desiredInitialEdge = ImagePreviewRasterPolicy.initialDecodePixelEdge(
                originalPixelSize: resolvedPixels,
                aspect: aspect,
                viewport: viewport,
                displayScale: self.effectiveDisplayScale,
                mode: mode
            )
            let originalMaxEdge = max(resolvedPixels.width, resolvedPixels.height)
            let decodedMaxEdge = max(
                self.lastDecodedPixelEdge,
                Self.validPixelSize(from: result.image).map { max($0.width, $0.height) } ?? 0
            )
            if desiredInitialEdge > decodedMaxEdge * 1.05,
               desiredInitialEdge > self.lastRequestedPixelEdge * 1.05,
               decodedMaxEdge < originalMaxEdge * 0.99 {
                self.requestFullStill(
                    url: url,
                    pixelEdge: desiredInitialEdge,
                    generation: generation,
                    isResolutionUpgrade: true
                )
            } else {
                self.upgradeResolutionForZoomIfNeeded()
            }
        }
    }

    func updateFailureVisibility() {
        if fullFailed, thumbFailed, imageView.image == nil {
            spinner.stopAnimating()
            errorButton.isHidden = false
        }
    }

    func applyAspect(
        _ aspect: CGFloat, authoritative: Bool, animated: Bool, onComplete: (() -> Void)? = nil
    ) {
        if authoritative { hasAuthoritativeAspect = true }
        let changed = resolvedAspect.map { abs($0 / aspect - 1) > 0.008 } ?? true
        resolvedAspect = aspect
        guard changed else {
            onComplete?()
            return
        }
        let preserveUserPose = scrollView.zoomScale > scrollView.minimumZoomScale + 0.02
            || scrollView.contentOffset.y > 4
        layoutImageContent(
            resetZoom: !preserveUserPose,
            animated: animated && !preserveUserPose,
            onComplete: onComplete
        )
    }
}
