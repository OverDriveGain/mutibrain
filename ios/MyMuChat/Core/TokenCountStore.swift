import Foundation

/// Last-known context consumption per session — shared by every list row that
/// shows a token count.
///
/// Why this exists: the Agents list originally probed SEQUENTIALLY, one
/// `history?limit=1` await at a time, each on the default 30s timeout. One
/// slow agent — typically one pinned to a host this account can't read —
/// stalled every row behind it; with a real fleet the tail took half a minute
/// or never arrived. Now:
///  - counts persist across launches and show INSTANTLY, then revalidate in
///    the background (stale-while-revalidate — a slightly old number beats a
///    blank row every time);
///  - probes run concurrently with a small cap, so one dead host can't block
///    the rest;
///  - probes use a short timeout — a host that's been silent for 8s isn't
///    going to answer usefully.
@MainActor
final class TokenCountStore: ObservableObject {
    static let shared = TokenCountStore()

    @Published private(set) var counts: [String: Int] = [:]
    /// Live progress of the current batch refresh — (done, total) while probes
    /// are in flight, nil when idle. Lists narrate THIS ("Updating usage 4/9")
    /// instead of holding a refresh spinner hostage until the slowest probe.
    @Published private(set) var progress: (done: Int, total: Int)?
    private var inFlight: Set<String> = []

    private static let defaultsKey = "mymu.tokenCounts"
    private static let probeTimeout: TimeInterval = 8
    private static let maxConcurrent = 5

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = saved
        }
    }

    private func persist() {
        // Bound the persisted set so it can't grow with every session ever
        // seen. No timestamps are kept — dropped entries just re-probe on sight.
        var snapshot = counts
        if snapshot.count > 400 {
            snapshot = Dictionary(uniqueKeysWithValues: Array(snapshot.prefix(400)))
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func fetch(_ sessionId: String, _ api: APIClient) async -> Int? {
        let used = (try? await api.history(sessionId: sessionId, limit: 1,
                                           timeout: Self.probeTimeout))?.context?.usedTokens
        return (used ?? 0) > 0 ? used : nil
    }

    /// Batch refresh (the Agents roster). Missing-only unless `force`; rows
    /// fill in one by one as results land, sliding-window concurrency.
    func refresh(sessionIds: [String], api: APIClient, force: Bool = false) async {
        let wanted = sessionIds.filter { (force || counts[$0] == nil) && !inFlight.contains($0) }
        guard !wanted.isEmpty else { return }
        wanted.forEach { inFlight.insert($0) }
        let running = progress ?? (0, 0)
        progress = (running.done, running.total + wanted.count)
        defer {
            wanted.forEach { inFlight.remove($0) }
            if inFlight.isEmpty { progress = nil }
            persist()
        }

        await withTaskGroup(of: (String, Int?).self) { group in
            var iterator = wanted.makeIterator()
            func addNext(_ group: inout TaskGroup<(String, Int?)>) {
                guard let sid = iterator.next() else { return }
                group.addTask { (sid, await self.fetch(sid, api)) }
            }
            for _ in 0..<Self.maxConcurrent { addNext(&group) }
            for await (sid, used) in group {
                if let used { counts[sid] = used }
                if let p = progress { progress = (p.done + 1, p.total) }
                addNext(&group)
            }
        }
    }

    /// One lazy probe — Conversations rows fire these as they scroll into view.
    func probe(sessionId: String, api: APIClient) async {
        guard counts[sessionId] == nil, !inFlight.contains(sessionId) else { return }
        inFlight.insert(sessionId)
        defer { inFlight.remove(sessionId) }
        if let used = await fetch(sessionId, api) {
            counts[sessionId] = used
            persist()
        }
    }
}
