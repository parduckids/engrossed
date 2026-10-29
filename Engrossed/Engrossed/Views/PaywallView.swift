import SwiftUI

/// The only thing this app ever asks you to pay for.
///
/// Deliberately plain: no countdown, no crossed-out price, no "most popular"
/// badge, no guilt in the dismiss button. The app is honest about weak evidence
/// elsewhere, and it would be strange to drop that register here.
struct PaywallView: View {
    @Environment(ReadingSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var store = Store.shared

    private var theme: PaperTheme { settings.theme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    EngrossedMark(size: 30, tint: theme.accent)
                    Spacer()
                    Button("Not now") { dismiss() }
                        .buttonStyle(SoftButtonStyle(theme: theme))
                        .keyboardShortcut(.escape, modifiers: [])
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Room for a shelf")
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.ink)

                    Text("One book at a time is free, and always will be. Finish it, delete it, add another, as often as you like. No limit on time, pages or features.")
                        .font(.system(size: 14.5, design: .rounded))
                        .foregroundStyle(theme.ink.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("If you would rather keep several on the go at once, that is one payment.")
                        .font(.system(size: 14.5, design: .rounded))
                        .foregroundStyle(theme.ink.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 9) {
                    point("Paid once. Yours for good.")
                    point("No subscription. No account. No sign up.")
                    point("Shared with your family. Up to five other people in your Family Sharing group get it without paying again.")
                    point("Reading works offline, like the rest of the app.")
                }

                Link("How Family Sharing works",
                     destination: URL(string: "https://www.apple.com/family-sharing/")!)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(theme.accent)
                .padding(.vertical, 2)

                buyButton

                HStack(spacing: 14) {
                    Button {
                        Task { await store.restore() }
                    } label: {
                        if store.isRestoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restore purchase")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.faint)
                    .disabled(store.isRestoring)

                    Spacer()
                }

                if let message = store.purchaseError {
                    Text(message)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .task { await store.refresh() }
        .onChange(of: store.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    @ViewBuilder
    private var buyButton: some View {
        Button {
            Task { await store.purchase() }
        } label: {
            Group {
                if store.isPurchasing {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let price = store.displayPrice {
                    Text("Get the full shelf \u{00B7} \(price)")
                } else {
                    Text("Get the full shelf")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SoftButtonStyle(theme: theme, prominent: true))
        .disabled(store.product == nil || store.isPurchasing || !store.canMakePayments)
        // A custom ButtonStyle does not dim itself when disabled, so a button
        // that cannot be pressed would otherwise look entirely pressable.
        .opacity(store.product == nil || !store.canMakePayments ? 0.45 : 1)

        if !store.canMakePayments {
            Text("Purchases are turned off on this device, probably by Screen Time or a device policy. Your free book works as normal.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.product == nil {
            // Say what is actually happening, and make clear nothing is broken.
            Text("The App Store can’t be reached right now. Your free book works as normal.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func point(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(theme.accent.opacity(0.5))
                .frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(theme.ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
