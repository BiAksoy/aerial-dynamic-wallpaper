#!/usr/bin/env swift
// Builds a solar-dynamic HEIC from the four Tahoe poster frames in
// ~/Pictures/TahoeWallpapers/. macOS reads the embedded apple_desktop:solar
// metadata and picks the right image based on the current sun position
// (computed from Location Services), so the wallpaper rotates natively
// and adapts when you travel.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = ("~/Pictures/TahoeWallpapers" as NSString).expandingTildeInPath
let outFile = "\(dir)/Tahoe-Dynamic.heic"

// Source frames, in display order. Indices below reference these positions.
let sources: [(phase: String, file: String)] = [
    ("morning", "tahoe-morning.png"),  // 0
    ("day",     "tahoe-day.png"),      // 1
    ("evening", "tahoe-evening.png"),  // 2
    ("night",   "tahoe-night.png"),    // 3
]

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
var missing: [String] = []
for src in sources {
    let path = "\(dir)/\(src.file)"
    guard FileManager.default.fileExists(atPath: path) else {
        missing.append(src.phase); continue
    }
    guard let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else {
        FileHandle.standardError.write(Data("decode failed: \(path)\n".utf8)); exit(1)
    }
    images.append(img)
}
if !missing.isEmpty {
    let names = missing.map { "Tahoe \($0.capitalized)" }.joined(separator: ", ")
    FileHandle.standardError.write(Data("""
        missing source frames for: \(missing.joined(separator: ", "))

        Open System Settings → Wallpaper, click the cloud-arrow icon to download
        \(names), then re-run:  tahoe-install

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
