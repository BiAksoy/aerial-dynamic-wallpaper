#!/usr/bin/env swift
// Extracts a still poster frame from each Tahoe aerial .mov and writes
// PNGs to ~/Pictures/TahoeWallpapers/. Asset UUIDs are looked up at run
// time from the system aerial manifest, so this keeps working if Apple
// republishes the pack with new IDs.

import AVFoundation
import AppKit
import Foundation

let aerialsDir = ("~/Library/Application Support/com.apple.wallpaper/aerials/videos" as NSString)
    .expandingTildeInPath
let manifestPath = ("~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json" as NSString)
    .expandingTildeInPath
let outDir = ("~/Pictures/TahoeWallpapers" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let pack = "Tahoe"
let phases = ["Morning", "Day", "Evening", "Night"]

// --- Resolve UUIDs by scanning the aerial manifest for "<Pack> <Phase>" labels.
struct ResolvedPhase { let phase: String; let uuid: String }

func resolvePhases() throws -> [ResolvedPhase] {
    guard let data = FileManager.default.contents(atPath: manifestPath) else {
        throw NSError(domain: "tahoe", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "manifest not found at \(manifestPath) — does this Mac run macOS Tahoe with aerial support?"])
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let assets = root["assets"] as? [[String: Any]] else {
        throw NSError(domain: "tahoe", code: 2, userInfo: [NSLocalizedDescriptionKey:
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
        throw NSError(domain: "tahoe", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "manifest is missing entries for: \(missing.joined(separator: ", "))"])
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

for r in resolved {
    let movPath = "\(aerialsDir)/\(r.uuid).mov"
    let outPath = "\(outDir)/tahoe-\(r.phase).png"

    guard FileManager.default.fileExists(atPath: movPath) else {
        FileHandle.standardError.write(Data(
            "skip \(r.phase): not downloaded — open System Settings → Wallpaper and click the cloud-arrow on Tahoe \(r.phase.capitalized)\n".utf8))
        continue
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: movPath))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero

    let sem = DispatchSemaphore(value: 0)
    var result: Result<CGImage, Error> = .failure(NSError(domain: "tahoe", code: -1))
    gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: posterAt)]) { _, image, _, _, error in
        if let image { result = .success(image) }
        else { result = .failure(error ?? NSError(domain: "tahoe", code: -1)) }
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
