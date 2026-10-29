import Foundation
import Testing
@testable import PrismCore

/// Generated P7 inputs carry real libdovi RPU data, including terminal corrupt
/// RPUs that synthetic HEVC encodes cannot represent. This exercises the public
/// session observation a host has after materializing the whole HLS stream.
@Suite(
    "Final Dolby Vision conversion statistics",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_FINAL_STATS"] != nil)
)
struct FinalDolbyVisionConversionStatsTests {

    private var fixtures: [URL] {
        (ProcessInfo.processInfo.environment["PRISMCORE_DV7_FINAL_STATS"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
    }

    @Test("a corrupt final RPU is published after the EOF tail lands")
    func finalRPUPublishesDirtyStatistics() async throws {
        let stats = try await produceToEnd(try fixture(at: 0, named: "long final-RPU fixture"))
        #expect(stats.convertedRPUs > 0)
        #expect(stats.failedRPUs > 0 || stats.staleUnconvertedPackets > 0)
        #expect(!stats.isClean)
    }

    @Test("a tail-only source publishes malformed-RPU statistics")
    func tailOnlySourcePublishesDirtyStatistics() async throws {
        let stats = try await produceToEnd(try fixture(at: 1, named: "two-frame tail fixture"))
        #expect(stats.convertedRPUs > 0)
        #expect(stats.failedRPUs > 0 || stats.staleUnconvertedPackets > 0)
        #expect(!stats.isClean)
    }

    private func fixture(at index: Int, named name: String) throws -> URL {
        guard fixtures.count == 2 else {
            throw FixtureError("PRISMCORE_DV7_FINAL_STATS must be long:short P7 fixtures")
        }
        let fixture = fixtures[index]
        guard FileManager.default.isReadableFile(atPath: fixture.path) else {
            throw FixtureError("Missing \(name): \(fixture.path)")
        }
        return fixture
    }

    private func produceToEnd(_ fixture: URL) async throws -> DolbyVisionConversionStats {
        let session = try PrismCoreSession(
            url: fixture,
            display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: true)
        )
        defer { Task { await session.stop() } }
        let playlist = try await session.start()
        let media = try await mediaPlaylist(for: playlist)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var fetched = Set<URL>()
        while ContinuousClock.now < deadline {
            let text = try await fetchText(media)
            for segment in segmentURLs(in: text, relativeTo: media) where fetched.insert(segment).inserted {
                let (data, response) = try await URLSession.uncached.data(from: segment)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    throw FixtureError("Loopback did not serve a nonempty \(segment.lastPathComponent)")
                }
            }
            if text.contains("#EXT-X-ENDLIST"), let stats = await session.dolbyVisionConversion {
                return stats
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("Timed out waiting for the session's final conversion statistics")
    }

    private func mediaPlaylist(for playlist: URL) async throws -> URL {
        let master = try await fetchText(playlist)
        guard let path = PrismCoreSession.playlistURIs(inMaster: master).last,
              let media = URL(string: path, relativeTo: playlist)?.absoluteURL else {
            return playlist
        }
        return media
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.uncached.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FixtureError("Loopback did not serve \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func segmentURLs(in playlist: String, relativeTo url: URL) -> [URL] {
        playlist.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), !line.isEmpty else { return nil }
            return URL(string: String(line), relativeTo: url)?.absoluteURL
        }
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
