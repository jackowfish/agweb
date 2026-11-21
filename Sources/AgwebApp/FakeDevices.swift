import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WebKit
import AgwebCore

/// `agweb media FILE` (or `--camera FILE --mic FILE`): a page's getUserMedia gets these files instead of devices, and
/// `agweb geolocation LAT LON`: navigator.geolocation gets that position (PageScripts.devicesShim). No camera,
/// microphone, location or macOS permission is involved. The CLI copies each file to
/// `<root>/media/<uuid>/`, so the app never opens one in the person's folders (which macOS would ask them about).
/// The camera reaches the page as compressed H.264 samples it decodes with WebCodecs, the microphone as an audio file
/// it decodes with Web Audio: no media URL, so a page's Content-Security-Policy can't block either.
final class FakeDevices: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = FakeDevices()
    static let handlerName = "agwebDevices"
    static let folder = Agweb.root.appendingPathComponent("media")
    weak var browser: Browser?

    struct Source: Equatable {
        /// What the page gets: H.264 for the camera, audio only for the microphone.
        let url: URL
        /// The file as the agent named it.
        let name: String
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let tab = browser?.tab(for: message.webView), let body = message.body as? [String: Any] else { return replyHandler(nil, nil) }
            let workspace = tab.workspace, media = workspace.media
            let devices = Self.devices(media, workspace: workspace, frame: message.frameInfo.securityOrigin, top: tab.webView.url)
            if body["info"] != nil {
                return replyHandler(["camera": media["camera"] != nil, "mic": media["mic"] != nil,
                                     "geolocation": workspace.geolocation != nil, "devices": devices], nil)
            }
            if let change = body["capturing"] as? Int {
                // From the page: a step of one, whatever it sends.
                tab.liveCaptures = max(0, tab.liveCaptures + change.signum())
                browser?.updateVisibility()
                return replyHandler(nil, nil)
            }
            if body["geolocation"] != nil {
                if !tab.geolocationAsked {
                    tab.geolocationAsked = true
                    tab.events.append(workspace.geolocation == nil ? "geolocation refused: none set; agweb -w \(workspace.name) geolocation LAT LON sets one"
                                      : "geolocation from \(message.frameInfo.securityOrigin.host)")
                }
                guard let at = workspace.geolocation else { return replyHandler(["geolocation": NSNull()], nil) }
                return replyHandler(["geolocation": ["latitude": at.latitude, "longitude": at.longitude, "accuracy": at.accuracy]], nil)
            }
            let wanted = ["camera", "mic"].filter { body[$0] as? Bool == true }
            guard !wanted.isEmpty else { return replyHandler(nil, nil) }
            if let missing = wanted.first(where: { media[$0] == nil }) {
                tab.events.append("getUserMedia refused: no \(missing) set; agweb -w \(workspace.name) media FILE sets one")
                return replyHandler(["error": ["name": "NotFoundError", "message": "Requested device not found"]], nil)
            }
            let sources = wanted.compactMap { kind in media[kind].map { (kind, $0) } }
            tab.events.append("getUserMedia from \(message.frameInfo.securityOrigin.host): "
                              + sources.map { "\($0.0) \($0.1.name)" }.joined(separator: ", "))
            Task.detached {
                var reply: [String: Any] = ["devices": devices]
                do {
                    for (kind, source) in sources {
                        reply[kind] = kind == "camera" ? try await Self.samples(source) : try Self.audio(source)
                    }
                } catch {
                    let message = "agweb could not read the \(sources.map(\.0).joined(separator: " or ")) file: \(error.localizedDescription)"
                    await MainActor.run { replyHandler(["error": ["name": "NotReadableError", "message": message]], nil) }
                    return
                }
                let answer = reply
                await MainActor.run { replyHandler(answer, nil) }
            }
        }
    }

    /// Names a Mac's built-in devices have, and ids made the way WebKit makes them: a SHA-1 of the device and a salt,
    /// in hex, different for every origin (and for the top page it is in) and every workspace or profile.
    @MainActor private static func devices(_ media: [String: Source], workspace: Workspace, frame: WKSecurityOrigin, top: URL?) -> [String: Any] {
        let origin = "\(frame.protocol)://\(frame.host):\(frame.port)|\(top?.scheme ?? "")://\(top?.host ?? "")"
        func id(_ text: String) -> String {
            Insecure.SHA1.hash(data: Data("\(text)|\(origin)|\(workspace.deviceSalt)".utf8)).map { String(format: "%02X", $0) }.joined()
        }
        var devices: [String: Any] = [:]
        for (kind, label) in [("camera", "MacBook Pro Camera"), ("mic", "MacBook Pro Microphone")] where media[kind] != nil {
            devices[kind] = ["id": id(label), "group": id(label + " group"), "label": label]
        }
        return devices
    }

    private nonisolated static func audio(_ source: Source) throws -> [String: Any] {
        let data = try Data(contentsOf: source.url)
        let type = UTType(filenameExtension: source.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ["data": data.base64EncodedString(), "type": type, "name": source.name]
    }

    /// The H.264 track as WebCodecs wants it: the avcC record and each sample (time and duration in µs, key, offset, size).
    private nonisolated static func samples(_ source: Source) async throws -> [String: Any] {
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("\(source.name) has no video") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("cannot read \(source.name)") }
        var data = Data(), samples: [[Int]] = [], description: Data?, size = CMVideoDimensions(width: 0, height: 0)
        var first: Int?, end = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) == 1, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if description == nil, let format = CMSampleBufferGetFormatDescription(buffer) {
                let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
                description = atoms?["avcC"] as? Data
                size = CMVideoFormatDescriptionGetDimensions(format)
            }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { continue }
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            // A corrupt clip's time would trap in Int(); a day is far beyond any clip.
            guard seconds.isFinite, abs(seconds) < 86_400 else { continue }
            let time = Int(seconds * 1_000_000)
            let duration = CMSampleBufferGetDuration(buffer).seconds
            let micros = duration.isFinite && duration > 0 && duration < 3_600 ? Int(duration * 1_000_000) : 33_333
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            first = min(first ?? time, time)
            end = max(end, time + micros)
            samples.append([time, key ? 1 : 0, data.count, length, micros])
            data.append(chunk)
        }
        guard let description, description.count >= 4, let first, !samples.isEmpty else { throw Failure("\(source.name) has no H.264 video") }
        // Edit lists can start a clip after zero; the page's clock starts at the first frame.
        samples = samples.map { [$0[0] - first] + $0.dropFirst() }
        let avc = [UInt8](description)
        let codec = "avc1." + avc[1...3].map { String(format: "%02x", $0) }.joined()
        return ["codec": codec, "description": description.base64EncodedString(), "width": Int(size.width), "height": Int(size.height),
                "duration": end - first, "samples": samples, "data": data.base64EncodedString(), "name": source.name]
    }

    /// Checks the agent's file and makes what the page gets: the camera's video as H.264 (converted when it is another
    /// codec), the microphone's audio alone (taken out of a video). `kinds`: what the file is wanted for; a file given
    /// without --camera or --mic serves both, whichever it has.
    static func prepare(_ path: String, for kinds: [String]) async throws -> [String: Source] {
        let url = URL(fileURLWithPath: path), name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var result: [String: Source] = [:]
        if kinds.contains("camera"), let video {
            let codec = try await video.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
            // A phone's portrait clip is stored sideways with a rotation to apply; the page gets the samples as stored,
            // so such a clip is converted with the rotation drawn in.
            let rotated = try await video.load(.preferredTransform) != .identity
            if codec == kCMVideoCodecType_H264, !rotated {
                result["camera"] = Source(url: url, name: name)
            } else {
                let upright = rotated ? try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                    request.finish(with: request.sourceImage, context: nil)
                }) : nil
                let output = url.deletingLastPathComponent().appendingPathComponent(".agweb-camera.mp4")
                result["camera"] = Source(url: try await export(asset, AVAssetExportPreset1920x1080, to: output, .mp4, composition: upright), name: name)
            }
        }
        if kinds.contains("mic"), audio != nil {
            result["mic"] = video == nil
                ? Source(url: url, name: name)
                : Source(url: try await export(asset, AVAssetExportPresetAppleM4A, to: url.deletingLastPathComponent().appendingPathComponent(".agweb-mic.m4a"), .m4a), name: name)
        }
        if kinds == ["camera"], video == nil { throw Failure("\(name) has no video") }
        if kinds == ["mic"], audio == nil { throw Failure("\(name) has no audio") }
        if result.isEmpty { throw Failure("\(name) has no audio or video agweb can read") }
        return result
    }

    private static func export(_ asset: AVAsset, _ preset: String, to output: URL, _ type: AVFileType,
                               composition: AVVideoComposition? = nil) async throws -> URL {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw Failure("cannot convert \(output.lastPathComponent)") }
        session.videoComposition = composition
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: type)
        return output
    }

    /// A copy the CLI made and nothing uses any more.
    static func discard(_ source: Source?, keeping: [String: Source]) {
        guard let folder = source?.url.deletingLastPathComponent(), folder.path.hasPrefix(Self.folder.path + "/"),
              !keeping.values.contains(where: { $0.url.deletingLastPathComponent() == folder }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copies left by a quit or a failed command. Not the last minutes': a CLI may have just copied one for an app it is launching.
    static func sweep() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date(timeIntervalSinceNow: -600) { try? fm.removeItem(at: folder) }
        }
    }
}

struct Geolocation: Equatable {
    var latitude: Double, longitude: Double, accuracy: Double
}

extension Workspace {
    func setMedia(_ kind: String, _ source: FakeDevices.Source?) {
        let old = media[kind]
        media[kind] = source
        if old != source { FakeDevices.discard(old, keeping: media) }
    }

    func describeMedia() -> String {
        guard !media.isEmpty else { return "no media set; getUserMedia sees no camera or microphone" }
        return ["camera", "mic"].compactMap { kind in media[kind].map { "\(kind): \($0.name), looped" } }.joined(separator: "\n")
    }
}
