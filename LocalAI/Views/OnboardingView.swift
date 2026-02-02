//
//  OnboardingView.swift
//  Own Ai
//
//  Created by Tudor on 29.01.2026.
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // Background
            Color.white.ignoresSafeArea()
            
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
                    
                    Text("Experience the power of AI,\nrunning 100% locally on your device.")
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
                        title: "Private & Secure",
                        subtitle: "Your data never leaves this device."
                    )
                    
                    featureRow(
                        icon: "bolt.fill",
                        color: .orange,
                        title: "Lightning Fast",
                        subtitle: "Powered by Apple Intelligence & MLX."
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
                
                // Action Button
                VStack(spacing: 12) {
                    Button {
                        isPresented = false
                    } label: {
                        Text("Understand & Accept Terms")
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
                    
                    Text("By tapping above, you agree to our [Terms of Service](https://sudoswisshub.github.io/MetalMind-AI/terms.html) and [Privacy Policy](https://sudoswisshub.github.io/MetalMind-AI/privacy.html).")
                        .font(.caption)
                        .tint(.orange)
                        .foregroundStyle(Color(white: 0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            animate = true
        }
    }
    
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
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
