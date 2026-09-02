//
//  SiriSettingsView.swift
//  LocalAI
//
//  Created by Tudor on 26.06.2026.
//

import AppIntents
import SwiftUI

/// A settings screen that explains Own AI's Siri integration and lets users
/// add or manage the "Ask Own AI" shortcut directly from within the app.
struct SiriSettingsView: View {

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                heroSection
                phrasesSection
                howItWorksSection
                shortcutsAppSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.27, blue: 0.55),
                                Color(red: 0.45, green: 0.28, blue: 0.60),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(
                        color: Color(red: 0.3, green: 0.2, blue: 0.5).opacity(0.35),
                        radius: 18,
                        y: 8
                    )

                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                Text("Talk to Own AI with Siri")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("Ask questions, start conversations, and get instant AI responses — all hands-free using your voice.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Add to Siri button
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
                .frame(maxWidth: 260)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Siri Phrases

    private var phrasesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Say to Siri")

            VStack(spacing: 0) {
                ForEach(siriPhrases.indices, id: \.self) { index in
                    HStack(spacing: 14) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)

                        Text("\"\(siriPhrases[index])\"")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .italic()

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)

                    if index < siriPhrases.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private let siriPhrases = [
        "Ask Own AI [your question]",
        "Get an answer from Own AI",
        "Chat with Own AI",
        "Talk to Own AI",
        "Hey Own AI",
    ]

    // MARK: - How It Works

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("How It Works")

            VStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 30, height: 30)
                            Text("\(index + 1)")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(steps[index].title)
                                .font(.body)
                                .fontWeight(.medium)

                            Text(steps[index].description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)

                    if index < steps.count - 1 {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private let steps: [(title: String, description: String)] = [
        (
            title: "Activate Siri",
            description: "Say \"Hey Siri\" or press the side button to open Siri."
        ),
        (
            title: "Speak your question",
            description: "Say \"Ask Own AI\" followed by your question."
        ),
        (
            title: "Own AI opens and responds",
            description: "The app opens with your question pre-filled and automatically sends it to your selected AI model."
        ),
        (
            title: "Own AI handles the response",
            description: "Siri hands your request to Own AI. Local models answer on-device; Apple Intelligence may use Apple processing when selected."
        ),
    ]

    // MARK: - Shortcuts App

    private var shortcutsAppSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Shortcuts App")

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apps.iphone")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automate Own AI")
                            .font(.body)
                            .fontWeight(.medium)

                        Text("Add Own AI to the Shortcuts app to build custom automations, widgets, and more.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider()
                    .padding(.leading, 60)

                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Private by Design")
                            .font(.body)
                            .fontWeight(.medium)

                        Text("Siri processes your spoken request under Apple's privacy terms, then hands it to Own AI. Local models generate the response on-device; Apple Intelligence may use Apple processing when selected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }
}

#Preview {
    NavigationStack {
        SiriSettingsView()
    }
}
