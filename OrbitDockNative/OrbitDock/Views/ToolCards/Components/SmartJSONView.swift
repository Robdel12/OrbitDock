//
//  SmartJSONView.swift
//  OrbitDock
//
//  Adaptive JSON renderer that auto-selects the best display format:
//  - Simple flat objects (<10 keys, no nesting) → key-value field list
//  - Uniform array of flat objects (<=10 items) → separated card list
//  - Complex JSON (nested, arrays, >10 keys) → JSONTreeView
//  - Plain text / single string → body text
//

import SwiftUI

struct SmartJSONView: View {
  let jsonString: String
  var labelWidth: CGFloat = 80

  var body: some View {
    switch classify(jsonString) {
      case let .plainText(text):
        Text(text)
          .font(.system(size: TypeScale.body))
          .foregroundStyle(Color.textSecondary)

      case let .keyValuePairs(pairs):
        keyValueList(pairs)

      case let .uniformArray(items):
        uniformArrayList(items)

      case .complexJSON:
        JSONTreeView(jsonString: jsonString)
    }
  }

  // MARK: - Key-Value List

  private func keyValueList(_ pairs: [(key: String, value: Any)]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
        HStack(alignment: .top, spacing: Spacing.sm) {
          Text(pair.key)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textTertiary)
            .frame(width: labelWidth, alignment: .trailing)

          valueView(pair.value)
        }
      }
    }
    .padding(Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  @ViewBuilder
  private func valueView(_ value: Any) -> some View {
    if value is NSNull {
      Text("null")
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textQuaternary)
    } else if let bool = value as? Bool {
      Text(bool ? "true" : "false")
        .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
        .foregroundStyle(bool ? Color.feedbackPositive : Color.feedbackNegative)
    } else if let number = value as? NSNumber {
      // NSNumber can also represent bools — disambiguate via objCType
      if CFBooleanGetTypeID() == CFGetTypeID(number) {
        let boolVal = number.boolValue
        Text(boolVal ? "true" : "false")
          .font(.system(size: TypeScale.code, weight: .medium, design: .monospaced))
          .foregroundStyle(boolVal ? Color.feedbackPositive : Color.feedbackNegative)
      } else {
        Text("\(number)")
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.accent)
      }
    } else if let string = value as? String {
      if looksLikeURL(string) {
        Text(string.count > 80 ? String(string.prefix(77)) + "..." : string)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.accent)
      } else if looksLikePath(string) {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "doc.plaintext")
            .font(.system(size: 8))
            .foregroundStyle(Color.toolRead)
          Text(string.count > 80 ? String(string.prefix(77)) + "..." : string)
            .font(.system(size: TypeScale.code, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
        }
      } else {
        Text(string.count > 80 ? String(string.prefix(77)) + "..." : string)
          .font(.system(size: TypeScale.code, design: .monospaced))
          .foregroundStyle(Color.textSecondary)
      }
    } else {
      Text(String(describing: value))
        .font(.system(size: TypeScale.code, design: .monospaced))
        .foregroundStyle(Color.textSecondary)
    }
  }

  // MARK: - Classification

  private enum JSONShape {
    case plainText(String)
    case keyValuePairs([(key: String, value: Any)])
    case uniformArray([[String: Any]])
    case complexJSON
  }

  private func classify(_ raw: String) -> JSONShape {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    else {
      // Not valid JSON → plain text
      return .plainText(raw)
    }

    // Single string value
    if let single = parsed as? String {
      return .plainText(single)
    }

    // Flat object with <10 keys and no nested objects/arrays
    if let dict = parsed as? [String: Any] {
      let keys = dict.keys.sorted()
      if keys.count > 0, keys.count < 10 {
        let hasNesting = dict.values.contains { $0 is [String: Any] || $0 is [Any] }
        if !hasNesting {
          let pairs = keys.map { (key: $0, value: dict[$0]!) }
          return .keyValuePairs(pairs)
        }
      }
    }

    // Array of uniform flat objects
    if let array = parsed as? [[String: Any]] {
      let allFlat = array.allSatisfy { dict in
        dict.count < 10 && !dict.values.contains { $0 is [String: Any] || $0 is [Any] }
      }
      if allFlat, !array.isEmpty, array.count <= 10 {
        return .uniformArray(array)
      }
    }

    // Everything else: complex JSON
    return .complexJSON
  }

  // MARK: - Uniform Array List

  private func uniformArrayList(_ items: [[String: Any]]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        let keys = item.keys.sorted()
        VStack(alignment: .leading, spacing: Spacing.xs) {
          ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
            HStack(alignment: .top, spacing: Spacing.sm) {
              Text(key)
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .frame(width: labelWidth, alignment: .trailing)
              valueView(item[key]!)
            }
          }
        }
        .padding(Spacing.sm)

        if index < items.count - 1 {
          Rectangle()
            .fill(Color.textQuaternary.opacity(0.08))
            .frame(height: 1)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.sm))
  }

  // MARK: - String Helpers

  private func looksLikePath(_ s: String) -> Bool {
    s.hasPrefix("/") || s.hasPrefix("./") || s.hasPrefix("~/")
  }

  private func looksLikeURL(_ s: String) -> Bool {
    s.hasPrefix("http://") || s.hasPrefix("https://")
  }
}
