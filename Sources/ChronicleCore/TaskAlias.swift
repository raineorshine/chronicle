import Foundation

/// A resolved task-rename alias: rows whose task/subtask identity matches
/// `from` are canonicalized to the `to` identity at read time, so a renamed
/// task and its former titles roll up as one activity across all metrics.
///
/// A `nil` subtask key means "no subtask" and matches only rows that themselves
/// have no subtask (exact-title matching).
public struct ResolvedAlias: Equatable {
    public let fromTaskKey: String
    public let fromSubtaskKey: String?
    public let toTaskKey: String
    public let toTaskLabel: String
    public let toSubtaskKey: String?
    public let toSubtaskLabel: String?

    public init(fromTaskKey: String,
                fromSubtaskKey: String?,
                toTaskKey: String,
                toTaskLabel: String,
                toSubtaskKey: String?,
                toSubtaskLabel: String?) {
        self.fromTaskKey = fromTaskKey
        self.fromSubtaskKey = fromSubtaskKey
        self.toTaskKey = toTaskKey
        self.toTaskLabel = toTaskLabel
        self.toSubtaskKey = toSubtaskKey
        self.toSubtaskLabel = toSubtaskLabel
    }
}

/// Resolves configured rename chains into a flat list of `ResolvedAlias` edges.
public enum AliasResolver {

    /// Flattens `aliasChains` into alias edges. For each chain, the **last**
    /// parseable title is the canonical target and every earlier parseable
    /// title becomes an alias into it. Titles are parsed with `separators` (the
    /// same rules the extractor uses) so keys line up with `daily_time`.
    ///
    /// Self-maps (an entry whose identity equals the canonical) and unparseable
    /// entries are skipped. If the same `from` identity appears in more than one
    /// chain, the later chain wins.
    public static func resolve(chains: [[String]],
                               separators: [String] = [" - ", " | "]) -> [ResolvedAlias] {
        // Keyed by (fromTaskKey, fromSubtaskKey) so cross-chain duplicates
        // collapse deterministically (last chain wins) and ordering is stable.
        var order: [String] = []
        var byKey: [String: ResolvedAlias] = [:]

        for chain in chains {
            let parsed = chain.compactMap { TitleParser.parse($0, separators: separators) }
            guard parsed.count >= 2, let canonical = parsed.last else { continue }

            for title in parsed.dropLast() {
                let fromTaskKey = title.task.key
                let fromSubtaskKey = title.subtask?.key
                // Skip an entry that already equals the canonical identity.
                if fromTaskKey == canonical.task.key
                    && fromSubtaskKey == canonical.subtask?.key { continue }

                let dedupe = "\(fromTaskKey)\u{1F}\(fromSubtaskKey ?? "")"
                if byKey[dedupe] == nil { order.append(dedupe) }
                byKey[dedupe] = ResolvedAlias(
                    fromTaskKey: fromTaskKey,
                    fromSubtaskKey: fromSubtaskKey,
                    toTaskKey: canonical.task.key,
                    toTaskLabel: canonical.task.label,
                    toSubtaskKey: canonical.subtask?.key,
                    toSubtaskLabel: canonical.subtask?.label)
            }
        }

        return order.map { byKey[$0]! }
    }
}
