import UIKit

/// Settings' first screen: its pages (General, AI, Running, Source Control, Advanced, About), as
/// iOS's Settings app lists them, and a search that finds a setting on any page.
final class SettingsRootViewController: UITableViewController, UISearchResultsUpdating {
    private let pages = SettingsViewController.Page.allCases
    /// While searching: the pages with a match, and what matched.
    private var results: [(page: SettingsViewController.Page, match: String)]?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search Settings"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            results = nil
        } else {
            results = pages.flatMap { page in
                ([page.title] + page.searchTerms)
                    .filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                    .map { (page: page, match: $0) }
            }
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results?.count ?? pages.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if let results, results.isEmpty { return "No settings match." }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if let results {
            let result = results[indexPath.row]
            content.text = result.match
            content.secondaryText = result.page.title
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: result.page.symbol)
        } else {
            content = UIListContentConfiguration.cell()
            let page = pages[indexPath.row]
            content.text = page.title
            content.image = UIImage(systemName: page.symbol)
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let page = results?[indexPath.row].page ?? pages[indexPath.row]
        navigationController?.pushViewController(SettingsViewController(page: page), animated: true)
    }
}
