import UIKit

/// One-off selector for additional actions on the squeeze palette. The six
/// core tools and circled + remain; unavailable tools are not offered.
final class PencilPaletteToolsController: UITableViewController {
    private var selected: Set<PencilRadialPalette.ExtraTool>
    var onDone: (([PencilRadialPalette.ExtraTool]) -> Void)?

    init(selected: [PencilRadialPalette.ExtraTool]) {
        self.selected = Set(selected)
        super.init(style: .insetGrouped)
        preferredContentSize = CGSize(width: 316, height: 370)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        title = "Add popup tools"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                             target: self,
                                                             action: #selector(doneTapped))
        tableView.backgroundColor = UIColor(white: 0.105, alpha: 1)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tool")
        tableView.rowHeight = 52
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        PencilRadialPalette.ExtraTool.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tool", for: indexPath)
        let tool = PencilRadialPalette.ExtraTool.allCases[indexPath.row]
        cell.textLabel?.text = tool.title
        cell.imageView?.image = UIImage(systemName: tool.symbol)
        cell.imageView?.tintColor = .white
        cell.accessoryType = selected.contains(tool) ? .checkmark : .none
        cell.tintColor = UIColor(red: 0.16, green: 0.53, blue: 1, alpha: 1)
        cell.accessibilityLabel = tool.title
        cell.accessibilityValue = selected.contains(tool) ? "Added" : "Not added"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let tool = PencilRadialPalette.ExtraTool.allCases[indexPath.row]
        if !selected.insert(tool).inserted { selected.remove(tool) }
        tableView.reloadRows(at: [indexPath], with: .none)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    @objc private func doneTapped() {
        let tools = PencilRadialPalette.ExtraTool.allCases.filter { selected.contains($0) }
        dismiss(animated: true) { [onDone] in onDone?(tools) }
    }
}
