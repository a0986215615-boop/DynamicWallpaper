import AppKit
import AVFoundation
import Darwin

/// Identical benchmark source can be compiled against 1.1 or 1.2. A fresh process
/// and an isolated preference suite prevent the installed app from being changed.
@main
struct MemoryBenchmark {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    @MainActor static func run() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard !NSScreen.screens.isEmpty else { throw NSError(domain: "No screen", code: 1) }
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/dynamicwallpaper-memory/fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("1080p.mov")
        let second = folder.appendingPathComponent("1080p-copy.mov")
        if !FileManager.default.fileExists(atPath: first.path) { try await makeVideo(first) }
        if !FileManager.default.fileExists(atPath: second.path) { try FileManager.default.copyItem(at: first, to: second) }
        // Fixture creation runs in a separate invocation to keep encoder memory
        // out of playback measurements.
        if CommandLine.arguments.contains("--prepare") { print("Fixture ready"); return }
        let suite = "DynamicWallpaper.MemoryBenchmark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = WallpaperManager(defaults: defaults, observesSystemEvents: false)
        defer { manager.stop(); manager.shutdown() }
        var failure: String?
        manager.onError = { failure = $0 }
        var samples: [Double] = []
        print("baseline_mib=\(footprintMiB())")
        await manager.applyVideoWallpaper(from: first).value
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 200_000_000)
            samples.append(footprintMiB())
        }
        let stable = samples.suffix(25).sorted()
        print("playback_median_mib=\(stable[stable.count / 2])")
        for index in 0..<30 {
            await manager.applyVideoWallpaper(from: index.isMultiple(of: 2) ? second : first).value
            try await Task.sleep(nanoseconds: 100_000_000)
            samples.append(footprintMiB())
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("switch_peak_mib=\(samples.max() ?? -1)")
        print("after_switches_mib=\(footprintMiB())")
        manager.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("after_stop_mib=\(footprintMiB())")
        if let failure { throw NSError(domain: failure, code: 2) }
    }

    static func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard result == kCVReturnSuccess, let buffer else { throw NSError(domain: "Pixel buffer", code: 3) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(20 + frame * 2), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            var waits = 0
            while !input.isReadyForMoreMediaData {
                waits += 1
                guard writer.status != .failed, waits < 500 else { throw writer.error ?? NSError(domain: "Encoder timeout", code: 4) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
