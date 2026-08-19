import SwiftUI

struct AttachmentOptionsPopup: View {
    let onPhotoPicker: () -> Void
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
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    
                    Text(String(localized: "Add to Chat"))
                        .font(.headline.bold())
                        .foregroundStyle(Color.primary)
                }
                
                Text(String(localized: "Select a file format to upload to your AI session"))
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
                                    colors: [Color.blue, Color.cyan],
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
                            .shadow(color: Color.blue.opacity(0.3), radius: 6, x: 0, y: 3)
                        
                        // Text Label
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Photo or Screenshot"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            
                            Text(String(localized: "Upload images from your photo library"))
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
                            .fill(Color(uiColor: .systemBackground).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                }
                .buttonStyle(PressedScaleButtonStyle())
                
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
                                    colors: [Color.indigo, Color.purple],
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
                            .shadow(color: Color.indigo.opacity(0.3), radius: 6, x: 0, y: 3)
                        
                        // Text Label
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Open Document"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            
                            Text(String(localized: "Attach PDFs, text, docx, or logs"))
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
                            .fill(Color(uiColor: .systemBackground).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
            RoundedRectangle(cornerRadius: 28)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.12), radius: 30, x: 0, y: 15)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.adaptiveBorder(opacity: 0.35), lineWidth: 1.5)
        )
    }
}

// Reusable scale transition on button press
struct PressedScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        AttachmentOptionsPopup(onPhotoPicker: {}, onDocumentImport: {}, onCancel: {})
    }
}
