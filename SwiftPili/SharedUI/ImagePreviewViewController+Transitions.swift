import UIKit

extension ImagePreviewViewController {
    func prepareInitialVisualState(item: ImagePreviewItem, source: ImagePreviewSourceSnapshot?) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if !reduceMotion, let source, let thumbnail = source.thumbnailImage,
           let thumbAspect = imageAspect(of: thumbnail) {
            let sourceRect = rectFromSourceWindow(source.frameInWindow)
            let startImg = ImagePreviewMath.aspectFillFrame(
                aspect: thumbAspect, in: sourceRect.size, topAligned: source.topAligned
            )
            transitionClipView.frame = sourceRect
            transitionClipView.layer.cornerRadius = source.cornerRadius
            transitionClipView.layer.cornerCurve = source.cornerCurve
            transitionClipView.alpha = 1
            transitionClipView.isHidden = false
            transitionImageView.image = thumbnail
            transitionImageView.frame = startImg
            pagerView.isHidden = true
            pagerView.alpha = 1
            pagerView.transform = .identity
        } else {
            transitionClipView.isHidden = true
            pagerView.isHidden = false
            pagerView.alpha = 0
            pagerView.transform = reduceMotion ? .identity : CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
        backdropView.alpha = 0
        chromeView.alpha = 0
    }

    func animateOpen(item: ImagePreviewItem, source: ImagePreviewSourceSnapshot?) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if !reduceMotion, let source, let thumbnail = source.thumbnailImage,
           let thumbAspect = imageAspect(of: thumbnail) {
            let fullAspect = pixelAspect(of: source.pixelSize)
            let displayAspect = fullAspect ?? thumbAspect
            animateOpenFromSource(
                item: item, source: source, displayAspect: displayAspect, thumbAspect: thumbAspect
            )
        } else {
            animateOpenFallback(item: item, reduceMotion: reduceMotion)
        }
    }

    func animateDismiss(item: ImagePreviewItem, destination: ImagePreviewSourceSnapshot?) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let cell = activePageCell()
        let activeImage = cell?.currentDisplayedImage ?? transitionImageView.image
        if !reduceMotion, let destination, let activeImage,
           let aspect = imageAspect(of: activeImage) ?? pixelAspect(of: destination.pixelSize) {
            animateDismissToSource(
                item: item, destination: destination, activeImage: activeImage, aspect: aspect, cell: cell
            )
        } else {
            animateDismissFallback(item: item, reduceMotion: reduceMotion)
        }
    }

    func cancelInteractiveDrag() {
        if UIAccessibility.isReduceMotionEnabled {
            pagerView.transform = .identity
            backdropView.alpha = 1
            chromeView.alpha = 1
            phase = .presented
            setStatusBarImmersive(true, animated: false)
            return
        }
        let timing = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: .zero)
        let animator = UIViewPropertyAnimator(duration: 0.26, timingParameters: timing)
        animator.addAnimations {
            self.pagerView.transform = .identity
            self.backdropView.alpha = 1
            self.chromeView.alpha = 1
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.phase == .dragging else { return }
            self.phase = .presented
            self.activeAnimator = nil
            self.setStatusBarImmersive(true, animated: true)
        }
        activeAnimator = animator
        animator.startAnimation()
    }
}

private extension ImagePreviewViewController {
    func animateOpenFromSource(
        item: ImagePreviewItem,
        source: ImagePreviewSourceSnapshot,
        displayAspect: CGFloat,
        thumbAspect: CGFloat
    ) {
        let target = targetFramesForOpen(
            url: item.urls[item.index],
            aspect: displayAspect,
            thumbAspect: thumbAspect,
            isServerCropped: source.isServerCropped
        )
        hiddenSourceView = source.sourceView
        hiddenSourceView?.isHidden = true
        phase = .opening

        let timing = UISpringTimingParameters(dampingRatio: 0.88, initialVelocity: .zero)
        let animator = UIViewPropertyAnimator(duration: 0.30, timingParameters: timing)
        animator.addAnimations {
            self.transitionClipView.frame = target.clip
            self.transitionClipView.layer.cornerRadius = 0
            self.transitionImageView.frame = target.image
            self.backdropView.alpha = 1
            self.chromeView.alpha = 1
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.item?.id == item.id else { return }
            self.pagerView.isHidden = false
            self.transitionClipView.isHidden = true
            self.transitionImageView.image = nil
            self.initialSourceSnapshot = nil
            self.restoreHiddenSourceView()
            self.phase = .presented
            self.activeAnimator = nil
            self.setStatusBarImmersive(true, animated: true)
            self.activePageCell()?.flushDeferredFullImageReveal()
            UIAccessibility.post(notification: .screenChanged, argument: self.chromeView)
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    func animateOpenFallback(item: ImagePreviewItem, reduceMotion: Bool) {
        phase = .opening
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.16 : 0.24, curve: .easeOut) {
            self.backdropView.alpha = 1
            self.chromeView.alpha = 1
            self.pagerView.alpha = 1
            self.pagerView.transform = .identity
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.item?.id == item.id else { return }
            self.initialSourceSnapshot = nil
            self.phase = .presented
            self.activeAnimator = nil
            self.setStatusBarImmersive(true, animated: !reduceMotion)
            self.activePageCell()?.flushDeferredFullImageReveal()
            UIAccessibility.post(notification: .screenChanged, argument: self.chromeView)
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    func animateDismissToSource(
        item: ImagePreviewItem,
        destination: ImagePreviewSourceSnapshot,
        activeImage: UIImage,
        aspect: CGFloat,
        cell: ImagePreviewPageCell?
    ) {
        let rawStart: CGRect
        if !transitionClipView.isHidden {
            rawStart = transitionClipView.convert(transitionImageView.frame, to: view)
        } else if let cell {
            rawStart = cell.visibleImageFrame(in: view)
        } else {
            rawStart = targetFramesForOpen(url: item.urls[currentIndex], aspect: aspect).clip
        }
        let startClip = rawStart.intersection(view.bounds)
        let clipFrame = startClip.isUsableImageRect ? startClip : rawStart
        let startImg = CGRect(
            x: rawStart.minX - clipFrame.minX,
            y: rawStart.minY - clipFrame.minY,
            width: rawStart.width,
            height: rawStart.height
        )
        let destRect = rectFromSourceWindow(destination.frameInWindow)
        let endImg = ImagePreviewMath.aspectFillFrame(
            aspect: aspect, in: destRect.size, topAligned: destination.topAligned
        )

        transitionClipView.frame = clipFrame
        transitionClipView.layer.cornerRadius = 0
        transitionClipView.layer.cornerCurve = destination.cornerCurve
        transitionClipView.alpha = 1
        transitionClipView.isHidden = false
        transitionImageView.image = activeImage
        transitionImageView.frame = startImg

        restoreHiddenSourceView()
        hiddenSourceView = destination.sourceView
        hiddenSourceView?.isHidden = true
        pagerView.isHidden = true
        pagerView.transform = .identity

        let timing = UISpringTimingParameters(dampingRatio: 0.90, initialVelocity: .zero)
        let animator = UIViewPropertyAnimator(duration: 0.26, timingParameters: timing)
        setStatusBarImmersive(false, animated: true)
        animator.addAnimations {
            self.transitionClipView.frame = destRect
            self.transitionClipView.layer.cornerRadius = destination.cornerRadius
            self.transitionImageView.frame = endImg
            self.backdropView.alpha = 0
            self.chromeView.alpha = 0
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.item?.id == item.id else { return }
            self.finishDismissal(itemID: item.id)
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    func animateDismissFallback(item: ImagePreviewItem, reduceMotion: Bool) {
        setStatusBarImmersive(false, animated: !reduceMotion)
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.14 : 0.20, curve: .easeOut) {
            self.backdropView.alpha = 0
            self.chromeView.alpha = 0
            self.pagerView.alpha = 0
            self.transitionClipView.alpha = 0
            if !reduceMotion {
                self.pagerView.transform = self.pagerView.transform.scaledBy(x: 0.92, y: 0.92)
            }
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.item?.id == item.id else { return }
            self.finishDismissal(itemID: item.id)
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    func targetFramesForOpen(
        url: URL,
        aspect: CGFloat,
        thumbAspect: CGFloat? = nil,
        isServerCropped: Bool = false
    ) -> (clip: CGRect, image: CGRect) {
        let bounds = view.bounds
        let mode = ImagePreviewRasterPolicy.displayMode(url: url, aspect: aspect)
        if mode == .reading {
            if isServerCropped, let thumbAspect {
                let fitted = ImagePreviewMath.fittedSize(in: bounds.size, aspect: thumbAspect)
                let clip = CGRect(
                    x: (bounds.width - fitted.width) / 2,
                    y: (bounds.height - fitted.height) / 2,
                    width: fitted.width,
                    height: fitted.height
                )
                return (clip, CGRect(origin: .zero, size: clip.size))
            }
            let fullHeight = bounds.width / aspect
            let clip = CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, fullHeight))
            return (clip, CGRect(x: 0, y: 0, width: bounds.width, height: fullHeight))
        }
        let fitted = ImagePreviewMath.fittedSize(in: bounds.size, aspect: aspect)
        let clip = CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        if isServerCropped, let thumbAspect {
            let thumbSize = ImagePreviewMath.fittedSize(in: clip.size, aspect: thumbAspect)
            let image = CGRect(
                x: (clip.width - thumbSize.width) / 2,
                y: (clip.height - thumbSize.height) / 2,
                width: thumbSize.width,
                height: thumbSize.height
            )
            return (clip, image)
        }
        return (clip, CGRect(origin: .zero, size: clip.size))
    }

    func pixelAspect(of pixelSize: CGSize?) -> CGFloat? {
        guard let pixelSize, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let ratio = pixelSize.width / pixelSize.height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    func imageAspect(of image: UIImage) -> CGFloat? {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = width / height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}
