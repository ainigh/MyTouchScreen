import Foundation

// MARK: - Compact JSON encoding of frames
//
// One hand is {"c":"right","s":0.93,"p":[[x,y,conf], ... 21 entries]} with 4-5 decimals, so a
// minute at 30 fps with one hand is roughly 2 MB: small enough to email back for tuning.

extension HandFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case chirality = "c", confidence = "s", points = "p", timestamp = "t", aspect = "a"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([[Double]].self, forKey: .points)
        guard raw.count == Joint.count, raw.allSatisfy({ $0.count >= 2 }) else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c,
                                                   debugDescription: "Expected 21 [x, y, confidence] points")
        }
        let confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        // Every distance divides y by the aspect; zero or negative would turn them all into
        // NaN/inf, and a NaN pinch distance never compares above the release threshold.
        let aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 16.0 / 9.0
        guard aspect > 0, aspect.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .aspect, in: c,
                                                   debugDescription: "Image aspect must be positive")
        }
        self.init(points: raw.map { Point2($0[0], $0[1]) },
                  jointConfidences: raw.map { $0.count > 2 ? $0[2] : confidence },
                  chirality: try c.decodeIfPresent(Chirality.self, forKey: .chirality) ?? .unknown,
                  confidence: confidence,
                  timestamp: try c.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0,
                  imageAspect: aspect)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chirality, forKey: .chirality)
        try c.encode(Self.round(confidence, 3), forKey: .confidence)
        let raw = zip(points, jointConfidences).map { p, conf in
            [Self.round(p.x, 5), Self.round(p.y, 5), Self.round(conf, 2)]
        }
        try c.encode(raw, forKey: .points)
        try c.encode(imageAspect, forKey: .aspect)
        // The per-hand timestamp equals the frame's, so it is omitted from the file.
    }

    static func round(_ v: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (v * scale).rounded() / scale
    }
}

extension TrackingFrame: Codable {
    private enum CodingKeys: String, CodingKey { case timestamp = "t", hands = "h", targets = "g" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(Double.self, forKey: .timestamp)
        var hands = try c.decode([HandFrame].self, forKey: .hands)
        for i in hands.indices { hands[i].timestamp = t }
        self.init(timestamp: t, hands: hands, targets: try c.decodeIfPresent([AssistTarget].self, forKey: .targets))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(HandFrame.round(timestamp, 4), forKey: .timestamp)
        try c.encode(hands, forKey: .hands)
        try c.encodeIfPresent(targets, forKey: .targets)
    }
}

// MARK: - Recording file

/// A recorded session: header plus frames. Timestamps keep their original clock; consumers
/// that need them to start at zero can use `rebased()`.
public struct Recording: Codable, Equatable {
    public static let formatName = "gesturepointer-replay"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    /// Free-form notes: camera name, resolution, app version, config used.
    public var info: [String: String]
    public var frames: [TrackingFrame]
    /// Labeled stretches from a guided `--record --script` session (absent in plain recordings).
    public var segments: [LabeledSegment]?

    public init(frames: [TrackingFrame], info: [String: String] = [:]) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.info = info
        self.frames = frames
    }

    public var duration: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.timestamp - first.timestamp
    }

    /// Same frames with time shifted so the first frame is at `start`.
    public func rebased(to start: Double = 0) -> Recording {
        guard let t0 = frames.first?.timestamp else { return self }
        var copy = self
        copy.frames = frames.map { frame in
            var f = frame
            f.timestamp = frame.timestamp - t0 + start
            for i in f.hands.indices { f.hands[i].timestamp = f.timestamp }
            return f
        }
        copy.segments = segments?.map {
            LabeledSegment(label: $0.label, startTime: $0.startTime - t0 + start, endTime: $0.endTime - t0 + start)
        }
        return copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode a recording. A file cut short (the app was killed mid-recording) is repaired by
    /// closing the frame array after the last complete frame, so no session is ever lost.
    public static func decode(_ data: Data) throws -> Recording {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Recording.self, from: data)
        } catch let firstError {
            guard var text = String(data: data, encoding: .utf8) else { throw firstError }
            // The streaming writer puts one frame per line; drop a partial last line.
            if let lastNewline = text.lastIndex(of: "\n") {
                text = String(text[..<lastNewline])
            }
            while text.hasSuffix(",") || text.hasSuffix("\n") || text.hasSuffix(" ") { text.removeLast() }
            if let repaired = (text + "\n]}").data(using: .utf8),
               let recording = try? decoder.decode(Recording.self, from: repaired) {
                return recording
            }
            throw firstError
        }
    }

    public static func load(from url: URL) throws -> Recording {
        try decode(Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}

/// Streams frames to disk as they arrive, one per line, so recording costs one small write per
/// frame and a crash loses at most the last frame. Not thread-safe: call from one queue.
public final class RecordingWriter {
    private let handle: FileHandle
    private var frameCount = 0
    private var closed = false
    private let encoder = JSONEncoder()

    public init(url: URL, info: [String: String] = [:]) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        encoder.outputFormatting = [.sortedKeys]
        let infoJSON = String(data: try encoder.encode(info), encoding: .utf8) ?? "{}"
        let header = "{\"format\":\"\(Recording.formatName)\",\"version\":\(Recording.currentVersion),\"info\":\(infoJSON),\"frames\":[\n"
        handle.write(Data(header.utf8))
    }

    public var framesWritten: Int { frameCount }

    public func append(_ frame: TrackingFrame) {
        guard !closed, let json = try? encoder.encode(frame) else { return }
        var line = Data((frameCount == 0 ? "" : ",\n").utf8)
        line.append(json)
        handle.write(line)
        frameCount += 1
    }

    /// Finish the file. Labeled segments (guided sessions) are written after the frames; a
    /// file cut off before this point still loads, without them.
    public func close(segments: [LabeledSegment] = []) {
        guard !closed else { return }
        closed = true
        var tail = "\n]"
        if !segments.isEmpty, let json = try? encoder.encode(segments), let text = String(data: json, encoding: .utf8) {
            tail += ",\"segments\":" + text
        }
        handle.write(Data((tail + "}\n").utf8))
        handle.closeFile()
    }

    deinit { close() }
}
