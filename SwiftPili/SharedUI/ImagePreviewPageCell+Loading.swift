import Kingfisher
import UIKit

/// Kingfisher progressive still loading, GIF playback, and deferred full-res reveal.
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
        if ImagePreviewRasterPolicy.isGIF(url) {
            loadGIF(url: url, generation: generation)
        } else {
            loadStill(url: url, generation: generation)
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

    static func validAspect(from size: CGSize?) -> CGFloat? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    static func validAspect(from image: UIImage?) -> CGFloat? {
        guard let image else { return nil }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return validAspect(from: size)
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
                    if let aspect = Self.validAspect(from: value.image) {
                        self.applyAspect(aspect, authoritative: true, animated: false)
                    }
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
        let requestAspect = targetMetadataAspect ?? resolvedAspect
        let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: requestAspect)
        let target = mode == .reading
            ? ImagePreviewRasterPolicy.readingTarget(width: viewport.width, aspect: requestAspect)
            : ImagePreviewRasterPolicy.zoomTarget(size: viewport, aspect: requestAspect)
        lastRasterEdge = ImagePreviewRasterPolicy.canonicalEdge(target: target)

        let thumbURL = ImagePreviewRasterPolicy.thumbnailURL(for: url, viewportWidth: viewport.width)
        if thumbURL != url, imageView.image == nil {
            let thumbOpts = ImagePreviewRasterPolicy.stillOptions(target: target, cacheOriginal: false)
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
        requestFullStill(url: url, target: target, generation: generation)
    }

    func requestFullStill(url: URL, target: CGSize, generation: UInt64) {
        let options = ImagePreviewRasterPolicy.stillOptions(target: target, cacheOriginal: true)
        let parsed = KingfisherParsedOptionsInfo(options)
        fullTask = KingfisherManager.shared.retrieveImage(with: url, options: options) { [weak self] res in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                switch res {
                case .success(let value):
                    if self.defersFullReveal, self.isShowingServerCroppedThumb {
                        self.pendingFullReveal = PendingFullReveal(
                            generation: generation, result: value, options: parsed, url: url
                        )
                        return
                    }
                    self.commitFullStillResult(value, options: parsed, url: url, generation: generation)
                case .failure:
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

        let newAspect = targetMetadataAspect ?? Self.validAspect(from: value.image)
        let aspectDiffers = newAspect.flatMap { next in
            resolvedAspect.map { abs($0 / next - 1) > 0.02 }
        } ?? false

        if wasEmpty {
            if let newAspect { applyAspect(newAspect, authoritative: false, animated: false) }
            installInitialImage(value.image)
        } else if aspectDiffers {
            // Long reading images or corrected metadata: keep center crop aligned during frame morph.
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
            // Frame is already at full original aspect: stationary cross-dissolve reveals outer strips
            // around the 1:1 center square with zero bounds movement or stretching.
            if !UIAccessibility.isReduceMotionEnabled {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                imageView.layer.add(fade, forKey: "imageUpgradeFade")
            }
            imageView.image = value.image
            imageView.alpha = 1
        } else {
            // Same aspect already on screen: swap directly for zero-flicker sharpening.
            imageView.image = value.image
            imageView.alpha = 1
        }
        resolveOriginalMetadata(result: value, options: options, url: url, generation: generation)
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
            let aspect = Self.validAspect(from: originalSize) ?? Self.validAspect(from: result.image)
            guard let aspect else { return }
            self.targetMetadataAspect = aspect
            self.applyAspect(aspect, authoritative: true, animated: true)
            let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: aspect)
            guard mode == .reading else { return }
            let readingTarget = ImagePreviewRasterPolicy.readingTarget(
                width: self.effectiveViewportSize.width, aspect: aspect
            )
            let neededEdge = ImagePreviewRasterPolicy.canonicalEdge(target: readingTarget)
            if neededEdge > self.lastRasterEdge * 1.15 {
                self.lastRasterEdge = neededEdge
                self.requestFullStill(url: url, target: readingTarget, generation: generation)
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
        let preserveUserPose = scrollView.zoomScale > 1.02 || scrollView.contentOffset.y > 4
        layoutImageContent(
            resetZoom: !preserveUserPose,
            animated: animated && !preserveUserPose,
            onComplete: onComplete
        )
    }
}
