import UIKit

/// Compact popover for the discrete PencilKit sizes used by DrawPort.
final class StrokeWidthController: UIViewController {
    private let sizes: [CGFloat]
    private let onChange: (Int) -> Void
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private var index: Int

    init(name: String, sizes: [CGFloat], selected: Int, onChange: @escaping (Int) -> Void) {
        self.sizes = sizes
        self.index = min(max(selected, 0), sizes.count - 1)
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = "\(name) · Stroke width"
        preferredContentSize = CGSize(width: 285, height: 150)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.15, alpha: 1)
        let heading = UILabel()
        heading.text = title
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = .white
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .right
        updateValue()
        let labels = UIStackView(arrangedSubviews: [heading, valueLabel])
        labels.axis = .horizontal
        labels.spacing = 8
        slider.minimumValue = 0
        slider.maximumValue = Float(sizes.count - 1)
        slider.value = Float(index)
        slider.isContinuous = true
        slider.accessibilityLabel = title
        slider.addTarget(self, action: #selector(changeWidth(_:)), for: .valueChanged)
        let ends = UIStackView()
        ends.axis = .horizontal
        ends.distribution = .equalSpacing
        for size in [sizes[0], sizes[sizes.count - 1]] {
            let label = UILabel()
            label.text = "\(String(format: "%g", Double(size))) pt"
            label.textColor = UIColor(white: 0.82, alpha: 1)
            label.font = .systemFont(ofSize: 13)
            ends.addArrangedSubview(label)
        }
        let stack = UIStackView(arrangedSubviews: [labels, slider, ends])
        stack.axis = .vertical
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateValue() {
        valueLabel.text = String(format: "%g pt", Double(sizes[index]))
    }

    @objc private func changeWidth(_ sender: UISlider) {
        let updated = min(max(Int(sender.value.rounded()), 0), sizes.count - 1)
        guard updated != index else { return }
        index = updated
        updateValue()
        onChange(updated)
    }
}
