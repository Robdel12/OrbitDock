//
//  FileTreeBuilder.swift
//  OrbitDock
//
//  Converts a flat list of file paths into a tree structure for display.
//  Used by GlobExpandedView for hierarchical file visualization.
//

import Foundation

struct FileTreeNode: Identifiable {
  let id = UUID()
  let name: String
  let isDirectory: Bool
  var children: [FileTreeNode]
  let fullPath: String

  /// Total file count in this subtree (including self if file)
  var fileCount: Int {
    if !isDirectory { return 1 }
    return children.reduce(0) { $0 + $1.fileCount }
  }
}

enum FileTreeBuilder {
  /// Build a tree from a flat list of file paths.
  /// Collapses single-child directory chains (e.g., "src/lib" becomes one node).
  static func buildTree(from paths: [String]) -> [FileTreeNode] {
    // Find common prefix to strip
    let prefix = commonPathPrefix(paths)

    var root: [String: Any] = [:]

    for path in paths {
      let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
      let components = relative.split(separator: "/").map(String.init)
      insert(components: components, into: &root)
    }

    let tree = buildNodes(from: root, parentPath: prefix)
    return collapseChains(tree)
  }

  // MARK: - Private

  private static func insert(components: [String], into dict: inout [String: Any]) {
    guard let first = components.first else { return }

    if components.count == 1 {
      // Leaf file
      dict[first] = NSNull()
    } else {
      var child = (dict[first] as? [String: Any]) ?? [:]
      insert(components: Array(components.dropFirst()), into: &child)
      dict[first] = child
    }
  }

  private static func buildNodes(from dict: [String: Any], parentPath: String) -> [FileTreeNode] {
    dict.sorted(by: { lhs, rhs in
      let lhsIsDir = lhs.value is [String: Any]
      let rhsIsDir = rhs.value is [String: Any]
      if lhsIsDir != rhsIsDir { return lhsIsDir } // directories first
      return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }).map { key, value in
      let fullPath = parentPath.isEmpty ? key : parentPath + "/" + key
      if let childDict = value as? [String: Any] {
        return FileTreeNode(
          name: key,
          isDirectory: true,
          children: buildNodes(from: childDict, parentPath: fullPath),
          fullPath: fullPath
        )
      } else {
        return FileTreeNode(
          name: key,
          isDirectory: false,
          children: [],
          fullPath: fullPath
        )
      }
    }
  }

  /// Collapse single-child directory chains: a/b/c → "a/b/c"
  private static func collapseChains(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
    nodes.map { node in
      var current = node
      while current.isDirectory, current.children.count == 1, current.children[0].isDirectory {
        let child = current.children[0]
        current = FileTreeNode(
          name: current.name + "/" + child.name,
          isDirectory: true,
          children: child.children,
          fullPath: child.fullPath
        )
      }
      return FileTreeNode(
        name: current.name,
        isDirectory: current.isDirectory,
        children: collapseChains(current.children),
        fullPath: current.fullPath
      )
    }
  }

  private static func commonPathPrefix(_ paths: [String]) -> String {
    guard let first = paths.first else { return "" }
    let components = first.split(separator: "/").map(String.init)
    var commonCount = components.count

    for path in paths.dropFirst() {
      let pathComponents = path.split(separator: "/").map(String.init)
      commonCount = min(commonCount, pathComponents.count)
      for i in 0..<commonCount {
        if components[i] != pathComponents[i] {
          commonCount = i
          break
        }
      }
    }

    // Don't include the file name in the common prefix
    if commonCount > 0 {
      let prefix = components.prefix(commonCount).joined(separator: "/")
      return "/" + prefix + "/"
    }
    return ""
  }
}
