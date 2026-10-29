import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFExtensions
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Packs in the app (NL-PLAT-23, phase 1): Tools ▸ Install Pack…, a `.zpdfpack` opened from
/// Finder, and Tools ▸ Create Pack… from the person's own library.
///
/// A pack installs through the validators each format already has — ``ToolSetImportValidator``
/// for tool sets, ``JobTemplateFile`` for templates, ``LedgerExportProfile/read(_:)`` for
/// profiles — and nothing in it executes. The review names every file and what it will do before
/// anything is written; one member that fails its validator refuses the pack.
@MainActor
enum ZenitPackFlow {

    static let chooserIdentifier = "pack.choose"
    static let reviewIdentifier = "pack.review"
    static let saveIdentifier = "pack.save"
    static let noteID = UUID(uuidString: "6B1E2D3C-4A5F-4E70-9C8B-7A6D5E4F3C2B")!

    static var packType: UTType {
        if let declared = UTType("com.zenitgroup.zenitpdf.pack"), declared.isDeclared { return declared }
        return UTType(filenameExtension: ZenitPack.fileExtension, conformingTo: .zip) ?? .zip
    }

    /// A pack after every member passed its own validator: what installing it would do.
    struct Plan: Equatable {
        let manifest: ZenitPack.Manifest
        let templates: [JobTemplate]
        let profiles: [LedgerExportProfile]
        /// Each tool set's bytes, already validated, in pack order.
        let toolSets: [(fileName: String, data: Data, toolCount: Int)]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.manifest == rhs.manifest && lhs.templates == rhs.templates && lhs.profiles == rhs.profiles
                && lhs.toolSets.map(\.fileName) == rhs.toolSets.map(\.fileName)
        }
    }

    enum PlanError: Error, Equatable, CustomStringConvertible {
        case pack(ZenitPack.ReadError)
        case member(file: String, reason: String)

        var description: String {
            switch self {
            case let .pack(error): return error.description
            case let .member(file, reason):
                return String(format: NSLocalizedString("“%1$@” in the pack was refused: %2$@", comment: "Pack member refused; file name, reason"), file, reason)
            }
        }
    }

    /// Reads a pack and runs every member through its validator. Pure: no panel, no store.
    nonisolated static func plan(_ data: Data) throws -> Plan {
        let pack: ZenitPack
        do { pack = try ZenitPack.read(data) } catch let error as ZenitPack.ReadError { throw PlanError.pack(error) }
        var templates: [JobTemplate] = []
        var profiles: [LedgerExportProfile] = []
        var toolSets: [(String, Data, Int)] = []
        for item in pack.items {
            switch item.kind {
            case .jobTemplate:
                do { templates.append(try JobTemplateFile.read(item.data)) } catch {
                    throw PlanError.member(file: item.fileName, reason: (error as? CustomStringConvertible)?.description ?? error.localizedDescription)
                }
            case .exportProfile:
                do { profiles.append(try LedgerExportProfile.read(item.data)) } catch {
                    throw PlanError.member(file: item.fileName, reason: (error as? CustomStringConvertible)?.description ?? error.localizedDescription)
                }
            case .toolSet:
                switch ToolSetImportValidator().review(data: item.data, fileName: item.fileName) {
                case let .success(review):
                    guard review.isSafeToImport else {
                        throw PlanError.member(file: item.fileName, reason: NSLocalizedString("the tool set review says it is not safe to import", comment: "Pack member refusal: unsafe tool set"))
                    }
                    toolSets.append((item.fileName, item.data, review.presets.count))
                case let .failure(error):
                    throw PlanError.member(file: item.fileName, reason: error.technicalDetail ?? error.subject ?? item.fileName)
                }
            }
        }
        return Plan(manifest: pack.manifest, templates: templates, profiles: profiles, toolSets: toolSets)
    }

    /// The review's text: who made the pack, what each file will do, and that nothing runs.
    static func reviewText(_ plan: Plan) -> (title: String, body: String) {
        let title = String(format: NSLocalizedString("Install the pack “%1$@” (version %2$@)?", comment: "Pack review title; name, version"),
                           plan.manifest.name, plan.manifest.version)
        var lines: [String] = []
        if let author = plan.manifest.author, !author.isEmpty {
            lines.append(String(format: NSLocalizedString("Made by %@.", comment: "Pack review: author"), author))
        }
        if let summary = plan.manifest.summary, !summary.isEmpty { lines.append(summary) }
        lines.append("")
        for set in plan.toolSets {
            lines.append(String(format: NSLocalizedString("Tool set “%1$@”: %2$d tools, reviewed in the Tool Library before they are added.", comment: "Pack review line; file, count"), set.fileName, set.toolCount))
        }
        for template in plan.templates {
            lines.append(String(format: NSLocalizedString("Job template “%@”.", comment: "Pack review line; template name"), template.name))
        }
        for profile in plan.profiles {
            lines.append(String(format: NSLocalizedString("Export profile “%@”.", comment: "Pack review line; profile name"), profile.name))
        }
        lines.append("")
        lines.append(NSLocalizedString("A pack holds tool sets, templates and export profiles only. Nothing in it runs, and nothing already drawn changes.", comment: "Pack review: posture"))
        return (title, lines.joined(separator: "\n"))
    }

    /// Tools ▸ Install Pack…: choose a file, then the review.
    static func chooseAndReview(document: ZenitPDFProjectDocument?, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [packType]
        panel.allowsMultipleSelection = false
        ZenitModalPresenter.runOpenPanel(panel, identifier: chooserIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in await review(url, window: window, document: document) }
        }
    }

    /// The review, and on Install the install. Returns what was installed, for tests.
    @discardableResult
    static func review(_ url: URL, window: NSWindow?, document: ZenitPDFProjectDocument?) async -> Installed? {
        let plan: Plan
        do {
            let data = try Data(contentsOf: url)
            plan = try await Task.detached(priority: .userInitiated) { try Self.plan(data) }.value
        } catch {
            ZenitErrorPresenter.present(error, in: window)
            return nil
        }
        let text = reviewText(plan)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.addButton(withTitle: NSLocalizedString("Install", comment: "Pack review: install"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Pack review: cancel"))
        let confirmed: Bool = await withCheckedContinuation { continuation in
            ZenitModalPresenter.runAlert(alert, identifier: reviewIdentifier, sheetedOn: window) { answer in
                continuation.resume(returning: answer.buttonIndex == 0)
            }
        }
        guard confirmed else { return nil }
        return await install(plan, document: document)
    }

    struct Installed: Equatable {
        var templates: [String] = []
        var profiles: [String] = []
        var toolSetsReviewed: Int = 0
    }

    /// Installs the templates and profiles, and puts the tool sets on the Tool Library's review
    /// (one review for all of them) when a drawing is open.
    static func install(_ plan: Plan, document: ZenitPDFProjectDocument?) async -> Installed {
        var installed = Installed()
        let store = ProjectWindowController.jobTemplateStore()
        if !plan.templates.isEmpty {
            var templates = (try? await store.read()) ?? []
            for var template in plan.templates {
                // A pack's newer copy of a template replaces the one of the same name: that is
                // what an office pack is for. The person saw the name in the review.
                templates = ProjectWindowController.mergeImportedTemplate(
                    &template, into: templates,
                    choice: templates.contains { $0.name == template.name } ? .replace : .add)
                installed.templates.append(template.name)
            }
            try? await store.write(templates)
        }
        let library = ExportProfileLibrary.standard()
        for profile in plan.profiles where (try? library.install(profile)) != nil {
            installed.profiles.append(profile.name)
        }
        if let document, !plan.toolSets.isEmpty, let merged = mergedToolSet(plan.toolSets.map(\.data), name: plan.manifest.name) {
            let model: ToolLibraryEditingModel? = ToolChestPanel.open[ObjectIdentifier(document)]?.model
                ?? (document.windowControllers.first as? ProjectWindowController)?.presentToolLibrary(for: document)?.model
            if let model {
                await model.reviewImport(data: merged, fileName: plan.manifest.name + "." + ZenitPack.fileExtension)
                installed.toolSetsReviewed = plan.toolSets.count
            }
        }
        var parts: [String] = []
        if !installed.templates.isEmpty { parts.append(String(format: NSLocalizedString("%d job templates", comment: "Pack installed: templates count"), installed.templates.count)) }
        if !installed.profiles.isEmpty { parts.append(String(format: NSLocalizedString("%d export profiles", comment: "Pack installed: profiles count"), installed.profiles.count)) }
        if installed.toolSetsReviewed > 0 { parts.append(String(format: NSLocalizedString("%d tool sets to review", comment: "Pack installed: tool sets count"), installed.toolSetsReviewed)) }
        if !plan.toolSets.isEmpty, document == nil {
            parts.append(NSLocalizedString("open a drawing and install the pack again to add its tools", comment: "Pack installed with no drawing open"))
        }
        document?.core?.document.post(AppWarning(
            id: noteID, severity: .info,
            title: String(format: NSLocalizedString("Installed the pack “%@”", comment: "Status note after installing a pack; name"), plan.manifest.name),
            message: parts.joined(separator: ", "),
            source: NSLocalizedString("Pack", comment: "Status note source for packs"),
            isDismissible: true, timestamp: Date()))
        return installed
    }

    /// Several tool set files as one: the first file's header, every file's presets in order.
    /// The result goes through the same validator as any imported file, so the merge trusts
    /// nothing it copies.
    nonisolated static func mergedToolSet(_ files: [Data], name: String) -> Data? {
        guard var root = files.first.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return nil }
        guard files.count > 1 else { return files.first }
        var presets: [Any] = []
        for file in files {
            guard let object = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
                  let list = object["presets"] as? [Any] else { return nil }
            presets.append(contentsOf: list)
        }
        root["presets"] = presets
        root["name"] = name
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: - Create Pack…

    /// Tools ▸ Create Pack…: the person's job templates, installed export profiles and the open
    /// project's My Tools, as one file a colleague installs.
    ///
    /// L-67: the pack was named after the open document ("Form.zpdfpack", pack name
    /// "Form") with no say in it, and it carried the Settings author's full name ("Made by …")
    /// without asking — a name meant for markups. Now the save panel's name is the pack's name,
    /// proposed as "My library", and the author is written only when the person ticks the panel's
    /// "Name me as the author" box, which starts unticked. Nothing is offered when there is
    /// nothing to pack: the note says so before any panel.
    static func createPack(document: ZenitPDFProjectDocument?, window: NSWindow?) {
        Task { @MainActor in
            let hasContents: Bool
            do {
                hasContents = try await packContents(author: nil, document: document) != nil
            } catch {
                ZenitErrorPresenter.present(error, in: window)
                return
            }
            guard hasContents else {
                document?.core?.document.post(AppWarning(
                    id: noteID, severity: .info,
                    title: NSLocalizedString("Nothing to put in a pack yet", comment: "Create Pack with an empty library: title"),
                    message: NSLocalizedString("Save a job template, install an export profile or make a tool first.", comment: "Create Pack with an empty library: detail"),
                    source: NSLocalizedString("Pack", comment: "Status note source for packs"), isDismissible: true, timestamp: Date()))
                return
            }
            let author = AuthorIdentity.current()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [packType]
            panel.nameFieldStringValue = defaultPackName + "." + ZenitPack.fileExtension
            panel.message = NSLocalizedString(
                "The file's name is the pack's name, as a colleague sees it when they install it.",
                comment: "Create Pack save panel message"
            )
            let nameMe = authorCheckbox(author: author)
            panel.accessoryView = nameMe
            ZenitModalPresenter.runSavePanel(panel, identifier: saveIdentifier, sheetedOn: window) { answer in
                guard let url = answer.firstURL else { return }
                let includeAuthor = nameMe.state == .on
                Task { @MainActor in
                    do {
                        try await writePack(to: url, author: includeAuthor ? author : nil, document: document)
                    } catch {
                        ZenitErrorPresenter.present(error, in: window)
                    }
                }
            }
        }
    }

    /// The name Create Pack proposes (L-67), where it proposed the open document's.
    static var defaultPackName: String { NSLocalizedString("My library", comment: "Default pack name") }

    /// The save panel's "Name me as the author" box (L-67): unticked, so a pack names its author
    /// only when the person chooses to.
    static func authorCheckbox(author: String) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: String(
                format: NSLocalizedString("Name me as the author (%@)", comment: "Create Pack option: write the Settings author name into the pack; the name"),
                author
            ),
            target: nil, action: nil
        )
        box.state = .off
        box.setAccessibilityHelp(NSLocalizedString(
            "When ticked, the pack says who made it. Your name is not written otherwise.",
            comment: "Accessibility help of the Create Pack author option"
        ))
        box.sizeToFit()
        return box
    }

    /// Writes the pack to `url`, named after the file the person chose (L-67). The half of
    /// Create Pack after the panel, and the half worth asserting.
    static func writePack(to url: URL, author: String?, document: ZenitPDFProjectDocument?) async throws {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try await buildPack(name: name.isEmpty ? defaultPackName : name, author: author, document: document) else { return }
        try data.write(to: url, options: .atomic)
    }

    /// The pack bytes, or `nil` when there is nothing to pack. `author` is written into the pack
    /// — its manifest and its tool set — only when given (L-67).
    static func buildPack(name: String, author: String?, document: ZenitPDFProjectDocument?) async throws -> Data? {
        guard let contents = try await packContents(author: author, document: document) else { return nil }
        let manifest = ZenitPack.Manifest(name: name, version: "1", author: author, summary: nil, items: contents.items)
        return try ZenitPack.write(manifest: manifest, files: contents.files)
    }

    /// What a pack of the person's library holds, or `nil` when there is nothing to pack.
    static func packContents(author: String?, document: ZenitPDFProjectDocument?) async throws -> (items: [ZenitPack.Manifest.Item], files: [String: Data])? {
        var items: [ZenitPack.Manifest.Item] = []
        var files: [String: Data] = [:]
        func add(_ kind: ZenitPack.ItemKind, name: String, data: Data) {
            var path = ZenitPack.suggestedPath(kind: kind, name: name)
            var counter = 2
            while files[path] != nil {
                path = ZenitPack.suggestedPath(kind: kind, name: "\(name) \(counter)")
                counter += 1
            }
            items.append(.init(path: path, kind: kind))
            files[path] = data
        }
        for template in (try? await ProjectWindowController.jobTemplateStore().read()) ?? [] {
            add(.jobTemplate, name: template.name, data: try JobTemplateFile.export(template))
        }
        for profile in ExportProfileLibrary.standard().profiles().profiles {
            add(.exportProfile, name: profile.name, data: try profile.encoded())
        }
        if let presets = document?.core?.toolLibrary.presets.filter({ $0.panel == .myTools }), !presets.isEmpty {
            let model = ToolLibraryEditingModel(presets: presets)
            let set = model.exportDocument(panel: .myTools, name: ToolLibraryPanel.myTools.displayName, author: author)
            add(.toolSet, name: ToolLibraryPanel.myTools.displayName, data: try set.jsonData())
        }
        guard !items.isEmpty else { return nil }
        return (items, files)
    }
}
