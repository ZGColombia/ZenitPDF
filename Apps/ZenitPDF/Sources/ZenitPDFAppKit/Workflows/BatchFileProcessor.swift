import AppKit
import CryptoKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFPDFKitBridge
import ZPDFSearch
import ZPDFServiceWire
import ZPDFUIPresentation

/// Tools ▸ Process PDF Files… (NL-PDF-19): the same steps on a whole folder of PDFs.
///
/// Make searchable (on-device OCR, an invisible text layer), reduce file size (with pictures
/// resampled), remove scripts and metadata, burn in the files' own annotations, protect with a
/// password — in that order, each file on its own, written to an output folder the person
/// chose and never beside the inputs unless they chose that folder on purpose. qpdf runs in the
/// repair service, so one hostile file stops a worker, not the application. Every input is
/// hashed before and after; a run that is stopped resumes where it stopped (a state file in the
/// output folder), and a per-file report — done, skipped or failed, with the reason — is
/// written beside the outputs.
enum BatchFileProcessor {

    /// What to do to every file.
    struct Steps: Equatable, Sendable {
        var makeSearchable = false
        var reduceSize = true
        var pictureDPI: Int? = 150
        var removeHiddenContent = false
        var flattenAnnotations = false
        /// `nil`: not protected.
        var protection: RepairWireTransform.Protection?

        var usesQPDF: Bool { reduceSize || removeHiddenContent || flattenAnnotations || protection != nil }
        var isEmpty: Bool { !makeSearchable && !usesQPDF }
    }

    enum Status: Equatable, Sendable {
        case done
        case skipped(String)
        case failed(String)
    }

    struct Item: Equatable, Sendable {
        var input: URL
        var output: URL?
        var status: Status
        var inputUnchanged: Bool
        /// What a done file lacks, said in the report's Reason column: the pages Make Searchable
        /// could not read (V-078). `nil` when the file is done in full.
        var note: String? = nil
    }

    /// What a run did.
    struct Report: Sendable {
        var items: [Item]
        var cancelled: Bool
        var done: Int { items.filter { $0.status == .done }.count }
        var failed: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
        var skipped: Int { items.filter { if case .skipped = $0.status { return true }; return false }.count }
        /// Done files with pages Make Searchable could not read (V-078).
        var incomplete: Int { items.filter { $0.status == .done && $0.note != nil }.count }
    }

    /// Recognises a whole file's text on this Mac, without an index. Injectable so a test can
    /// make a page fail without a damaged PDF.
    typealias FileRecogniser = @Sendable (URL) async throws -> OCRFileRecognition

    /// The on-device recogniser.
    static let liveRecogniser: FileRecogniser = { input in
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: input)
        do {
            let recognition = try await OCRService.recogniseFile(handle: opened.handle, provider: provider)
            await provider.close(opened.handle)
            return recognition
        } catch {
            await provider.close(opened.handle)
            throw error
        }
    }

    /// The report's reason for a searchable file some of whose pages could not be read, or
    /// `nil` when every page was. Page numbers count from one, as the sheets are numbered.
    static func unreadablePagesNote(_ pages: [Int]) -> String? {
        guard !pages.isEmpty else { return nil }
        let numbers = pages.sorted().map { String($0 + 1) }.joined(separator: ", ")
        return pages.count == 1
            ? String(format: NSLocalizedString(
                "page %@ could not be read for text, so it has no text layer; run again to retry it",
                comment: "Batch report reason: one page Make Searchable could not render or recognise; its page number"
            ), numbers)
            : String(format: NSLocalizedString(
                "pages %@ could not be read for text, so they have no text layer; run again to retry them",
                comment: "Batch report reason: pages Make Searchable could not render or recognise; their page numbers"
            ), numbers)
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case nothingChosen
        case noSteps
        case outputBesideInputs

        var description: String {
            switch self {
            case .nothingChosen: NSLocalizedString("Choose at least one PDF file or folder.", comment: "Batch refusal: no inputs")
            case .noSteps: NSLocalizedString("Choose at least one thing to do to the files.", comment: "Batch refusal: no steps")
            case .outputBesideInputs:
                NSLocalizedString("The output folder is the folder the files are in. Choose another folder, or tick “Write beside the originals”.", comment: "Batch refusal: output folder is an input folder")
            }
        }
    }

    static let stateFileName = ".zenit-batch-state.json"
    static let reportFileName = "Processing report.csv"

    /// The PDFs to process: the chosen files, and the PDFs directly inside chosen folders, sorted
    /// by name. Anything else is reported as skipped rather than silently ignored.
    static func expand(_ chosen: [URL]) -> [URL] {
        var files: [URL] = []
        for url in chosen {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files += entries.filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }
        return files
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The finished inputs of an earlier run into `folder`, by path and digest, and the file
    /// each one was written to.
    struct State: Codable, Equatable {
        var finished: [String: String] = [:]   // input path → digest when it was processed
        /// Input path → the output file name that run wrote. A resume is taken only when the
        /// output it would skip is the one *this* input produced: two inputs of one name used
        /// to share an output, and the second's result was reported as the first's (R-024).
        /// Absent in a state written before it existed, which then resumes nothing.
        var outputs: [String: String]? = nil

        /// The state without any output name more than one input claims. Only a state written
        /// before claims were made exclusive holds such a name, and which input's result its
        /// file holds cannot be known, so none of them may resume against it (R-024).
        func withoutSharedClaims() -> State {
            guard let outputs else { return self }
            let holders = Dictionary(grouping: outputs, by: { $0.value.lowercased() })
            let shared = Set(holders.values.filter { $0.count > 1 }.flatMap { $0.map(\.key) })
            guard !shared.isEmpty else { return self }
            var cleaned = self
            for input in shared {
                cleaned.outputs?.removeValue(forKey: input)
                cleaned.finished.removeValue(forKey: input)
            }
            return cleaned
        }
    }

    static func readState(in folder: URL) -> State {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(stateFileName)),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    static func writeState(_ state: State, in folder: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: folder.appendingPathComponent(stateFileName), options: .atomic)
    }

    static func outputName(for input: URL) -> String {
        outputName(stem: input.deletingPathExtension().lastPathComponent)
    }

    private static func outputName(stem: String) -> String {
        stem + " — " + NSLocalizedString("Processed", comment: "Batch output file-name suffix") + ".pdf"
    }

    /// Every input's output file name: unique within the run, and never a name the state
    /// records for another input.
    ///
    /// Inputs from different folders can share a name, and their outputs used to be one file:
    /// the second overwrote the first and both were reported done (R-024). A name that more than
    /// one input would produce is told apart by each input's folder name — every holder of it,
    /// so a name does not depend on which of them came first — and then by a number if the
    /// folders share a name too. Case is ignored, as the default Mac volume ignores it.
    ///
    /// `claimed` is the state's input path → output name. An input keeps the name the state
    /// records for it alone, so a resume finds its own file; a name the state records for any
    /// other input is never handed out again. Two runs into one folder — Level 1/Plan.pdf, then
    /// Level 2/Plan.pdf on its own — used to give both the plain name, so the second replaced
    /// the first's file and a third run reported the first "already processed" against the
    /// second's result (R-024, second finding).
    ///
    /// `folder` is where the outputs go. An input that sits directly in it is an original, and
    /// its name is never an output's (U-010): writing beside the originals, "Plan.pdf" beside an
    /// original named "Plan — Processed.pdf" used to take that name and replace the original.
    static func outputNames(for inputs: [URL], claimed: [String: String] = [:], folder: URL? = nil) -> [URL: String] {
        func key(_ name: String) -> String { name.lowercased() }
        func path(_ input: URL) -> String { input.standardizedFileURL.path }
        // Every claimed name and who claims it. A state written before claims were exclusive
        // can hold one name for two inputs; neither may keep it, since its file is one of theirs.
        var claimants: [String: Set<String>] = [:]
        for (input, name) in claimed { claimants[key(name), default: []].insert(input) }
        let folderPath = folder?.standardizedFileURL.path
        let originals = Set(inputs.filter { $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }
            .map { key($0.lastPathComponent) })
        var names: [URL: String] = [:]
        var used = Set(claimants.keys).union(originals)
        for input in inputs {
            guard let name = claimed[path(input)], claimants[key(name)] == [path(input)],
                  !originals.contains(key(name)) else { continue }
            names[input] = name
        }
        let unnamed = inputs.filter { names[$0] == nil }
        let counts = Dictionary(grouping: unnamed, by: { key(outputName(for: $0)) }).mapValues(\.count)
        // Plain names first, so a disambiguated name can never take a plain one.
        for input in unnamed where counts[key(outputName(for: input))] == 1 && !used.contains(key(outputName(for: input))) {
            names[input] = outputName(for: input)
            used.insert(key(outputName(for: input)))
        }
        for input in unnamed where names[input] == nil {
            let stem = input.deletingPathExtension().lastPathComponent
            let folder = input.deletingLastPathComponent().lastPathComponent
            var candidate = outputName(stem: "\(stem) (\(folder))")
            var number = 2
            while used.contains(key(candidate)) {
                candidate = outputName(stem: "\(stem) (\(folder)) \(number)")
                number += 1
            }
            names[input] = candidate
            used.insert(key(candidate))
        }
        return names
    }

    /// Runs `steps` over `inputs`, writing into `folder`.
    ///
    /// - Parameters:
    ///   - allowBesideInputs: the person ticked "Write beside the originals".
    ///   - transform: the qpdf step; the repair service in the product, injectable for tests.
    ///   - progress: told after each file.
    ///   - recognise: Make Searchable's recogniser; on device in the product, injectable for tests.
    static func run(
        inputs chosen: [URL],
        steps: Steps,
        outputFolder folder: URL,
        allowBesideInputs: Bool = false,
        transform: @escaping @Sendable (URL, URL, RepairWireTransform) async throws -> Void,
        progress: (@MainActor (Int, Int) -> Void)? = nil,
        recognise: @escaping FileRecogniser = liveRecogniser
    ) async throws -> Report {
        var inputs = expand(chosen)
        guard !inputs.isEmpty else { throw Refusal.nothingChosen }
        guard !steps.isEmpty else { throw Refusal.noSteps }
        let inputFolders = Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if !allowBesideInputs, inputFolders.contains(folder.standardizedFileURL.path) { throw Refusal.outputBesideInputs }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var state = readState(in: folder).withoutSharedClaims()
        // Written beside the originals, an earlier run's results and report sit among the inputs
        // (T-013): a rerun — which the stopped-run note invites — processed "Plan — Processed.pdf"
        // into "Plan — Processed — Processed.pdf" and listed the report as "not a PDF". What this
        // folder's state says a run wrote, and the report, are not inputs.
        inputs = withoutEarlierOutputs(inputs, folder: folder, state: state)
        guard !inputs.isEmpty else { throw Refusal.nothingChosen }
        var items: [Item] = []
        var cancelled = false
        let names = outputNames(for: inputs, claimed: state.outputs ?? [:], folder: folder)
        for (position, input) in inputs.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let item = await process(
                input, steps: steps, folder: folder, outputName: names[input] ?? outputName(for: input),
                state: &state, originals: inputs, transform: transform, recognise: recognise
            )
            items.append(item)
            writeState(state, in: folder)
            await progress?(position + 1, inputs.count)
        }
        let report = Report(items: items, cancelled: cancelled)
        try? csv(report).write(to: folder.appendingPathComponent(reportFileName), atomically: true, encoding: .utf8)
        return report
    }

    /// `inputs` without the files a run into `folder` wrote there: every output the state
    /// records, and the processing report. Only files directly in `folder` are dropped, and
    /// names compare without case, as the default Mac volume does.
    static func withoutEarlierOutputs(_ inputs: [URL], folder: URL, state: State) -> [URL] {
        let folderPath = folder.standardizedFileURL.path
        let written = Set(((state.outputs ?? [:]).values.map { $0 } + [reportFileName]).map { $0.lowercased() })
        return inputs.filter { input in
            input.deletingLastPathComponent().standardizedFileURL.path != folderPath
                || !written.contains(input.lastPathComponent.lowercased())
        }
    }

    /// - Parameter originals: every input of the run. An output that is one of them is refused
    ///   before anything is written (U-010): the run promises the originals are never changed.
    static func process(
        _ input: URL,
        steps: Steps,
        folder: URL,
        outputName: String,
        state: inout State,
        originals: [URL] = [],
        transform: @Sendable (URL, URL, RepairWireTransform) async throws -> Void,
        recognise: FileRecogniser = liveRecogniser
    ) async -> Item {
        guard input.pathExtension.lowercased() == "pdf" else {
            return Item(input: input, output: nil, status: .skipped(NSLocalizedString("not a PDF", comment: "Batch skip reason")), inputUnchanged: true)
        }
        guard let before = sha256(of: input) else {
            return Item(input: input, output: nil, status: .failed(NSLocalizedString("the file could not be read", comment: "Batch failure reason")), inputUnchanged: true)
        }
        let output = folder.appendingPathComponent(outputName)
        guard !(originals + [input]).contains(where: { StagedFileReplacement.sameItem(output, $0) }) else {
            return Item(input: input, output: nil, status: .failed(NSLocalizedString(
                "its output name is an original's; nothing was written", comment: "Batch failure reason: the output would replace one of the files being processed"
            )), inputUnchanged: true)
        }
        let key = input.standardizedFileURL.path
        // A resume only against a file this input alone is recorded as having written.
        let sharedWithAnother = (state.outputs ?? [:]).contains { $0.key != key && $0.value.lowercased() == outputName.lowercased() }
        if state.finished[key] == before, state.outputs?[key] == outputName, !sharedWithAnother,
           FileManager.default.fileExists(atPath: output.path) {
            return Item(input: input, output: output, status: .skipped(NSLocalizedString("already processed in an earlier run", comment: "Batch skip reason: resumed")), inputUnchanged: true)
        }
        if let document = CGPDFDocument(input as CFURL), document.isEncrypted, !document.isUnlocked {
            return Item(input: input, output: nil, status: .skipped(NSLocalizedString("locked with a password; open it with its password first", comment: "Batch skip reason")), inputUnchanged: true)
        }
        let staging = folder.appendingPathComponent(".zpdf-batch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var current = input
            var unreadablePages: [Int] = []
            if steps.makeSearchable {
                let searchable = staging.appendingPathComponent("searchable.pdf")
                unreadablePages = try await makeSearchable(current, to: searchable, recognise: recognise)
                current = searchable
            }
            if steps.usesQPDF {
                let request = RepairWireTransform(
                    flattensAnnotations: steps.flattenAnnotations,
                    compresses: steps.reduceSize,
                    sanitizes: steps.removeHiddenContent,
                    linearizes: false,
                    protection: steps.protection,
                    pictureTargetDPI: steps.reduceSize ? steps.pictureDPI.map(Double.init) : nil
                )
                let transformed = staging.appendingPathComponent("transformed.pdf")
                try await transform(current, transformed, request)
                current = transformed
            }
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.copyItem(at: current, to: output)
            let unchanged = sha256(of: input) == before
            guard unchanged else {
                try? FileManager.default.removeItem(at: output)
                return Item(input: input, output: nil, status: .failed(NSLocalizedString("the original changed while it was processed", comment: "Batch failure reason")), inputUnchanged: false)
            }
            // A file with pages that could not be read is not finished: a rerun retries it rather
            // than skipping it as "already processed", and its report says so again (V-078).
            let note = unreadablePagesNote(unreadablePages)
            if note == nil { state.finished[key] = before } else { state.finished.removeValue(forKey: key) }
            // The file is this input's now: no other input may resume against it (R-024).
            var outputs = state.outputs ?? [:]
            for (other, name) in outputs where other != key && name.lowercased() == outputName.lowercased() {
                outputs.removeValue(forKey: other)
                state.finished.removeValue(forKey: other)
            }
            outputs[key] = outputName
            state.outputs = outputs
            return Item(input: input, output: output, status: .done, inputUnchanged: true, note: note)
        } catch {
            let reason = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            return Item(input: input, output: nil, status: .failed(reason), inputUnchanged: sha256(of: input) == before)
        }
    }

    /// On-device OCR of every page, written as an invisible text layer.
    ///
    /// - Returns: the zero-based pages that could not be rendered or recognised, ascending. They
    ///   are written without a text layer, like a blank page — and, unlike a blank page, the
    ///   caller is told (V-078).
    @discardableResult
    static func makeSearchable(_ input: URL, to output: URL, recognise: FileRecogniser = liveRecogniser) async throws -> [Int] {
        let recognition = try await recognise(input)
        let tokens = recognition.tokens
        let rotations = CGPDFDocument(input as CFURL).map { document -> [Int: Int] in
            var out: [Int: Int] = [:]
            for number in 1...max(1, document.numberOfPages) where document.numberOfPages > 0 {
                out[number - 1] = Int(document.page(at: number)?.rotationAngle ?? 0)
            }
            return out
        } ?? [:]
        let pages = tokens.keys.sorted().map { index in
            SearchableTextLayerWriter.Page(
                sourcePageIndex: index,
                rotation: rotations[index] ?? 0,
                tokens: (tokens[index] ?? []).map { .init(text: $0.text, bounds: $0.bounds) }
            )
        }
        let source = try Data(contentsOf: input, options: .mappedIfSafe)
        let produced = try SearchableTextLayerWriter().data(source: source, pages: pages)
        try produced.data.write(to: output, options: .atomic)
        return recognition.unreadablePages
    }

    /// The per-file report: file, status, reason, output.
    static func csv(_ report: Report) -> String {
        // The app's one CSV field rule (V-022): quoted when it must be, and a file name or reason
        // that starts like a formula is written as text, not run by a spreadsheet.
        func quote(_ text: String) -> String { LedgerCSVExport.field(text) }
        var lines = ["File,Status,Reason,Output,Original unchanged"]
        for item in report.items {
            let (status, reason): (String, String) = switch item.status {
            case .done: ("done", item.note ?? "")
            case let .skipped(why): ("skipped", why)
            case let .failed(why): ("failed", why)
            }
            lines.append([quote(item.input.lastPathComponent), status, quote(reason), quote(item.output?.lastPathComponent ?? ""), item.inputUnchanged ? "yes" : "no"].joined(separator: ","))
        }
        if report.cancelled { lines.append("\"(stopped — run again with the same files and folder to continue)\",,,,") }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - The command

@MainActor
enum BatchFileCommand {

    static let inputPanelIdentifier = "batch.chooseInputs"
    static let stepsIdentifier = "batch.steps"
    static let outputPanelIdentifier = "batch.chooseOutput"
    static let refusalIdentifier = "batch.refused"
    static let resultNoteID = UUID(uuidString: "5A3E1C29-7B4D-4E68-9F10-2B8C6D4E7A91")!

    /// The run in progress, so Stop Processing can cancel it.
    private(set) static var running: Task<Void, Never>?
    /// Which run ``running`` is, so a finishing run clears the handle only when it is still its
    /// own (R-023).
    private static var runningID: UUID?

    /// Whether a run is in progress: what enables Stop Processing PDF Files.
    static var isRunning: Bool { running != nil }

    /// The steps chooser, as an alert accessory.
    final class StepsAccessory: NSView {
        let searchable = NSButton(checkboxWithTitle: NSLocalizedString("Make searchable (recognise text on this Mac)", comment: "Batch step"), target: nil, action: nil)
        let reduce = NSButton(checkboxWithTitle: NSLocalizedString("Reduce file size, pictures to 150 dpi", comment: "Batch step"), target: nil, action: nil)
        let sanitize = NSButton(checkboxWithTitle: NSLocalizedString("Remove scripts, attachments and metadata", comment: "Batch step"), target: nil, action: nil)
        let flatten = NSButton(checkboxWithTitle: NSLocalizedString("Burn in the files' own annotations and form fields", comment: "Batch step"), target: nil, action: nil)
        let protect = NSButton(checkboxWithTitle: NSLocalizedString("Protect with a permissions password", comment: "Batch step"), target: nil, action: nil)
        let password = NSSecureTextField(frame: .zero)
        let beside = NSButton(checkboxWithTitle: NSLocalizedString("Write beside the originals", comment: "Batch option"), target: nil, action: nil)

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
            reduce.state = .on
            password.placeholderString = NSLocalizedString("Permissions password", comment: "Batch protect password placeholder")
            password.setAccessibilityLabel(password.placeholderString ?? "")
            for box in [searchable, reduce, sanitize, flatten, protect, beside] { box.setAccessibilityLabel(box.title) }
            let stack = NSStackView(views: [searchable, reduce, sanitize, flatten, protect, password, beside])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.frame = bounds
            stack.autoresizingMask = [.width, .height]
            addSubview(stack)
            password.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Why the chosen steps cannot run, said before the output folder is asked for; `nil`
        /// when they can. Protect ticked with no password used to write *unprotected* copies
        /// and report them done, and a run with nothing ticked was refused only after the
        /// folder had been chosen (R-025).
        var refusal: String? {
            if protect.state == .on, password.stringValue.isEmpty {
                return NSLocalizedString(
                    "Type a permissions password, or untick “Protect with a permissions password”.",
                    comment: "Batch refusal: protect is ticked with no password"
                )
            }
            if steps.isEmpty { return BatchFileProcessor.Refusal.noSteps.description }
            return nil
        }

        var steps: BatchFileProcessor.Steps {
            var steps = BatchFileProcessor.Steps()
            steps.makeSearchable = searchable.state == .on
            steps.reduceSize = reduce.state == .on
            steps.pictureDPI = reduce.state == .on ? 150 : nil
            steps.removeHiddenContent = sanitize.state == .on
            steps.flattenAnnotations = flatten.state == .on
            if protect.state == .on, !password.stringValue.isEmpty {
                steps.protection = .init(openPassword: "", permissionsPassword: password.stringValue, printing: 2,
                                         allowsChanges: false, allowsCopying: true, allowsAnnotating: true)
            }
            return steps
        }
    }

    static func resultNote(_ report: BatchFileProcessor.Report, folder: URL, now: Date = Date()) -> AppWarning {
        // "The originals are unchanged" only when the report says so of every file (S-019): an
        // original that changed while it was processed is named instead, as the CSV report
        // marks it.
        let changed = report.items.filter { !$0.inputUnchanged }.map(\.input.lastPathComponent)
        let originals = changed.isEmpty
            ? NSLocalizedString("the originals are unchanged", comment: "Batch result detail: every original is as it was")
            : String(
                format: NSLocalizedString("these originals changed while they were processed: %@", comment: "Batch result detail: originals that changed; the file names"),
                changed.joined(separator: ", ")
            )
        // A done file with pages that could not be read is said here too, not only in the CSV
        // (V-078): "3 done" alone read as three fully searchable files.
        let incomplete = report.items.filter { $0.status == .done && $0.note != nil }.map(\.input.lastPathComponent)
        let incompleteDetail = incomplete.isEmpty ? "" : " " + String(
            format: NSLocalizedString(
                "Some pages of these files could not be read for text: %@. The report names the pages.",
                comment: "Batch result detail: done files with pages Make Searchable could not read; the file names"
            ),
            incomplete.joined(separator: ", ")
        )
        return AppWarning(
            id: resultNoteID,
            severity: report.failed > 0 || !changed.isEmpty || !incomplete.isEmpty ? .warning : .info,
            title: report.cancelled
                ? NSLocalizedString("Processing stopped.", comment: "Batch result headline: cancelled")
                : NSLocalizedString("PDF files processed.", comment: "Batch result headline"),
            message: String(
                format: NSLocalizedString(
                    "%1$lld done, %2$lld skipped, %3$lld failed; %4$@. The report “%5$@” is in “%6$@”.",
                    comment: "Batch result detail; done, skipped, failed, the originals' state, report name, folder"
                ),
                Int64(report.done), Int64(report.skipped), Int64(report.failed), originals, BatchFileProcessor.reportFileName, folder.lastPathComponent
            ) + incompleteDetail
                + (report.cancelled ? " " + NSLocalizedString("Choose the same files and folder again to continue.", comment: "Batch result: resume hint") : ""),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// The qpdf step through the repair service.
    static let serviceTransform: @Sendable (URL, URL, RepairWireTransform) async throws -> Void = { input, output, request in
        let client = await DamagedDrawingRepair.client
        _ = try await client.transform(input: input, output: output, password: nil, transform: request)
    }

    /// Tools ▸ Process PDF Files…. With no project window (`controller` `nil`, T-009) every
    /// panel and alert is app-modal.
    static func present(controller: ProjectWindowController?, document: ZenitPDFProjectDocument?) {
        let window = controller?.window
        // One run at a time: a second one used to cancel the first and take its Stop handle,
        // which the first then cleared when it finished, so Stop reached nothing (R-023).
        guard !isRunning else {
            refuse(alreadyRunningMessage, window: window)
            return
        }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.allowedContentTypes = [.pdf, .folder]
        open.message = NSLocalizedString("Choose PDF files, or folders of them, to process.", comment: "Batch input panel message")
        ZenitModalPresenter.runOpenPanel(open, identifier: inputPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(inputs) = answer, !inputs.isEmpty else { return }
            let accessory = StepsAccessory()
            let alert = NSAlert()
            alert.messageText = stepsHeadline(fileCount: BatchFileProcessor.expand(inputs).count)
            alert.informativeText = NSLocalizedString("Each file is processed on its own and written to a folder you choose next. The originals are never changed.", comment: "Batch steps detail")
            alert.accessoryView = accessory
            alert.addButton(withTitle: NSLocalizedString("Choose Output Folder…", comment: "Batch steps: continue"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button: cancel"))
            ZenitModalPresenter.runAlert(alert, identifier: stepsIdentifier, sheetedOn: window, answerWithoutAUser: .button(1)) { choice in
                guard choice.buttonIndex == 0 else { return }
                chooseOutputFolder(inputs: inputs, accessory: accessory, document: document, window: window)
            }
        }
    }

    /// After the steps were confirmed: refuse steps that cannot run, then ask for the folder.
    static func chooseOutputFolder(inputs: [URL], accessory: StepsAccessory, document: ZenitPDFProjectDocument?, window: NSWindow?) {
        if let refusal = accessory.refusal {
            refuse(refusal, window: window)
            return
        }
        let steps = accessory.steps
        let beside = accessory.beside.state == .on
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseDirectories = true
        folderPanel.canChooseFiles = false
        folderPanel.canCreateDirectories = true
        folderPanel.message = NSLocalizedString("Choose the folder the processed files go to.", comment: "Batch output panel message")
        ZenitModalPresenter.runOpenPanel(folderPanel, identifier: outputPanelIdentifier, sheetedOn: window) { picked in
            guard case let .urls(folders) = picked, let folder = folders.first else { return }
            start(inputs: inputs, steps: steps, folder: folder, beside: beside, document: document, window: window)
        }
    }

    /// The steps confirmation's headline (L-48): "Process 1 PDF file?", "Process 3 PDF files?".
    static func stepsHeadline(fileCount: Int) -> String {
        LocalizedPlural.string(
            "Process %lld PDF files?",
            count: fileCount,
            one: NSLocalizedString("Process %lld PDF file?", comment: "Batch steps headline, one file; file count"),
            other: NSLocalizedString("Process %lld PDF files?", comment: "Batch steps headline; file count")
        )
    }

    static var alreadyRunningMessage: String {
        NSLocalizedString(
            "PDF files are already being processed. Wait for that run to finish, or choose Tools ▸ Stop Processing PDF Files first.",
            comment: "Batch refusal: a run is already in progress"
        )
    }

    static func refuse(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The PDF files were not processed", comment: "Batch refusal headline")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button: OK"))
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
    }

    /// Starts a run. Refused, answering `false`, while another run is in progress.
    @discardableResult
    static func start(
        inputs: [URL],
        steps: BatchFileProcessor.Steps,
        folder: URL,
        beside: Bool,
        document: ZenitPDFProjectDocument?,
        window: NSWindow?,
        transform: @escaping @Sendable (URL, URL, RepairWireTransform) async throws -> Void = serviceTransform
    ) -> Bool {
        guard !isRunning else {
            refuse(alreadyRunningMessage, window: window)
            return false
        }
        let id = UUID()
        runningID = id
        running = Task { @MainActor in
            defer {
                // Only this run's own handle: a finished run never clears another's (R-023).
                if runningID == id {
                    running = nil
                    runningID = nil
                }
            }
            do {
                let report = try await BatchFileProcessor.run(
                    inputs: inputs, steps: steps, outputFolder: folder, allowBesideInputs: beside,
                    transform: transform
                ) { done, total in
                    document?.core?.status.setActiveToolNote(String(
                        format: NSLocalizedString("Processing PDF files: %1$lld of %2$lld.", comment: "Batch progress; done, total"),
                        Int64(done), Int64(total)
                    ))
                }
                // The progress note comes down when the run ends, however it ends (S-019): it
                // kept saying "Processing PDF files: 3 of 12." after a finished or stopped run.
                document?.core?.status.setActiveToolNote(nil)
                let note = resultNote(report, folder: folder)
                if let core = document?.core {
                    core.document.post(note)
                } else {
                    // Started with no project open (T-009): there is no tray to note it in.
                    showResult(note, window: window)
                }
            } catch {
                document?.core?.status.setActiveToolNote(nil)
                ZenitErrorPresenter.present(error, in: window)
            }
        }
        return true
    }

    static let resultIdentifier = "batch.result"

    /// The result as an alert, for a run with no document to note it in.
    static func showResult(_ note: AppWarning, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = note.severity == .warning ? .warning : .informational
        alert.messageText = note.title
        alert.informativeText = note.message
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Button: OK"))
        ZenitModalPresenter.runAlert(alert, identifier: resultIdentifier, sheetedOn: window, answerWithoutAUser: .button(0)) { _ in }
    }

    /// Tools ▸ Stop Processing PDF Files.
    static func stop() {
        running?.cancel()
    }
}

extension BatchFileProcessor.Refusal: LocalizedError {
    var errorDescription: String? { description }
}
