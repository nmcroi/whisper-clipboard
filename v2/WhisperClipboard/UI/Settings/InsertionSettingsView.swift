import AppKit
import SwiftUI

/// The "Invoegen" settings tab: toggles direct text insertion (Wispr Flow
/// style paste into the frontmost app), surfaces Accessibility permission
/// status with one-click remediation, and manages the per-app deny list.
struct InsertionSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var manualBundleId = ""
    @State private var showingAddMenu = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                toggleSection
                Divider().overlay(Theme.border)
                accessibilitySection
                Divider().overlay(Theme.border)
                denyListSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.window)
        .onAppear { accessibilityGranted = AccessibilityPermission.isGranted }
    }

    // MARK: - Toggle

    private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Invoegen")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Toggle(isOn: Binding(
                get: { environment.settings.directInsertion },
                set: { environment.settings.directInsertion = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Direct invoegen in de actieve app")
                        .font(ThemeFont.ui(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("Plakt de tekst automatisch in het venster waarin je begon met dicteren, in plaats van alleen op het klembord te zetten.")
                        .font(ThemeFont.ui(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }

    // MARK: - Accessibility status

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Toegankelijkheid")
                .font(ThemeFont.ui(15, weight: .semibold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 10) {
                if accessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("Toegankelijkheid toegestaan")
                            .font(ThemeFont.ui(12, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                            Text("Toegankelijkheid niet toegestaan")
                                .font(ThemeFont.ui(12, weight: .medium))
                                .foregroundStyle(Theme.text)
                        }
                        Text("Direct invoegen heeft eenmalig Toegankelijkheid-toestemming nodig om een plak-toetsaanslag naar de actieve app te sturen. macOS blokkeert invoegen in wachtwoordvelden sowieso, ongeacht deze instelling.")
                            .font(ThemeFont.ui(11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Toestemming geven") {
                                requestAccessibility()
                            }
                            .buttonStyle(AccentButtonStyle())

                            Button("Open Systeeminstellingen") {
                                AccessibilityPermission.openSettingsPane()
                            }
                            .buttonStyle(.plain)
                            .font(ThemeFont.ui(12, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
        }
    }

    private func requestAccessibility() {
        _ = AccessibilityPermission.request()
        AccessibilityPermission.pollUntilGranted { granted in
            accessibilityGranted = granted
        }
    }

    // MARK: - Deny list

    private var denyListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Uitgesloten apps")
                    .font(ThemeFont.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    if runningCandidates.isEmpty {
                        Text("Geen andere apps actief")
                    } else {
                        ForEach(runningCandidates, id: \.self) { bundleId in
                            Button(displayName(for: bundleId)) {
                                addDenied(bundleId)
                            }
                        }
                    }
                } label: {
                    Label("Voeg toe", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(Theme.accent)
            }

            Text("Direct invoegen wordt overgeslagen voor apps in deze lijst; de tekst blijft dan wel op het klembord staan.")
                .font(ThemeFont.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if environment.settings.insertionDeniedBundleIds.isEmpty {
                Text("Nog geen apps uitgesloten.")
                    .font(ThemeFont.ui(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themeCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(environment.settings.insertionDeniedBundleIds.enumerated()), id: \.element) { index, bundleId in
                        deniedRow(bundleId)
                        if index < environment.settings.insertionDeniedBundleIds.count - 1 {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                .themeCard()
            }

            HStack(spacing: 8) {
                TextField("Bundle-id handmatig toevoegen (bijv. com.apple.Terminal)", text: $manualBundleId)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.ui(12).monospaced())
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                    .onSubmit { addManualBundleId() }

                Button("Toevoegen") { addManualBundleId() }
                    .buttonStyle(.plain)
                    .font(ThemeFont.ui(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.border, lineWidth: 1))
                    .disabled(manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func deniedRow(_ bundleId: String) -> some View {
        HStack(spacing: 10) {
            if let icon = icon(for: bundleId) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 20)
            }
            Text(displayName(for: bundleId))
                .font(ThemeFont.ui(13))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Button {
                removeDenied(bundleId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Verwijder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - App resolution helpers

    /// Currently-running regular (Dock-visible) apps, excluding ourselves and
    /// apps already on the deny list.
    private var runningCandidates: [String] {
        let denied = Set(environment.settings.insertionDeniedBundleIds.map { $0.lowercased() })
        let ownId = InsertionPolicy.ownBundleId.lowercased()
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier }
            .filter { !denied.contains($0.lowercased()) && $0.lowercased() != ownId }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return ids.filter { seen.insert($0.lowercased()).inserted }
    }

    private func appURL(for bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    private func icon(for bundleId: String) -> NSImage? {
        guard let url = appURL(for: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func displayName(for bundleId: String) -> String {
        guard let url = appURL(for: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path)
    }

    // MARK: - Mutations

    private func addDenied(_ bundleId: String) {
        var list = environment.settings.insertionDeniedBundleIds
        guard !list.contains(where: { $0.caseInsensitiveCompare(bundleId) == .orderedSame }) else { return }
        list.append(bundleId)
        environment.settings.insertionDeniedBundleIds = list
    }

    private func addManualBundleId() {
        let trimmed = manualBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addDenied(trimmed)
        manualBundleId = ""
    }

    private func removeDenied(_ bundleId: String) {
        environment.settings.insertionDeniedBundleIds.removeAll {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }
}

#Preview {
    InsertionSettingsView()
        .environmentObject(AppEnvironment())
        .frame(width: 520, height: 460)
        .preferredColorScheme(.dark)
}
