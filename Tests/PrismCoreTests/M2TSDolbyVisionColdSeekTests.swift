import Foundation
import Testing
@testable import PrismCore

/// The long transport fixture is generated outside Git.  Its first requested
/// media segment is near 75 seconds, before a cold producer could have
/// reached it by reading from the head under the normal lead cap.
@Suite(
    "M2TS Dolby Vision cold seeks",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE"] != nil)
)
struct M2TSDolbyVisionColdSeekTests {
    @Test("a cold required M2TS session publishes the complete VOD before a late first fetch")
    func coldLateFetchUsesPlannedTimeline() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE"])
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-m2ts-cold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let session = try PrismCoreSession(
            url: URL(fileURLWithPath: path),
            displayIsHDRReady: true,
            displayIsDolbyVisionCapable: true,
            segmentCacheBytes: 1,
            keyframeIndexCacheDirectory: cache,
            segmentTargetDuration: 6,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)
        let duration = timeline.segments.reduce(0) { $0 + $1.duration }
        #expect(duration >= 95, "cold transport session did not publish its full timeline")
        let index = try #require(timeline.segments.indices.last(where: {
            timeline.segments[$0].start <= 75 && timeline.segments[$0].start + timeline.segments[$0].duration > 75
        }))

        let masterText = try await text(master)
        guard let variant = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: variant, relativeTo: master)?.absoluteURL
        else { throw ColdSeekError.unproven("no video playlist") }
        let mediaText = try await text(media)
        let segments = mediaText.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard segments.indices.contains(index) else {
            throw ColdSeekError.unproven("planned late segment missing")
        }
        // A one-byte segment cache makes every jump a real producer
        // re-anchor. The forward/backward/repeat sequence covers the pairer's
        // reset floor after timestamp seeks, rather than merely proving the
        // first cold target can be located.
        let requests = [
            index,
            min(index + 2, segments.index(before: segments.endIndex)),
            max(index - 1, segments.startIndex),
            index,
        ]
        for requested in requests {
            guard let segment = URL(string: String(segments[requested]), relativeTo: media)?.absoluteURL else {
                throw ColdSeekError.unproven("invalid planned segment URL")
            }
            var request = URLRequest(url: segment)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.uncached.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(!data.isEmpty)
        }

        // The scout itself is deliberately not cache evidence. Stopping this
        // session only creates a sidecar after its producer has traversed
        // real packet keys from the head; the next session must then use that
        // packet-key namespace and still service a late re-anchor.
        await session.stop()
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: cache.path)
            .filter { $0.hasSuffix(".json") }
        #expect(!sidecars.isEmpty, "producer did not persist a harvested packet-key map")

        let warm = try PrismCoreSession(
            url: URL(fileURLWithPath: path),
            displayIsHDRReady: true,
            displayIsDolbyVisionCapable: true,
            segmentCacheBytes: 1,
            keyframeIndexCacheDirectory: cache,
            segmentTargetDuration: 6,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await warm.stop() } }
        let warmMaster = try await warm.start()
        let warmReport = await warm.diagnosticReport()
        #expect(warmReport.startup.planOrigin == SegmentPlanOrigin.keyframeIndexCache.rawValue)
        let warmMasterText = try await text(warmMaster)
        guard let warmVariant = PrismCoreSession.playlistURIs(inMaster: warmMasterText).last,
              let warmMedia = URL(string: warmVariant, relativeTo: warmMaster)?.absoluteURL
        else { throw ColdSeekError.unproven("no warm video playlist") }
        let warmMediaText = try await text(warmMedia)
        let warmSegments = warmMediaText.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard warmSegments.indices.contains(index),
              let warmSegment = URL(string: String(warmSegments[index]), relativeTo: warmMedia)?.absoluteURL
        else { throw ColdSeekError.unproven("warm late segment missing") }
        var warmRequest = URLRequest(url: warmSegment)
        warmRequest.timeoutInterval = 10
        let (warmData, warmResponse) = try await URLSession.uncached.data(for: warmRequest)
        #expect((warmResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!warmData.isEmpty)
    }

    @Test(
        "an inferred tail boundary locates the next real IRAP without emitting a conversion failure",
        .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_GOP48_FIXTURE"] != nil)
    )
    func inferredTailBoundaryUsesVerifiedIRAP() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_GOP48_FIXTURE"])
        let session = try PrismCoreSession(
            url: URL(fileURLWithPath: path),
            displayIsHDRReady: true,
            displayIsDolbyVisionCapable: true,
            segmentCacheBytes: 1,
            segmentTargetDuration: 5,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)
        // This fixture's 77 s planned tail boundary is deliberately not an
        // IRAP. The next valid BL anchor is at 78.083 s.
        let target = try #require(timeline.segments.indices.last(where: {
            timeline.segments[$0].start <= 78
                && timeline.segments[$0].start + timeline.segments[$0].duration > 78
        }))
        let masterText = try await text(master)
        guard let variant = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: variant, relativeTo: master)?.absoluteURL
        else { throw ColdSeekError.unproven("no GOP48 video playlist") }
        let mediaText = try await text(media)
        let segments = mediaText.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard segments.indices.contains(target),
              let segment = URL(string: String(segments[target]), relativeTo: media)?.absoluteURL
        else { throw ColdSeekError.unproven("inferred tail segment missing") }
        var request = URLRequest(url: segment)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.uncached.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!data.isEmpty)
        let remuxFailure = await session.remuxFailure
        let conversion = await session.dolbyVisionConversion
        #expect(remuxFailure == nil)
        #expect(conversion?.isClean == true)
    }

    private func text(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.uncached.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ColdSeekError.unproven("loopback did not serve \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum ColdSeekError: Error {
    case unproven(String)
}
