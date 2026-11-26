import Foundation

/// One visible row of the Saved tree: a folder or an item, how deep it sits and the folder it's in.
struct SavedTreeRow<Item> {
    let item: Item
    let depth: Int
    /// The folder it's listed under (nil: the top level).
    let parent: UUID?
}

/// Saved as a tree (docs/features/panel-v3.md §4): each level lists its subfolders (by name),
/// then its items; an expanded folder's level follows right under it, one step deeper.
enum SavedTreeLayout {
    /// `folder` gives a folder's row (nil skips it and everything below it); `items` are each
    /// level's items in list order, keyed by folder (nil: the top level).
    static func rows<Item>(tree: FolderTree, folder: (UUID) -> Item?, items: [UUID?: [Item]],
                           expanded: Set<UUID>) -> [SavedTreeRow<Item>] {
        var rows: [SavedTreeRow<Item>] = []
        func level(_ parent: UUID?, _ depth: Int) {
            for node in tree.children(of: parent) {
                guard let row = folder(node.id) else { continue }
                rows.append(SavedTreeRow(item: row, depth: depth, parent: parent))
                if expanded.contains(node.id) { level(node.id, depth + 1) }
            }
            for item in items[parent] ?? [] {
                rows.append(SavedTreeRow(item: item, depth: depth, parent: parent))
            }
        }
        level(nil, 0)
        return rows
    }
}
