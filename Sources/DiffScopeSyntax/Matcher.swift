import DiffScopeEngine
import Foundation

public struct MatcherSettings: Sendable {
    public var minimumHeight: Int
    public var minimumDice: Double
    public var maximumCandidates: Int
    public var boundarySnapBudget: Int
    public var moveContentFloor: Int

    public init(minimumHeight: Int = 1, minimumDice: Double = 0.5, maximumCandidates: Int = 32,
                boundarySnapBudget: Int = DiffScopeSyntax.boundarySnapBudget,
                moveContentFloor: Int = DiffScopeSyntax.moveContentFloor) {
        self.minimumHeight = minimumHeight
        self.minimumDice = minimumDice
        self.maximumCandidates = maximumCandidates
        self.boundarySnapBudget = boundarySnapBudget
        self.moveContentFloor = moveContentFloor
    }
}

public struct AmbiguityRecord: Sendable, Equatable {
    public let oldCandidates: [Int]
    public let newCandidates: [Int]
    public let structuralHash: UInt64
    public let height: Int
}

public struct NodeMapping: Sendable {
    public private(set) var oldToNew: [Int: Int] = [:]
    public private(set) var newToOld: [Int: Int] = [:]
    public private(set) var ambiguities: [AmbiguityRecord] = []

    mutating func link(old: Int, new: Int) {
        guard oldToNew[old] == nil, newToOld[new] == nil else { return }
        oldToNew[old] = new
        newToOld[new] = old
    }

    mutating func record(_ ambiguity: AmbiguityRecord) {
        ambiguities.append(ambiguity)
    }

    public func isMapped(old: Int) -> Bool { oldToNew[old] != nil }
    public func isMapped(new: Int) -> Bool { newToOld[new] != nil }

    public var ambiguousOldNodes: Set<Int> {
        Set(ambiguities.flatMap(\.oldCandidates))
    }

    public var ambiguousNewNodes: Set<Int> {
        Set(ambiguities.flatMap(\.newCandidates))
    }
}

public func matchTrees(
    old: SyntaxTree,
    new: SyntaxTree,
    settings: MatcherSettings = MatcherSettings()
) -> NodeMapping {
    var mapping = NodeMapping()
    guard let oldRoot = old.rootID, let newRoot = new.rootID else { return mapping }

    topDown(old: old, new: new, oldRoot: oldRoot, newRoot: newRoot, settings: settings, mapping: &mapping)
    bottomUp(old: old, new: new, oldRoot: oldRoot, newRoot: newRoot, settings: settings, mapping: &mapping)
    return mapping
}

private func topDown(
    old: SyntaxTree, new: SyntaxTree, oldRoot: Int, newRoot: Int,
    settings: MatcherSettings, mapping: inout NodeMapping
) {
    var oldFrontier = [oldRoot]
    var newFrontier = [newRoot]

    while !oldFrontier.isEmpty, !newFrontier.isEmpty {
        let oldMax = oldFrontier.map { old.node($0).height }.max() ?? 0
        let newMax = newFrontier.map { new.node($0).height }.max() ?? 0

        if oldMax < settings.minimumHeight, newMax < settings.minimumHeight { return }

        if oldMax > newMax {
            oldFrontier = expand(oldFrontier, keeping: oldMax, in: old)
            continue
        }
        if newMax > oldMax {
            newFrontier = expand(newFrontier, keeping: newMax, in: new)
            continue
        }

        let oldTall = oldFrontier.filter { old.node($0).height == oldMax }.sorted()
        let newTall = newFrontier.filter { new.node($0).height == newMax }.sorted()

        var oldByHash: [UInt64: [Int]] = [:]
        for id in oldTall { oldByHash[old.node(id).structuralHash, default: []].append(id) }
        var newByHash: [UInt64: [Int]] = [:]
        for id in newTall { newByHash[new.node(id).structuralHash, default: []].append(id) }

        var consumedOld = Set<Int>()
        var consumedNew = Set<Int>()

        for hash in oldByHash.keys.sorted() {
            guard let oldGroup = oldByHash[hash], let newGroup = newByHash[hash] else { continue }
            if oldGroup.count == 1, newGroup.count == 1 {
                mapSubtrees(old: old, new: new, oldID: oldGroup[0], newID: newGroup[0], mapping: &mapping)
                consumedOld.insert(oldGroup[0])
                consumedNew.insert(newGroup[0])
            } else if oldGroup.count <= settings.maximumCandidates,
                      newGroup.count <= settings.maximumCandidates {
                mapping.record(AmbiguityRecord(
                    oldCandidates: oldGroup, newCandidates: newGroup,
                    structuralHash: hash, height: oldMax
                ))
                let pairs = min(oldGroup.count, newGroup.count)
                for index in 0..<pairs {
                    mapSubtrees(old: old, new: new, oldID: oldGroup[index], newID: newGroup[index], mapping: &mapping)
                    consumedOld.insert(oldGroup[index])
                    consumedNew.insert(newGroup[index])
                }
            }
        }

        oldFrontier = oldFrontier.filter { old.node($0).height != oldMax || !consumedOld.contains($0) }
        newFrontier = newFrontier.filter { new.node($0).height != newMax || !consumedNew.contains($0) }
        oldFrontier = expand(oldFrontier, keeping: oldMax, in: old)
        newFrontier = expand(newFrontier, keeping: newMax, in: new)
    }
}

private func expand(_ frontier: [Int], keeping height: Int, in tree: SyntaxTree) -> [Int] {
    var next: [Int] = []
    for id in frontier {
        if tree.node(id).height == height {
            next.append(contentsOf: tree.node(id).children)
        } else {
            next.append(id)
        }
    }
    return next.sorted()
}

private func mapSubtrees(old: SyntaxTree, new: SyntaxTree, oldID: Int, newID: Int, mapping: inout NodeMapping) {
    mapping.link(old: oldID, new: newID)
    let oldChildren = old.node(oldID).children
    let newChildren = new.node(newID).children
    guard oldChildren.count == newChildren.count else { return }
    for index in 0..<oldChildren.count {
        mapSubtrees(old: old, new: new, oldID: oldChildren[index], newID: newChildren[index], mapping: &mapping)
    }
}

private func bottomUp(
    old: SyntaxTree, new: SyntaxTree, oldRoot: Int, newRoot: Int,
    settings: MatcherSettings, mapping: inout NodeMapping
) {
    var oldMappedDescendants: [Int: Set<Int>] = [:]
    for id in old.descendants(of: oldRoot).sorted(by: >) {
        var set = Set<Int>()
        if mapping.isMapped(old: id) { set.insert(id) }
        for child in old.node(id).children { set.formUnion(oldMappedDescendants[child] ?? []) }
        oldMappedDescendants[id] = set
    }

    let newPostOrder = new.descendants(of: newRoot).sorted(by: >)
    var newMappedDescendants: [Int: Set<Int>] = [:]
    for id in newPostOrder {
        var set = Set<Int>()
        if mapping.isMapped(new: id) { set.insert(id) }
        for child in new.node(id).children { set.formUnion(newMappedDescendants[child] ?? []) }
        newMappedDescendants[id] = set
    }

    let oldCandidatesByType = Dictionary(grouping: old.descendants(of: oldRoot).sorted()) { old.node($0).type }

    for newID in newPostOrder.reversed() {
        guard !mapping.isMapped(new: newID) else { continue }
        let newNode = new.node(newID)
        guard !newNode.isLeaf else { continue }

        let newMapped = newMappedDescendants[newID] ?? []
        guard !newMapped.isEmpty else { continue }

        let translated = Set(newMapped.compactMap { mapping.newToOld[$0] })
        guard !translated.isEmpty else { continue }

        var best: (id: Int, dice: Double)?
        for oldID in oldCandidatesByType[newNode.type] ?? [] {
            guard !mapping.isMapped(old: oldID) else { continue }
            let oldMapped = oldMappedDescendants[oldID] ?? []
            guard !oldMapped.isEmpty else { continue }
            let shared = oldMapped.intersection(translated).count
            guard shared > 0 else { continue }
            let dice = 2.0 * Double(shared) / Double(oldMapped.count + newMapped.count)
            if dice >= settings.minimumDice {
                if best == nil || dice > best!.dice || (dice == best!.dice && oldID < best!.id) {
                    best = (oldID, dice)
                }
            }
        }

        if let best {
            mapping.link(old: best.id, new: newID)
        }
    }
}
