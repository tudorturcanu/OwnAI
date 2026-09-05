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
                    ?? String(localized: "Connect to Wi-Fi, or enable Cellular Downloads in Settings.")
            )
        }
    }
}

extension View {
    /// Surfaces a refused-because-cellular download as an alert in this
    /// view's presentation context.
    func cellularRestrictionAlert() -> some View {
        modifier(CellularRestrictionAlertModifier())
    }
}
