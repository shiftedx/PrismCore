import Foundation
import Libavformat
import Libavutil

/// The one PMT relationship PrismCore needs before it can even consider
/// converting a dual-PID Profile 7 transport stream.  MPEG-TS stream order is
/// not a relationship: only the EL's DOVI `dependency_pid` is.
///
/// This intentionally reads only Blu-ray M2TS's 192-byte carriage.  A generic
/// TS parser would have to make promises about 188/204-byte resync and FEC
/// carriage that the remux path has not qualified.  Callers that do not obtain
/// this proof keep the normal non-conversion route.
struct M2TSDolbyVisionAssociation: Sendable, Equatable {
    let programNumber: Int
    let pmtPID: Int
    let pmtVersion: Int
    let pmtCRC: UInt32
    let basePID: Int
    let enhancementPID: Int
    let profile: UInt8
    let level: UInt8
    let compatibilityID: UInt8
    /// Profile-tier-level extracted from the mandatory HEVC video descriptor.
    /// Parameter sets remain in-band and are collected by FFmpeg's MP4 muxer.
    let baseHEVCConfiguration: HEVCConfigurationRecord
    let enhancementHEVCConfiguration: HEVCConfigurationRecord

    enum Verdict: Sendable, Equatable {
        case absent
        case association(M2TSDolbyVisionAssociation)
        case invalid
    }

    /// The raw parser's verdict, or an I/O failure that must remain distinct
    /// from a transport that simply lacks a usable Dolby Vision association.
    /// The latter is a typed conversion refusal; the former is a source
    /// failure and is eligible for the caller's normal transport diagnostics.
    enum InputVerdict: Sendable, Equatable {
        case verdict(Verdict)
        case ioFailure(code: Int32, operation: String)
    }

    static let packetSize = 192
    static let maximumScanBytes = 4 * 1024 * 1024
    static let scanBudget: Duration = .seconds(2)
    private static let maximumSectionLength = 1021

    /// Parse an already bounded, origin-owned prefix.  The scanner never
    /// guesses a sync offset: the 4-byte M2TS arrival header and every TS sync
    /// byte have to be where the carriage says they are.
    static func scan(_ source: [UInt8]) -> Verdict {
        guard source.count >= packetSize else { return .absent }
        let count = min(source.count, maximumScanBytes)
        let wholeBytes = count - count % packetSize
        guard wholeBytes >= packetSize else { return .absent }

        var sections: [Int: SectionAssembler] = [0: .init()]
        var continuities: [Int: UInt8] = [:]
        var protectedPIDs = Set<Int>()
        var pat: PAT?
        var pmt: PMT?
        var invalid = false

        for start in stride(from: 0, to: wholeBytes, by: packetSize) {
            let packet = Array(source[(start + 4)..<(start + packetSize)])
            guard packet.count == 188, packet[0] == 0x47 else { return .invalid }
            let transportError = packet[1] & 0x80 != 0
            let payloadStart = packet[1] & 0x40 != 0
            let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
            // The media PIDs are still FFmpeg's job. Once PMT proof identifies
            // the pair, however, those two exact PIDs also become protected:
            // a scrambled or discontinuous EL cannot be silently skipped and
            // then misrepresented as a clean P8.1 conversion.
            let isPSI = pid == 0 || pid == pat?.pmtPID
            let isProtectedMedia = protectedPIDs.contains(pid)
            guard isPSI || isProtectedMedia else { continue }
            let scrambling = packet[3] >> 6
            let adaptationControl = (packet[3] >> 4) & 0x03
            let continuity = packet[3] & 0x0F
            guard !transportError, scrambling == 0, adaptationControl != 0 else { return .invalid }

            var cursor = 4
            var discontinuity = false
            if adaptationControl & 0x02 != 0 {
                guard cursor < packet.count else { return .invalid }
                let length = Int(packet[cursor])
                cursor += 1
                guard cursor + length <= packet.count else { return .invalid }
                if length > 0 { discontinuity = packet[cursor] & 0x80 != 0 }
                cursor += length
            }
            guard adaptationControl & 0x01 != 0 else { continue }
            guard cursor < packet.count else { continue }
            // A table split at a discontinuity cannot establish an association.
            guard !discontinuity else { return .invalid }
            if let previous = continuities[pid], continuity != ((previous + 1) & 0x0F) {
                return .invalid
            }
            continuities[pid] = continuity

            if isProtectedMedia { continue }

            if sections[pid] == nil { sections[pid] = .init() }
            do {
                guard var assembler = sections[pid] else { return .invalid }
                let complete = try assembler.append(
                    Array(packet[cursor...]), payloadStart: payloadStart
                )
                sections[pid] = assembler
                for section in complete {
                    guard sectionHasValidCRC(section) else { return .invalid }
                    if pid == 0 {
                        let parsed = try PAT(section: section)
                        if let pat, pat != parsed { return .invalid }
                        pat = parsed
                        if sections[parsed.pmtPID] == nil { sections[parsed.pmtPID] = .init() }
                    } else if let pat, pid == pat.pmtPID {
                        let parsed = try PMT(section: section, expectedProgram: pat.programNumber)
                        if let pmt, pmt != parsed { return .invalid }
                        pmt = parsed
                        if let association = association(pat: pat, pmt: parsed) {
                            protectedPIDs = [association.basePID, association.enhancementPID]
                        }
                    }
                }
            } catch {
                invalid = true
                break
            }
        }
        guard !invalid else { return .invalid }
        guard let pat, let pmt else { return .absent }
        guard let association = association(pat: pat, pmt: pmt) else { return .invalid }
        return .association(association)
    }

    private static func association(pat: PAT, pmt: PMT) -> M2TSDolbyVisionAssociation? {
        guard pmt.programNumber == pat.programNumber,
              let el = pmt.entries.first(where: { $0.doviEL != nil }),
              pmt.entries.filter({ $0.doviEL != nil }).count == 1,
              let dovi = el.doviEL,
              let base = pmt.entries.first(where: { $0.pid == dovi.dependencyPID }),
              pmt.entries.filter({ $0.pid == dovi.dependencyPID }).count == 1,
              base.streamType == 0x24,
              let baseHEVCConfiguration = base.hevcConfiguration,
              let enhancementHEVCConfiguration = el.hevcConfiguration,
              el.streamType == 0x06,
              el.hasDOVIRegistration
        else { return nil }
        return .init(
            programNumber: pat.programNumber, pmtPID: pat.pmtPID,
            pmtVersion: pmt.version, pmtCRC: pmt.crc,
            basePID: base.pid, enhancementPID: el.pid,
            profile: dovi.profile, level: dovi.level, compatibilityID: dovi.compatibilityID,
            baseHEVCConfiguration: baseHEVCConfiguration,
            enhancementHEVCConfiguration: enhancementHEVCConfiguration
        )
    }

    /// Read the bounded PSI prefix through the already-open AVIO context.  The
    /// host's input and FFmpeg's origin connection stay singular; this merely
    /// seeks and restores the same context before remux starts.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>, interruptGuard: ReadInterruptGuard
    ) -> InputVerdict {
        guard let pb = input.pointee.pb, pb.pointee.seekable != 0 else {
            return .verdict(.absent)
        }
        let originalError = pb.pointee.error
        let originalEOF = pb.pointee.eof_reached
        guard originalError >= 0 else {
            return .ioFailure(code: originalError, operation: "AVIOContext.error(M2TS Dolby Vision)")
        }

        interruptGuard.arm(budget: scanBudget)
        // Keep the deadline armed through the restoring seek. A seek can make
        // a blocking origin request too; disarming first turns the supposedly
        // bounded scanner into an unbounded source read.
        defer { interruptGuard.disarm() }
        // A complete local/known-length M2TS has no partial carriage packet.
        // The bounded raw parser cannot know whether a prefix was EOF, but the
        // live AVIO can. An unknown length remains eligible for the same
        // bounded PSI proof; it is not silently treated as a complete file.
        let knownSize = avio_size(pb)
        if interruptGuard.shouldInterrupt {
            return .ioFailure(code: swift_AVERROR_EXIT(), operation: "avio_size(M2TS Dolby Vision)")
        }
        if pb.pointee.error < 0 {
            return .ioFailure(code: pb.pointee.error, operation: "avio_size(M2TS Dolby Vision)")
        }
        guard knownSize <= 0 || knownSize % Int64(packetSize) == 0 else {
            return .verdict(.invalid)
        }
        let originalPosition = avio_tell(pb)
        guard originalPosition >= 0 else {
            return .ioFailure(code: Int32(clamping: originalPosition), operation: "avio_tell(M2TS Dolby Vision)")
        }
        let seekToHead = avio_seek(pb, 0, SEEK_SET)
        guard seekToHead >= 0 else {
            return .ioFailure(code: Int32(clamping: seekToHead), operation: "avio_seek(M2TS Dolby Vision head)")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(maximumScanBytes)
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while bytes.count < maximumScanBytes, !interruptGuard.shouldInterrupt {
            let requested = min(buffer.count, maximumScanBytes - bytes.count)
            let count = buffer.withUnsafeMutableBufferPointer {
                avio_read(pb, $0.baseAddress, Int32(requested))
            }
            if count == swift_AVERROR_EOF() || count == 0 { break }
            guard count > 0 else {
                return .ioFailure(code: count, operation: "avio_read(M2TS Dolby Vision)")
            }
            bytes.append(contentsOf: buffer.prefix(Int(count)))
        }
        if interruptGuard.shouldInterrupt {
            return .ioFailure(code: swift_AVERROR_EXIT(), operation: "M2TS Dolby Vision scan budget exhausted")
        }
        // Custom AVIO records the host's typed failure even when libavformat
        // turns its callback's errno into an EOF-shaped read result. Do not
        // let that partial prefix fall through to the raw parser as a missing
        // or malformed association; HLSRemuxer restores this cause first.
        if interruptGuard.customInputFailure != nil {
            return .ioFailure(
                code: pb.pointee.error < 0 ? pb.pointee.error : swift_AVERROR(EIO),
                operation: "avio_read(M2TS Dolby Vision)"
            )
        }
        if pb.pointee.error < 0 {
            return .ioFailure(code: pb.pointee.error, operation: "avio_read(M2TS Dolby Vision)")
        }

        let restored = avio_seek(pb, originalPosition, SEEK_SET)
        guard restored >= 0 else {
            return .ioFailure(code: Int32(clamping: restored), operation: "avio_seek(M2TS Dolby Vision restore)")
        }
        if interruptGuard.shouldInterrupt {
            return .ioFailure(code: swift_AVERROR_EXIT(), operation: "M2TS Dolby Vision scan restore budget exhausted")
        }
        guard pb.pointee.error >= 0 else {
            return .ioFailure(code: pb.pointee.error, operation: "avio_seek(M2TS Dolby Vision restore)")
        }
        // A successful bounded scan is observational: return the cursor and
        // AVIO's pre-existing EOF/error state exactly as the producer saw it.
        pb.pointee.error = originalError
        pb.pointee.eof_reached = originalEOF
        return .verdict(scan(bytes))
    }
}

private extension M2TSDolbyVisionAssociation {
    struct PAT: Equatable {
        let programNumber: Int
        let pmtPID: Int
        let version: Int
        let crc: UInt32

        init(section: [UInt8]) throws {
            guard section.count >= 12, section[0] == 0x00,
                  section[1] & 0x80 != 0, section[5] & 0x01 != 0,
                  section[6] == 0, section[7] == 0
            else { throw ParseError.invalid }
            let end = section.count - 4
            var programs: [(Int, Int)] = []
            var cursor = 8
            while cursor < end {
                guard cursor + 4 <= end else { throw ParseError.invalid }
                let program = Int(section[cursor]) << 8 | Int(section[cursor + 1])
                let pid = Int(section[cursor + 2] & 0x1F) << 8 | Int(section[cursor + 3])
                if program != 0 { programs.append((program, pid)) }
                cursor += 4
            }
            guard programs.count == 1, let program = programs.first else { throw ParseError.invalid }
            programNumber = program.0
            pmtPID = program.1
            version = Int((section[5] >> 1) & 0x1F)
            crc = UInt32(section[end]) << 24 | UInt32(section[end + 1]) << 16
                | UInt32(section[end + 2]) << 8 | UInt32(section[end + 3])
        }
    }

    struct PMT: Equatable {
        let programNumber: Int
        let version: Int
        let crc: UInt32
        let entries: [ElementaryStream]

        init(section: [UInt8], expectedProgram: Int) throws {
            guard section.count >= 16, section[0] == 0x02,
                  section[1] & 0x80 != 0, section[5] & 0x01 != 0,
                  section[6] == 0, section[7] == 0
            else { throw ParseError.invalid }
            let program = Int(section[3]) << 8 | Int(section[4])
            guard program == expectedProgram else { throw ParseError.invalid }
            let programInfoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
            var cursor = 12 + programInfoLength
            let end = section.count - 4
            guard cursor <= end else { throw ParseError.invalid }
            var entries: [ElementaryStream] = []
            while cursor < end {
                guard cursor + 5 <= end else { throw ParseError.invalid }
                let streamType = section[cursor]
                let pid = Int(section[cursor + 1] & 0x1F) << 8 | Int(section[cursor + 2])
                let infoLength = Int(section[cursor + 3] & 0x0F) << 8 | Int(section[cursor + 4])
                cursor += 5
                guard cursor + infoLength <= end else { throw ParseError.invalid }
                let descriptors = Array(section[cursor..<(cursor + infoLength)])
                entries.append(try .init(pid: pid, streamType: streamType, descriptors: descriptors))
                cursor += infoLength
            }
            guard cursor == end else { throw ParseError.invalid }
            self.programNumber = program
            version = Int((section[5] >> 1) & 0x1F)
            crc = UInt32(section[end]) << 24 | UInt32(section[end + 1]) << 16
                | UInt32(section[end + 2]) << 8 | UInt32(section[end + 3])
            self.entries = entries
        }
    }

    struct ElementaryStream: Equatable {
        let pid: Int
        let streamType: UInt8
        let hasDOVIRegistration: Bool
        let hevcConfiguration: HEVCConfigurationRecord?
        let doviEL: DOVIEL?

        init(pid: Int, streamType: UInt8, descriptors: [UInt8]) throws {
            self.pid = pid
            self.streamType = streamType
            var cursor = 0
            var registration = false
            var hevc: HEVCConfigurationRecord?
            var dovi: DOVIEL?
            while cursor < descriptors.count {
                guard cursor + 2 <= descriptors.count else { throw ParseError.invalid }
                let tag = descriptors[cursor]
                let length = Int(descriptors[cursor + 1])
                cursor += 2
                guard cursor + length <= descriptors.count else { throw ParseError.invalid }
                let body = Array(descriptors[cursor..<(cursor + length)])
                cursor += length
                switch tag {
                case 0x05:
                    registration = body == [0x44, 0x4F, 0x56, 0x49]
                case 0x38:
                    guard hevc == nil else { throw ParseError.invalid }
                    guard let parsed = HEVCConfigurationRecord(m2tsDescriptor: body) else {
                        throw ParseError.invalid
                    }
                    hevc = parsed
                case 0xB0:
                    if dovi != nil { throw ParseError.invalid }
                    dovi = try DOVIEL(body: body)
                default:
                    break
                }
            }
            hasDOVIRegistration = registration
            hevcConfiguration = hevc
            doviEL = dovi
        }
    }

    struct DOVIEL: Equatable {
        let profile: UInt8
        let level: UInt8
        let dependencyPID: Int
        let compatibilityID: UInt8

        init(body: [UInt8]) throws {
            // v1.0 carries major/minor plus two flag bytes, dependency PID and
            // a compatibility/reserved byte.  Newer descriptor versions are
            // deliberately not interpreted as v1.0.
            guard body.count == 7, body[0] == 1, body[1] == 0 else { throw ParseError.invalid }
            let flags = UInt16(body[2]) << 8 | UInt16(body[3])
            let profile = UInt8((flags >> 9) & 0x7F)
            let level = UInt8((flags >> 3) & 0x3F)
            let rpu = flags & 0x04 != 0
            let el = flags & 0x02 != 0
            let bl = flags & 0x01 != 0
            // The final two bytes carry the 13-bit dependency PID followed
            // by three v1.0 reserved bits.  Do not read them like the TS
            // header's PID fields: `80 8f` is the standard encoding of
            // dependency PID 0x1011, not PID 0x008f.
            let dependencyField = UInt16(body[4]) << 8 | UInt16(body[5])
            guard dependencyField & 0x07 == 0x07 else { throw ParseError.invalid }
            let dependency = Int(dependencyField >> 3)
            let compatibility = body[6] >> 4
            guard profile == 7, level > 0, rpu, el, !bl, dependency > 0,
                  compatibility == 6
            else { throw ParseError.invalid }
            self.profile = profile
            self.level = level
            dependencyPID = dependency
            compatibilityID = compatibility
        }
    }

    struct SectionAssembler {
        private var pending: [UInt8] = []
        private var expectedLength: Int?

        mutating func append(_ payload: [UInt8], payloadStart: Bool) throws -> [[UInt8]] {
            var output: [[UInt8]] = []
            var cursor = 0
            if payloadStart {
                guard !payload.isEmpty else { throw ParseError.invalid }
                let pointer = Int(payload[0])
                cursor = 1
                guard cursor + pointer <= payload.count else { throw ParseError.invalid }
                if pointer > 0 {
                    guard !pending.isEmpty else { throw ParseError.invalid }
                    try consume(Array(payload[cursor..<(cursor + pointer)]), into: &output)
                    guard pending.isEmpty else { throw ParseError.invalid }
                } else if !pending.isEmpty {
                    throw ParseError.invalid
                }
                cursor += pointer
            }
            if cursor < payload.count { try consume(Array(payload[cursor...]), into: &output) }
            return output
        }

        private mutating func consume(_ bytes: [UInt8], into output: inout [[UInt8]]) throws {
            var cursor = 0
            while cursor < bytes.count {
                if pending.isEmpty && bytes[cursor] == 0xFF { return }
                pending.append(bytes[cursor])
                cursor += 1
                if expectedLength == nil, pending.count >= 3 {
                    let length = (Int(pending[1] & 0x0F) << 8) | Int(pending[2])
                    guard length <= M2TSDolbyVisionAssociation.maximumSectionLength else { throw ParseError.invalid }
                    expectedLength = length + 3
                }
                if let expectedLength, pending.count == expectedLength {
                    output.append(pending)
                    pending.removeAll(keepingCapacity: true)
                    self.expectedLength = nil
                } else if let expectedLength, pending.count > expectedLength {
                    throw ParseError.invalid
                }
            }
        }
    }

    enum ParseError: Error { case invalid }

    static func sectionHasValidCRC(_ section: [UInt8]) -> Bool {
        guard section.count >= 4 else { return false }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in section {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = crc & 0x8000_0000 == 0 ? crc << 1 : (crc << 1) ^ 0x04C1_1DB7
            }
        }
        return crc == 0
    }
}

private extension HEVCConfigurationRecord {
    /// ISO/IEC 13818-1 HEVC video descriptor: its first twelve bytes are the
    /// same general profile-tier-level fields an hvcC carries.  The descriptor
    /// is accepted only alongside the actual Main 10 base stream and a strict
    /// PMT dependency; it is never inferred from a PID number or codec name.
    init?(m2tsDescriptor body: [UInt8]) {
        guard body.count == 13 else { return nil }
        var constraints: UInt64 = 0
        for index in 5...10 { constraints = (constraints << 8) | UInt64(body[index]) }
        self.init(
            profileSpace: (body[0] & 0xC0) >> 6,
            tierFlag: (body[0] & 0x20) >> 5,
            profileIDC: body[0] & 0x1F,
            profileCompatibilityFlags: UInt32(body[1]) << 24 | UInt32(body[2]) << 16
                | UInt32(body[3]) << 8 | UInt32(body[4]),
            constraintIndicatorFlags: constraints,
            levelIDC: body[11]
        )
    }
}
