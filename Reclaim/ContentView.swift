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

    var filteredItems: [ScanItem] {
        model.items.filter { item in
            (categoryFilter == nil || item.category == categoryFilter)
                && (safetyFilter == nil || item.safety == safetyFilter)
                && (searchText.isEmpty
                    || item.displayName.localizedCaseInsensitiveContains(searchText)
                    || item.path.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 18) {
                    HeroCard()
                    if !model.items.isEmpty {
                        CategoryChips(selection: $categoryFilter)
                        SafetyChips(selection: $safetyFilter)
                        ItemCardList(items: filteredItems, expandedItem: $expandedItem,
                                     onCleanSingle: { item in
                                         model.selection = [item.id]
                                         confirmingCleanup = true
                                     })
                    }
                }
                .padding(20)
                .padding(.bottom, 72)
            }
            SelectionBar(onClean: { confirmingCleanup = true })
        }
        .background(.background.secondary)
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
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.scan() }
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

    var body: some View {
        VStack(spacing: 14) {
            if model.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.scanProgress)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
            }
            if model.items.isEmpty && !model.isScanning {
                VStack(spacing: 10) {
                    PixelSpriteView(palette: .blue)
                        .frame(width: 72, height: 48)
                    Text("Find your lost gigabytes")
                        .font(.title2.weight(.semibold))
                    Text("Worktrees, node_modules, caches, and AI agent leftovers.\nNothing is deleted without asking you first.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Scan Now") { model.scan() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                .padding(.vertical, 12)
            } else if !model.items.isEmpty {
                HStack(spacing: 0) {
                    HeroStat(value: model.totalBytes, label: "found", tint: .primary)
                    Divider().frame(height: 36)
                    HeroStat(value: model.safeBytes, label: "safe to clean", tint: .green)
                    Divider().frame(height: 36)
                    VStack(spacing: 2) {
                        Text("\(model.items.count)")
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .monospacedDigit()
                        Text("items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct HeroStat: View {
    let value: Int64
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value.formattedBytes)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Filter chips

struct CategoryChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: StorageCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "Everything", icon: "internaldrive",
                     subtitle: model.totalBytes.formattedBytes,
                     isSelected: selection == nil) { selection = nil }
                ForEach(StorageCategory.allCases) { category in
                    let items = model.items.filter { $0.category == category }
                    if !items.isEmpty {
                        Chip(title: category.rawValue,
                             icon: category.systemImage,
                             subtitle: items.compactMap(\.sizeBytes).reduce(0, +).formattedBytes,
                             isSelected: selection == category) {
                            selection = selection == category ? nil : category
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }
}

struct SafetyChips: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Safety?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Safety.allCases) { safety in
                let count = model.items.filter { $0.safety == safety }.count
                if count > 0 {
                    Chip(title: safety.rawValue, icon: nil, subtitle: "\(count)",
                         tint: safety.color,
                         isSelected: selection == safety) {
                        selection = selection == safety ? nil : safety
                    }
                }
            }
            Spacer()
        }
    }
}

struct Chip: View {
    var title: String
    var icon: String?
    var subtitle: String?
    var tint: Color = .accentColor
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.callout.weight(.medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(tint.opacity(0.55)).interactive() : .regular.interactive(),
                     in: .capsule)
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
                        withAnimation(.snappy(duration: 0.28)) {
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

                ToolIconView(tool: item.tool, category: item.category)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.tool.rawValue)
                        if let branch = item.worktree?.branch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                        } else if item.worktree != nil, item.worktree?.isPrunable != true {
                            Label("detached", systemImage: "arrow.triangle.branch")
                        }
                        if let date = item.lastActivity {
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
            .onTapGesture(perform: onToggleExpand)

            if isExpanded {
                ItemDetail(item: item, onClean: onClean)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
            Image(systemName: category.systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
        }
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

                Menu {
                    ForEach(Tool.allCases.filter { ToolIntegration.supportsPromptURL($0) }) { tool in
                        Button("Ask \(tool.rawValue)") {
                            let prompt = ToolIntegration.inspectionPrompt(for: item)
                            if let url = ToolIntegration.promptURL(tool: tool, prompt: prompt, path: item.worktree?.repositoryPath ?? item.path) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } label: {
                    Label("Investigate with AI", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .fixedSize()

                Spacer()

                if cleanable {
                    Button("Clean…", systemImage: "trash", role: .destructive, action: onClean)
                        .buttonStyle(.glass)
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
        if !model.selection.isEmpty {
            HStack(spacing: 14) {
                Text("\(model.selection.count) selected · \(model.selectedBytes.formattedBytes)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Button("Deselect All") { model.selection = [] }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Clean…", systemImage: "trash", action: onClean)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
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
