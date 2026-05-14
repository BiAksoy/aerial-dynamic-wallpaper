#!/usr/bin/env swift
// Builds a solar-dynamic HEIC from the four poster frames of an aerial pack
// in ~/Pictures/AerialWallpapers/. macOS reads the embedded
// apple_desktop:solar metadata and picks the right image based on the
// current sun position (computed from Location Services), so the wallpaper
// rotates natively and adapts when you travel.
//
// Usage: tahoe-build-dynamic [--pack <Name>]
//   --pack    Aerial pack name (default: Tahoe). Reads
//             "<pack-lower>-{morning,day,evening,night}.png" and writes
//             "<Pack>-Dynamic.heic" in ~/Pictures/AerialWallpapers/.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

let dir = ("~/Pictures/AerialWallpapers" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

let packLower = pack.lowercased()
let phases = ["Morning", "Day", "Evening", "Night"]
let sourcePaths = phases.map { "\(dir)/\(packLower)-\($0.lowercased()).png" }
let outFile = "\(dir)/\(pack)-Dynamic.heic"

// Solar anchors: (altitude°, azimuth°, image index).
// macOS picks the entry whose (alt, az) is nearest the current sun position.
// Doubled-up entries widen each phase's coverage so transitions feel right
// across mid-latitudes north and south.
let solar: [[String: Any]] = [
    ["a":   4.0, "z":  90.0, "i": 0],  // sunrise  → morning
    ["a":  25.0, "z": 130.0, "i": 0],  // mid-AM   → morning
    ["a":  60.0, "z": 180.0, "i": 1],  // noon     → day
    ["a":  25.0, "z": 230.0, "i": 1],  // mid-PM   → day
    ["a":   4.0, "z": 270.0, "i": 2],  // sunset   → evening
    ["a":  -8.0, "z": 300.0, "i": 2],  // dusk     → evening
    ["a": -40.0, "z":   0.0, "i": 3],  // midnight → night
    ["a":  -8.0, "z":  60.0, "i": 3],  // pre-dawn → night
]

// --- Load all four source images, error out cleanly if any are missing.
var images: [CGImage] = []
var missingPhases: [String] = []
for (path, phase) in zip(sourcePaths, phases) {
    guard FileManager.default.fileExists(atPath: path) else {
        missingPhases.append(phase); continue
    }
    guard let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else {
        FileHandle.standardError.write(Data("decode failed: \(path)\n".utf8)); exit(1)
    }
    images.append(img)
}
if !missingPhases.isEmpty {
    let names = missingPhases.map { "\(pack) \($0)" }.joined(separator: ", ")
    let installCmd = pack == "Tahoe" ? "tahoe-install" : "tahoe-install --pack \(pack)"
    FileHandle.standardError.write(Data("""
        missing source frames for: \(missingPhases.joined(separator: ", "))

        Open System Settings → Wallpaper, click the cloud-arrow icon to download
        \(names), then re-run:  \(installCmd)

        """.utf8))
    exit(1)
}

// --- Light/Dark appearance fallback. If a user forces Light or Dark mode
// (overriding Auto), macOS uses these indices instead of the solar table.
let appearance: [String: Int] = ["l": 1, "d": 3]  // light → day, dark → night

// --- Encode the metadata as a base64 binary plist (Apple's format).
let plistData = try PropertyListSerialization.data(
    fromPropertyList: ["ap": appearance, "si": solar],
    format: .binary,
    options: 0)
let solarBase64 = plistData.base64EncodedString()

// --- Build the HEIC with apple_desktop:solar metadata on the primary image.
let outURL = URL(fileURLWithPath: outFile)
try? FileManager.default.removeItem(at: outURL)
guard let dest = CGImageDestinationCreateWithURL(
        outURL as CFURL, UTType.heic.identifier as CFString, images.count, nil) else {
    FileHandle.standardError.write(Data("cannot create HEIC at \(outFile)\n".utf8)); exit(1)
}

let metadata = CGImageMetadataCreateMutable()
CGImageMetadataRegisterNamespaceForPrefix(
    metadata,
    "http://ns.apple.com/namespace/1.0/" as CFString,
    "apple_desktop" as CFString, nil)
guard let tag = CGImageMetadataTagCreate(
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        "solar" as CFString,
        .string,
        solarBase64 as CFString) else {
    FileHandle.standardError.write(Data("metadata tag creation failed\n".utf8)); exit(1)
}
CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:solar" as CFString, tag)

CGImageDestinationAddImageAndMetadata(dest, images[0], metadata, nil)
for img in images.dropFirst() {
    CGImageDestinationAddImage(dest, img, nil)
}
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("HEIC finalize failed\n".utf8)); exit(1)
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: outFile)[.size] as? Int) ?? 0
let mb = Double(bytes) / 1_048_576
print(String(format: "wrote %@ (%.1f MB, %d frames, %d solar anchors)",
             outFile, mb, images.count, solar.count))
