import SwiftUI
import ReclaimKit

struct CleanupConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [ScanItem]
    let excluded: [ScanItem]
    let onConfirm: () -> Void

    var totalBytes: Int64 { items.compactMap(\.sizeBytes).reduce(0, +) }
    var reviewItems: [ScanItem] { items.filter { $0.safety == .review } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?", systemImage: "trash")
                .font(.title3.weight(.semibold))
            Text("Expected space reclaimed: \(totalBytes.formattedBytes). Everything goes to the macOS Trash and can be put back. Registered worktrees are re-checked for uncommitted work immediately before removal and pruned from their repository afterwards.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !reviewItems.isEmpty {
                Label("\(reviewItems.count) item\(reviewItems.count == 1 ? " is" : "s are") marked “Review first” — check the reasons column before continuing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !excluded.isEmpty {
                Label("\(excluded.count) selected item\(excluded.count == 1 ? "" : "s") will be skipped (active, protected, or unknown).", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
            }

            List(items) { item in
                HStack {
                    SafetyBadge(safety: item.safety)
                    Text(item.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(item.sizeBytes?.formattedBytes ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") { onConfirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

struct CleanupResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let results: [CleanupResult]

    var freed: Int64 { results.filter(\.success).compactMap(\.freedBytes).reduce(0, +) }
    var failures: [CleanupResult] { results.filter { !$0.success } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                failures.isEmpty
                    ? "Cleanup complete — reclaimed \(freed.formattedBytes)"
                    : "Cleanup finished with \(failures.count) skipped item\(failures.count == 1 ? "" : "s")",
                systemImage: failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(failures.isEmpty ? Color.green : .orange)

            List(results) { result in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? Color.green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.displayName)
                        Text(result.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let freed = result.freedBytes, result.success {
                        Text(freed.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 400)
    }
}
