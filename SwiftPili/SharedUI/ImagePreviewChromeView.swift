import UIKit

@MainActor final class ImagePreviewChromeView: UIView {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let saveControl = ImagePreviewCircleControl(
        symbolName: "arrow.down",
        accessibilityLabel: String(localized: "Save")
    )
    private let closeControl = ImagePreviewCircleControl(
        symbolName: "xmark",
        accessibilityLabel: String(localized: "Close")
    )
    private let counterPill = ImagePreviewGlassPill()
    private let toastPill = ImagePreviewGlassPill()
    private var saveTopConstraint: NSLayoutConstraint?
    private var closeTopConstraint: NSLayoutConstraint?
    private var lockedTopInset: CGFloat = 0
    private var toastHideTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        setupSubviews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransparencyChange),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated deinit { NotificationCenter.default.removeObserver(self) }

    func reset() {
        toastHideTask?.cancel()
        toastHideTask = nil
        toastPill.alpha = 0
        toastPill.isHidden = true
    }

    func setTopInset(_ inset: CGFloat) {
        let clamped = max(inset, 20)
        guard abs(clamped - lockedTopInset) > 0.5 else { return }
        lockedTopInset = clamped
        saveTopConstraint?.constant = clamped + 2
        closeTopConstraint?.constant = clamped + 2
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if safeAreaInsets.top > lockedTopInset + 0.5 {
            setTopInset(safeAreaInsets.top)
        }
    }

    func updateCounter(index: Int, total: Int) {
        guard total > 1 else {
            counterPill.isHidden = true
            return
        }
        counterPill.isHidden = false
        counterPill.setText("\(index + 1) / \(total)")
    }

    func updateSaveStatus(_ status: ImagePreviewSaveState.Status) {
        saveControl.isEnabled = status != .saving
        saveControl.setSymbol(status.icon, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func showCopiedToast() {
        toastHideTask?.cancel()
        toastPill.setText(String(localized: "Copied"))
        toastPill.isHidden = false
        let animate = !UIAccessibility.isReduceMotionEnabled
        if animate {
            UIView.animate(withDuration: 0.18) { self.toastPill.alpha = 1 }
        } else {
            toastPill.alpha = 1
        }
        toastHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled, let self else { return }
            if !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.2, animations: {
                    self.toastPill.alpha = 0
                }, completion: { _ in
                    if self.toastPill.alpha < 0.01 { self.toastPill.isHidden = true }
                })
            } else {
                self.toastPill.alpha = 0
                self.toastPill.isHidden = true
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        for control in [saveControl, closeControl] where !control.isHidden && control.alpha > 0.01 {
            let local = convert(point, to: control)
            if control.bounds.contains(local) {
                return control.hitTest(local, with: event) ?? control
            }
        }
        return nil
    }

    private func setupSubviews() {
        saveControl.addTarget(self, action: #selector(handleSaveTap), for: .touchUpInside)
        closeControl.addTarget(self, action: #selector(handleCloseTap), for: .touchUpInside)

        for child in [saveControl, closeControl, counterPill, toastPill] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        counterPill.isUserInteractionEnabled = false
        toastPill.isUserInteractionEnabled = false
        toastPill.alpha = 0
        toastPill.isHidden = true

        let safe = safeAreaLayoutGuide
        let saveTop = saveControl.topAnchor.constraint(equalTo: topAnchor, constant: 22)
        let closeTop = closeControl.topAnchor.constraint(equalTo: topAnchor, constant: 22)
        saveTopConstraint = saveTop
        closeTopConstraint = closeTop
        let counterBottom = counterPill.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16)
        counterBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            saveControl.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            saveTop,
            saveControl.widthAnchor.constraint(equalToConstant: 56),
            saveControl.heightAnchor.constraint(equalToConstant: 56),

            closeControl.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -6),
            closeTop,
            closeControl.widthAnchor.constraint(equalToConstant: 56),
            closeControl.heightAnchor.constraint(equalToConstant: 56),

            counterPill.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            counterPill.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32),
            counterBottom,
            counterPill.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -16),
            counterPill.bottomAnchor.constraint(lessThanOrEqualTo: keyboardLayoutGuide.topAnchor, constant: -16),

            toastPill.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            toastPill.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -56),
        ])
    }

    @objc private func handleSaveTap() { onSave?() }
    @objc private func handleCloseTap() { onClose?() }

    @objc private func handleTransparencyChange() {
        saveControl.refreshMaterial()
        closeControl.refreshMaterial()
        counterPill.refreshMaterial()
        toastPill.refreshMaterial()
    }
}

@MainActor private final class ImagePreviewCircleControl: UIControl {
    private let discEffectView = UIVisualEffectView()
    private let opaqueBackdrop = UIView()
    private let iconView = UIImageView()
    private var currentSymbolName: String

    init(symbolName: String, accessibilityLabel: String) {
        self.currentSymbolName = symbolName
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel
        backgroundColor = .clear
        overrideUserInterfaceStyle = .dark

        opaqueBackdrop.translatesAutoresizingMaskIntoConstraints = false
        opaqueBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.76)
        opaqueBackdrop.layer.cornerRadius = 22
        opaqueBackdrop.layer.borderWidth = 1
        opaqueBackdrop.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        opaqueBackdrop.isUserInteractionEnabled = false
        addSubview(opaqueBackdrop)

        discEffectView.translatesAutoresizingMaskIntoConstraints = false
        discEffectView.layer.cornerRadius = 22
        discEffectView.clipsToBounds = true
        discEffectView.isUserInteractionEnabled = false
        addSubview(discEffectView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            opaqueBackdrop.centerXAnchor.constraint(equalTo: centerXAnchor),
            opaqueBackdrop.centerYAnchor.constraint(equalTo: centerYAnchor),
            opaqueBackdrop.widthAnchor.constraint(equalToConstant: 44),
            opaqueBackdrop.heightAnchor.constraint(equalToConstant: 44),

            discEffectView.centerXAnchor.constraint(equalTo: centerXAnchor),
            discEffectView.centerYAnchor.constraint(equalTo: centerYAnchor),
            discEffectView.widthAnchor.constraint(equalToConstant: 44),
            discEffectView.heightAnchor.constraint(equalToConstant: 44),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        refreshMaterial()
        setSymbol(symbolName, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet {
            let scale: CGFloat = isHighlighted ? 0.92 : 1.0
            let alpha: CGFloat = isHighlighted ? 0.8 : 1.0
            let update = {
                self.discEffectView.transform = CGAffineTransform(scaleX: scale, y: scale)
                self.opaqueBackdrop.transform = CGAffineTransform(scaleX: scale, y: scale)
                self.iconView.alpha = alpha
            }
            if UIAccessibility.isReduceMotionEnabled {
                update()
            } else {
                UIView.animate(withDuration: 0.14, animations: update)
            }
        }
    }

    override var isEnabled: Bool {
        didSet { iconView.alpha = isEnabled ? 1.0 : 0.65 }
    }

    func setSymbol(_ name: String, animated: Bool) {
        currentSymbolName = name
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        guard let image = UIImage(systemName: name, withConfiguration: config) else { return }
        if animated {
            iconView.setSymbolImage(image, contentTransition: .replace)
        } else {
            iconView.image = image
        }
    }

    func refreshMaterial() {
        if UIAccessibility.isReduceTransparencyEnabled {
            discEffectView.isHidden = true
            opaqueBackdrop.isHidden = false
            return
        }
        opaqueBackdrop.isHidden = true
        discEffectView.isHidden = false
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            discEffectView.effect = glass
            discEffectView.cornerConfiguration = .capsule()
        } else {
            discEffectView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
    }
}

@MainActor private final class ImagePreviewGlassPill: UIView {
    private let effectView = UIVisualEffectView()
    private let opaqueBackdrop = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        backgroundColor = .clear

        opaqueBackdrop.translatesAutoresizingMaskIntoConstraints = false
        opaqueBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        opaqueBackdrop.clipsToBounds = true
        addSubview(opaqueBackdrop)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        addSubview(effectView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.88)
        label.textAlignment = .center
        addSubview(label)

        NSLayoutConstraint.activate([
            opaqueBackdrop.topAnchor.constraint(equalTo: topAnchor),
            opaqueBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            opaqueBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            opaqueBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        refreshMaterial()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = bounds.height / 2
        opaqueBackdrop.layer.cornerRadius = radius
        if #unavailable(iOS 26.0) {
            effectView.layer.cornerRadius = radius
        }
    }

    func setText(_ text: String) {
        label.text = text
    }

    func refreshMaterial() {
        if UIAccessibility.isReduceTransparencyEnabled {
            effectView.isHidden = true
            opaqueBackdrop.isHidden = false
            return
        }
        opaqueBackdrop.isHidden = true
        effectView.isHidden = false
        if #available(iOS 26.0, *) {
            effectView.effect = UIGlassEffect(style: .regular)
            effectView.cornerConfiguration = .capsule()
        } else {
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight]
        let descriptor = fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: descriptor, size: 0)
    }
}
