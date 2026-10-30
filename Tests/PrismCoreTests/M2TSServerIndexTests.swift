import Foundation
import Testing
@testable import PrismCore

/// The external index is deliberately sparse: it records the real IRAPs the
/// server selected as segment anchors, not a cadence inferred from the head.
/// This fixture is large enough that the bounded local proof cannot establish
/// a VOD plan over a throttled origin, so a successful late fetch proves the
/// validator-bound map reached the strict M2TS planner.
@Suite(
    "M2TS server seek index",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_SERVER_INDEX_FIXTURE"] != nil)
)
struct M2TSServerIndexTests {

    @Test("a validator-bound complete M2TS map publishes VOD and reanchors at its packet offset")
    func suppliedMapPlansAndSeeks() async throws {
        let source = try fixture()
        let evidence = try indexEvidence(for: source)
        let media = try Data(contentsOf: source)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-m2ts-server-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let validator = "\"m2ts-server-index-v1\""
        let origin = try RangeFixtureServer(
            media: media, bytesPerSecond: 4_000_000, firstByteDelay: 0.01, etag: validator
        )
        let url = try await origin.start()
        defer { origin.stop() }

        let hints = SourceOpenHints(
            expectedValidator: validator,
            keyframes: SuppliedKeyframeMap(
                streamIndex: evidence.streamIndex,
                timeBaseNum: evidence.timeBaseNum,
                timeBaseDen: evidence.timeBaseDen,
                keyframePTS: evidence.keyframePTS,
                completeness: .complete,
                transportPID: evidence.basePID,
                sourceSize: evidence.sourceSize,
                packetOffsets: evidence.packetOffsets
            )
        )
        let session = try PrismCoreSession(
            url: url,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            keyframeIndexCacheDirectory: cache,
            sourceOpenHints: hints,
            segmentTargetDuration: 6,
            coordinatedHTTP: true,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)
        #expect(timeline.segments.reduce(0) { $0 + $1.duration } >= 95)
        let index = try #require(timeline.segments.indices.last(where: {
            $0 < timeline.segments.count
                && timeline.segments[$0].start <= evidence.targetSeconds
                && timeline.segments[$0].start + timeline.segments[$0].duration > evidence.targetSeconds
        }))

        let playlist = try await mediaPlaylist(for: master)
        let segments = try await segmentURLs(in: playlist)
        let requested = try #require(segments.indices.contains(index) ? segments[index] : nil)
        let packetOffset = try evidence.packetOffset(for: timeline.segments[index].start)
        let first = try await fetch(requested)

        // A one-byte cache forces the second request to re-anchor rather than
        // returning retained media. The external map's offset is the earliest
        // BL/EL packet for this advertised real boundary.
        if let neighbor = segments.indices.contains(index + 1) ? segments[index + 1] : segments.first {
            _ = try await fetch(neighbor)
        }
        #expect(try await fetch(requested) == first)
        #expect(origin.ranges.contains(where: {
            $0.hasPrefix("bytes=\(packetOffset)-")
        }), "deep re-anchor did not issue the supplied packet-offset range")
        #expect((await session.dolbyVisionConversion)?.isClean == true)
        #expect(await session.remuxFailure == nil)
        await session.stop()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: cache.path)
                .filter { $0.hasSuffix(".json") }
                .isEmpty,
            "a server assertion must not become a local harvested-keyframe map"
        )
    }

    @Test("a complete map that names the enhancement PID cannot publish strict M2TS VOD")
    func enhancementPIDMapFallsBackToSequential() async throws {
        let source = try fixture()
        let evidence = try indexEvidence(for: source)
        let media = try Data(contentsOf: source)
        let validator = "\"m2ts-server-index-v1\""
        let origin = try RangeFixtureServer(
            media: media, bytesPerSecond: 4_000_000, firstByteDelay: 0.01, etag: validator
        )
        let url = try await origin.start()
        defer { origin.stop() }

        // The enhancement PID is a real video stream and its time base agrees,
        // so generic hint evaluation can only identify it. The strict M2TS
        // association below must still reject it as a base-layer plan.
        let hints = SourceOpenHints(
            expectedValidator: validator,
            keyframes: SuppliedKeyframeMap(
                streamIndex: 0,
                timeBaseNum: evidence.timeBaseNum,
                timeBaseDen: evidence.timeBaseDen,
                keyframePTS: evidence.keyframePTS,
                completeness: .complete,
                transportPID: evidence.enhancementPID,
                sourceSize: evidence.sourceSize,
                packetOffsets: evidence.packetOffsets
            )
        )
        let session = try PrismCoreSession(
            url: url,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            sourceOpenHints: hints,
            segmentTargetDuration: 6,
            coordinatedHTTP: true,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        _ = try await session.start()
        #expect(session.segmentTimeline == nil, "an EL-named external map must not become a strict VOD plan")
        #expect(await session.remuxFailure == nil)
    }

    private func fixture() throws -> URL {
        URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_SERVER_INDEX_FIXTURE"]
        ))
    }

    private func indexEvidence(for source: URL) throws -> Evidence {
        struct Manifest: Decodable {
            struct Variable: Decodable {
                struct Fixture: Decodable {
                    struct ColdSeek: Decodable {
                        let targetSeconds: Double
                    }
                    struct SuppliedSeekIndex: Decodable {
                        let sourceSize: Int64
                        let basePID: Int32
                        let enhancementPID: Int32
                        let streamIndex: Int32
                        let timeBaseNum: Int32
                        let timeBaseDen: Int32
                        let keyframePTS: [Int64]
                        let packetOffsets: [Int64]

                        enum CodingKeys: String, CodingKey {
                            case sourceSize = "SourceSize"
                            case basePID = "BasePID"
                            case enhancementPID = "EnhancementPID"
                            case streamIndex = "StreamIndex"
                            case timeBaseNum = "TimeBaseNum"
                            case timeBaseDen = "TimeBaseDen"
                            case keyframePTS = "KeyframePTS"
                            case packetOffsets = "PacketOffsets"
                        }
                    }
                    let coldSeek: ColdSeek
                    let suppliedSeekIndex: SuppliedSeekIndex
                }
                let fixture: Fixture
            }
            let variableGOPColdSeek: Variable
        }
        let decoded = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        ).variableGOPColdSeek.fixture
        guard decoded.suppliedSeekIndex.packetOffsets.count == decoded.suppliedSeekIndex.keyframePTS.count else {
            throw ServerIndexError.missingTargetAnchor
        }
        return Evidence(
            sourceSize: decoded.suppliedSeekIndex.sourceSize,
            basePID: decoded.suppliedSeekIndex.basePID,
            enhancementPID: decoded.suppliedSeekIndex.enhancementPID,
            streamIndex: decoded.suppliedSeekIndex.streamIndex,
            timeBaseNum: decoded.suppliedSeekIndex.timeBaseNum,
            timeBaseDen: decoded.suppliedSeekIndex.timeBaseDen,
            keyframePTS: decoded.suppliedSeekIndex.keyframePTS,
            packetOffsets: decoded.suppliedSeekIndex.packetOffsets,
            targetSeconds: decoded.coldSeek.targetSeconds
        )
    }

    private func mediaPlaylist(for master: URL) async throws -> URL {
        let text = String(decoding: try await fetch(master), as: UTF8.self)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: text).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL else {
            throw ServerIndexError.missingVideoPlaylist
        }
        return media
    }

    private func segmentURLs(in media: URL) async throws -> [URL] {
        let text = String(decoding: try await fetch(media), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), !line.isEmpty else { return nil }
            return URL(string: String(line), relativeTo: media)?.absoluteURL
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.uncached.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw ServerIndexError.loopbackFetch(url.lastPathComponent)
        }
        return data
    }

    private struct Evidence {
        let sourceSize: Int64
        let basePID: Int32
        let enhancementPID: Int32
        let streamIndex: Int32
        let timeBaseNum: Int32
        let timeBaseDen: Int32
        let keyframePTS: [Int64]
        let packetOffsets: [Int64]
        let targetSeconds: Double

        func packetOffset(for segmentStart: Double) throws -> Int64 {
            guard let firstPTS = keyframePTS.first else { throw ServerIndexError.missingTargetAnchor }
            let ticks = Int64((segmentStart * Double(timeBaseDen) / Double(timeBaseNum)).rounded())
            let targetPTS = firstPTS + ticks
            guard let index = keyframePTS.firstIndex(of: targetPTS),
                  packetOffsets.indices.contains(index) else {
                throw ServerIndexError.missingTargetAnchor
            }
            return packetOffsets[index]
        }
    }

    private enum ServerIndexError: Error {
        case missingTargetAnchor
        case missingVideoPlaylist
        case loopbackFetch(String)
    }
}
