#!/usr/bin/env swift
// Extracts a still poster frame from each phase of an Apple aerial pack
// and writes PNGs to ~/Pictures/AerialWallpapers/. Asset UUIDs are looked
// up at run time from the system aerial manifest, so the script keeps
// working if Apple republishes a pack with new IDs.
//
// Usage: tahoe-extract-frames [--pack <Name>]
//   --pack    Aerial pack name (default: Tahoe). The pack must contain
//             four assets labelled "<Pack> Morning", "<Pack> Day",
//             "<Pack> Evening", "<Pack> Night".

import AVFoundation
import AppKit
import Foundation

// --- Parse args.
var pack = "Tahoe"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--pack":
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("--pack requires a value\n".utf8)); exit(2)
        }
        pack = args.removeFirst()
    case let other:
        FileHandle.standardError.write(Data("unknown argument: \(other)\n".utf8)); exit(2)
    }
}

let aerialsDir = ("~/Library/Application Support/com.apple.wallpaper/aerials/videos" as NSString)
    .expandingTildeInPath
let manifestPath = ("~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json" as NSString)
    .expandingTildeInPath
let outDir = ("~/Pictures/AerialWallpapers" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let phases = ["Morning", "Day", "Evening", "Night"]

// --- Resolve UUIDs by scanning the aerial manifest for "<Pack> <Phase>" labels.
struct ResolvedPhase { let phase: String; let uuid: String }

func resolvePhases() throws -> [ResolvedPhase] {
    guard let data = FileManager.default.contents(atPath: manifestPath) else {
        throw NSError(domain: "aerial", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "manifest not found at \(manifestPath) — does this Mac run macOS Tahoe with aerial support?"])
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let assets = root["assets"] as? [[String: Any]] else {
        throw NSError(domain: "aerial", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "manifest shape unexpected — Apple may have changed the format"])
    }
    var resolved: [ResolvedPhase] = []
    var missing: [String] = []
    for phase in phases {
        let label = "\(pack) \(phase)"
        if let asset = assets.first(where: { ($0["accessibilityLabel"] as? String) == label }),
           let id = asset["id"] as? String {
            resolved.append(ResolvedPhase(phase: phase.lowercased(), uuid: id))
        } else {
            missing.append(label)
        }
    }
    if !missing.isEmpty {
        throw NSError(domain: "aerial", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "pack \"\(pack)\" is missing required phases in the manifest: \(missing.joined(separator: ", "))\n" +
            "(this pack may not have a four-phase day cycle on this macOS version)"])
    }
    return resolved
}

let resolved: [ResolvedPhase]
do {
    resolved = try resolvePhases()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

// --- Extract a poster frame for each phase.
let posterAt = CMTime(seconds: 5.0, preferredTimescale: 600)
let packLower = pack.lowercased()

for r in resolved {
    let movPath = "\(aerialsDir)/\(r.uuid).mov"
    let outPath = "\(outDir)/\(packLower)-\(r.phase).png"

    guard FileManager.default.fileExists(atPath: movPath) else {
        FileHandle.standardError.write(Data(
            "skip \(r.phase): not downloaded — open System Settings → Wallpaper and click the cloud-arrow on \(pack) \(r.phase.capitalized)\n".utf8))
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
            FileHandle.standardError.write(Data("encode failed for \(r.phase)\n".utf8)); continue
        }
        try data.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
    } catch {
        FileHandle.standardError.write(Data("extract failed for \(r.phase): \(error)\n".utf8))
    }
}
