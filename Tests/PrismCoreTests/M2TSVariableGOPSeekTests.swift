import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import PrismCore

/// The transport fixture starts with one-second GOPs, then changes to 12 s, 1 s and 3 s GOPs.
/// A head-derived stride therefore makes a plausible VOD playlist that is wrong after the scout.
@Suite(
    "M2TS variable-GOP seeks",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_VARIABLE_GOP_FIXTURE"] != nil)
)
struct M2TSVariableGOPSeekTests {

    @Test("a cold VOD uses observed variable-GOP boundaries and preserves the requested source IRAP")
    func coldVODUsesObservedBoundaries() async throws {
        let source = try fixture()
        let targetSeconds = try coldSeekTarget(at: source)
        let pair = try transportPair(for: source)
        let sourcePackets = try packets(from: source, streamIndex: pair.baseStreamIndex)
        let sourceIRAPs = sourcePackets.filter(\.isKeyframe).map(\.pts)
        let sourceOrigin = try #require(sourceIRAPs.first)
        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            segmentTargetDuration: 6,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let timeline = try #require(session.segmentTimeline)
        let index = try #require(timeline.segments.indices.last(where: {
            timeline.segments[$0].start <= targetSeconds
                && timeline.segments[$0].start + timeline.segments[$0].duration > targetSeconds
        }))
        // SegmentTimeline begins at the source's first IRAP. Every immutable VOD boundary must
        // therefore be a separately observed source keyframe. The old partial-tail planner made
        // plausible six-second boundaries such as 14 s, where this fixture has no IRAP at all.
        for segment in timeline.segments {
            let sourcePTS = sourceOrigin + segment.start
            #expect(sourceIRAPs.contains(where: { abs($0 - sourcePTS) < 0.001 }))
        }

        let media = try await mediaPlaylist(for: master)
        let segments = try await segmentURLs(in: media)
        let requested = try #require(segments.indices.contains(index) ? segments[index] : nil)
        let base = master.deletingLastPathComponent()
        let initialisation = try await fetch(base.appendingPathComponent("init.mp4"))
        let first = try await fetch(requested)

        // A one-byte cache forces this second fetch through the re-anchor path rather than a
        // retained fragment. The byte equality catches duplicate or post-anchor substitutions.
        if let neighbor = segments.indices.contains(index + 1) ? segments[index + 1] : segments.first {
            _ = try await fetch(neighbor)
        }
        #expect(try await fetch(requested) == first)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-m2ts-variable-gop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fragment = directory.appendingPathComponent("segment.mp4")
        try (initialisation + first).write(to: fragment)

        let output = try videoUnits(from: fragment, streamIndex: 0).filter { $0.type <= 31 }
        let firstOutput = try #require(output.first)
        #expect(firstOutput.isIRAP)
        let sourceUnits = try videoUnits(from: source, streamIndex: pair.baseStreamIndex).filter { $0.type <= 31 }
        #expect(sourceUnits.count == sourcePackets.count)
        let sourceIndex = try #require(sourceUnits.firstIndex(of: firstOutput))
        #expect(sourceUnits[sourceIndex].isIRAP)
        #expect(sourcePackets[sourceIndex].isKeyframe)
        #expect(abs(sourcePackets[sourceIndex].pts - (sourceOrigin + timeline.segments[index].start)) < 0.001)
        let start = sourceOrigin + timeline.segments[index].start
        let end = start + timeline.segments[index].duration
        let nextAnchor = try #require(sourcePackets.indices.first(where: {
            $0 > sourceIndex && sourcePackets[$0].isKeyframe && abs(sourcePackets[$0].pts - end) < 0.001
        }))
        // Fragments preserve source decode order. A B-frame can present before the next anchor
        // after it was decoded, so clipping this interval by presentation end would reject legal
        // tail pictures. The only PTS floor is the actual re-anchor's preroll rule.
        let expected = sourceUnits[sourceIndex..<nextAnchor].indices.filter {
            sourcePackets[$0].pts >= start
        }.map { sourceUnits[$0] }
        #expect(output == expected, "the fragment must cover exactly its advertised source-time span")
        #expect((await session.dolbyVisionConversion)?.isClean == true)
        #expect(await session.remuxFailure == nil)
    }

    @Test("a budget-starved complete proof publishes no partial map")
    func budgetStarvedProofIsInsufficient() throws {
        let source = try fixture()
        let association = try association(for: source)
        let opened = try open(source)
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = opened.context
            avformat_close_input(&context)
        }
        let pair = try #require(SourceProbe.describe(
            input: opened.context, m2tsDolbyVisionAssociation: association
        ).dolbyVisionSeparateTrackPair)
        let stream = try #require(opened.context.pointee.streams[Int(pair.baseStreamIndex)])
        let end = stream.pointee.start_time + stream.pointee.duration
        let result = M2TSColdKeyframeScout.completeSparsePlan(
            input: opened.context,
            baseStreamIndex: Int32(pair.baseStreamIndex),
            timeBase: stream.pointee.time_base,
            timelineEndPTS: end,
            targetSeconds: 6,
            firstSegmentSeconds: SegmentPlan.defaultFirstSegmentSeconds,
            interruptGuard: opened.guard,
            byteBudget: 1
        )
        guard case let .insufficient(rewindRequired) = result else {
            Issue.record("Expected no VOD map under the sparse-proof byte budget, got \(result)")
            return
        }
        #expect(!rewindRequired)
    }

    private func fixture() throws -> URL {
        URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_VARIABLE_GOP_FIXTURE"]
        ))
    }

    private func coldSeekTarget(at source: URL) throws -> Double {
        struct Manifest: Decodable {
            struct Variable: Decodable {
                struct Fixture: Decodable {
                    struct ColdSeek: Decodable {
                        let targetSeconds: Double
                    }
                    let coldSeek: ColdSeek
                }
                let fixture: Fixture
            }
            let variableGOPColdSeek: Variable
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        )
        return manifest.variableGOPColdSeek.fixture.coldSeek.targetSeconds
    }

    private func mediaPlaylist(for master: URL) async throws -> URL {
        let text = String(decoding: try await fetch(master), as: UTF8.self)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: text).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL else {
            throw VariableGOPError("master has no video playlist")
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
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.uncached.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw VariableGOPError("loopback did not serve \(url.lastPathComponent)")
        }
        return data
    }

    private func association(for source: URL) throws -> M2TSDolbyVisionAssociation {
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard case let .association(association) = M2TSDolbyVisionAssociation.scan(Array(data)) else {
            throw VariableGOPError("fixture has no strict transport association")
        }
        return association
    }

    private func transportPair(for source: URL) throws -> DolbyVisionSeparateTrackPair {
        let association = try association(for: source)
        let opened = try open(source)
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = opened.context
            avformat_close_input(&context)
        }
        return try #require(SourceProbe.describe(
            input: opened.context, m2tsDolbyVisionAssociation: association
        ).dolbyVisionSeparateTrackPair)
    }

    private func open(_ source: URL) throws -> (
        guard: ReadInterruptGuard, context: UnsafeMutablePointer<AVFormatContext>
    ) {
        let guardBox = ReadInterruptGuard()
        var context: UnsafeMutablePointer<AVFormatContext>? = guardBox.makeContext()
        try FFmpegError.check(avformat_open_input(&context, source.path, nil, nil), "open variable GOP fixture")
        let opened = try #require(context)
        try FFmpegError.check(avformat_find_stream_info(opened, nil), "read variable GOP stream info")
        return (guardBox, opened)
    }

    private func videoUnits(from source: URL, streamIndex: Int) throws -> [NAL] {
        let output = try ffmpeg(
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", source.path,
            "-map", "0:\(streamIndex)", "-c", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "pipe:1"
        )
        return try output.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let units = HEVCNALUnits.strictUnits(in: .init(start: base, count: raw.count), framing: .annexB)
            else { throw VariableGOPError("invalid HEVC Annex-B payload") }
            return units.map { NAL(bytes: Data($0.bytes), type: $0.type) }
        }
    }

    private func packets(from source: URL, streamIndex: Int) throws -> [Packet] {
        let output = try ffmpeg(
            "ffprobe", "-v", "error", "-select_streams", "\(streamIndex)",
            "-show_packets", "-show_entries", "packet=pts_time,flags", "-of", "json", source.path
        )
        let document = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let values = try #require(document["packets"] as? [[String: Any]])
        return try values.map {
            guard let text = $0["pts_time"] as? String, let pts = Double(text) else {
                throw VariableGOPError("BL packet lacks PTS")
            }
            return Packet(pts: pts, isKeyframe: ($0["flags"] as? String)?.contains("K") == true)
        }
    }

    private func ffmpeg(_ command: String...) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else {
            throw VariableGOPError("\(command.first ?? "ffmpeg") failed: \(String(decoding: error, as: UTF8.self))")
        }
        return output
    }

    private struct NAL: Equatable {
        let bytes: Data
        let type: UInt8
        var isIRAP: Bool { (16...21).contains(Int(type)) }
    }

    private struct Packet {
        let pts: Double
        let isKeyframe: Bool
    }

    private struct VariableGOPError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
