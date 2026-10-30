import Foundation
import Testing
import Libavformat
@testable import PrismCore

/// The generated corpus is opt-in: its PMT descriptors are authored from the
/// Dolby transport specification and its RPU payloads come from libdovi.
@Suite(
    "M2TS Dolby Vision PMT",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] != nil)
)
struct M2TSDolbyVisionPMTTests {
    @Test("strict M2TS scanner proves only the explicit PMT dependency")
    func readsExplicitDependency() throws {
        let paths = (ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        guard let source = paths.first else { throw M2TSFixtureError.missingFixture }
        let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
        let verdict = M2TSDolbyVisionAssociation.scan(Array(bytes))
        guard case let .association(association) = verdict else {
            throw M2TSFixtureError.unproven("\(source.lastPathComponent): \(verdict)")
        }
        #expect(association.profile == 7)
        #expect(association.compatibilityID == 6)
        #expect(association.basePID != association.enhancementPID)
    }

    @Test("PMT HEVC descriptors must match their own in-band SPS")
    func sourceProbeBindsEachDescriptorToItsElementaryStream() throws {
        let source = try fixtureDirectory().appendingPathComponent("p7-m2ts-mel.m2ts")
        let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
        guard case let .association(association) = M2TSDolbyVisionAssociation.scan(Array(bytes)) else {
            throw M2TSFixtureError.unproven("positive PMT association missing")
        }

        let probed = try SourceProbe.open(url: source)
        var ownedInput = probed.consumeContext()
        guard let input = ownedInput else {
            throw M2TSFixtureError.unproven("probe did not retain its context")
        }
        defer { avformat_close_input(&ownedInput) }

        // A real M2TS does not carry hvcC extradata.  The accepted pair proves
        // SourceProbe read the in-band SPS for both PMT-bound PIDs instead of
        // trusting the descriptor as a standalone codec declaration.
        #expect(
            SourceProbe.describe(input: input, m2tsDolbyVisionAssociation: association)
                .dolbyVisionSeparateTrackPair != nil
        )

        let badBase = replacing(
            association,
            base: differentProfileTierLevel(association.baseHEVCConfiguration)
        )
        #expect(
            SourceProbe.describe(input: input, m2tsDolbyVisionAssociation: badBase)
                .dolbyVisionSeparateTrackPair == nil
        )

        let badEnhancement = replacing(
            association,
            enhancement: differentProfileTierLevel(association.enhancementHEVCConfiguration)
        )
        #expect(
            SourceProbe.describe(input: input, m2tsDolbyVisionAssociation: badEnhancement)
                .dolbyVisionSeparateTrackPair == nil
        )
    }

    @Test("rejects a corrupt protected PID or PMT proof")
    func rejectsInvalidPSIAndProtectedTransport() throws {
        let directory = try fixtureDirectory()
        // These failures occur before packet pairing: accepting any of them
        // would let an untrusted transport claim the explicit DV association.
        for name in [
            "p7-m2ts-invalid-188.ts",
            "p7-m2ts-invalid-ambiguous-el.m2ts",
            "p7-m2ts-invalid-dependency.m2ts",
            "p7-m2ts-invalid-el-continuity.m2ts",
            "p7-m2ts-invalid-el-scrambled.m2ts",
            "p7-m2ts-invalid-no-dovi.m2ts",
            "p7-m2ts-invalid-pmt-crc.m2ts",
            "p7-m2ts-invalid-pmt-version.m2ts",
        ] {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name), options: [.mappedIfSafe])
            #expect(
                M2TSDolbyVisionAssociation.scan(Array(bytes)) == .invalid,
                Comment(rawValue: name)
            )
        }
    }

    @Test("required transport pairing rejects a truncated M2TS before publication")
    func rejectsTruncatedTransport() async throws {
        let source = try fixtureDirectory().appendingPathComponent("p7-m2ts-invalid-truncated.bin")
        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }
        do {
            _ = try await session.start()
            throw M2TSFixtureError.unproven("truncated M2TS published a master")
        } catch {
            guard case .invalidDolbyVisionConversion = PrismCoreError.classify(error) else { throw error }
        }
    }

    @Test("required transport pairing binds PMT PIDs before HLS setup")
    func requiredPairingStarts() async throws {
        let paths = (ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }
        guard let source = paths.first else { throw M2TSFixtureError.missingFixture }
        let session = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentTargetDuration: 1,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await session.stop() } }
        let playlist = try await session.start()
        let (master, response) = try await URLSession.shared.data(from: playlist)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let masterText = String(decoding: master, as: UTF8.self)
        #expect(masterText.contains("CODECS=\"hvc1."))
        #expect(masterText.contains("SUPPLEMENTAL-CODECS=\"dvh1.08"))
        #expect(masterText.contains("db1p"))
        #expect(masterText.contains("VIDEO-RANGE=PQ"))
        let stats: DolbyVisionConversionStats
        do {
            stats = try await materializeToEnd(session: session, master: playlist)
        } catch {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: await session.workDirectory.path).sorted()) ?? []
            let timeline = session.segmentTimeline?.segments.map { "\($0.start):\($0.duration)" } ?? []
            throw M2TSFixtureError.unproven(
                "materialization failed: \(error); files: \(files); timeline: \(timeline); remux failure: \(String(describing: await session.remuxFailure))"
            )
        }
        #expect(stats.convertedRPUs >= 192)
        #expect(stats.droppedEnhancementLayerNALs >= 192)
        #expect(stats.isClean)
    }

    @Test("M2TS reuses harvested BL keys for an exact forced re-anchor")
    func harvestedKeyframeMapSupportsReanchor() async throws {
        let source = try #require(
            (ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] ?? "")
                .split(separator: ":").first.map { URL(fileURLWithPath: String($0)) }
        )
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("prismcore-m2ts-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }

        let first = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            keyframeIndexCacheDirectory: cache,
            segmentTargetDuration: 1,
            requireDolbyVisionTransportPairing: true
        )
        let firstMaster = try await first.start()
        _ = try await materializeToEnd(session: first, master: firstMaster)
        await first.stop()
        let cachedMaps = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(!cachedMaps.isEmpty, "first sequential M2TS run did not persist harvested BL keys")

        let replay = try PrismCoreSession(
            url: source,
            display: .init(isHDRReady: true, isDolbyVisionCapable: true),
            segmentCacheBytes: 1,
            keyframeIndexCacheDirectory: cache,
            segmentTargetDuration: 1,
            requireDolbyVisionTransportPairing: true
        )
        defer { Task { await replay.stop() } }
        let master = try await replay.start()
        #expect((replay.segmentTimeline?.segments.count ?? 0) >= 8)
        let masterText = try await fetchText(master)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL
        else { throw M2TSFixtureError.unproven("no replay video media playlist") }
        let root = master.deletingLastPathComponent()
        let initBefore = try await fetchData(root.appendingPathComponent("init.mp4"))
        _ = try await fetchData(media.deletingLastPathComponent().appendingPathComponent("seg00000.m4s"))
        // A tiny cache evicts the head. A tail request must re-anchor from the
        // harvested packet-key map, not revive the rejected PCR index.
        _ = try await fetchData(media.deletingLastPathComponent().appendingPathComponent("seg00007.m4s"))
        #expect(try await fetchData(root.appendingPathComponent("init.mp4")) == initBefore)
        #expect((await replay.dolbyVisionConversion)?.isClean == true)
    }
}

private extension M2TSDolbyVisionPMTTests {
    func differentProfileTierLevel(_ configuration: HEVCConfigurationRecord) -> HEVCConfigurationRecord {
        .init(
            profileSpace: configuration.profileSpace,
            tierFlag: configuration.tierFlag,
            profileIDC: configuration.profileIDC,
            profileCompatibilityFlags: configuration.profileCompatibilityFlags,
            constraintIndicatorFlags: configuration.constraintIndicatorFlags,
            levelIDC: configuration.levelIDC ^ 0x01
        )
    }

    func replacing(
        _ association: M2TSDolbyVisionAssociation,
        base: HEVCConfigurationRecord? = nil,
        enhancement: HEVCConfigurationRecord? = nil
    ) -> M2TSDolbyVisionAssociation {
        .init(
            programNumber: association.programNumber,
            pmtPID: association.pmtPID,
            pmtVersion: association.pmtVersion,
            pmtCRC: association.pmtCRC,
            basePID: association.basePID,
            enhancementPID: association.enhancementPID,
            profile: association.profile,
            level: association.level,
            compatibilityID: association.compatibilityID,
            baseHEVCConfiguration: base ?? association.baseHEVCConfiguration,
            enhancementHEVCConfiguration: enhancement ?? association.enhancementHEVCConfiguration
        )
    }

    func fixtureDirectory() throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PRISMCORE_DV7_M2TS_FIXTURES"] ?? "")
            .split(separator: ":")
        guard let first = paths.first else { throw M2TSFixtureError.missingFixture }
        return URL(fileURLWithPath: String(first)).deletingLastPathComponent()
    }

    func materializeToEnd(session: PrismCoreSession, master: URL) async throws -> DolbyVisionConversionStats {
        let masterText = try await fetchText(master)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL
        else { throw M2TSFixtureError.unproven("no video media playlist") }
        let deadline = ContinuousClock.now + .seconds(15)
        var fetched = Set<URL>()
        while ContinuousClock.now < deadline {
            let playlist = try await fetchText(media)
            for line in playlist.split(whereSeparator: \.isNewline)
            where !line.hasPrefix("#") && !line.isEmpty {
                guard let url = URL(string: String(line), relativeTo: media)?.absoluteURL,
                      fetched.insert(url).inserted else { continue }
                _ = try await fetchData(url)
            }
            if playlist.contains("#EXT-X-ENDLIST"), let stats = await session.dolbyVisionConversion {
                return stats
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw M2TSFixtureError.unproven("M2TS conversion did not finish")
    }

    func forceReanchor(session: PrismCoreSession, master: URL) async throws {
        let masterText = try await fetchText(master)
        guard let relative = PrismCoreSession.playlistURIs(inMaster: masterText).last,
              let media = URL(string: relative, relativeTo: master)?.absoluteURL
        else { throw M2TSFixtureError.unproven("no video media playlist") }
        let playlist = try await fetchText(media)
        let segments = playlist.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
            guard !line.hasPrefix("#"), !line.isEmpty else { return nil }
            return URL(string: String(line), relativeTo: media)?.absoluteURL
        }
        guard let first = segments.first, let last = segments.last, segments.count >= 8 else {
            throw M2TSFixtureError.unproven("not enough segments for a re-anchor")
        }
        let root = master.deletingLastPathComponent()
        let initBefore = try await fetchData(root.appendingPathComponent("init.mp4"))
        _ = try await fetchData(first)
        _ = try await fetchData(last)
        #expect(try await fetchData(root.appendingPathComponent("init.mp4")) == initBefore)
        #expect((await session.dolbyVisionConversion)?.isClean == true)
    }

    func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.uncached.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw M2TSFixtureError.unproven("loopback did not serve \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.uncached.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw M2TSFixtureError.unproven("loopback did not serve bytes for \(url.lastPathComponent)")
        }
        return data
    }
}

private enum M2TSFixtureError: Error {
    case missingFixture
    case unproven(String)
}
