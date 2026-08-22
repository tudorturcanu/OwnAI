//
//  VoiceConversationView.swift
//  LocalAI
//
//  Created by Tudor.
//

import SwiftUI

/// Full-screen hands-free voice conversation UI.
///
/// This view is purely presentational: the actual conversation loop
/// (final transcription -> send, finalized reply -> spoken TTS, speech
/// finished -> resume listening) lives in ChatView's onChange handlers and
/// keeps running while this cover is presented. The screen reflects that
/// loop's state and offers three interactions: end the session, skip the
/// current spoken reply, and re-arm the microphone after an idle stall.
struct VoiceConversationView: View {
    @Environment(SpeechManager.self) private var speechManager
    @Environment(LLMEngine.self) private var llmEngine
    @Environment(ModelManager.self) private var modelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bound to ChatView's `voiceConversationMode`; setting it false ends the
    /// session (ChatView stops the mic and speech) and dismisses this cover.
    @Binding var isActive: Bool

    /// Starts listening, with ChatView's permission/engine guards applied.
    let onStartListening: () -> Void

    private enum Phase: Equatable {
        case listening
        case thinking
        case speaking
        case idle

        var label: String {
            switch self {
            case .listening: return String(localized: "Listening…")
            case .thinking: return String(localized: "Thinking…")
            case .speaking: return String(localized: "Speaking")
            case .idle: return String(localized: "Tap the circle to talk")
            }
        }
    }

    /// The loop's current phase, derived rather than stored so the screen can
    /// never disagree with the underlying managers. Order matters: speech
    /// output wins over "generating" because both are briefly true while the
    /// tail of a reply is still being spoken.
    private var phase: Phase {
        if speechManager.isSpeaking || !speechManager.isSpeechQueueEmpty {
            return .speaking
        }
        if llmEngine.state == .generating || llmEngine.state == .loading {
            return .thinking
        }
        if speechManager.isListening {
            return .listening
        }
        return .idle
    }

    /// The phase label, except during a model load, which can take a while
    /// and deserves an honest message instead of "Thinking…".
    private var statusText: String {
        if phase == .thinking && llmEngine.state == .loading {
            return String(localized: "Loading model…")
        }
        if phase == .speaking && speechManager.isPreparingSpeechOutput {
            return String(localized: "Preparing voice…")
        }
        return phase.label
    }

    private var orbAccentColor: Color {
        switch phase {
        case .listening: return Color(red: 0.20, green: 0.48, blue: 0.97)
        case .thinking: return Color(red: 0.48, green: 0.36, blue: 0.94)
        case .speaking: return Color(red: 0.13, green: 0.62, blue: 0.52)
        case .idle: return Color(white: 0.55)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer()

            orb
                .frame(maxWidth: .infinity)

            Text(statusText)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.adaptive(white: 0.25))
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.25), value: statusText)
                .padding(.top, 44)

            transcriptArea
                .padding(.top, 12)

            Spacer()

            endButton
                .padding(.bottom, 40)
        }
        .padding(.horizontal, 24)
        .background(backgroundGradient.ignoresSafeArea())
        .onAppear {
            // Covers the resume path (e.g. the session was interrupted by a
            // phone call): if nothing is running, re-arm the mic. The normal
            // entry path already started listening via ChatView's onChange.
            if phase == .idle {
                onStartListening()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Voice Conversation"))
                    .font(.headline)
                    .foregroundStyle(Color.adaptive(white: 0.15))
                Text(modelManager.selectedModel?.name ?? String(localized: "No model selected"))
                    .font(.footnote)
                    .foregroundStyle(Color.adaptive(white: 0.5))
            }

            Spacer()

            Label(String(localized: "On-device"), systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.adaptive(white: 0.45))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.adaptiveCard.opacity(0.8))
                .clipShape(Capsule())
        }
        .padding(.top, 20)
    }

    // MARK: - Orb

    private var orb: some View {
        Button(action: handleOrbTap) {
            ZStack {
                // Outer halo that swells with the microphone level while
                // listening, and breathes on a slow cycle while speaking.
                Circle()
                    .fill(orbAccentColor.opacity(0.16))
                    .frame(width: 220, height: 220)
                    .scaleEffect(haloScale)
                    .animation(.smooth(duration: 0.16), value: haloScale)

                Circle()
                    .fill(orbAccentColor.opacity(0.22))
                    .frame(width: 176, height: 176)
                    .scaleEffect(midScale)
                    .animation(.smooth(duration: 0.16), value: midScale)

                coreCircle
                    .frame(width: 140, height: 140)

                orbGlyph
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(orbAccessibilityLabel)
        .animation(.smooth(duration: 0.35), value: phase)
    }

    /// The solid center. While thinking it carries a slowly sweeping angular
    /// gradient so "working" reads even with no level signal; otherwise it is
    /// a calm radial fill in the phase color.
    @ViewBuilder
    private var coreCircle: some View {
        if phase == .thinking && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let angle = Angle(degrees: context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 4) / 4 * 360)
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                orbAccentColor,
                                orbAccentColor.opacity(0.55),
                                orbAccentColor
                            ],
                            center: .center,
                            angle: angle
                        )
                    )
            }
        } else {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [orbAccentColor.opacity(0.95), orbAccentColor.opacity(0.7)],
                        center: .init(x: 0.35, y: 0.3),
                        startRadius: 8,
                        endRadius: 130
                    )
                )
        }
    }

    @ViewBuilder
    private var orbGlyph: some View {
        switch phase {
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.breathe, options: reduceMotion ? .nonRepeating : .repeating, isActive: !reduceMotion)
        case .thinking:
            Image(systemName: "ellipsis")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
        case .speaking:
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
        case .idle:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Halo scale: real microphone level while listening, gentle fixed
    /// breathing while speaking, still otherwise. Reduce Motion pins both.
    private var haloScale: Double {
        guard !reduceMotion else { return 1.0 }
        switch phase {
        case .listening:
            return 1.0 + speechManager.inputAudioLevel * 0.45
        case .speaking:
            return 1.12
        case .thinking, .idle:
            return 1.0
        }
    }

    private var midScale: Double {
        guard !reduceMotion else { return 1.0 }
        switch phase {
        case .listening:
            return 1.0 + speechManager.inputAudioLevel * 0.25
        case .speaking:
            return 1.06
        case .thinking, .idle:
            return 1.0
        }
    }

    private var orbAccessibilityLabel: String {
        switch phase {
        case .listening: return String(localized: "Listening. Double tap to stop listening.")
        case .thinking: return String(localized: "Thinking.")
        case .speaking: return String(localized: "Speaking. Double tap to skip the spoken reply.")
        case .idle: return String(localized: "Start listening.")
        }
    }

    private func handleOrbTap() {
        switch phase {
        case .speaking:
            // Skip the rest of the spoken reply. stopSpeaking() bumps
            // speechCompletionVersion, which makes ChatView's loop re-arm
            // the microphone once generation is also finished.
            speechManager.stopSpeaking()
        case .listening:
            speechManager.stopListening()
        case .idle:
            onStartListening()
        case .thinking:
            break
        }
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        Group {
            if let text = transcriptText, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.adaptive(white: 0.4))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .transition(.opacity)
            } else {
                // Keep the layout stable so the orb doesn't shift as text
                // appears and disappears between turns.
                Text(verbatim: " ")
                    .font(.body)
            }
        }
        .frame(minHeight: 88, alignment: .top)
        .animation(.smooth(duration: 0.2), value: transcriptText)
    }

    /// While the user talks, show their words; while the model answers, show
    /// the tail of the streamed reply that is being spoken.
    private var transcriptText: String? {
        switch phase {
        case .listening:
            return speechManager.transcribedText
        case .thinking, .speaking:
            let visible = AssistantOutputSanitizer.sanitize(llmEngine.currentResponse)
            return visible.isEmpty ? nil : String(visible.suffix(280))
        case .idle:
            return nil
        }
    }

    // MARK: - Controls

    private var endButton: some View {
        Button {
            isActive = false
        } label: {
            Label(String(localized: "End"), systemImage: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.adaptive(white: 0.15))
                .clipShape(Capsule())
        }
        .accessibilityLabel(String(localized: "End voice conversation"))
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.adaptive(white: 0.98),
                orbAccentColor.opacity(0.07)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .animation(.smooth(duration: 0.6), value: phase)
    }
}
