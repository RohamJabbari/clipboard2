import Foundation

/// A folder row's caption: "3 folders · 12 items", leaving out a zero part.
nonisolated enum FolderCaption {
    static func text(folders: Int, items: Int) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if items > 0 { parts.append(items == 1 ? "1 item" : "\(items) items") }
        return parts.isEmpty ? "Empty folder" : parts.joined(separator: " · ")
    }
}

/// The folders of one space as a tree (docs/features/nested-folders.md). A folder's stored
/// parent counts only when it's a folder of the same space and walking up from the folder
/// neither meets the folder again nor goes deeper than `maxDepth` levels; otherwise the folder
/// is at the top level. Pure: built from a snapshot, never changes the folders.
nonisolated struct FolderTree: Sendable {
    nonisolated struct Node: Sendable, Equatable {
        var id: UUID
        var name: String
        var parentID: UUID?
        var createdAt: Date
    }

    static let maxDepth = 8

    let nodes: [Node]
    private let byID: [UUID: Node]
    /// Effective parent of every folder that has one.
    private let parents: [UUID: UUID]
    private let childrenByParent: [UUID?: [Node]]

    init(nodes: [Node]) {
        self.nodes = nodes
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byID = byID
        var parents: [UUID: UUID] = [:]
        for node in nodes {
            if let parent = Self.validParent(of: node, in: byID) { parents[node.id] = parent }
        }
        self.parents = parents
        var children: [UUID?: [Node]] = [:]
        for node in nodes { children[parents[node.id], default: []].append(node) }
        for key in children.keys {
            children[key]?.sort {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
            }
        }
        childrenByParent = children
    }

    init(_ folders: [ClipFolder]) {
        self.init(nodes: folders.map { Node(id: $0.id, name: $0.name, parentID: $0.parentID, createdAt: $0.createdAt) })
    }

    /// The stored parent, if it's usable (see the type's comment).
    private static func validParent(of node: Node, in byID: [UUID: Node]) -> UUID? {
        guard let first = node.parentID, first != node.id, byID[first] != nil else { return nil }
        var current: UUID? = first
        var depth = 1
        while let id = current {
            depth += 1
            if id == node.id || depth > maxDepth { return nil }
            guard let next = byID[id] else { break }
            current = next.parentID.flatMap { byID[$0] != nil ? $0 : nil }
        }
        return first
    }

    func contains(_ id: UUID) -> Bool { byID[id] != nil }
    func node(_ id: UUID) -> Node? { byID[id] }
    func parent(of id: UUID) -> UUID? { parents[id] }

    /// Subfolders of a folder (nil: the top level), by name.
    func children(of id: UUID?) -> [Node] { childrenByParent[id] ?? [] }

    func hasChildren(_ id: UUID) -> Bool { !(childrenByParent[id] ?? []).isEmpty }

    /// From the top level down to the folder itself.
    func path(to id: UUID) -> [Node] {
        var path: [Node] = []
        var current: UUID? = id
        while let id = current, let node = byID[id], path.count <= Self.maxDepth {
            path.insert(node, at: 0)
            current = parents[id]
        }
        return path
    }

    /// 1 for a top-level folder.
    func depth(of id: UUID) -> Int { path(to: id).count }

    /// Levels in the folder's subtree: 1 for a folder without subfolders.
    func height(of id: UUID) -> Int {
        1 + (children(of: id).map { height(of: $0.id) }.max() ?? 0)
    }

    /// Every folder below it (not itself).
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var stack = children(of: id).map(\.id)
        while let next = stack.popLast() {
            guard result.insert(next).inserted else { continue }
            stack += children(of: next).map(\.id)
        }
        return result
    }

    /// The folder and everything below it.
    func subtree(of id: UUID) -> Set<UUID> { descendants(of: id).union([id]) }

    /// Whether a folder may go under `target` (nil: the top level): never into itself or below
    /// itself, never deeper than `maxDepth`, and not where it already is.
    func canMove(_ id: UUID, under target: UUID?) -> Bool {
        guard contains(id), parent(of: id) != target else { return false }
        guard let target else { return true }
        guard contains(target), target != id, !descendants(of: id).contains(target) else { return false }
        return depth(of: target) + height(of: id) <= Self.maxDepth
    }

    /// A folder (nil: top level) a new subfolder can go in.
    func canCreate(in parent: UUID?) -> Bool {
        guard let parent else { return true }
        return contains(parent) && depth(of: parent) < Self.maxDepth
    }

    /// "Work › Clients", relative to `base` (whose own name and ancestors are left out).
    func pathName(of id: UUID, relativeTo base: UUID? = nil) -> String {
        var segments = path(to: id)
        if let base, let index = segments.firstIndex(where: { $0.id == base }) {
            segments.removeFirst(index + 1)
        }
        return segments.map(\.name).joined(separator: " › ")
    }

    /// Depth-first, each folder followed by its subfolders, with its level (0: top).
    func flattened(from root: UUID? = nil, excluding: Set<UUID> = []) -> [(node: Node, level: Int)] {
        var result: [(Node, Int)] = []
        func walk(_ parent: UUID?, _ level: Int) {
            for child in children(of: parent) where !excluding.contains(child.id) {
                result.append((child, level))
                walk(child.id, level + 1)
            }
        }
        walk(root, 0)
        return result
    }
}
