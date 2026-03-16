//
//  JSONTreeView.swift
//  OrbitDock
//
//  Interactive, collapsible JSON tree viewer.
//  Replaces flat JSON dumps with structured, color-coded display.
//

import SwiftUI

struct JSONTreeView: View {
  let json: Any
  let maxDepth: Int

  init(jsonString: String, maxDepth: Int = 20) {
    if let data = jsonString.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
      self.json = parsed
    } else {
      self.json = jsonString
    }
    self.maxDepth = maxDepth
  }

  init(json: Any, maxDepth: Int = 20) {
    self.json = json
    self.maxDepth = maxDepth
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      JSONNodeView(value: json, key: nil, depth: 0, maxDepth: maxDepth)
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }
}

// MARK: - Node View

private struct JSONNodeView: View {
  let value: Any
  let key: String?
  let depth: Int
  let maxDepth: Int

  @State private var isExpanded = true

  private var indent: CGFloat { CGFloat(depth) * 14 }
  private var isArrayIndex: Bool { key?.hasPrefix("[") == true }

  var body: some View {
    if let dict = value as? [String: Any] {
      objectNode(dict)
    } else if let array = value as? [Any] {
      arrayNode(array)
    } else {
      leafNode
    }
  }

  // MARK: - Object

  @ViewBuilder
  private func objectNode(_ dict: [String: Any]) -> some View {
    let sortedKeys = dict.keys.sorted()

    Button(action: { withAnimation(Motion.snappy) { isExpanded.toggle() } }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 10)

        if let key {
          Text(isArrayIndex ? key : "\"\(key)\"")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(isArrayIndex ? Color.textQuaternary : Color.syntaxProperty)
          if !isArrayIndex {
            Text(":")
              .font(.system(size: TypeScale.code, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }
        }

        if !isExpanded {
          Text("{\(dict.count) key\(dict.count == 1 ? "" : "s")}")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        } else {
          Text("{")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.leading, indent)
    }
    .buttonStyle(.plain)

    if isExpanded, depth < maxDepth {
      ForEach(Array(sortedKeys.enumerated()), id: \.offset) { _, childKey in
        JSONNodeView(
          value: dict[childKey] ?? NSNull(),
          key: childKey,
          depth: depth + 1,
          maxDepth: maxDepth
        )
      }

      Text("}")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .padding(.leading, indent)
    }
  }

  // MARK: - Array

  @ViewBuilder
  private func arrayNode(_ array: [Any]) -> some View {
    Button(action: { withAnimation(Motion.snappy) { isExpanded.toggle() } }) {
      HStack(spacing: Spacing.xs) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(Color.textQuaternary)
          .frame(width: 10)

        if let key {
          Text(isArrayIndex ? key : "\"\(key)\"")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(isArrayIndex ? Color.textQuaternary : Color.syntaxProperty)
          if !isArrayIndex {
            Text(":")
              .font(.system(size: TypeScale.code, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }
        }

        if !isExpanded {
          Text("[\(array.count) item\(array.count == 1 ? "" : "s")]")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        } else {
          Text("[")
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.leading, indent)
    }
    .buttonStyle(.plain)

    if isExpanded, depth < maxDepth {
      ForEach(Array(array.enumerated()), id: \.offset) { index, item in
        JSONNodeView(
          value: item,
          key: "[\(index)]",
          depth: depth + 1,
          maxDepth: maxDepth
        )
      }

      Text("]")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
        .padding(.leading, indent)
    }
  }

  // MARK: - Leaf

  private var leafNode: some View {
    HStack(spacing: Spacing.xs) {
      Spacer().frame(width: 10) // align with chevron space

      if let key {
        Text("\"\(key)\"")
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.syntaxProperty)
        Text(":")
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      leafValueText
    }
    .padding(.leading, indent)
  }

  @ViewBuilder
  private var leafValueText: some View {
    if value is NSNull {
      Text("null")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
    } else if let bool = value as? Bool {
      Text(bool ? "true" : "false")
        .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.syntaxKeyword)
    } else if let number = value as? NSNumber {
      Text("\(number)")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.syntaxNumber)
    } else if let string = value as? String {
      let display = string.count > 200 ? String(string.prefix(197)) + "..." : string
      Text("\"\(display)\"")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.syntaxString)
    } else {
      Text("\(String(describing: value))")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
  }
}
