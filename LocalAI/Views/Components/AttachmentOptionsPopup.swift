import SwiftUI

struct AttachmentOptionsPopup: View {
    let onPhotoPicker: () -> Void
    /// Nil hides the camera row (simulator, iPads without a camera).
    let onCamera: (() -> Void)?
    let onDocumentImport: () -> Void
    let onCancel: () -> Void
    
    // Shared Haptic Generator
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.headline)
                        .foregroundStyle(.brandAccent)
                        .accessibilityHidden(true)
                    
                    Text(String(localized: "Add to Chat"))
                        .font(.headline.bold())
                        .foregroundStyle(Color.primary)
                }
                
                Text(String(localized: "Choose what to attach to this conversation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .padding(.top, 4)
            
            // Buttons List
            VStack(spacing: 12) {
                // Photo or Screenshot Button
                Button {
                    lightHaptic.impactOccurred()
                    onPhotoPicker()
                } label: {
                    HStack(spacing: 16) {
                        // Icon Container
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.brandAccent, Color.brandAccentDeep],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .accessibilityHidden(true)
                            )
                            .shadow(color: Color.brandAccent.opacity(0.3), radius: 6, x: 0, y: 3)
                        
                        // Text Label
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Photo or Screenshot"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            
                            Text(String(localized: "Choose an image from your photo library."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.adaptiveCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.brandHairline, lineWidth: 1)
                    )
                }
                .buttonStyle(PressedScaleButtonStyle())
                
                if let onCamera {
                    Button {
                        lightHaptic.impactOccurred()
                        onCamera()
                    } label: {
                        HStack(spacing: 16) {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.brandAccent, Color.brandAccentDeep],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.white)
                                        .accessibilityHidden(true)
                                )
                                .shadow(color: Color.brandAccent.opacity(0.3), radius: 6, x: 0, y: 3)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(localized: "Take Photo"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.primary)

                                Text(String(localized: "Snap a document, whiteboard, or receipt."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.adaptiveCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.brandHairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressedScaleButtonStyle())
                }

                // Document Button
                Button {
                    lightHaptic.impactOccurred()
                    onDocumentImport()
                } label: {
                    HStack(spacing: 16) {
                        // Icon Container
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.brandAccentDeep, Color.brandAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "doc.text.fill")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                    .accessibilityHidden(true)
                            )
                            .shadow(color: Color.brandAccentDeep.opacity(0.3), radius: 6, x: 0, y: 3)
                        
                        // Text Label
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Open Document"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            
                            Text(String(
                                format: String(localized: "Attach PDFs, text, docx, or logs. Reads up to %lld pages.", defaultValue: "Attach PDFs, text, docx, or logs. Reads up to %lld pages."),
                                Int64(DocumentManager.currentDocumentProcessingMode().maxPDFPages)
                            ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.adaptiveCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.brandHairline, lineWidth: 1)
                    )
                }
                .buttonStyle(PressedScaleButtonStyle())
            }
            
            Divider()
                .background(Color.primary.opacity(0.08))
            
            // Cancel Button
            Button {
                mediumHaptic.impactOccurred()
                onCancel()
            } label: {
                Text(String(localized: "Cancel"))
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .buttonStyle(PressedScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.adaptiveBackground)
                .shadow(color: Color.black.opacity(0.18), radius: 30, x: 0, y: 15)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.brandHairline, lineWidth: 1)
        )
    }
}

// Reusable scale transition on button press
struct PressedScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        AttachmentOptionsPopup(onPhotoPicker: {}, onCamera: {}, onDocumentImport: {}, onCancel: {})
    }
}
