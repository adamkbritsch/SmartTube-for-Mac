import SwiftUI

/// Native app Settings panel — opened by the gear in the header. Groups the settings the backend
/// models (ad-block / SponsorBlock + per-category / DeArrow, playback speed / max-quality / Enhance,
/// theme / theater, and account) into one place. Every control reads `store.settings.*` and writes
/// through a `Store` setter (optimistic local update + `PATCH /api/settings`), so it stays in sync
/// with the inline enhance bar under the player and any other client on the shared `/api/settings`.
struct SettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.24, green: 0.65, blue: 1)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).clickable()
            }
            .padding(16)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Ads & sponsors") {
                        toggleRow("Ad blocking", "Block YouTube video ads", store.settings.adBlock) { store.setAdBlock($0) }
                        rowDivider
                        toggleRow("SponsorBlock", "Auto-skip sponsor segments", store.settings.sponsorBlock) { store.setSponsorBlock($0) }
                        // Per-category toggles — shown only when SponsorBlock is on (hide inert UI).
                        if store.settings.sponsorBlock {
                            ForEach(SettingsSheet.sbCats, id: \.0) { cat in
                                rowDivider
                                subToggleRow(cat.1, cat.2, store.settings.sbCategories.contains(cat.0)) { store.setSbCategory(cat.0, $0) }
                            }
                        }
                        rowDivider
                        toggleRow("DeArrow", "De-clickbait titles & thumbnails", store.settings.deArrow) { store.setDeArrow($0) }
                    }

                    section("Playback") {
                        segRow("Speed", "", options: [("1x", 1.0), ("1.25x", 1.25), ("1.5x", 1.5), ("1.75x", 1.75), ("2x", 2.0)],
                               selected: store.settings.playbackSpeed) { store.setPlaybackSpeed($0) }
                        rowDivider
                        toggleRow("Max quality", "Force the highest available resolution", store.settings.maxResolution) { store.setMaxResolution($0) }
                        rowDivider
                        segRow("Enhance", "GPU detail-sharpen (off at 4K)", options: [("Off", "off"), ("Subtle", "subtle"), ("Sharper", "sharper")],
                               selected: store.settings.enhance) { store.setEnhance($0) }
                        rowDivider
                        toggleRow("Auto fullscreen", "Enter fullscreen when a video starts", store.settings.autoFullscreen) { store.setAutoFullscreen($0) }
                    }

                    section("Appearance") {
                        segRow("Theme", "", options: [("Dark", "dark"), ("Light", "light")],
                               selected: store.settings.theme) { store.setTheme($0) }
                        rowDivider
                        toggleRow("Theater mode", "Wide player, hide the up-next rail", store.settings.theaterMode) { store.setTheater($0) }
                    }

                    section("Account") { accountRow }
                }
                .padding(16)
            }
        }
        .frame(width: 470, height: 560)
        .background(themeBackground(store.settings.theme))
    }

    // MARK: rows

    private var rowDivider: some View { Divider().padding(.leading, 12).opacity(0.15) }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            VStack(spacing: 0) { content() }
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func toggleRow(_ name: String, _ hint: String, _ isOn: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            label(name, hint)
            Spacer(minLength: 10)
            Toggle("", isOn: Binding(get: { isOn }, set: { set($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).clickable()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    /// Indented toggle row for the SponsorBlock sub-categories (visually nested under it).
    private func subToggleRow(_ name: String, _ hint: String, _ isOn: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            label(name, hint).padding(.leading, 22)
            Spacer(minLength: 10)
            Toggle("", isOn: Binding(get: { isOn }, set: { set($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).clickable()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// SponsorBlock skip categories: (id matching Settings.sbAllCategories, label, hint).
    static let sbCats: [(String, String, String)] = [
        ("sponsor", "Sponsors", "Paid promotions & sponsorships"),
        ("selfpromo", "Self-promotion", "Merch, donations, unpaid promos"),
        ("interaction", "Interaction reminders", "Like / subscribe prompts"),
        ("intro", "Intros", "Intermissions & intro animations"),
        ("outro", "Endcards & credits", ""),
        ("preview", "Previews & recaps", ""),
        ("music_offtopic", "Non-music sections", "In music videos"),
    ]

    private func segRow<V: Hashable>(_ name: String, _ hint: String, options: [(String, V)], selected: V, _ set: @escaping (V) -> Void) -> some View {
        HStack {
            label(name, hint)
            Spacer(minLength: 10)
            HStack(spacing: 2) {
                ForEach(options, id: \.1) { opt in
                    let active = opt.1 == selected
                    Button { set(opt.1) } label: {
                        Text(opt.0).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(active ? AnyShapeStyle(accent) : AnyShapeStyle(Color.clear)))
                            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                    }
                    .buttonStyle(.plain).clickable()
                }
            }
            .padding(2).background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func label(_ name: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 13, weight: .medium))
            if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    // MARK: account

    @ViewBuilder private var accountRow: some View {
        if store.account.signedIn, let p = store.account.profile {
            HStack(spacing: 12) {
                CachedImage(url: p.picture) {
                    Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0, blue: 0.2), .purple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .frame(width: 40, height: 40).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 13, weight: .semibold))
                    if !p.email.isEmpty { Text(p.email).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 10)
                Button("Sign out") { store.signOut() }.clickable()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        } else {
            HStack {
                label("Not signed in", "Uses the YouTube login in your Firefox profile")
                Spacer(minLength: 10)
                Button { store.signIn() } label: {
                    Text("Sign in").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 30)
                        .overlay(Capsule().stroke(accent, lineWidth: 1))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain).clickable()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}
