//
//  OnboardingView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(ModelManager.self) private var modelManager
    @State private var animate = false
    @State private var currentPage = 0
    
    var body: some View {
        ZStack {
            // Background
            Color.white.ignoresSafeArea()
            
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                privacyPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .onAppear {
            animate = true
        }
    }
    
    // MARK: - Page 1: Welcome
    
    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Icon / Hero
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.orange.opacity(0.1), .pink.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 200)
                    
                Image(systemName: "sparkles")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(animate ? 1.05 : 0.95)
                    .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: animate)
            }
            .padding(.bottom, 48)
            
            // Title & Subtitle
            VStack(spacing: 16) {
                Text("Welcome to Own Ai")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color(white: 0.1))
                
                Text(modelManager.isAppleIntelligenceDeviceSupported ?
                     "Experience the power of AI,\non-device and with Apple Intelligence when enabled." :
                     "Experience the power of AI,\nrunning entirely on your device.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(white: 0.5))
                    .padding(.horizontal, 32)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 64)
            
            // Features
            VStack(spacing: 24) {
                featureRow(
                    icon: "lock.shield.fill",
                    color: .green,
                    title: "Hybrid Privacy",
                    subtitle: modelManager.isAppleIntelligenceDeviceSupported ?
                        "MLX models run 100% on-device. Apple Intelligence may send data to Apple Inc. for advanced tasks." :
                        "Your data never leaves your device. Everything runs locally."
                )
                
                featureRow(
                    icon: "bolt.fill",
                    color: .orange,
                    title: "Lightning Fast",
                    subtitle: modelManager.isAppleIntelligenceDeviceSupported ?
                        "Powered by Apple Intelligence and on-device models." :
                        "Powered by highly optimized on-device models."
                )
                
                featureRow(
                    icon: "mic.fill",
                    color: .blue,
                    title: "Voice Interactions",
                    subtitle: "Speak naturally to your assistant."
                )
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            // Next button
            VStack(spacing: 12) {
                Button {
                    withAnimation {
                        currentPage = 1
                    }
                } label: {
                    Text("Next")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .pink.opacity(0.3), radius: 10, y: 5)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Page 2: Data & Privacy
    
    private var privacyPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 50, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text("Data & Privacy")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color(white: 0.1))
                    
                    Text("Before you begin, here's how the app handles your data.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(white: 0.5))
                        .padding(.horizontal, 32)
                }
                .padding(.top, 40)
                .padding(.bottom, 28)
                
                VStack(spacing: 16) {
                    // Data the app processes
                    privacyCard(
                        icon: "doc.text.fill",
                        iconColor: .blue,
                        title: "Data the App Processes",
                        items: [
                            "Chat messages and prompts you type",
                            "Text from documents you import",
                            "Voice input (speech-to-text)",
                            "Conversation history stored on your device"
                        ]
                    )
                    
                    // On-device models
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.green)
                            Text("On-Device Models (e.g. Gemma 2 2B)")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color(white: 0.2))
                        }
                        
                        Text("MLX models like Gemma 2 2B run **100% on your device**. Your prompts, documents, and personal data are **never sent** to Google LLC or any third-party AI service.")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.15), lineWidth: 1)
                    )
                    
                    
                    if modelManager.isAppleIntelligenceDeviceSupported {
                        // Apple Intelligence
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.intelligence")
                                    .foregroundStyle(.orange)
                                Text("Apple Intelligence")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color(white: 0.2))
                            }
                            
                            Text("If you choose Apple Intelligence, prompts and document text may be sent to **Apple Inc.** (including Private Cloud Compute) for AI processing. You will be asked for permission before this model is used.")
                                .font(.caption)
                                .foregroundStyle(Color(white: 0.5))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                        )
                    }
                    
                    // Model downloads
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Model Downloads")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color(white: 0.2))
                        }
                        
                        Text("Downloading model files uses a network request to **Hugging Face Inc.** This may share your IP address and device headers. No personal content is sent.")
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
                
                // Accept button
                VStack(spacing: 12) {
                    Button {
                        isPresented = false
                    } label: {
                        Text("I Understand & Accept")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .purple.opacity(0.3), radius: 10, y: 5)
                    }
                    
                    Text("By tapping above, you agree to our [Terms of Service](https://sudoswisshub.github.io/MetalMind-AI/terms.html) and [Privacy Policy](https://sudoswisshub.github.io/MetalMind-AI/privacy.html).")
                        .font(.caption)
                        .tint(.blue)
                        .foregroundStyle(Color(white: 0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.2))
                
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.6))
            }
            
            Spacer()
        }
    }
    
    private func privacyCard(icon: String, iconColor: Color, title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color(white: 0.2))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(iconColor.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .environment(ModelManager())
}
