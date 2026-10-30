import Foundation
import Testing
@testable import PrismCore

/// Public-session coverage for the legacy Matroska layout that carries a P7
/// base layer and its RPU/EL on complementary HEVC tracks.  The generated
/// corpus is deliberately opt-in: its RPUs come from libdovi rather than a
/// synthetic byte fixture, and belongs outside the ordinary hermetic suite.
@Suite(
    "Separate-track Dolby Vision",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_SEPARATE_FIXTURES"] != nil)
)
struct SeparateTrackDolbyVisionTests {
    private var fixtures: [URL] {
        paths(named: "PRISMCORE_DV7_SEPARATE_FIXTURES")
    }

    @Test("explicit P7 BL/EL Matroska pairs produce clean P8.1 HLS", arguments: ["MEL", "FEL"])
    func explicitPairsConvertToProfile81(kind: String) async throws {
        let index = kind == "MEL" ? 0 : 1
        guard fixtures.count == 2 else {
            throw FixtureError("PRISMCORE_DV7_SEPARATE_FIXTURES must be MEL:FEL")
        }
        let source = fixtures[index]
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw FixtureError("Missing \(kind) fixture: \(source.path)")
        }

        let info = try SourceProbe.probe(url: source)
        let pair = try #require(info.dolbyVisionSeparateTrackPair)
        #expect(info.video?.streamIndex == pair.baseStreamIndex)
        #expect(pair.baseStreamIndex != pair.enhancementStreamIndex)

        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            segmentTargetDuration: 1
        )
        defer { Task { await session.stop() } }
        let master = try await session.start()
        let masterText = try await fetchText(master)
        #expect(masterText.contains("dvh1.08"), "P7 pair was not declared as converted P8.1")
        #expect(masterText.contains("db1p"), "P8.1 HDR10 base was not declared supplemental")

        let stats = try await materializeToEnd(session: session, master: master)
        #expect(stats.convertedRPUs >= 192)
        #expect(stats.droppedEnhancementLayerNALs >= 192)
        #expect(stats.failedRPUs == 0)
        #expect(stats.staleUnconvertedPackets == 0)
        #expect(stats.isClean)
        try await forceReanchor(session: session, master: master)
    }

    @Test("the legacy default AAC rendition remains servable after a forced video re-anchor")
    func selectedAACSurvivesForcedReanchor() async throws {
        guard let source = fixtures.first else {
            throw FixtureError("PRISMCORE_DV7_SEPARATE_FIXTURES must include a MEL fixture")
        }
        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            segmentTargetDuration: 1
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let masterText = try await fetchText(master)
        guard masterText.contains("mp4a.40.2"),
              let audioRelative = PrismCoreSession.playlistURIs(inMaster: masterText).first(where: {
                  $0.hasPrefix("audio")
              }),
              let videoRelative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let audio = URL(string: audioRelative, relativeTo: master)?.absoluteURL,
              let video = URL(string: videoRelative, relativeTo: master)?.absoluteURL
        else { throw FixtureError("Missing selected AAC or video rendition") }

        let audioSegments = try await segmentURLs(in: audio)
        let videoSegments = try await segmentURLs(in: video)
        guard let firstAudio = audioSegments.first,
              let lastAudio = audioSegments.last,
              let firstVideo = videoSegments.first,
              let lastVideo = videoSegments.last,
              audioSegments.count >= 8,
              videoSegments.count >= 8
        else { throw FixtureError("Fixture did not produce enough selected AAC/video segments") }

        let audioRoot = audio.deletingLastPathComponent()
        #expect(!(try await fetchData(audioRoot.appendingPathComponent("init.mp4"))).isEmpty)
        #expect(!(try await fetchData(firstAudio)).isEmpty)
        #expect(!(try await fetchData(firstVideo)).isEmpty)
        // A one-byte cache makes this tail request abandon the head and
        // rebuild all rendition writers at the selected video boundary.
        #expect(!(try await fetchData(lastVideo)).isEmpty)
        #expect(!(try await fetchData(lastAudio)).isEmpty)
        #expect((await session.dolbyVisionConversion)?.isClean == true)
    }

    private func paths(named name: String) -> [URL] {
        (ProcessInfo.processInfo.environment[name] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
    }

    private func materializeToEnd(
        session: PrismCoreSession, master: URL
    ) async throws -> DolbyVisionConversionStats {
        let masterText = try await fetchText(master)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL
        else { throw FixtureError("No media playlist in master") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var fetched = Set<URL>()
        while ContinuousClock.now < deadline {
            let playlist = try await fetchText(media)
            for line in playlist.split(whereSeparator: \.isNewline)
            where !line.hasPrefix("#") && !line.isEmpty {
                guard let segment = URL(string: String(line), relativeTo: media)?.absoluteURL,
                      fetched.insert(segment).inserted
                else { continue }
                let (data, response) = try await URLSession.uncached.data(from: segment)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    throw FixtureError("Loopback did not serve a nonempty \(segment.lastPathComponent)")
                }
            }
            if playlist.contains("#EXT-X-ENDLIST"), let stats = await session.dolbyVisionConversion {
                return stats
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("Timed out waiting for final separate-track conversion statistics")
    }

    private func forceReanchor(session: PrismCoreSession, master: URL) async throws {
        let masterText = try await fetchText(master)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL
        else { throw FixtureError("No media playlist in master") }
        let finalPlaylist = try await fetchText(media)
        var segmentURLs: [URL] = []
        for line in finalPlaylist.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), !line.isEmpty,
                  let url = URL(string: String(line), relativeTo: media)?.absoluteURL
            else { continue }
            segmentURLs.append(url)
        }
        guard segmentURLs.count >= 8, let first = segmentURLs.first, let last = segmentURLs.last else {
            throw FixtureError("Fixture did not produce enough segments to force a re-anchor")
        }
        let work = await session.workDirectory
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent(first.lastPathComponent).path))
        let initBefore = try await fetchData(master.deletingLastPathComponent().appendingPathComponent("init.mp4"))
        #expect(!(try await fetchData(first)).isEmpty)
        do {
            #expect(!(try await fetchData(last)).isEmpty)
        } catch {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: work.path).sorted()) ?? []
            let failure = await session.remuxFailure
            throw FixtureError("re-anchor tail fetch failed: \(error); files=\(files); failure=\(String(describing: failure))")
        }
        #expect(try await fetchData(master.deletingLastPathComponent().appendingPathComponent("init.mp4")) == initBefore)
        let observedStats = await session.dolbyVisionConversion
        let stats = try #require(observedStats)
        #expect(stats.isClean)
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.uncached.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FixtureError("Loopback did not serve \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.uncached.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FixtureError("Loopback did not serve \(url.lastPathComponent)")
        }
        return data
    }

    private func segmentURLs(in playlist: URL) async throws -> [URL] {
        let text = try await fetchText(playlist)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), !line.isEmpty else { return nil }
            return URL(string: String(line), relativeTo: playlist)?.absoluteURL
        }
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@Suite(
    "Separate-track Dolby Vision refusals",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_SEPARATE_NEGATIVES"] != nil)
)
struct SeparateTrackDolbyVisionRefusalTests {
    @Test("malformed or ambiguous pairs fail typed")
    func invalidPairsFailClosed() async throws {
        let paths = (ProcessInfo.processInfo.environment["PRISMCORE_DV7_SEPARATE_NEGATIVES"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        guard paths.count == 4 else {
            throw FixtureError("PRISMCORE_DV7_SEPARATE_NEGATIVES must list final:missing:shifted:ambiguous")
        }
        for source in paths {
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw FixtureError("Missing negative fixture: \(source.path)")
            }
            try await verifyTypedRefusal(source)
        }
    }

    private func verifyTypedRefusal(_ source: URL) async throws {
        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true)
        )
        defer { Task { await session.stop() } }
        do {
            let master = try await session.start()
            try await fetchToTerminalFailure(session: session, master: master)
        } catch {
            guard case .invalidDolbyVisionConversion = PrismCoreError.classify(error) else {
                throw error
            }
        }
        guard case .invalidDolbyVisionConversion? = await session.remuxFailure else {
            throw FixtureError("Expected typed separate-track refusal for \(source.lastPathComponent)")
        }
    }

    private func fetchToTerminalFailure(session: PrismCoreSession, master: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if case .invalidDolbyVisionConversion? = await session.remuxFailure { return }
            if let text = try? await fetchText(master),
               let relative = PrismCoreSession.playlistURIs(inMaster: text).last,
               let media = URL(string: relative, relativeTo: master)?.absoluteURL {
                // Planned production parks at its lead cap until a segment is
                // requested. These fixtures are only two 6 s windows, so this
                // bounded look-ahead drives every malformed terminal case to
                // the same public producer failure without assuming it was
                // already listed when the playlist was first read.
                for index in 0...2 {
                    let path = String(format: "seg%05d.m4s", index)
                    try? await poke(media.deletingLastPathComponent().appendingPathComponent(path))
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError("Timed out waiting for typed separate-track refusal; observed \(String(describing: await session.remuxFailure))")
    }

    private func poke(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.2
        _ = try await URLSession.uncached.data(for: request)
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.uncached.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FixtureError("Loopback did not serve \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
