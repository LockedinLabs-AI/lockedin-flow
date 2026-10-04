import AppKit
import SwiftUI
import VoiceCore

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var retention: RetentionPolicy = HistoryStore.shared.retention
    @State private var pendingRetention: RetentionPolicy?
    @State private var teaching: HistoryEntry?
    @State private var confirmingDeleteAll = false

    private var filtered: [HistoryEntry] {
        query.isEmpty
            ? state.historyEntries
            : state.historyEntries.filter {
                $0.final.localizedCaseInsensitiveContains(query)
                    || $0.raw.localizedCaseInsensitiveContains(query)
                    || $0.profileID.localizedCaseInsensitiveContains(query)
                    || ($0.targetAppName?.localizedCaseInsensitiveContains(query) ?? false)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let notice = state.pendingReinsertInspection {
                reinsertInspectionNotice(notice)
            }
            searchField
            content
            footer
        }
        .padding(24)
        .background(FlowWorkspace.canvas)
        .frame(minWidth: 660, minHeight: 500)
        .preferredColorScheme(.light)
        .sheet(item: $teaching) { entry in
            TeachCorrectionView(entry: entry)
                .environmentObject(state)
        }
        .confirmationDialog(
            "Delete all dictations?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                state.deleteAllHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved transcript from this Mac and cannot be undone.")
        }
        .confirmationDialog(
            "Change history retention?",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingRetention {
                Button(retentionConfirmationLabel(for: pendingRetention), role: .destructive) {
                    applyRetention(pendingRetention)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRetention = nil
            }
        } message: {
            if let pendingRetention {
                Text(retentionConfirmationMessage(for: pendingRetention))
            }
        }
    }

    private func reinsertInspectionNotice(
        _ notice: ReinsertInspectionNotice
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(FlowWorkspace.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text("Check the original insertion")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Text(notice.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowWorkspace.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("I checked") {
                state.acknowledgeReinsertInspection(notice)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityHint("Clears this warning without inserting any text")
        }
        .padding(14)
        .background(FlowWorkspaceSurface(radius: 13, emphasized: true))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dictation history")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(FlowWorkspace.primaryText)
                Text(historySummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowWorkspace.secondaryText)
            }

            Spacer()

            Picker(
                "Retention",
                selection: Binding(
                    get: { retention },
                    set: { proposeRetention($0) }
                )
            ) {
                ForEach(RetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 178)
            .accessibilityHint("Controls how long transcripts stay on this Mac")
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FlowWorkspace.tertiaryText)
            TextField("Search text, profile, or app", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FlowWorkspace.tertiaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(FlowWorkspaceSurface(radius: 11))
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(FlowWorkspace.line)
                        }
                        HistoryEntryRow(
                            entry: entry,
                            currentTargetAppName: state.targetAppName,
                            onCopy: copy,
                            onReinsert: { completion in
                                state.reinsert(
                                    entry.final,
                                    sourceID: entry.id,
                                    completion: completion
                                )
                            },
                            reinsertBlocked: state.pendingReinsertInspection != nil
                                || !state.automaticInsertionEnabled,
                            ownedInspection: state.pendingReinsertInspection.flatMap {
                                $0.sourceID == entry.id ? $0 : nil
                            },
                            onTeach: { teaching = entry },
                            onDelete: { state.deleteHistoryEntry(entry.id) }
                        )
                    }
                }
                .background(FlowWorkspaceSurface(radius: 16))
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: retention == .off ? "eye.slash" : "text.quote")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(FlowWorkspace.action)
            Text(emptyTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FlowWorkspace.primaryText)
            Text(emptyDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(FlowWorkspace.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(36)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .semibold))
            Text(historyStorageSummary)
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Button("Delete All", role: .destructive) {
                confirmingDeleteAll = true
            }
            .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
            .font(.system(size: 11.5, weight: .semibold))
            .disabled(state.historyEntries.isEmpty)
        }
        .foregroundStyle(FlowWorkspace.tertiaryText)
        .padding(.horizontal, 2)
    }

    private var historySummary: String {
        if retention == .off { return "History is off. Nothing is retained." }
        if state.historyEntries.isEmpty {
            return retention.persistsAcrossLaunches
                ? "Polished text can stay here, encrypted on this Mac."
                : "Polished text can stay in memory until you quit."
        }
        if filtered.count != state.historyEntries.count {
            return "\(filtered.count) of \(state.historyEntries.count) dictations"
        }
        let storage = retention.persistsAcrossLaunches ? "encrypted on this Mac" : "in memory"
        return
            "\(state.historyEntries.count) \(state.historyEntries.count == 1 ? "dictation" : "dictations") · \(storage)"
    }

    private var historyStorageSummary: String {
        switch retention {
        case .off:
            return "History off · raw audio is never saved to disk"
        case .sessionOnly:
            return "Session-only transcripts in memory · raw audio is never saved to disk"
        case .oneHour, .oneDay, .sevenDays, .thirtyDays, .forever:
            return "Encrypted transcripts on this Mac · raw audio is never saved to disk"
        }
    }

    private var emptyTitle: String {
        if retention == .off { return "History is off" }
        if query.isEmpty { return "No dictations yet" }
        return "No matching dictations"
    }

    private var emptyDetail: String {
        if retention == .off {
            return "Choose a retention period to keep future transcripts locally."
        }
        if query.isEmpty { return "Finished dictations will appear here when history is enabled." }
        return "Try a different word, profile, or application name."
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }

    private func proposeRetention(_ policy: RetentionPolicy) {
        guard policy != retention else { return }
        if entriesRemoved(by: policy) > 0 {
            pendingRetention = policy
        } else {
            applyRetention(policy)
        }
    }

    private func applyRetention(_ policy: RetentionPolicy) {
        retention = policy
        pendingRetention = nil
        state.setHistoryRetention(policy)
    }

    private func entriesRemoved(by policy: RetentionPolicy) -> Int {
        switch policy {
        case .off, .sessionOnly:
            return state.historyEntries.count
        case .oneHour, .oneDay, .sevenDays, .thirtyDays:
            guard let cutoff = policy.cutoff() else { return 0 }
            return state.historyEntries.filter { $0.createdAt < cutoff }.count
        case .forever:
            return 0
        }
    }

    private func retentionConfirmationLabel(for policy: RetentionPolicy) -> String {
        switch policy {
        case .off: return "Turn Off and Delete"
        case .sessionOnly: return "Use Session Only"
        default: return "Change and Delete Older"
        }
    }

    private func retentionConfirmationMessage(for policy: RetentionPolicy) -> String {
        let count = entriesRemoved(by: policy)
        let noun = count == 1 ? "saved transcript" : "saved transcripts"
        return "This change will remove \(count) \(noun) from this Mac and cannot be undone."
    }
}

private struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let currentTargetAppName: String?
    let onCopy: (String) -> Void
    let onReinsert: (@escaping (Result<ReinsertSuccess, Error>) -> Void) -> Void
    let reinsertBlocked: Bool
    let ownedInspection: ReinsertInspectionNotice?
    let onTeach: () -> Void
    let onDelete: () -> Void

    @State private var showsOriginal = false
    @State private var copiedFinal = false
    @State private var copiedOriginal = false
    @State private var confirmingDelete = false
    @State private var reinsertionMessage: String?
    @State private var reinsertionDetail: String?
    @State private var reinsertionFailed = false
    @State private var reinsertionCanceled = false

    private var hasCleanupChanges: Bool {
        entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != entry.final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.final)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(FlowWorkspace.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    metadata
                }

                Spacer(minLength: 12)

                Button {
                    onCopy(entry.final)
                    copiedFinal = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copiedFinal = false
                    }
                } label: {
                    Label(
                        copiedFinal ? "Copied" : "Copy",
                        systemImage: copiedFinal ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(copiedFinal ? FlowWorkspace.success : FlowWorkspace.action)
            }

            if hasCleanupChanges {
                VStack(alignment: .leading, spacing: 9) {
                    Button {
                        showsOriginal.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Text("Raw")
                                .foregroundStyle(FlowWorkspace.tertiaryText)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FlowWorkspace.tertiaryText)
                            Text("Polished")
                                .foregroundStyle(FlowWorkspace.action)

                            Spacer()

                            Text(showsOriginal ? "Hide" : "Compare")
                                .foregroundStyle(FlowWorkspace.secondaryText)
                            Image(systemName: showsOriginal ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FlowWorkspace.tertiaryText)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .background(
                            FlowWorkspace.surfaceRaised.opacity(0.64),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(FlowWorkspace.line, lineWidth: 0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Raw transcript to polished text")
                    .accessibilityValue(
                        showsOriginal ? "Raw transcript shown" : "Raw transcript hidden"
                    )
                    .accessibilityHint(
                        showsOriginal
                            ? "Collapses the raw transcript" : "Shows the transcript before cleanup"
                    )

                    if showsOriginal {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Raw transcript")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowWorkspace.tertiaryText)
                            Text(entry.raw)
                                .font(.system(size: 12.5))
                                .foregroundStyle(FlowWorkspace.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                onCopy(entry.raw)
                                copiedOriginal = true
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.4))
                                    copiedOriginal = false
                                }
                            } label: {
                                Label(
                                    copiedOriginal ? "Original copied" : "Copy original",
                                    systemImage: copiedOriginal ? "checkmark" : "doc.on.doc"
                                )
                            }
                            .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
                            .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(12)
                        .background(
                            FlowWorkspace.surfaceRaised.opacity(0.70),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            HStack(spacing: 16) {
                Button {
                    onReinsert { result in
                        switch result {
                        case .success(let outcome):
                            reinsertionMessage = outcome.compactMessage
                            reinsertionDetail = nil
                            reinsertionFailed = false
                            reinsertionCanceled = false
                        case .failure(let error) where error is CancellationError:
                            reinsertionMessage = "Canceled"
                            reinsertionDetail = nil
                            reinsertionFailed = false
                            reinsertionCanceled = true
                        case .failure(let error) where error is ReinsertSafetyNoticeError:
                            reinsertionMessage = "Check insertion"
                            reinsertionDetail = error.localizedDescription
                            reinsertionFailed = true
                            reinsertionCanceled = false
                        case .failure(let error):
                            reinsertionMessage = "Couldn’t insert"
                            reinsertionDetail = error.localizedDescription
                            reinsertionFailed = true
                            reinsertionCanceled = false
                        }
                    }
                } label: {
                    Label(
                        reinsertionMessage ?? currentTargetAppName.map { "Insert in \($0)" }
                            ?? "Re-insert",
                        systemImage: reinsertionFailed
                            ? "exclamationmark"
                            : reinsertionCanceled
                                ? "xmark"
                                : reinsertionMessage == nil
                                    ? "arrow.turn.down.right"
                                    : "checkmark"
                    )
                }
                .disabled(currentTargetAppName == nil || reinsertBlocked)
                .help(
                    reinsertionDetail ?? currentTargetAppName.map { "Re-insert in \($0)" }
                        ?? "Focus an app first, then re-insert"
                )
                .accessibilityLabel(
                    reinsertionMessage
                        ?? currentTargetAppName.map { "Re-insert in \($0)" }
                        ?? "Re-insert unavailable; focus an app first"
                )
                .accessibilityHint(reinsertionDetail ?? "Places this dictation in the focused app")
                .onChange(of: ownedInspection) { oldInspection, newInspection in
                    if oldInspection != nil, newInspection == nil {
                        reinsertionMessage = nil
                        reinsertionDetail = nil
                        reinsertionFailed = false
                        reinsertionCanceled = false
                    }
                }
                .frame(minHeight: 24)
                Button(action: onTeach) {
                    Label("Teach correction", systemImage: "text.badge.plus")
                }
                .frame(minHeight: 24)

                Spacer()

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .frame(minHeight: 24)
            }
            .buttonStyle(FlowCompactButtonStyle(focusColor: FlowWorkspace.action))
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(FlowWorkspace.secondaryText)

            if let reinsertionDetail, reinsertionFailed {
                Text(reinsertionDetail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowWorkspace.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved transcript will be removed from this Mac.")
        }
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            Text(entry.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            if let app = entry.targetAppName {
                Text("·")
                Text(app).lineLimit(1)
            }
            Text("·")
            Text(String(format: "%.1fs", entry.duration))
            Text("·")
            Text(entry.profileID)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(FlowWorkspace.tertiaryText)
    }

}
