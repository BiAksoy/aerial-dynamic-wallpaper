#!/usr/bin/env swift
// Extracts a still poster frame from each clip of an Apple aerial pack
// and writes PNGs to ~/Pictures/AerialWallpapers/. Packs are defined in
// ../scenes.json; asset UUIDs are looked up at run time from the system
// aerial manifest, so the script keeps working if Apple republishes a
// pack with new IDs.
//
// Usage: aerial-extract-frames [--pack <Name>] [--default-pack]
//   --pack          Pack name from scenes.json (e.g. "Golden Gate").
//                   Default: the first pack in scenes.json whose clips
//                   are all in this Mac's aerial manifest.
//   --default-pack  Print that default pack name and exit.

import AVFoundation
import AppKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8)); exit(code)
}

// --- Parse args.
var requestedPack: String? = nil
var printDefaultPack = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--pack":
        guard !args.isEmpty else { fail("--pack requires a value", code: 2) }
        requestedPack = args.removeFirst()
    case "--default-pack":
        printDefaultPack = true
    case let other:
        fail("unknown argument: \(other)", code: 2)
    }
}

let aerialsDir = ("~/Library/Application Support/com.apple.wallpaper/aerials/videos" as NSString)
    .expandingTildeInPath
let manifestPath = ("~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json" as NSString)
    .expandingTildeInPath
let outDir = ("~/Pictures/AerialWallpapers" as NSString).expandingTildeInPath

// --- Load pack definitions (frame name → shotID) from scenes.json.
struct Scene { let name: String; let clips: [String: String] }

let scenesURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scenes.json")
guard let scenesData = try? Data(contentsOf: scenesURL),
      let scenesJSON = try? JSONSerialization.jsonObject(with: scenesData) as? [[String: Any]] else {
    fail("cannot read pack definitions at \(scenesURL.path)")
}
let scenes: [Scene] = scenesJSON.compactMap {
    guard let name = $0["name"] as? String, let clips = $0["clips"] as? [String: String] else { return nil }
    return Scene(name: name, clips: clips)
}

// --- Map shotID → asset UUID from the aerial manifest. Clips are matched
// by shotID because accessibilityLabel is not a dependable name: on
// macOS 27.0 two of the Golden Gate labels are raw file names.
guard let manifestData = FileManager.default.contents(atPath: manifestPath) else {
    fail("manifest not found at \(manifestPath). Does this Mac have Apple's aerial wallpapers (macOS Tahoe or newer)?")
}
guard let root = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      let assets = root["assets"] as? [[String: Any]] else {
    fail("manifest shape unexpected — Apple may have changed the format")
}
var uuidByShotID: [String: String] = [:]
for asset in assets {
    if let shotID = asset["shotID"] as? String, let id = asset["id"] as? String {
        uuidByShotID[shotID] = id
    }
}

// --- Pick the pack.
let scene: Scene
if let requestedPack {
    guard let match = scenes.first(where: { $0.name == requestedPack }) else {
        fail("unknown pack \"\(requestedPack)\". Packs in scenes.json: \(scenes.map(\.name).joined(separator: ", "))")
    }
    scene = match
} else {
    guard let match = scenes.first(where: { $0.clips.values.allSatisfy { uuidByShotID[$0] != nil } }) else {
        fail("none of the packs in scenes.json (\(scenes.map(\.name).joined(separator: ", "))) is in this Mac's aerial manifest")
    }
    scene = match
}
if printDefaultPack {
    print(scene.name); exit(0)
}

let missing = scene.clips.values.filter { uuidByShotID[$0] == nil }.sorted()
if !missing.isEmpty {
    fail("pack \"\(scene.name)\" is not in this Mac's aerial manifest (missing: \(missing.joined(separator: ", ")))")
}

// --- Extract a poster frame for each clip.
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let posterAt = CMTime(seconds: 5.0, preferredTimescale: 600)
let filePrefix = scene.name.lowercased().filter { !$0.isWhitespace }

for (frame, shotID) in scene.clips.sorted(by: { $0.key < $1.key }) {
    let movPath = "\(aerialsDir)/\(uuidByShotID[shotID]!).mov"
    let outPath = "\(outDir)/\(filePrefix)-\(frame).png"

    guard FileManager.default.fileExists(atPath: movPath) else {
        FileHandle.standardError.write(Data(
            "skip \(frame): not downloaded — open System Settings → Wallpaper and click the cloud-arrow on \(scene.name) \(frame.capitalized)\n".utf8))
        continue
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: movPath))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero

    let sem = DispatchSemaphore(value: 0)
    var result: Result<CGImage, Error> = .failure(NSError(domain: "aerial", code: -1))
    gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: posterAt)]) { _, image, _, _, error in
        if let image { result = .success(image) }
        else { result = .failure(error ?? NSError(domain: "aerial", code: -1)) }
        sem.signal()
    }
    sem.wait()

    do {
        let cgImage = try result.get()
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("encode failed for \(frame)\n".utf8)); continue
        }
        try data.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
    } catch {
        FileHandle.standardError.write(Data("extract failed for \(frame): \(error)\n".utf8))
    }
}
