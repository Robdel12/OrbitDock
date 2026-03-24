//
//  MarkdownRenderSegment.swift
//  OrbitDock
//
//  Stable render model for conversation markdown.
//  The projector groups semantic markdown blocks into a small set of
//  render segments so the eventual SwiftUI renderer can keep identity
//  stable while streaming content updates arrive.
//

import Foundation

enum MarkdownRenderSegment: Equatable {
  case prose(Prose)
  case codeBlock(CodeBlock)
  case table(Table)
  case thematicBreak(ThematicBreak)

  enum Kind: String, Hashable {
    case prose
    case codeBlock
    case table
    case thematicBreak
  }

  struct Identity: Hashable {
    let kind: Kind
    let startBlockIndex: Int
  }

  struct Prose: Equatable {
    let identity: Identity
    let sourceBlockRange: Range<Int>
    let blocks: [MarkdownBlock]
  }

  struct CodeBlock: Equatable {
    let identity: Identity
    let sourceBlockRange: Range<Int>
    let language: String?
    let code: String
  }

  struct Table: Equatable {
    let identity: Identity
    let sourceBlockRange: Range<Int>
    let headers: [String]
    let rows: [[String]]
  }

  struct ThematicBreak: Equatable {
    let identity: Identity
    let sourceBlockRange: Range<Int>
  }

  var kind: Kind {
    switch self {
      case .prose:
        return .prose
      case .codeBlock:
        return .codeBlock
      case .table:
        return .table
      case .thematicBreak:
        return .thematicBreak
    }
  }

  var identity: Identity {
    switch self {
      case let .prose(segment):
        return segment.identity
      case let .codeBlock(segment):
        return segment.identity
      case let .table(segment):
        return segment.identity
      case let .thematicBreak(segment):
        return segment.identity
    }
  }

  var sourceBlockRange: Range<Int> {
    switch self {
      case let .prose(segment):
        return segment.sourceBlockRange
      case let .codeBlock(segment):
        return segment.sourceBlockRange
      case let .table(segment):
        return segment.sourceBlockRange
      case let .thematicBreak(segment):
        return segment.sourceBlockRange
    }
  }

  var startBlockIndex: Int {
    identity.startBlockIndex
  }

  var leadingBlock: MarkdownBlock? {
    switch self {
      case let .prose(segment):
        return segment.blocks.first
      case let .codeBlock(segment):
        return .codeBlock(language: segment.language, code: segment.code)
      case let .table(segment):
        return .table(headers: segment.headers, rows: segment.rows)
      case .thematicBreak:
        return .thematicBreak
    }
  }

  var trailingBlock: MarkdownBlock? {
    switch self {
      case let .prose(segment):
        return segment.blocks.last
      case let .codeBlock(segment):
        return .codeBlock(language: segment.language, code: segment.code)
      case let .table(segment):
        return .table(headers: segment.headers, rows: segment.rows)
      case .thematicBreak:
        return .thematicBreak
    }
  }
}
