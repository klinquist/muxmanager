import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

/// Inspect the finished export independently and bind its metadata to its bytes.
@main struct PreviewMetadata {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, args[0] == "inspect" else { fatalError("Usage: video inspect output.mp4") }
        let url = URL(fileURLWithPath: args[1])
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first, let audio = audios.first else { fatalError("Preview requires video and audio tracks") }
        let videoFormats = try await video.load(.formatDescriptions)
        let audioFormats = try await audio.load(.formatDescriptions)
        let videoFormat = videoFormats[0]
        let audioFormat = audioFormats[0]
        let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
        let audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)!.pointee
        let duration = try await asset.load(.duration)
        let fps = try await video.load(.nominalFrameRate)
        let metadata: [String: Any] = [
            "width": Int(dimensions.width), "height": Int(dimensions.height),
            "duration": CMTimeGetSeconds(duration), "fps": fps,
            "videoCodec": CMFormatDescriptionGetMediaSubType(videoFormat) == kCMVideoCodecType_H264 ? "h264" : "other",
            "audioCodec": audioDescription.mFormatID == kAudioFormatMPEG4AAC ? "aac" : "other",
            "sampleRate": audioDescription.mSampleRate, "channels": Int(audioDescription.mChannelsPerFrame),
            "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined(),
            "source": "Native Simulator screen recording; FFmpeg H.264/AAC export"
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
    }
}
