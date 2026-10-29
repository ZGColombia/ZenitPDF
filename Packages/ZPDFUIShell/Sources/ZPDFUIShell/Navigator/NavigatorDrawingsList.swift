import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Every open drawing, as a clickable thumbnail — the Navigator's Drawings section.
///
/// With thirty one-page drawings open, a list on the left that shows every open drawing the way
/// Pages shows pages — scroll to it, click it, and that drawing is in front — is the quickest way
/// to move between them.
///
/// Three decisions:
///
///   * Clicking a row goes through **`tabBar.onSelect`** — the exact hook the tab strip uses and
///     the application tier rewires to its real document switch. A second path that called the
///     presenter directly would switch the summary and not the window.
///   * A drawing with unsaved work carries the same dot the tab carries. A list of drawings is a
///     place work gets lost from otherwise.
///   * There is **no close control here**. The tab asks before discarding work; a grid that also
///     closed would be a second door to lose it, with no room for the question.
struct NavigatorDrawingsList: View {

    let environment: ProjectShellEnvironment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: ZPDFSpacing.xs) {
                    ForEach(environment.document.tabs) { tab in
                        NavigatorDrawingRow(
                            tab: tab,
                            thumbnails: environment.drawingThumbnails
                        ) {
                            environment.tabBar.onSelect?(tab.id)
                        }
                        .id(tab.id)
                    }
                }
                .padding(ZPDFSpacing.s)
            }
            // Each tab switch rebuilds this list from scratch, which reset it to the TOP —
            // clicking a drawing far down lost the place every time (LT-2, 2026-08-29). Landing
            // on the ACTIVE drawing beats
            // restoring a raw offset: the list always shows where you actually are.
            .onAppear {
                if let active = environment.document.activeTabID {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
            // …and keeps doing so while the list stays on screen (IM-124): a switch from the tab
            // strip or the Window menu moved the front drawing out of view here.
            .onChange(of: environment.document.activeTabID) { _, active in
                guard let active else { return }
                withAnimation(ZPDFMotion.animation(.standard, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Open drawings",
            comment: "Accessibility label for the open-drawings list"
        )))
    }
}

/// One drawing as a card, in the page cards' language (2026-09-23 mockup): its first sheet on
/// the left; its name, its page count and its unsaved dot on the right; the drawing in front
/// raised and framed in the accent.
private struct NavigatorDrawingRow: View {

    let tab: DocumentTabSummary
    let thumbnails: NavigatorThumbnailLoader
    let onOpen: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = NavigatorPageCard.appearance(isCurrent: tab.isActive, isSelected: false, isHovered: isHovered)
        let shape = RoundedRectangle(cornerRadius: NavigatorStyle.cardRadius, style: .continuous)
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: ZPDFSpacing.l) {
                sheet
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: ZPDFSpacing.xs) {
                        if tab.hasUnsavedChanges {
                            Circle()
                                .fill(ZPDFColor.color(NavigatorStyle.indicator))
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(tab.title)
                            .zpdfText(.rowLabel.withWeight(.medium), .textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if tab.pageCount > 0 {
                        Text(NavigatorDrawingsList.pageCountText(tab.pageCount))
                            .zpdfText(.rowLabel, .textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .padding(NavigatorStyle.cardPadding)
            .frame(maxWidth: .infinity, minHeight: NavigatorStyle.cardHeight, alignment: .leading)
            .background {
                ZStack {
                    if let base = look.base { shape.fill(ZPDFColor.color(base)) }
                    if let tint = look.tint { shape.fill(ZPDFColor.color(tint).opacity(look.tintOpacity)) }
                }
            }
            .overlay {
                if let border = look.border {
                    shape.strokeBorder(ZPDFColor.color(border), lineWidth: look.borderWidth)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ZPDFMotion.animation(.micro, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
        .zpdfAnimation(NavigatorStyle.motion, value: look)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: NavigatorStyle.cardRadius)
        .accessibilityLabel(Text(tab.accessibilityLabel))
        .accessibilityAddTraits(tab.isActive ? [.isSelected, .isButton] : .isButton)
        .help(tab.fileName)
    }

    @ViewBuilder
    private var sheet: some View {
        let box = NavigatorStyle.thumbnailSize
        let paper = RoundedRectangle(cornerRadius: ZPDFRadius.hairline, style: .continuous)
        Group {
            if let image = thumbnails.image(for: tab.id) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .background(NavigatorStyle.paper)
                    .clipShape(paper)
                    .overlay { paper.strokeBorder(ZPDFColor.color(NavigatorStyle.hairline), lineWidth: ZPDFStroke.regular) }
            } else {
                // The placeholder: a paper-toned sheet, as the page cards draw it, filled in when
                // the render lands. A failure stays a placeholder; never fatal, never an alert.
                paper
                    .fill(NavigatorStyle.paper)
                    .aspectRatio(0.7071, contentMode: .fit)
                    .overlay {
                        ZPDFGlyphView(.symbol(.pages), size: ZPDFSpacing.Control.iconLarge)
                            .foregroundStyle(ZPDFColor.color(.textTertiary, variant: .light))
                    }
                    .overlay { paper.strokeBorder(ZPDFColor.color(NavigatorStyle.hairline), lineWidth: ZPDFStroke.regular) }
            }
        }
        .frame(maxWidth: box.width, maxHeight: box.height)
        .frame(width: box.width, height: box.height)
        .accessibilityHidden(true)
        // `pageCount` moves 0 → n when the drawing finishes loading, which re-runs the task
        // and turns the placeholder into the sheet without anyone refreshing anything.
        .task(id: NavigatorThumbnailTaskKey(
            subject: tab.id,
            providerRevision: thumbnails.providerRevision,
            pageCount: tab.pageCount
        )) { await thumbnails.request(id: tab.id) }
    }
}

extension NavigatorDrawingsList {

    /// "1 page", "6 pages" — the drawing card's second line.
    static func pageCountText(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld pages",
            count: count,
            one: NSLocalizedString("%lld page", comment: "Open Drawings card: page count, singular"),
            other: NSLocalizedString("%lld pages", comment: "Open Drawings card: page count, plural")
        )
    }
}
