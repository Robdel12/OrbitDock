import Foundation

enum LibraryProjectSectionBadge: Equatable {
  case live(Int)
  case cached(Int)
  case cost(String)
  case tokens(String)
}

enum LibraryProjectArchiveSectionKind: Equatable {
  case archive
  case cachedArchive
}

struct LibraryProjectSectionState: Equatable {
  let badges: [LibraryProjectSectionBadge]
  let visibleEndpointFacetCount: Int
  let hiddenEndpointFacetCount: Int
  let archiveSectionKind: LibraryProjectArchiveSectionKind

  var archiveSectionTitle: String {
    switch archiveSectionKind {
      case .archive:
        "Archive"
      case .cachedArchive:
        "Cached / Archive"
    }
  }

  static func build(group: LibraryProjectGroup) -> LibraryProjectSectionState {
    var badges: [LibraryProjectSectionBadge] = []

    if group.liveSessions.count > 0 {
      badges.append(.live(group.liveSessions.count))
    }

    if group.cachedActiveSessionCount > 0 {
      badges.append(.cached(group.cachedActiveSessionCount))
    }

    if group.totalCost > 0 {
      badges.append(.cost(LibraryValueFormatter.cost(group.totalCost)))
    }

    if group.totalTokens > 0 {
      badges.append(.tokens(LibraryValueFormatter.tokens(group.totalTokens)))
    }

    return LibraryProjectSectionState(
      badges: badges,
      visibleEndpointFacetCount: min(group.endpointFacets.count, 3),
      hiddenEndpointFacetCount: max(group.endpointFacets.count - 3, 0),
      archiveSectionKind: group.cachedActiveSessionCount > 0 ? .cachedArchive : .archive
    )
  }
}
