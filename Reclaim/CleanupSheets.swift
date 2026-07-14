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
    @Environment(AppModel.self) private var model
    @State private var confirmingForce = false
    @State private var confirmingForceAgain = false

    // Read live from the model so a force pass refreshes the sheet in place.
    var results: [CleanupResult] { model.cleanupResults }

    var freed: Int64 { results.filter(\.success).compactMap(\.freedBytes).reduce(0, +) }
    var failures: [CleanupResult] { results.filter { !$0.success } }
    var forceable: [ScanItem] {
        let paths = Set(results.filter { !$0.success && $0.canForce }.map(\.path))
        return model.items.filter { paths.contains($0.path) }
    }

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
                if !forceable.isEmpty, !model.isCleaning {
                    Button("Force Clean \(forceable.count) Skipped…", systemImage: "exclamationmark.triangle") {
                        confirmingForce = true
                    }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .pointerStyle(.link)
                }
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                    Text(model.cleaningStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isCleaning)
            }
        }
        .padding(20)
        .frame(width: 560, height: 400)
        .alert("Force clean \(forceable.count) skipped item\(forceable.count == 1 ? "" : "s")?", isPresented: $confirmingForce) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { confirmingForceAgain = true }
        } message: {
            Text("These were skipped because they contain uncommitted changes, untracked files, or commits that exist nowhere else. Forcing will move that work to the Trash.")
        }
        .alert("Are you absolutely sure?", isPresented: $confirmingForceAgain) {
            Button("Cancel", role: .cancel) {}
            Button("Force Clean", role: .destructive) {
                let items = forceable
                Task { await model.clean(items, force: true) }
            }
        } message: {
            Text("The uncommitted work inside exists nowhere else. It stays recoverable only until the Trash is emptied — after that it is gone for good.")
        }
    }
}
