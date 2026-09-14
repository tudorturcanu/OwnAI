import SwiftUI

/// Presents the "Cellular Downloads Off" alert from `ModelManager`.
///
/// Every screen that can start a download needs its own copy: an alert is
/// bound to a presentation context, and one attached to a view sitting
/// *under* a sheet never reaches the screen. The models list lives inside
/// the Settings sheet, so without this the tap on Download did nothing
/// visible at all.
///
/// All copies read the same observable notice and clear it on dismiss, so
/// only the frontmost one presents and a covered screen can never surface a
/// stale alert once it is uncovered again.
private struct CellularRestrictionAlertModifier: ViewModifier {
    @Environment(ModelManager.self) private var modelManager

    func body(content: Content) -> some View {
        content.alert(
            // Low Data Mode and a Personal Hotspot trip the same restriction on
            // Wi-Fi, where a title about cellular reads as plainly wrong.
            DownloadNetworkMonitor.shared.isActuallyCellular
                ? String(localized: "Cellular Downloads Off")
                : String(localized: "Metered Network"),
            isPresented: Binding(
                get: { modelManager.cellularRestrictionNotice != nil },
                set: { isPresented in
                    if !isPresented {
                        modelManager.cellularRestrictionNotice = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                modelManager.cellularRestrictionNotice = nil
            }
        } message: {
            Text(
                modelManager.cellularRestrictionNotice
                    ?? String(localized: "Connect to Wi-Fi, or enable Cellular Downloads in Own AI Settings.")
            )
        }
    }
}

/// Offers to flip Cellular Downloads on right where a download was refused
/// for being on cellular, instead of sending the user off to find the toggle.
private struct AllowCellularDownloadsAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onAllow: () -> Void
    @Environment(ModelManager.self) private var modelManager

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "Allow Cellular Downloads?"),
            isPresented: $isPresented
        ) {
            Button(String(localized: "Allow")) {
                modelManager.enableCellularDownloads()
                onAllow()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Models will download over cellular data until you turn Cellular Downloads off in Own AI Settings."))
        }
    }
}

extension View {
    /// Surfaces a refused-because-cellular download as an alert in this
    /// view's presentation context.
    func cellularRestrictionAlert() -> some View {
        modifier(CellularRestrictionAlertModifier())
    }

    /// Asks before turning Cellular Downloads on; `onAllow` runs once the
    /// preference is set (typically to retry the refused download).
    func allowCellularDownloadsAlert(isPresented: Binding<Bool>, onAllow: @escaping () -> Void) -> some View {
        modifier(AllowCellularDownloadsAlertModifier(isPresented: isPresented, onAllow: onAllow))
    }
}
