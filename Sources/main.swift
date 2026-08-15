// apple-photos-sync — attach externally rendered JPEGs (e.g. Lightroom exports) as the
// *edited version* of existing Apple Photos assets, preserving the original.
//
// Uses the same PhotoKit mechanism as Photos editing extensions:
//   PHContentEditingInput -> PHContentEditingOutput -> PHAssetChangeRequest
// The asset keeps its identity (date, albums, faces, favorites, memories), the
// original RAW stays put, and "Revert to Original" undoes everything.

import CryptoKit
import UniformTypeIdentifiers
import Foundation
import ImageIO
import Photos

// MARK: - Constants

let formatIdentifier = "com.ondruska.apple-photos-sync"
let formatVersion = "1.0"

func isOurs(_ data: PHAdjustmentData) -> Bool {
    data.formatIdentifier == formatIdentifier && data.formatVersion == formatVersion
}

/// Capture date is a corroborating signal, not the match key: camera clocks are
/// routinely on the wrong timezone, so the window is deliberately generous.
let dateTolerance: TimeInterval = 26 * 3600
/// A second candidate this close to the best one means we refuse to guess.
let ambiguityMargin: TimeInterval = 60

/// Set once the accepted render formats have been reported under --verbose.
var reportedRenderTypes = false

// MARK: - Options

struct Options {
    var folder: URL
    var dryRun = false
    var force = false
    var revert = false
    var verbose = false
}

/// When the tool is launched via `open -a` (the reliable way to get a Photos
/// permission prompt), stdout is discarded — so mirror everything to a log file.
var logHandle: FileHandle?

func say(_ text: String) {
    print(text)
    if let handle = logHandle, let data = (text + "\n").data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

func usage() -> Never {
    print("""
    usage: apple-photos-sync [--dry-run] [--force] [--revert] [--verbose] [--log <file>] <folder>

      --dry-run    report matches, write nothing
      --force      rewrite even when the asset already holds this exact render
      --revert     revert matched assets to their originals (undo)
      --verbose    print per-asset detail
      --log <file> mirror output to a file (needed when launched via `open -a`)

    Matches JPEGs in <folder> to Photos assets by filename stem, corroborated by
    capture date. Files that match zero or several assets are skipped, never guessed.
    """)
    exit(2)
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    var dryRun = false, force = false, revert = false, verbose = false
    var path: String?

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--dry-run", "-n": dryRun = true
        case "--force": force = true
        case "--revert": revert = true
        case "--verbose", "-v": verbose = true
        case "--help", "-h": usage()
        case "--log":
            guard !args.isEmpty else { usage() }
            let path = (args.removeFirst() as NSString).expandingTildeInPath
            FileManager.default.createFile(atPath: path, contents: nil)
            logHandle = FileHandle(forWritingAtPath: path)
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!)
                usage()
            }
            guard path == nil else {
                FileHandle.standardError.write("only one folder may be given\n".data(using: .utf8)!)
                usage()
            }
            path = arg
        }
    }

    guard let path else { usage() }
    if revert && force {
        FileHandle.standardError.write("--revert and --force are mutually exclusive\n".data(using: .utf8)!)
        usage()
    }

    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        fail("not a folder: \(url.path)")
    }
    return Options(folder: url, dryRun: dryRun, force: force, revert: revert, verbose: verbose)
}

/// The log's last line carries the exit status, so the wrapper script can
/// propagate it back to the shell that launched us through `open -a`.
func finish(_ code: Int32) -> Never {
    if let handle = logHandle, let data = "##exit \(code)\n".data(using: .utf8) {
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    exit(code)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("apple-photos-sync: \(message)\n".data(using: .utf8)!)
    if let handle = logHandle, let data = "apple-photos-sync: \(message)\n".data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
    finish(1)
}

// MARK: - Source files

struct SourceFile {
    let url: URL
    let stem: String
    let captureDate: Date?
    let sha256: String
}

struct AdjustmentPayload: Codable {
    let source: String
    let sha256: String
    let appliedAt: String
}

/// Reads EXIF DateTimeOriginal, honouring OffsetTimeOriginal when present.
/// Falls back to the local timezone, which is why callers treat the result as a hint.
func captureDate(of url: URL) -> Date? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
          let stamp = exif["DateTimeOriginal"] as? String
    else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if let offset = exif["OffsetTimeOriginal"] as? String,
       let zone = TimeZone(iso8601Offset: offset) {
        formatter.timeZone = zone
    }
    return formatter.date(from: stamp)
}

extension TimeZone {
    /// Parses "+01:00" / "-08:00" / "+0100" style EXIF offsets.
    init?(iso8601Offset text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().split(separator: ":").joined()
        guard digits.count == 4, let value = Int(digits) else { return nil }
        let seconds = (value / 100) * 3600 + (value % 100) * 60
        self.init(secondsFromGMT: sign == "-" ? -seconds : seconds)
    }
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func isJPEG(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(source) as String?
    else { return false }
    return type == "public.jpeg"
}

func collectSourceFiles(in folder: URL) -> [SourceFile] {
    let names: [URL]
    do {
        names = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    } catch {
        fail("cannot read folder: \(error.localizedDescription)")
    }

    return names
        .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in
            guard isJPEG(url) else {
                say("  \(url.lastPathComponent.padded(16))  SKIPPED   not a JPEG (PhotoKit requires JPEG)")
                return nil
            }
            guard let hash = try? sha256(of: url) else {
                say("  \(url.lastPathComponent.padded(16))  SKIPPED   unreadable")
                return nil
            }
            return SourceFile(
                url: url,
                stem: url.deletingPathExtension().lastPathComponent.uppercased(),
                captureDate: captureDate(of: url),
                sha256: hash)
        }
}

// MARK: - Photos access

func authorize() {
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
        let gate = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
            status = newStatus
            gate.signal()
        }
        gate.wait()
    }
    switch status {
    case .authorized:
        return
    case .limited:
        fail("""
        Photos granted only limited access; this tool needs full library access.
        Grant it under System Settings > Privacy & Security > Photos.
        """)
    default:
        fail("""
        Photos access denied (status \(status.rawValue), bundle \(Bundle.main.bundleIdentifier ?? "none")).
        Grant it under System Settings > Privacy & Security > Photos, then run again.
        PhotoKit writes to the System Photo Library.
        """)
    }
}

/// Index of filename stem -> assets. A Leica RAW+JPG pair is one asset carrying
/// resources L1037323.DNG and L1037323.JPG, so one stem covers both.
func buildIndex(dateRange: (start: Date, end: Date)?) -> [String: [PHAsset]] {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    options.includeAllBurstAssets = false
    if let range = dateRange {
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            range.start as NSDate, range.end as NSDate)
    }

    var index: [String: [PHAsset]] = [:]
    let result = PHAsset.fetchAssets(with: .image, options: options)
    result.enumerateObjects { asset, _, _ in
        var seen = Set<String>()
        for resource in PHAssetResource.assetResources(for: asset) {
            let stem = (resource.originalFilename as NSString)
                .deletingPathExtension.uppercased()
            guard !stem.isEmpty, seen.insert(stem).inserted else { continue }
            index[stem, default: []].append(asset)
        }
    }
    return index
}

// MARK: - Matching

enum MatchResult {
    case matched(PHAsset)
    case notFound
    case ambiguous(Int)
}

func match(_ file: SourceFile, in index: [String: [PHAsset]]) -> MatchResult {
    guard let candidates = index[file.stem], !candidates.isEmpty else { return .notFound }
    if candidates.count == 1 { return .matched(candidates[0]) }

    guard let target = file.captureDate else { return .ambiguous(candidates.count) }
    let ranked = candidates
        .map { (asset: $0, delta: abs(($0.creationDate ?? .distantPast).timeIntervalSince(target))) }
        .sorted { $0.delta < $1.delta }
    guard ranked.count < 2 || ranked[1].delta - ranked[0].delta > ambiguityMargin else {
        return .ambiguous(candidates.count)
    }
    return .matched(ranked[0].asset)
}

// MARK: - PhotoKit operations, made synchronous

func contentEditingInput(for asset: PHAsset) -> PHContentEditingInput? {
    let options = PHContentEditingInputRequestOptions()
    options.isNetworkAccessAllowed = true
    // Claiming our own adjustments means PhotoKit hands back the *original* as the
    // editing base (not a previous run's render) and populates adjustmentData.
    options.canHandleAdjustmentData = { data in isOurs(data) }

    var result: PHContentEditingInput?
    let gate = DispatchSemaphore(value: 0)
    asset.requestContentEditingInput(with: options) { input, _ in
        result = input
        gate.signal()
    }
    gate.wait()
    return result
}

func performChanges(_ block: @escaping () -> Void) -> Error? {
    var failure: Error?
    let gate = DispatchSemaphore(value: 0)
    PHPhotoLibrary.shared().performChanges(block) { _, error in
        failure = error
        gate.signal()
    }
    gate.wait()
    return failure
}

func existingPayload(in input: PHContentEditingInput) -> AdjustmentPayload? {
    guard let data = input.adjustmentData, isOurs(data) else { return nil }
    return try? JSONDecoder().decode(AdjustmentPayload.self, from: data.data)
}

func applyRender(_ file: SourceFile, to asset: PHAsset, force: Bool) -> String {
    guard let input = contentEditingInput(for: asset) else {
        return "FAILED    could not open asset for editing"
    }
    if !force, let payload = existingPayload(in: input), payload.sha256 == file.sha256 {
        return "UP TO DATE"
    }

    let output = PHContentEditingOutput(contentEditingInput: input)
    do {
        try? FileManager.default.removeItem(at: output.renderedContentURL)
        try FileManager.default.copyItem(at: file.url, to: output.renderedContentURL)
    } catch {
        return "FAILED    writing render: \(error.localizedDescription)"
    }

    let payload = AdjustmentPayload(
        source: file.url.path,
        sha256: file.sha256,
        appliedAt: ISO8601DateFormatter().string(from: Date()))
    guard let encoded = try? JSONEncoder().encode(payload) else {
        return "FAILED    encoding adjustment data"
    }
    output.adjustmentData = PHAdjustmentData(
        formatIdentifier: formatIdentifier, formatVersion: formatVersion, data: encoded)

    // One asset per change block, so a single failure cannot roll back the batch.
    if let error = performChanges({
        let request = PHAssetChangeRequest(for: asset)
        request.contentEditingOutput = output
    }) {
        return "FAILED    \(error.localizedDescription)"
    }
    return "UPDATED"
}

func revert(_ asset: PHAsset) -> String {
    if let error = performChanges({
        PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
    }) {
        return "FAILED    \(error.localizedDescription)"
    }
    return "REVERTED"
}

// MARK: - Formatting

extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

let display: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

func describe(_ date: Date?) -> String {
    date.map { display.string(from: $0) } ?? "—"
}

// MARK: - Main

func run() -> Int32 {
    let options = parseOptions()

    say("Source: \(options.folder.path)")
    let files = collectSourceFiles(in: options.folder)
    guard !files.isEmpty else { fail("no JPEGs found in \(options.folder.path)") }
    say("Found \(files.count) JPEG\(files.count == 1 ? "" : "s")\n")

    authorize()

    // Narrow the library scan to the capture window first; fall back to a full
    // scan only for stems that window misses.
    let dates = files.compactMap(\.captureDate)
    var index: [String: [PHAsset]] = [:]
    if let earliest = dates.min(), let latest = dates.max() {
        index = buildIndex(dateRange: (earliest.addingTimeInterval(-dateTolerance),
                                       latest.addingTimeInterval(dateTolerance)))
    }
    if files.contains(where: { index[$0.stem] == nil }) {
        if options.verbose { say("(scanning full library for unmatched stems)\n") }
        let full = buildIndex(dateRange: nil)
        index.merge(full) { current, _ in current }
    }

    var updated = 0, upToDate = 0, reverted = 0, notFound = 0, ambiguous = 0, failed = 0

    say("  \("FILE".padded(16))  \("CAPTURED".padded(19))  \("ASSET DATE".padded(19))  ACTION")
    for file in files {
        let name = file.url.lastPathComponent
        switch match(file, in: index) {
        case .notFound:
            notFound += 1
            say("  \(name.padded(16))  \(describe(file.captureDate).padded(19))  \("—".padded(19))  NOT FOUND")

        case .ambiguous(let count):
            ambiguous += 1
            say("  \(name.padded(16))  \(describe(file.captureDate).padded(19))  \("—".padded(19))  AMBIGUOUS (\(count) assets)")

        case .matched(let asset):
            let assetDate = asset.creationDate
            var note = ""
            if let captured = file.captureDate, let assetDate,
               abs(assetDate.timeIntervalSince(captured)) > dateTolerance {
                note = "  [date differs by \(Int(abs(assetDate.timeIntervalSince(captured)) / 3600))h]"
            }

            let action: String
            if options.revert {
                action = options.dryRun ? "WOULD REVERT" : revert(asset)
            } else if options.dryRun {
                // Read the asset's adjustment data so a dry run doesn't claim
                // work for renders that are already in place.
                let input = contentEditingInput(for: asset)
                if options.verbose, !reportedRenderTypes, let input {
                    reportedRenderTypes = true
                    let types = PHContentEditingOutput(contentEditingInput: input)
                        .supportedRenderedContentTypes.map(\.identifier)
                    say("      accepted render formats: \(types.joined(separator: ", "))")
                }
                let current = input.flatMap(existingPayload)
                action = (!options.force && current?.sha256 == file.sha256)
                    ? "UP TO DATE" : "WOULD UPDATE"
            } else {
                action = applyRender(file, to: asset, force: options.force)
            }

            switch true {
            case action.hasPrefix("UPDATED"): updated += 1
            case action.hasPrefix("UP TO DATE"): upToDate += 1
            case action.hasPrefix("REVERTED"): reverted += 1
            case action.hasPrefix("FAILED"): failed += 1
            default: updated += 1  // dry-run projections
            }

            var line = "  \(name.padded(16))  \(describe(file.captureDate).padded(19))  \(describe(assetDate).padded(19))  \(action)\(note)"
            if options.verbose {
                line += "\n      asset \(asset.localIdentifier)"
            }
            say(line)
        }
    }

    say("")
    var summary = ["matched: \(updated + upToDate + reverted)"]
    if options.dryRun { summary = ["would act on: \(updated + reverted)"] }
    if upToDate > 0 { summary.append("up to date: \(upToDate)") }
    if reverted > 0 { summary.append("reverted: \(reverted)") }
    if notFound > 0 { summary.append("not found: \(notFound)") }
    if ambiguous > 0 { summary.append("ambiguous: \(ambiguous)") }
    if failed > 0 { summary.append("failed: \(failed)") }
    say(summary.joined(separator: "   "))

    if options.dryRun {
        say("\nDry run — nothing was written.")
    } else if updated > 0 {
        say("\nDone. Photos now shows the rendered version; originals are intact")
        say("(Image > Revert to Original, or re-run with --revert).")
    }

    return (failed > 0 || notFound > 0 || ambiguous > 0) ? 1 : 0
}

// PhotoKit delivers several callbacks on the main queue, so the work runs on a
// background queue and the main thread stays free to service the run loop.
DispatchQueue.global(qos: .userInitiated).async {
    finish(run())
}
RunLoop.main.run()
