import UIKit

/// A fixed, high-contrast ink palette. It edits the selected pen slot, never a
/// saved stroke or the purple question/context ink's reserved semantic color.
final class InkPaletteController: UIViewController, UIColorPickerViewControllerDelegate {
    var selectedColor: UIColor
    var favoriteColors: [UIColor]
    var onColor: (UIColor) -> Void
    var onWidth: ((CGFloat) -> Void)?
    private let body = UIView()
    private let current = UIView()
    private var mode = 0

    init(color: UIColor, favorites: [UIColor], onColor: @escaping (UIColor) -> Void) {
        selectedColor = color
        favoriteColors = favorites
        self.onColor = onColor
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 510, height: 520)
        modalPresentationStyle = .popover
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.105, alpha: 1)
        let title = UILabel()
        title.text = "Color"
        title.textColor = .white
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textAlignment = .center
        title.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let divider = UIView()
        divider.backgroundColor = UIColor(white: 0.28, alpha: 1)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let paletteTitle = UILabel()
        paletteTitle.text = "Palette"
        paletteTitle.textColor = UIColor(white: 0.72, alpha: 1)
        paletteTitle.font = .systemFont(ofSize: 15)
        let sampleRow = UIStackView()
        sampleRow.axis = .horizontal
        sampleRow.alignment = .center
        sampleRow.spacing = 18
        for color in favoriteColors.prefix(4) {
            let circle = UIButton(type: .custom)
            circle.backgroundColor = color
            circle.layer.cornerRadius = 19
            circle.layer.borderWidth = color.isVisuallyEqual(to: selectedColor) ? 3 : 1
            circle.layer.borderColor = (color.isVisuallyEqual(to: selectedColor) ? UIColor.systemBlue : UIColor(white: 0.45, alpha: 1)).cgColor
            circle.widthAnchor.constraint(equalToConstant: 38).isActive = true
            circle.heightAnchor.constraint(equalToConstant: 38).isActive = true
            circle.addAction(UIAction { [weak self] _ in self?.choose(color) }, for: .touchUpInside)
            sampleRow.addArrangedSubview(circle)
        }
        let spacer = UIView()
        sampleRow.addArrangedSubview(spacer)
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        add.tintColor = .systemBlue
        add.accessibilityLabel = "Choose custom ink color"
        add.addAction(UIAction { [weak self] _ in self?.openWheel() }, for: .touchUpInside)
        add.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sampleRow.addArrangedSubview(add)
        sampleRow.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let modePicker = UISegmentedControl(items: ["Grid", "Wheel", "Palettes", "Style"])
        modePicker.selectedSegmentIndex = 0
        modePicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if modePicker.selectedSegmentIndex == 1 { self.openWheel(); modePicker.selectedSegmentIndex = self.mode }
            else { self.mode = modePicker.selectedSegmentIndex; self.refreshBody() }
        }, for: .valueChanged)
        modePicker.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let content = UIStackView(arrangedSubviews: [title, divider, body, paletteTitle, sampleRow, modePicker])
        content.axis = .vertical
        content.spacing = 12
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 4, left: 20, bottom: 18, right: 20)
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.heightAnchor.constraint(equalToConstant: 310)
        ])
        refreshBody()
    }

    private func refreshBody() {
        body.subviews.forEach { $0.removeFromSuperview() }
        if mode == 3 {
            let label = UILabel()
            label.text = "Pen thickness"
            label.textColor = .white
            let slider = UISlider()
            slider.minimumValue = 0.5
            slider.maximumValue = 12
            slider.value = 1.5
            slider.tintColor = .systemBlue
            slider.addAction(UIAction { [weak self] _ in self?.onWidth?(CGFloat(slider.value)) }, for: .valueChanged)
            let column = UIStackView(arrangedSubviews: [label, slider])
            column.axis = .vertical
            column.spacing = 24
            fill(column)
            return
        }
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 0
        let rows = mode == 2 ? 4 : 10
        for row in 0..<rows {
            let strip = UIStackView()
            strip.axis = .horizontal
            strip.distribution = .fillEqually
            for column in 0..<12 {
                let color: UIColor
                if mode == 2 {
                    color = UIColor(hue: CGFloat(column) / 12, saturation: CGFloat(row + 1) / 4,
                                    brightness: 0.95, alpha: 1)
                } else if row == 0 {
                    color = UIColor(white: 1 - CGFloat(column) / 11, alpha: 1)
                } else {
                    // Saturated center and pastel lower rows as in the reference grid.
                    let hue = (CGFloat(column) / 12 + 0.50).truncatingRemainder(dividingBy: 1)
                    color = UIColor(hue: hue, saturation: row > 5 ? CGFloat(10 - row) / 5 : 0.95,
                                    brightness: row < 3 ? 0.35 + CGFloat(row) * 0.19 : 1, alpha: 1)
                }
                let tile = UIButton(type: .custom)
                tile.backgroundColor = color
                tile.accessibilityLabel = "Ink color, row \(row + 1), column \(column + 1)"
                tile.addAction(UIAction { [weak self] _ in self?.choose(color) }, for: .touchUpInside)
                strip.addArrangedSubview(tile)
            }
            grid.addArrangedSubview(strip)
        }
        grid.distribution = .fillEqually
        grid.layer.cornerRadius = 14
        grid.clipsToBounds = true
        fill(grid)
    }

    private func fill(_ child: UIView) {
        body.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: body.topAnchor),
            child.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: body.trailingAnchor)
        ])
    }

    private func choose(_ color: UIColor) {
        selectedColor = color
        onColor(color)
        dismiss(animated: true)
    }

    private func openWheel() {
        let picker = UIColorPickerViewController()
        picker.overrideUserInterfaceStyle = .dark
        picker.supportsAlpha = false
        picker.selectedColor = selectedColor
        picker.delegate = self
        present(picker, animated: true)
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        selectedColor = viewController.selectedColor
        onColor(selectedColor)
    }
}

private extension UIColor {
    func isVisuallyEqual(to other: UIColor) -> Bool {
        var a: CGFloat = 0, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 0
        var e: CGFloat = 0, f: CGFloat = 0, g: CGFloat = 0, h: CGFloat = 0
        return getRed(&a, green: &b, blue: &c, alpha: &d) &&
            other.getRed(&e, green: &f, blue: &g, alpha: &h) &&
            abs(a - e) + abs(b - f) + abs(c - g) < 0.04
    }
}
