import CryptoKit
import Foundation
import ReaderModel

private struct ManifoldWorksEnvelope: Decodable {
    struct RawResonance: Decodable {
        var workId: String
        var domain: String
        var title: String?
        var sim: Double
    }
    struct RawWork: Decodable {
        var workId: String
        var domain: String
        var title: String
        var creator: String
        var year: Int?
        var kind: String?
        var subject: String?
        var format: String?
        var summary: String?
        var shard: String?
        var x: Double?
        var y: Double?
        var vec32: [Int]?
        var neighbours: [NeighbourScore]?
        var resonances: [RawResonance]?
        var epubUrl: String?
        var openAccessUrl: String?
    }
    var works: [RawWork]
}

private struct ManifoldLensesEnvelope: Decodable {
    struct RawLens: Decodable {
        var id: String
        var domain: String
        var name: String
        var summary: String
        var issuerHandle: String?
        var anchors: [LensAnchorItem]
        var transitions: [LensTransitionItem]?
    }
    var lenses: [RawLens]
}

public enum ManifoldReaderClient {
    public static let defaultHub = "https://manifold-chi.vercel.app"
    public static let userAgent = "CohortReader/1.0 (https://github.com/todd866/cohort-reader)"

    /// K-anonymous 2-hex prefix (`sha256(workId)[:2]`) matching Manifold's `workShardPrefix`.
    public static func workShardPrefix(_ workId: String) -> String {
        let digest = SHA256.hash(data: Data(workId.utf8))
        var iter = digest.makeIterator()
        guard let first = iter.next() else { return "00" }
        return String(format: "%02x", first)
    }

    public static func fetchSnapshot(
        hubBase: String = defaultHub,
        session: URLSession = .shared
    ) async throws -> (works: [ManifoldReaderWork], lenses: [ReaderLens]) {
        let clean = hubBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let worksURL = URL(string: "\(clean)/api/v1/works?domain=reader&limit=200"),
              let lensesURL = URL(string: "\(clean)/api/v1/lenses?domain=reader") else {
            throw URLError(.badURL)
        }

        var worksReq = URLRequest(url: worksURL)
        worksReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        worksReq.timeoutInterval = 12

        var lensesReq = URLRequest(url: lensesURL)
        lensesReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        lensesReq.timeoutInterval = 12

        async let wPair = session.data(for: worksReq)
        async let lPair = session.data(for: lensesReq)
        let (wData, _) = try await wPair
        let (lData, _) = try await lPair

        let decoder = JSONDecoder()
        let wEnv = try decoder.decode(ManifoldWorksEnvelope.self, from: wData)
        let lEnv = try decoder.decode(ManifoldLensesEnvelope.self, from: lData)

        let works = wEnv.works
            .filter { $0.domain == "reader" }
            .map { raw in
            let resLinks = (raw.resonances ?? []).compactMap { res -> ResonanceLink? in
                guard let rawTitle = res.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawTitle.isEmpty else {
                    return nil
                }
                let link = ResonanceLink(workId: res.workId, domain: res.domain, title: rawTitle, sim: res.sim)
                return link.isValidEditorialResonance ? link : nil
            }
            return ManifoldReaderWork(
                workId: raw.workId,
                title: raw.title,
                creator: raw.creator,
                year: raw.year ?? 2026,
                kind: raw.kind ?? "reader",
                subject: raw.subject,
                format: BookFormat(rawValue: raw.format ?? "") ?? .article,
                summary: raw.summary ?? "",
                shard: raw.shard ?? workShardPrefix(raw.workId),
                x: raw.x ?? 0,
                y: raw.y ?? 0,
                vec32: raw.vec32 ?? [],
                neighbours: raw.neighbours ?? [],
                resonances: resLinks,
                epubURL: raw.epubUrl,
                openAccessURL: raw.openAccessUrl
            )
        }

        let lenses = lEnv.lenses
            .filter { $0.domain == "reader" }
            .map { raw in
            ReaderLens(
                id: raw.id,
                name: raw.name,
                summary: raw.summary,
                issuerHandle: raw.issuerHandle ?? "manifold",
                anchors: raw.anchors,
                transitions: raw.transitions ?? []
            )
        }

        return (works, lenses)
    }

    public static func fetchShard(
        prefix: String,
        hubBase: String = defaultHub,
        session: URLSession = .shared
    ) async throws -> (rawData: Data, works: [ManifoldReaderWork]) {
        let clean = hubBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let normPrefix = String(prefix.lowercased().prefix(2))
        guard let url = URL(string: "\(clean)/api/v1/shard/\(normPrefix)?domain=reader") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        let (data, _) = try await session.data(for: req)
        let env = try JSONDecoder().decode(ManifoldWorksEnvelope.self, from: data)
        let works = env.works
            .filter { $0.domain == "reader" }
            .map { raw in
            let resLinks = (raw.resonances ?? []).compactMap { res -> ResonanceLink? in
                guard let rawTitle = res.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawTitle.isEmpty else {
                    return nil
                }
                let link = ResonanceLink(workId: res.workId, domain: res.domain, title: rawTitle, sim: res.sim)
                return link.isValidEditorialResonance ? link : nil
            }
            return ManifoldReaderWork(
                workId: raw.workId,
                title: raw.title,
                creator: raw.creator,
                year: raw.year ?? 2026,
                kind: raw.kind ?? "reader",
                subject: raw.subject,
                format: BookFormat(rawValue: raw.format ?? "") ?? .article,
                summary: raw.summary ?? "",
                shard: raw.shard ?? normPrefix,
                x: raw.x ?? 0,
                y: raw.y ?? 0,
                vec32: raw.vec32 ?? [],
                neighbours: raw.neighbours ?? [],
                resonances: resLinks,
                epubURL: raw.epubUrl,
                openAccessURL: raw.openAccessUrl
            )
        }
        return (data, works)
    }
}

public struct RankedWork: Identifiable, Sendable {
    public var id: String { work.workId }
    public var work: ManifoldReaderWork
    public var score: Double

    public init(work: ManifoldReaderWork, score: Double) {
        self.work = work
        self.score = score
    }
}

public enum LensRanker {
    public static func cosine(_ a: [Int], _ b: [Int]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let va = Double(a[i])
            let vb = Double(b[i])
            dot += va * vb
            na += va * va
            nb += vb * vb
        }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }

    public static func rank(
        works: [ManifoldReaderWork],
        lens: ReaderLens,
        currentWorkId: String? = nil
    ) -> [RankedWork] {
        let byId = Dictionary(uniqueKeysWithValues: works.map { ($0.workId, $0) })
        let anchorPairs: [(work: ManifoldReaderWork, weight: Double)] = lens.anchors.compactMap { anc in
            guard let w = byId[anc.workId] else { return nil }
            return (w, anc.weight)
        }
        let transitions = Dictionary(
            uniqueKeysWithValues: lens.transitions
                .filter { $0.from == currentWorkId }
                .map { ($0.to, $0.weight) }
        )

        var out: [RankedWork] = []
        for cand in works where cand.workId != currentWorkId {
            var weightedSum = 0.0
            var totalWeight = 0.0
            var bestSim = -1.0
            for anc in anchorPairs {
                let sim = cand.workId == anc.work.workId ? 1.0 : cosine(anc.work.vec32, cand.vec32)
                weightedSum += sim * anc.weight
                totalWeight += anc.weight
                bestSim = max(bestSim, sim)
            }
            let base = totalWeight > 0 ? weightedSum / totalWeight : 0
            let tBoost = (transitions[cand.workId] ?? 0) * 0.25
            let total = base * 0.7 + max(0, bestSim) * 0.3 + tBoost
            out.append(RankedWork(work: cand, score: total))
        }
        return out.sorted { $0.score > $1.score }
    }
}

public enum OpenAccessResolver {
    public static func directDownloadURL(for canonicalId: String) -> URL? {
        if canonicalId.hasPrefix("gutenberg:") {
            let id = String(canonicalId.dropFirst("gutenberg:".count))
            return URL(string: "https://www.gutenberg.org/ebooks/\(id).epub3.images")
        }
        if canonicalId.hasPrefix("arxiv:") {
            let id = String(canonicalId.dropFirst("arxiv:".count))
            return URL(string: "https://arxiv.org/pdf/\(id).pdf")
        }
        return nil
    }
}
