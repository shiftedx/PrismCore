import Foundation
import Testing
import Libavformat
@testable import PrismCore

/// A served fragment being HTTP 200 proves only that a producer wrote bytes. These two cold
/// routes also prove the bytes retain the chosen BL pictures and the matching P8.1 RPUs.
@Suite(
    "M2TS cold-seek payloads",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE"] != nil)
)
struct M2TSColdSeekPayloadTests {

    @Test("a late cold request preserves its selected BL VCL and matching P8.1 RPUs")
    func lateColdRequestPreservesPayload() async throws {
        let source = try fixture(named: "PRISMCORE_DV7_M2TS_COLD_SEEK_FIXTURE")
        // 75 s is an independently requested cold region. The source starts at 1/12 s, so its
        // verified IRAP is 74.083 s, not an inferred PCR boundary or a retimed source head.
        try await verifyColdPayload(
            source: source, requestedSecond: 75, segmentTargetDuration: 6,
            expectedIRAPPTS: 74.083_333
        )
    }

    @Test(
        "a nonaligned GOP request advances to the next real IRAP without changing its payload",
        .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_COLD_GOP48_FIXTURE"] != nil)
    )
    func nonalignedGOPRequestPreservesPayload() async throws {
        let source = try fixture(named: "PRISMCORE_DV7_M2TS_COLD_GOP48_FIXTURE")
        // The planned 77 s boundary has no IRAP. Its first independently decodable picture is
        // the 78.083 s source picture, ordinal 1872 at 24 fps.
        try await verifyColdPayload(
            source: source, requestedSecond: 77, segmentTargetDuration: 5,
            expectedIRAPPTS: 78.083_333
        )
    }

    private func verifyColdPayload(
        source: URL, requestedSecond: Double, segmentTargetDuration: Int, expectedIRAPPTS: Double
    ) async throws {
        let pair = try provenTransportPair(for: source)
        let expectedRPU = try annexBUnits(
            Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("p81-m2ts-cold-seek-mel.rpu"))
        )

        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            segmentTargetDuration: segmentTargetDuration,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }

        let master = try await session.start()
        let media = try await mediaPlaylist(for: master)
        let segments = try await segments(in: media)
        let timeline = try #require(session.segmentTimeline)
        let requestedIndex = try #require(timeline.segments.indices.last(where: {
            timeline.segments[$0].start <= requestedSecond
                && timeline.segments[$0].start + timeline.segments[$0].duration > requestedSecond
        }))
        guard segments.indices.contains(requestedIndex) else {
            throw PayloadError("no segment for requested cold second \(requestedSecond)")
        }

        let base = master.deletingLastPathComponent()
        let initBefore = try await fetch(base.appendingPathComponent("init.mp4"))
        #expect(initBefore.range(of: Data("dvvC".utf8)) != nil)
        let segment = try await fetch(segments[requestedIndex])

        // Make the same cold location real again after a different demand. A one-byte cache
        // cannot hide a re-anchor behind retained media, while the init record is immutable.
        if let neighbor = segments.indices.contains(requestedIndex + 1) ? segments[requestedIndex + 1] : segments.first {
            _ = try await fetch(neighbor)
        }
        _ = try await fetch(segments[requestedIndex])
        #expect(try await fetch(base.appendingPathComponent("init.mp4")) == initBefore)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-m2ts-cold-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let fragment = work.appendingPathComponent("fragment.mp4")
        try (initBefore + segment).write(to: fragment)

        let outputUnits = try annexBUnits(hevcElementaryStream(from: fragment, streamIndex: 0))
        let outputVCL = outputUnits.filter { $0.type <= 31 }
        let outputRPU = outputUnits.filter { $0.type == 62 }
        #expect(!outputVCL.isEmpty)
        #expect(outputVCL.first?.isIRAP == true)
        #expect(outputRPU.count == outputVCL.count, "one converted RPU must accompany every emitted BL picture")
        #expect(!outputUnits.contains(where: { $0.type == 63 || $0.layerID != 0 }))

        let sourceUnits = try annexBUnits(hevcElementaryStream(from: source, streamIndex: pair.baseStreamIndex))
        let sourceVCL = sourceUnits.filter { $0.type <= 31 }
        let sourcePackets = try videoPackets(from: source, streamIndex: pair.baseStreamIndex)
        #expect(sourcePackets.count == sourceVCL.count, "source packet timing must remain one-to-one with BL pictures")
        guard let offset = sourceVCL.firstIndex(of: outputVCL[0]) else {
            let outputPreview = outputVCL.prefix(3).map(\.hexPrefix)
            let sourcePreview = sourceVCL.prefix(3).map(\.hexPrefix)
            throw PayloadError("served BL VCLs are not a contiguous source slice; base=\(pair.baseStreamIndex), enhancement=\(pair.enhancementStreamIndex), output=\(outputPreview), source=\(sourcePreview)")
        }
        let sourceStart = try #require(sourcePackets.indices.contains(offset) ? sourcePackets[offset] : nil)
        #expect(sourceVCL[offset].isIRAP)
        #expect(sourceStart.isKeyframe)
        #expect(sourceStart.pts >= timeline.segments[requestedIndex].start)
        #expect(abs(sourceStart.pts - expectedIRAPPTS) < 0.001, "cold output must bind to the real source IRAP PTS")
        // Decode-order B-frame preroll can arrive after an IRAP but still present before it.
        // The independent fragment must omit those PTS values yet preserve every retained BL AU
        // and the corresponding converted RPU at its original decode-order ordinal.
        let selectedIndices = Array(offset..<sourceVCL.count).filter { sourcePackets[$0].pts >= sourceStart.pts }
        let expectedVCL = selectedIndices.prefix(outputVCL.count).map { sourceVCL[$0] }
        #expect(outputVCL == expectedVCL)

        let expectedSlice = selectedIndices.prefix(outputRPU.count).map { expectedRPU[$0] }
        // `extract-rpu`'s public vector strips the HEVC unspec62 header; the served fMP4 keeps
        // it so AVPlayer sees a legal HEVC NAL. Compare the common payload byte-for-byte.
        #expect(outputRPU.map(\.rpuPayload) == expectedSlice.map(\.bytes))
        #expect((await session.dolbyVisionConversion)?.isClean == true)
        #expect(await session.remuxFailure == nil)
    }

    private func fixture(named variable: String) throws -> URL {
        URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[variable]))
    }

    private func mediaPlaylist(for master: URL) async throws -> URL {
        let text = String(decoding: try await fetch(master), as: UTF8.self)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: text).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL else {
            throw PayloadError("master has no video playlist")
        }
        return media
    }

    private func segments(in media: URL) async throws -> [URL] {
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
            throw PayloadError("loopback did not serve \(url.lastPathComponent)")
        }
        return data
    }

    private func hevcElementaryStream(from source: URL, streamIndex: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", source.path,
            "-map", "0:\(streamIndex)", "-c", "copy", "-bsf:v", "hevc_mp4toannexb",
            "-f", "hevc", "pipe:1",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else {
            throw PayloadError("ffmpeg HEVC extraction failed: \(String(decoding: error, as: UTF8.self))")
        }
        return output
    }

    private func annexBUnits(_ data: Data) throws -> [NAL] {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw PayloadError("empty Annex-B payload")
            }
            guard let units = HEVCNALUnits.strictUnits(
                in: UnsafeBufferPointer(start: base, count: raw.count), framing: .annexB
            ) else { throw PayloadError("invalid Annex-B HEVC framing") }
            return units.map { NAL(bytes: Data($0.bytes), type: $0.type, layerID: $0.layerID) }
        }
    }

    private func videoPackets(from source: URL, streamIndex: Int) throws -> [Packet] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "error", "-select_streams", "\(streamIndex)",
            "-show_packets", "-show_entries", "packet=pts_time,flags", "-of", "json", source.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PayloadError("ffprobe packet timing failed: \(String(decoding: error, as: UTF8.self))")
        }
        let document = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let packets = try #require(document["packets"] as? [[String: Any]])
        return try packets.map { packet in
            guard let text = packet["pts_time"] as? String, let pts = Double(text) else {
                throw PayloadError("BL packet lacks a presentation timestamp")
            }
            return Packet(pts: pts, isKeyframe: (packet["flags"] as? String)?.contains("K") == true)
        }
    }

    private func provenTransportPair(for source: URL) throws -> DolbyVisionSeparateTrackPair {
        let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard case let .association(association) = M2TSDolbyVisionAssociation.scan(Array(bytes)) else {
            throw PayloadError("fixture has no strict M2TS Dolby Vision association")
        }
        let probed = try SourceProbe.open(url: source)
        var ownedInput = probed.consumeContext()
        guard let input = ownedInput else { throw PayloadError("probe did not retain an input context") }
        defer { avformat_close_input(&ownedInput) }
        return try #require(
            SourceProbe.describe(input: input, m2tsDolbyVisionAssociation: association)
                .dolbyVisionSeparateTrackPair
        )
    }

    private struct NAL: Equatable {
        let bytes: Data
        let type: UInt8
        let layerID: UInt8

        var isIRAP: Bool { (16...21).contains(Int(type)) }
        var rpuPayload: Data { Data(bytes.dropFirst(2)) }
        var hexPrefix: String { bytes.prefix(16).map { String(format: "%02x", $0) }.joined() }
    }

    private struct Packet {
        let pts: Double
        let isKeyframe: Bool
    }

    private struct PayloadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
