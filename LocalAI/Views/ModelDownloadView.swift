//
//  ModelDownloadView.swift
//  LocalAI
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct ModelDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var modelManager
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header description
                    headerView
                    
                    // Model cards
                    ForEach(modelManager.models) { model in
                        ModelCard(model: model)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .background(Color(white: 0.96))
            .navigationTitle("Manage Models")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue.opacity(0.8))
                
                Text("Choose your AI model. Apple Intelligence is built-in, while other models can be downloaded.")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.4))
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 3)
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: ModelInfo
    @Environment(ModelManager.self) private var modelManager
    @State private var isHovered = false
    
    private var isSelected: Bool {
        modelManager.selectedModel?.id == model.id
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row
            HStack(alignment: .top, spacing: 14) {
                // Icon
                modelIcon
                
                // Title and description
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.title3.bold())
                            .foregroundStyle(Color(white: 0.1))
                        
                        if model.isAppleFoundation {
                            Text("DEFAULT")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(model.description)
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.5))
                        .lineLimit(3)
                }
                
                Spacer(minLength: 0)
            }
            
            // Info tags
            HStack(spacing: 10) {
                if model.isAppleFoundation {
                    InfoTag(icon: "apple.logo", text: "Built-in", isHighlighted: true)
                    InfoTag(icon: "lock.shield", text: "Private")
                } else {
                    InfoTag(icon: "externaldrive", text: String(format: "%.1f GB", model.sizeGB))
                    InfoTag(icon: "cpu", text: "MLX")
                }
                
                if model.downloadState.isDownloaded && !model.isAppleFoundation {
                    InfoTag(icon: "checkmark.circle.fill", text: "Ready", isHighlighted: true)
                }
                
                Spacer()
            }
            
            // Action button
            actionButton
        }
        .padding(20)
        .background(
            model.isAppleFoundation ?
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color.white, Color(white: 0.99)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            ) :
            AnyShapeStyle(Color.white)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange.opacity(0.3), .pink.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: model.isAppleFoundation ? 1.5 : 0
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 12 : 8, y: isHovered ? 6 : 4)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    // MARK: - Components
    
    private var modelIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange.opacity(0.15), .pink.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(
                        colors: [.blue.opacity(0.12), .purple.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
            
            Image(systemName: model.isAppleFoundation ? "apple.intelligence" : "sparkles")
                .font(.title2)
                .foregroundStyle(
                    model.isAppleFoundation ?
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ) :
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
    
    @ViewBuilder
    private var actionButton: some View {
        switch model.downloadState {
        case .builtin:
            BuiltInButton(isSelected: isSelected) {
                modelManager.selectModel(model.id)
            }
            
        case .notDownloaded:
            DownloadButton(action: {
                modelManager.downloadModel(model.id)
            })
            
        case .downloading(let progress):
            DownloadingButton(progress: progress, action: {
                modelManager.cancelDownload(model.id)
            })
            
        case .downloaded:
            HStack(spacing: 12) {
                SelectButton(isSelected: isSelected) {
                    modelManager.selectModel(model.id)
                }
                DeleteButton(action: {
                    modelManager.deleteModel(model.id)
                })
            }
            
        case .error(let message):
            ErrorButton(message: message, action: {
                modelManager.downloadModel(model.id)
            })
        }
    }
}

// MARK: - Info Tag

struct InfoTag: View {
    let icon: String
    let text: String
    var isHighlighted: Bool = false
    
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(isHighlighted ? .green : Color(white: 0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.green.opacity(0.1) : Color(white: 0.95))
        .clipShape(Capsule())
    }
}

// MARK: - Action Buttons

struct BuiltInButton: View {
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.bold())
                    Text("Selected")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text("Use This Model")
                        .fontWeight(.medium)
                }
            }
            .foregroundStyle(isSelected ? .white : .orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ?
                LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .leading,
                    endPoint: .trailing
                ) :
                LinearGradient(
                    colors: [.orange.opacity(0.1), .pink.opacity(0.1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct SelectButton: View {
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.bold())
                    Text("Selected")
                        .fontWeight(.semibold)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                    Text("Select")
                        .fontWeight(.medium)
                }
            }
            .foregroundStyle(isSelected ? .white : .blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSelected ?
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                ) :
                LinearGradient(
                    colors: [.blue.opacity(0.08), .blue.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct DownloadButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body.bold())
                Text("Download")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [.blue, .blue.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct DownloadingButton: View {
    let progress: Double
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Animated progress ring
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.2), lineWidth: 3)
                    
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
                .frame(width: 22, height: 22)
                
                Text("Downloading \(Int(progress * 100))%")
                    .fontWeight(.semibold)
                
                Spacer()
                
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(white: 0.6))
            }
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
    }
}

struct DeleteButton: View {
    let action: () -> Void
    @State private var showConfirmation = false
    
    var body: some View {
        Button {
            showConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.body)
                .foregroundStyle(.red.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActionButtonStyle())
        .confirmationDialog("Delete Model?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the downloaded model from your device. You can download it again anytime.")
        }
    }
}

struct ErrorButton: View {
    let message: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(1)
            }
            
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                        .fontWeight(.medium)
                }
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(ActionButtonStyle())
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    ModelDownloadView()
        .environment(ModelManager())
}
