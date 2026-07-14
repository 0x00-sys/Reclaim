import SwiftUI
import ReclaimKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var categoryFilter: StorageCategory?
    @State private var safetyFilter: Safety?
    @State private var searchText = ""
    @State private var expandedItem: String?
    @State private var confirmingCleanup = false
    @State private var showingResults = false
    @State private var excludedTools: Set<Tool> = []
    @AppStorage("showSmallItems") private var showSmallItems = false
    @AppStorage("minIdleSeconds") private var minIdleSeconds = 0.0

    static let smallItemThreshold: Int64 = 10_000_000 // 10 MB

    var matchingItems: [ScanItem] {
        let idleCutoff = minIdleSeconds > 0 ? Date.now.addingTimeInterval(-minIdleSeconds) : nil
        return model.items.filter { item in
            (categoryFilter == nil || item.category == categoryFilter)
                && (safetyFilter == nil || item.safety == safetyFilter)
                && !excludedTools.contains(item.tool)
                // Recently touched things are excluded from view AND from cleaning.
                && (idleCutoff == nil || item.lastActivity == nil || item.lastActivity! <= idleCutoff!)
                && (searchText.isEmpty
                    || item.displayName.localizedCaseInsensitiveContains(searchText)
                    || item.path.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Items below the threshold are noise; stale registrations stay visible
    /// because they are zero bytes by nature but real repo hygiene.
    var filteredItems: [ScanItem] {
        guard !showSmallItems else { return matchingItems }
        return matchingItems.filter { item in
            item.worktree?.isPrunable == true
                || item.sizeBytes == nil
                || item.sizeBytes! >= Self.smallItemThreshold
        }
    }

    var hiddenSmallCount: Int { matchingItems.count - filteredItems.count }

    /// What the one-click Clean button would remove: only Safe items among the
    /// currently filtered set. Review/Protected/Unknown are never auto-included.
    var filteredSafeBytes: Int64 {
        filteredItems.filter { $0.safety == .safe }.compactMap(\.sizeBytes).reduce(0, +)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.items.isEmpty && !model.isScanning {
                HeroCard(filteredSafeBytes: 0, onCleanSafe: {})
                    .frame(maxWidth: 560)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        HeroCard(filteredSafeBytes: filteredSafeBytes, onCleanSafe: {
                            model.selection = Set(filteredItems.filter { $0.safety == .safe }.map(\.id))
                            confirmingCleanup = true
                        })
                        FilterBar(categoryFilter: $categoryFilter,
                                  safetyFilter: $safetyFilter,
                                  excludedTools: $excludedTools,
                                  minIdleSeconds: $minIdleSeconds)
                        ItemCardList(items: filteredItems, expandedItem: $expandedItem,
                                     onCleanSingle: { item in
                                         model.selection = [item.id]
                                         confirmingCleanup = true
                                     })
                        if hiddenSmallCount > 0 || showSmallItems {
                            HoverTextButton(title: showSmallItems
                                            ? "Hide small items"
                                            : "Show \(hiddenSmallCount) small item\(hiddenSmallCount == 1 ? "" : "s") under 10 MB") {
                                showSmallItems.toggle()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 72)
                }
            }
            SelectionBar(onClean: { confirmingCleanup = true })
        }
        .background(.background.secondary)
        .frame(minWidth: 720, minHeight: 480)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by name or path")
        .navigationTitle("Reclaim")
        .task {
            // Launch argument for scripted runs: open Reclaim.app --args -scanOnLaunch YES
            if UserDefaults.standard.bool(forKey: "scanOnLaunch"), model.items.isEmpty, !model.isScanning {
                model.scan()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isScanning {
                    Button("Stop", systemImage: "stop.circle") { model.cancelScan() }
                        .help("Stop the current scan")
                        .pointerStyle(.link)
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.scan() }
                        .help("Scan for reclaimable development storage")
                        .pointerStyle(.link)
                }
            }
        }
        .sheet(isPresented: $confirmingCleanup) {
            CleanupConfirmationView(items: cleanableSelection, excluded: excludedSelection) {
                let toClean = cleanableSelection
                confirmingCleanup = false
                Task {
                    await model.clean(toClean)
                    showingResults = true
                }
            }
        }
        .sheet(isPresented: $showingResults) {
            CleanupResultsView(results: model.cleanupResults)
        }
    }

    var cleanableSelection: [ScanItem] {
        model.selectedItems.filter { $0.safety == .safe || $0.safety == .review }
    }

    var excludedSelection: [ScanItem] {
        model.selectedItems.filter { $0.safety == .protected || $0.safety == .unknown }
    }
}

// MARK: - Hero

struct HeroCard: View {
    @Environment(AppModel.self) private var model
    var filteredSafeBytes: Int64
    var onCleanSafe: () -> Void

    var body: some View {
        Group {
            if model.items.isEmpty && !model.isScanning {
                VStack(spacing: 14) {
                    PixelSpriteView(palette: .blue)
                        .frame(width: 96, height: 64)
                    Text("Find your lost gigabytes")
                        .font(.title.weight(.semibold))
                    Text("Worktrees, node_modules, caches, and AI agent leftovers.\nNothing is deleted without asking you first.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Scan Now") { model.scan() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .pointerStyle(.link)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                HStack(spacing: 18) {
                    ReclaimGauge(safe: model.safeBytes, total: model.totalBytes, isScanning: model.isScanning)
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model.safeBytes.formattedBytes)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("safe to clean")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 5) {
                            Text(model.totalBytes.formattedBytes + " found")
                            DotSeparator()
                            Text("\(model.items.count) items")
                            if let date = model.lastScanDate, !model.isScanning {
                                DotSeparator()
                                Text("scanned \(date.formatted(.relative(presentation: .named)))")
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }

                    Spacer()

                    if model.isCleaning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.cleaningStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.opacity)
                        }
                    } else if model.isScanning {
                        Text(model.scanProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    } else if filteredSafeBytes > 0 {
                        Button {
                            onCleanSafe()
                        } label: {
                            Label("Clean \(filteredSafeBytes.formattedBytes)", systemImage: "trash")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .pointerStyle(.link)
                        .help("Move every item marked Safe in the current filter to the Trash")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct ReclaimGauge: View {
    let safe: Int64
    let total: Int64
    let isScanning: Bool

    private var fraction: Double {
        total > 0 ? Double(safe) / Double(total) : 0
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.green, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: fraction)
            if isScanning {
                ProgressView().controlSize(.small)
            } else {
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
        }
        .padding(4)
    }
}

struct DotSeparator: View {
    var body: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

// MARK: - Filter bar

/// One compact row of dropdown pills replacing the two chip rows.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var categoryFilter: StorageCategory?
    @Binding var safetyFilter: Safety?
    @Binding var excludedTools: Set<Tool>
    @Binding var minIdleSeconds: Double

    static let idleOptions: [(label: String, seconds: Double)] = [
        ("Any age", 0),
        ("Idle 1+ hour", 3_600),
        ("Idle 24+ hours", 86_400),
        ("Idle 3+ days", 3 * 86_400),
        ("Idle 7+ days", 7 * 86_400),
    ]

    private var presentTools: [Tool] {
        Tool.allCases.filter { tool in model.items.contains { $0.tool == tool } }
    }

    private var hasActiveFilter: Bool {
        categoryFilter != nil || safetyFilter != nil || !excludedTools.isEmpty || minIdleSeconds > 0
    }

    var body: some View {
        HStack(spacing: 8) {
            FilterPill(label: categoryFilter?.rawValue ?? "Everything",
                       icon: categoryFilter?.systemImage ?? "internaldrive",
                       isActive: categoryFilter != nil) {
                Button("Everything") { categoryFilter = nil }
                Divider()
                ForEach(StorageCategory.allCases) { category in
                    let bytes = model.items.filter { $0.category == category }.compactMap(\.sizeBytes).reduce(0, +)
                    if model.items.contains(where: { $0.category == category }) {
                        Toggle(isOn: Binding(
                            get: { categoryFilter == category },
                            set: { categoryFilter = $0 ? category : nil }
                        )) {
                            Label("\(category.rawValue)  ·  \(bytes.formattedBytes)", systemImage: category.systemImage)
                        }
                    }
                }
            }

            FilterPill(label: toolsLabel, icon: "app.connected.to.app.below.fill",
                       isActive: !excludedTools.isEmpty) {
                Button("Include all tools") { excludedTools = [] }
                Divider()
                ForEach(presentTools) { tool in
                    Toggle(isOn: Binding(
                        get: { !excludedTools.contains(tool) },
                        set: { included in
                            if included { excludedTools.remove(tool) } else { excludedTools.insert(tool) }
                        }
                    )) {
                        Text(tool.rawValue)
                    }
                }
            }

            FilterPill(label: safetyFilter?.rawValue ?? "Any status", icon: "checkmark.shield",
                       isActive: safetyFilter != nil) {
                Button("Any status") { safetyFilter = nil }
                Divider()
                ForEach(Safety.allCases) { safety in
                    let count = model.items.filter { $0.safety == safety }.count
                    if count > 0 {
                        Toggle(isOn: Binding(
                            get: { safetyFilter == safety },
                            set: { safetyFilter = $0 ? safety : nil }
                        )) {
                            Text("\(safety.rawValue)  ·  \(count)")
                        }
                    }
                }
            }

            FilterPill(label: idleLabel, icon: "clock",
                       isActive: minIdleSeconds > 0) {
                ForEach(Self.idleOptions, id: \.seconds) { option in
                    Toggle(isOn: Binding(
                        get: { minIdleSeconds == option.seconds },
                        set: { if $0 { minIdleSeconds = option.seconds } }
                    )) {
                        Text(option.label)
                    }
                }
            }

            if hasActiveFilter {
                HoverTextButton(title: "Reset") {
                    categoryFilter = nil
                    safetyFilter = nil
                    excludedTools = []
                    minIdleSeconds = 0
                }
            }
            Spacer()
        }
    }

    private var toolsLabel: String {
        switch excludedTools.count {
        case 0: "All tools"
        case 1: "No \(excludedTools.first!.rawValue)"
        default: "\(excludedTools.count) tools excluded"
        }
    }

    private var idleLabel: String {
        Self.idleOptions.first { $0.seconds == minIdleSeconds }?.label ?? "Any age"
    }
}

struct FilterPill<Content: View>: View {
    var label: String
    var icon: String
    var isActive: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.callout.weight(.medium))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.visible)
        .controlSize(.large)
        .tint(isActive ? .accentColor : nil)
        .fixedSize()
        .pointerStyle(.link)
    }
}


// MARK: - Item cards

struct ItemCardList: View {
    @Environment(AppModel.self) private var model
    let items: [ScanItem]
    @Binding var expandedItem: String?
    let onCleanSingle: (ScanItem) -> Void

    var body: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { item in
                ItemCard(
                    item: item,
                    isExpanded: expandedItem == item.id,
                    isSelected: model.selection.contains(item.id),
                    onToggleExpand: {
                        withAnimation(.smooth(duration: 0.25)) {
                            expandedItem = expandedItem == item.id ? nil : item.id
                        }
                    },
                    onToggleSelect: {
                        if model.selection.contains(item.id) {
                            model.selection.remove(item.id)
                        } else {
                            model.selection.insert(item.id)
                        }
                    },
                    onClean: { onCleanSingle(item) }
                )
            }
        }
    }
}

struct ItemCard: View {
    let item: ScanItem
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void
    let onClean: () -> Void

    private var selectable: Bool { item.safety == .safe || item.safety == .review }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!selectable)
                .opacity(selectable ? 1 : 0.25)
                .pointerStyle(.link)

                ToolIconView(tool: item.tool, category: item.category)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(item.tool.rawValue)
                        if let branch = item.worktree?.branch {
                            DotSeparator()
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                        } else if item.worktree != nil, item.worktree?.isPrunable != true {
                            DotSeparator()
                            Label("detached", systemImage: "arrow.triangle.branch")
                        }
                        if let date = item.lastActivity {
                            DotSeparator()
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(item.sizeBytes?.formattedBytes ?? "…")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                SafetyBadge(safety: item.safety)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onTapGesture(perform: onToggleExpand)

            if isExpanded {
                ItemDetail(item: item, onClean: onClean)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(.background, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06),
                              lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
    }
}

struct ToolIconView: View {
    let tool: Tool
    let category: StorageCategory

    var body: some View {
        if let icon = AppIconProvider.icon(for: tool) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            BrandBadge(tool: tool, category: category)
        }
    }
}

/// Faithful vector recreations of the real logos for tools that don't ship a
/// .app bundle we could borrow an icon from.
struct BrandBadge: View {
    let tool: Tool
    let category: StorageCategory

    var body: some View {
        switch tool {
        case .git: GitLogo()
        case .npm: NpmLogo()
        case .pnpm: PnpmLogo()
        case .claudeCode:
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34).gradient)
                .overlay {
                    Image(systemName: "asterisk")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
        default:
            RoundedRectangle(cornerRadius: 6)
                .fill(.gray.gradient)
                .overlay {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }
}

/// Git's rotated orange diamond with the commit/branch diagram.
struct GitLogo: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let brand = Color(red: 0.94, green: 0.32, blue: 0.20)
            var diamond = Path(roundedRect: CGRect(x: w * 0.15, y: w * 0.15, width: w * 0.7, height: w * 0.7),
                               cornerRadius: w * 0.12)
            diamond = diamond.applying(
                CGAffineTransform(translationX: w / 2, y: w / 2)
                    .rotated(by: .pi / 4)
                    .translatedBy(x: -w / 2, y: -w / 2)
            )
            context.fill(diamond, with: .color(brand))

            var line = Path()
            line.move(to: CGPoint(x: w * 0.38, y: w * 0.30))
            line.addLine(to: CGPoint(x: w * 0.38, y: w * 0.70))
            line.move(to: CGPoint(x: w * 0.40, y: w * 0.33))
            line.addLine(to: CGPoint(x: w * 0.62, y: w * 0.52))
            context.stroke(line, with: .color(.white), lineWidth: w * 0.07)

            for center in [CGPoint(x: w * 0.38, y: w * 0.30),
                           CGPoint(x: w * 0.38, y: w * 0.70),
                           CGPoint(x: w * 0.64, y: w * 0.54)] {
                let dot = Path(ellipseIn: CGRect(x: center.x - w * 0.075, y: center.y - w * 0.075,
                                                 width: w * 0.15, height: w * 0.15))
                context.fill(dot, with: .color(.white))
            }
        }
    }
}

/// npm's red square icon variant: white "n" glyph drawn as blocks, like the original.
struct NpmLogo: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let red = Color(red: 0.76, green: 0.18, blue: 0.16)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: w), cornerRadius: w * 0.17),
                         with: .color(red))
            // The "n": a white block with a red notch cut from its lower middle.
            let glyph = CGRect(x: w * 0.28, y: w * 0.30, width: w * 0.44, height: w * 0.44)
            context.fill(Path(glyph), with: .color(.white))
            let cut = CGRect(x: glyph.minX + glyph.width * 0.38, y: glyph.midY,
                             width: glyph.width * 0.24, height: glyph.height / 2)
            context.fill(Path(cut), with: .color(red))
        }
    }
}

/// pnpm's three-by-three block mark.
struct PnpmLogo: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let cell = w * 0.26
            let gap = w * 0.05
            let origin = (w - cell * 3 - gap * 2) / 2
            let orange = Color(red: 0.97, green: 0.68, blue: 0.14)
            let dark = Color(white: 0.35)
            // (column, row): top row all orange, right column orange; the rest dark.
            let cells: [(Int, Int, Color)] = [
                (0, 0, orange), (1, 0, orange), (2, 0, orange),
                (2, 1, orange), (1, 1, dark),
                (1, 2, dark), (2, 2, dark),
            ]
            for (col, row, color) in cells {
                let rect = CGRect(
                    x: origin + CGFloat(col) * (cell + gap),
                    y: origin + CGFloat(row) * (cell + gap),
                    width: cell, height: cell
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

struct HoverTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.primary.opacity(hovering ? 0.08 : 0), in: Capsule())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

struct ItemDetail: View {
    let item: ScanItem
    let onClean: () -> Void
    private var cleanable: Bool { item.safety == .safe || item.safety == .review }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Text(item.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            ForEach(item.reasons, id: \.self) { reason in
                Label {
                    Text(reason).font(.callout)
                } icon: {
                    Image(systemName: item.safety == .safe ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(item.safety.color)
                }
            }

            if let worktree = item.worktree, worktree.isPrunable != true {
                HStack(spacing: 14) {
                    DetailPill(label: "Registered", ok: worktree.isRegistered)
                    DetailPill(label: "Clean tree", ok: !worktree.hasModifiedFiles && !worktree.hasUntrackedFiles)
                    DetailPill(label: "All pushed", ok: worktree.unpushedCommits == 0)
                    if let repo = worktree.repositoryPath {
                        Text(URL(filePath: repo).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Label {
                        Text("Reveal in Finder")
                    } icon: {
                        Image(nsImage: AppIconProvider.finder)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.glass)
                .pointerStyle(.link)

                Menu {
                    ForEach(Tool.allCases.filter { ToolIntegration.isInstalled($0) }) { tool in
                        Button {
                            let prompt = ToolIntegration.inspectionPrompt(for: item)
                            if let url = ToolIntegration.promptURL(tool: tool, prompt: prompt, path: item.worktree?.repositoryPath ?? item.path) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label {
                                Text("Ask \(tool.rawValue)")
                            } icon: {
                                if let appIcon = AppIconProvider.icon(for: tool) {
                                    Image(nsImage: appIcon)
                                } else {
                                    Image(systemName: "terminal")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Investigate with AI", systemImage: "doc.text.magnifyingglass")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .pointerStyle(.link)

                Spacer()

                if cleanable {
                    Button("Move to Trash", systemImage: "trash", role: .destructive, action: onClean)
                        .buttonStyle(.glass)
                        .pointerStyle(.link)
                }
            }
        }
    }
}

struct DetailPill: View {
    let label: String
    let ok: Bool

    var body: some View {
        Label(label, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

// MARK: - Selection bar

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    let onClean: () -> Void

    var body: some View {
        if !model.selection.isEmpty && !model.isCleaning {
            HStack(spacing: 14) {
                Text("\(model.selection.count) selected · \(model.selectedBytes.formattedBytes)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                HoverTextButton(title: "Deselect All") { model.selection = [] }
                Button("Move to Trash", systemImage: "trash", action: onClean)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .fixedSize()
                    .pointerStyle(.link)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Shared bits

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(safety.color.opacity(0.15), in: Capsule())
            .foregroundStyle(safety.color)
            .fixedSize()
    }
}

extension Safety {
    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .protected: .red
        case .unknown: .gray
        }
    }
}

extension StorageCategory {
    var systemImage: String {
        switch self {
        case .worktree: "arrow.triangle.branch"
        case .nodeModules: "shippingbox"
        case .buildCache: "wrench.and.screwdriver"
        case .packageCache: "archivebox"
        case .derivedData: "hammer"
        case .archives: "doc.zipper"
        case .deviceSupport: "iphone"
        case .simulators: "ipad.and.iphone"
        case .toolSessions: "text.bubble"
        case .toolCache: "memorychip"
        }
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
