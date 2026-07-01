//
//  AIPersonalityView.swift
//  LocalAI
//
//  Created by Tudor on 01.02.2026.
//

import SwiftUI
import UIKit

struct AIPersonalityView: View {
    @Environment(MonetizationManager.self) private var monetizationManager
    @AppStorage("systemPrompt") private var storedSystemPrompt = AIResponseDefaults.defaultSystemPrompt
    @AppStorage("temperature") private var storedTemperature = 0.7
    @AppStorage("topP") private var storedTopP = 1.0
    @AppStorage("maxTokens") private var storedMaxTokens = AIResponseDefaults.maxTokens
    @AppStorage("responseCharacterLimit") private var storedResponseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    @AppStorage("customPersonalityPresetsJSON") private var customPresetsJSON = "[]"
    @State private var draftSystemPrompt = AIResponseDefaults.defaultSystemPrompt
    @State private var draftTemperature = 0.7
    @State private var draftTopP = 1.0
    @State private var draftMaxTokens = AIResponseDefaults.maxTokens
    @State private var draftResponseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    @State private var showUpgradeSheet = false
    @State private var isEditorPresented = false
    @State private var isImportPresented = false
    @State private var importText = ""
    @State private var importErrorMessage: String?
    @State private var draftPreset = UserPersonalityPreset(
        name: "",
        icon: "sparkles",
        systemPrompt: AIResponseDefaults.defaultSystemPrompt,
        temperature: 0.7,
        topP: 1.0,
        maxTokens: AIResponseDefaults.maxTokens,
        responseCharacterLimit: AIResponseDefaults.responseCharacterLimit
    )
    @State private var editingPresetID: String?
    @State private var sharePayload: String?
    @State private var isSavePromptAlertPresented = false
    @State private var savePromptName = ""
    @State private var promptSaveErrorMessage: String?
    @State private var savedPromptsUpgradeFeature: PremiumFeature?
    @State private var hasLoadedDrafts = false

    private var promptStore: SavedPromptStore { SavedPromptStore.shared }

    private let responseLengthOptions = [0, 500, 1000, 1500, 2000]
    private let cardCornerRadius: CGFloat = 18

    private var selectedPresetID: String? {
        PersonalityPreset.presets.first { preset in
            preset.systemPrompt == draftSystemPrompt &&
            abs(preset.temperature - draftTemperature) < 0.0001 &&
            abs(preset.topP - draftTopP) < 0.0001 &&
            preset.maxTokens == draftMaxTokens &&
            draftResponseCharacterLimit == AIResponseDefaults.responseCharacterLimit
        }?.id
    }

    private var basePresetName: String? {
        PersonalityPreset.presets.first { preset in
            preset.systemPrompt == draftSystemPrompt &&
            abs(preset.temperature - draftTemperature) < 0.0001 &&
            abs(preset.topP - draftTopP) < 0.0001 &&
            preset.maxTokens == draftMaxTokens
        }?.name
    }

    private var userPresets: [UserPersonalityPreset] {
        (try? UserPersonalityPreset.decodeList(from: customPresetsJSON)) ?? []
    }

    private var activePresetName: String {
        if let selectedPresetID,
           let preset = PersonalityPreset.presets.first(where: { $0.id == selectedPresetID }) {
            return preset.name
        }

        if let basePresetName {
            return String(format: String(localized: "Modified %@", defaultValue: "Modified %@"), basePresetName)
        }

        return String(localized: "Custom")
    }

    private var savedPromptCountText: String {
        let count = promptStore.prompts.count
        return count == 1
            ? String(localized: "1 saved prompt")
            : String(format: String(localized: "%lld saved prompts", defaultValue: "%lld saved prompts"), Int64(count))
    }

    private var hasPendingChanges: Bool {
        draftSystemPrompt != storedSystemPrompt ||
        abs(draftTemperature - storedTemperature) > 0.0001 ||
        abs(draftTopP - storedTopP) > 0.0001 ||
        draftMaxTokens != storedMaxTokens ||
        draftResponseCharacterLimit != storedResponseCharacterLimit
    }

    private var draftPromptIsEmpty: Bool {
        draftSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                headerSection
                savedPromptsSection
                builtInPresetsSection
                customPresetsSection
                systemPromptSection
                parametersSection
                applyChangesSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(String(localized: "AI Personality"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeView(feature: .advancedPersonality)
                .environment(monetizationManager)
        }
        .sheet(item: $savedPromptsUpgradeFeature) { feature in
            UpgradeView(feature: feature)
                .environment(monetizationManager)
        }
        .alert(String(localized: "Save to Prompt Library"), isPresented: $isSavePromptAlertPresented) {
            TextField(String(localized: "Prompt name"), text: $savePromptName)
            Button(String(localized: "Save")) {
                let name = savePromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                let didSave = promptStore.add(
                    name: name.isEmpty ? String(localized: "Untitled Prompt") : name,
                    prompt: draftSystemPrompt
                )

                if !didSave {
                    promptSaveErrorMessage = promptStore.prompts.count >= SavedPromptStore.maxPrompts
                        ? String(localized: "The prompt library is full. Delete a prompt before saving another one.")
                        : String(localized: "Add a system prompt before saving it to the library.")
                }
            }
            .disabled(promptStore.prompts.count >= SavedPromptStore.maxPrompts || draftPromptIsEmpty)
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "Prompt Library saves instructions only. It does not save temperature, Top-P, or length settings."))
        }
        .alert(
            String(localized: "Couldn’t Save Prompt"),
            isPresented: Binding(
                get: { promptSaveErrorMessage != nil },
                set: { if !$0 { promptSaveErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { promptSaveErrorMessage = nil }
        } message: {
            Text(promptSaveErrorMessage ?? "")
        }
        .sheet(isPresented: $isEditorPresented) {
            PersonalityEditorSheet(
                title: editingPresetID == nil ? String(localized: "New Preset") : String(localized: "Edit Preset"),
                draft: $draftPreset
            ) { saved in
                upsertUserPreset(saved, editingID: editingPresetID)
            }
        }
        .sheet(isPresented: $isImportPresented) {
            NavigationStack {
                VStack(spacing: 12) {
                    Text(String(localized: "Paste a preset JSON to import."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextEditor(text: $importText)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        }

                    if let importErrorMessage {
                        Text(importErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()
                }
                .padding(16)
                .navigationTitle(String(localized: "Import Preset"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { isImportPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Import")) {
                            importPresets(from: importText)
                        }
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: shareSheetPresentedBinding, onDismiss: { sharePayload = nil }) {
            ShareSheet(items: [sharePayload ?? ""])
        }
        .onAppear(perform: syncInitialDraftsFromStorage)
        .onChange(of: storedSystemPrompt) { syncDraftsFromStorage() }
        .onChange(of: storedTemperature) { syncDraftsFromStorage() }
        .onChange(of: storedTopP) { syncDraftsFromStorage() }
        .onChange(of: storedMaxTokens) { syncDraftsFromStorage() }
        .onChange(of: storedResponseCharacterLimit) { syncDraftsFromStorage() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "brain.head.profile.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(
                        LinearGradient(
                            colors: [.indigo, .blue, .teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Shape how the assistant thinks, writes, and decides when it answers."))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Label(LocalizedStringKey(activePresetName), systemImage: "slider.horizontal.2.square")
                        Text("•")
                            .accessibilityHidden(true)
                        Text(String(format: "%.1f", draftTemperature))
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var savedPromptsSection: some View {
        settingsSection(title: "Saved Prompts") {
            NavigationLink {
                SavedPromptsView()
                    .environment(monetizationManager)
            } label: {
                HStack(spacing: 14) {
                    rowIcon(systemImage: "books.vertical.fill", tint: .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Prompt Library"))
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(savedPromptCountText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if !monetizationManager.canUse(.savedPrompts) {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel(String(localized: "Pro"))
                    }

                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var builtInPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey("Presets"))
                    .font(.footnote)
                    .bold()
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PersonalityPreset.presets) { preset in
                        Button {
                            withAnimation(.snappy) {
                                applyPreset(preset)
                            }
                        } label: {
                            Label(LocalizedStringKey(preset.name), systemImage: preset.icon)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .foregroundStyle(selectedPresetID == preset.id ? .white : .primary)
                                .background(
                                    selectedPresetID == preset.id ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(selectedPresetID == preset.id ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, -20)
        }
    }

    private var customPresetsSection: some View {
        sectionGroup(title: "Your Presets") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: startNewPreset) {
                        Label(String(localized: "New Full Preset"), systemImage: "plus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button(action: startImport) {
                        Label(String(localized: "Import"), systemImage: "square.and.arrow.down")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer(minLength: 0)
                }
                .padding(16)

                Divider()

                if userPresets.isEmpty {
                    emptyPresetRow
                } else {
                    ForEach(Array(userPresets.enumerated()), id: \.element.id) { index, preset in
                        customPresetRow(preset)

                        if index < userPresets.count - 1 {
                            Divider()
                                .padding(.leading, 62)
                        }
                    }
                }
            }
            .locked(if: !monetizationManager.canUse(.advancedPersonality), overlay: lockedOverlay)
        }
    }

    private var emptyPresetRow: some View {
        HStack(spacing: 14) {
            rowIcon(systemImage: "tray", tint: .gray)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "No custom presets yet"))
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(String(localized: "Save prompt and tuning together so you can reuse the full setup."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func customPresetRow(_ preset: UserPersonalityPreset) -> some View {
        Button {
            withAnimation(.snappy) {
                applyUserPreset(preset)
            }
        } label: {
            HStack(spacing: 14) {
                rowIcon(systemImage: preset.icon, tint: .indigo)

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(preset.systemPrompt)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "Edit")) {
                startEditing(preset)
            }

            Button(String(localized: "Export")) {
                export(preset)
            }

            Button(role: .destructive) {
                deleteUserPreset(id: preset.id)
            } label: {
                Text(String(localized: "Delete"))
            }
        }
    }

    private var systemPromptSection: some View {
        sectionGroup(
            title: "System Prompt",
            trailing: {
                HStack(spacing: 14) {
                    Button(String(localized: "Save Prompt")) {
                        savePromptToLibrary()
                    }
                    .foregroundStyle(.orange)

                    if draftSystemPrompt != AIResponseDefaults.defaultSystemPrompt {
                        Button(String(localized: "Reset")) {
                            resetDefaultPrompt()
                        }
                    }
                }
                .font(.subheadline)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draftSystemPrompt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 170)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                Text(String(localized: "This prompt is sent before each chat response. Save Prompt stores only this text; full presets include the tuning below."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .locked(if: !monetizationManager.canUse(.advancedPersonality), overlay: lockedOverlay)
        }
    }

    private var responseSizeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Response Size"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(String(localized: "Adds a visible-character cap for concise replies."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Picker(String(localized: "Response Size"), selection: $draftResponseCharacterLimit) {
                    ForEach(responseLengthOptions, id: \.self) { option in
                        Text(LocalizedStringKey(responseLengthLabel(for: option))).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(.secondary)
            }
        }
        .padding(16)
    }

    private var tokenLimitText: String {
        String(format: String(localized: "%lld tokens", defaultValue: "%lld tokens"), Int64(draftMaxTokens))
    }

    private func sliderParameterRow<Control: View>(
        title: LocalizedStringKey,
        valueText: String,
        help: LocalizedStringKey,
        tint: Color,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
            }

            control()

            Text(help)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func settingsSection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionGroup(title: title) {
            settingsCard(content: content)
        }
    }

    private func sectionGroup<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        sectionGroup(title: title, trailing: { EmptyView() }, content: content)
    }

    private func sectionGroup<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.footnote)
                    .bold()
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Spacer()

                trailing()
            }
            .padding(.horizontal, 4)

            settingsCard(content: content)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.background, in: RoundedRectangle(cornerRadius: cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func rowIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var applyChangesSection: some View {
        Group {
            if hasPendingChanges {
                HStack(spacing: 12) {
                    Button(action: discardDraftChanges) {
                        Label(String(localized: "Discard"), systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: applyDraftChanges) {
                        Label(String(localized: "Apply"), systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftPromptIsEmpty)
                }
                .font(.body)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: cardCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cardCornerRadius)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: hasPendingChanges)
    }

    private func startNewPreset() {
        guard monetizationManager.canUse(.advancedPersonality) else {
            showUpgradeSheet = true
            return
        }

        editingPresetID = nil
        draftPreset = UserPersonalityPreset(
            name: "",
            icon: "sparkles",
            systemPrompt: draftSystemPrompt,
            temperature: draftTemperature,
            topP: draftTopP,
            maxTokens: draftMaxTokens,
            responseCharacterLimit: draftResponseCharacterLimit
        )
        isEditorPresented = true
    }

    private func startImport() {
        guard monetizationManager.canUse(.advancedPersonality) else {
            showUpgradeSheet = true
            return
        }

        importText = ""
        importErrorMessage = nil
        isImportPresented = true
    }

    private func startEditing(_ preset: UserPersonalityPreset) {
        guard monetizationManager.canUse(.advancedPersonality) else {
            showUpgradeSheet = true
            return
        }

        editingPresetID = preset.id
        draftPreset = preset
        isEditorPresented = true
    }

    private func export(_ preset: UserPersonalityPreset) {
        if let json = try? UserPersonalityPreset.encode([sanitizedPreset(preset)]) {
            sharePayload = json
        }
    }

    private func savePromptToLibrary() {
        guard monetizationManager.canUse(.savedPrompts) else {
            savedPromptsUpgradeFeature = .savedPrompts
            return
        }

        guard !draftPromptIsEmpty else {
            promptSaveErrorMessage = String(localized: "Add a system prompt before saving it to the library.")
            return
        }

        guard promptStore.prompts.count < SavedPromptStore.maxPrompts else {
            promptSaveErrorMessage = String(localized: "The prompt library is full. Delete a prompt before saving another one.")
            return
        }

        savePromptName = ""
        isSavePromptAlertPresented = true
    }

    private func resetDefaultPrompt() {
        withAnimation(.snappy) {
            draftSystemPrompt = AIResponseDefaults.defaultSystemPrompt
        }
    }

    private func resetParameters() {
        withAnimation(.snappy) {
            draftTemperature = 0.7
            draftTopP = 1.0
            draftMaxTokens = AIResponseDefaults.maxTokens
            draftResponseCharacterLimit = AIResponseDefaults.responseCharacterLimit
        }
    }

    private func sanitizedPreset(_ preset: UserPersonalityPreset) -> UserPersonalityPreset {
        let trimmedName = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = preset.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = preset.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = isValidSystemImage(trimmedIcon) ? trimmedIcon : "sparkles"
        let responseLimit = responseLengthOptions.contains(preset.responseCharacterLimit)
            ? preset.responseCharacterLimit
            : AIResponseDefaults.responseCharacterLimit

        return UserPersonalityPreset(
            id: preset.id,
            name: trimmedName.isEmpty ? String(localized: "Untitled Preset") : trimmedName,
            icon: icon,
            systemPrompt: trimmedPrompt.isEmpty ? AIResponseDefaults.defaultSystemPrompt : trimmedPrompt,
            temperature: min(max(preset.temperature, 0.0), 1.0),
            topP: min(max(preset.topP, 0.0), 1.0),
            maxTokens: min(max(preset.maxTokens, 64), 4096),
            responseCharacterLimit: responseLimit
        )
    }

    private func isValidSystemImage(_ name: String) -> Bool {
        !name.isEmpty && UIImage(systemName: name) != nil
    }

    private func syncDraftsFromStorage() {
        draftSystemPrompt = storedSystemPrompt
        draftTemperature = storedTemperature
        draftTopP = storedTopP
        draftMaxTokens = storedMaxTokens
        draftResponseCharacterLimit = storedResponseCharacterLimit
    }

    private func syncInitialDraftsFromStorage() {
        guard !hasLoadedDrafts else { return }
        syncDraftsFromStorage()
        hasLoadedDrafts = true
    }

    private func applyDraftChanges() {
        guard !draftPromptIsEmpty else { return }

        storedSystemPrompt = draftSystemPrompt
        storedTemperature = draftTemperature
        storedTopP = draftTopP
        storedMaxTokens = draftMaxTokens
        storedResponseCharacterLimit = draftResponseCharacterLimit
    }

    private func discardDraftChanges() {
        withAnimation(.snappy) {
            syncDraftsFromStorage()
        }
    }

    private var parametersSection: some View {
        sectionGroup(
            title: "Parameters",
            trailing: {
                Button(String(localized: "Reset"), action: resetParameters)
                    .font(.subheadline)
            }
        ) {
            VStack(spacing: 0) {
                sliderParameterRow(
                    title: "Temperature",
                    valueText: String(format: "%.1f", draftTemperature),
                    help: "Lower values are consistent; higher values are more exploratory.",
                    tint: .orange
                ) {
                    Slider(value: $draftTemperature, in: 0.0...1.0)
                        .tint(.orange)
                }

                Divider()
                    .padding(.leading, 16)

                sliderParameterRow(
                    title: "Top-P",
                    valueText: String(format: "%.1f", draftTopP),
                    help: "Narrows sampling to the most likely words before choosing a response.",
                    tint: .blue
                ) {
                    Slider(value: $draftTopP, in: 0.0...1.0)
                        .tint(.blue)
                }

                Divider()
                    .padding(.leading, 16)

                responseSizeRow

                Divider()
                    .padding(.leading, 16)

                sliderParameterRow(
                    title: "Max Length",
                    valueText: tokenLimitText,
                    help: "Caps the generated response before the visible-character limit is applied.",
                    tint: .teal
                ) {
                    Slider(
                        value: Binding(
                            get: { Float(draftMaxTokens) },
                            set: { draftMaxTokens = Int($0) }
                        ),
                        in: 64...4096,
                        step: 64
                    )
                    .tint(.teal)
                }
            }
            .locked(if: !monetizationManager.canUse(.advancedPersonality), overlay: lockedOverlay)
        }
    }

    private func applyPreset(_ preset: PersonalityPreset) {
        draftSystemPrompt = preset.systemPrompt
        draftTemperature = preset.temperature
        draftTopP = preset.topP
        draftMaxTokens = preset.maxTokens
        draftResponseCharacterLimit = AIResponseDefaults.responseCharacterLimit
    }

    private func applyUserPreset(_ preset: UserPersonalityPreset) {
        let sanitized = sanitizedPreset(preset)
        draftSystemPrompt = sanitized.systemPrompt
        draftTemperature = sanitized.temperature
        draftTopP = sanitized.topP
        draftMaxTokens = sanitized.maxTokens
        draftResponseCharacterLimit = sanitized.responseCharacterLimit
    }

    private func upsertUserPreset(_ preset: UserPersonalityPreset, editingID: String?) {
        let sanitizedPreset = sanitizedPreset(preset)
        var current = userPresets
        if let editingID, let idx = current.firstIndex(where: { $0.id == editingID }) {
            var updated = sanitizedPreset
            updated = UserPersonalityPreset(
                id: editingID,
                name: updated.name,
                icon: updated.icon,
                systemPrompt: updated.systemPrompt,
                temperature: updated.temperature,
                topP: updated.topP,
                maxTokens: updated.maxTokens,
                responseCharacterLimit: updated.responseCharacterLimit
            )
            current[idx] = updated
        } else {
            current.insert(sanitizedPreset, at: 0)
        }
        persistUserPresets(current)
    }

    private func deleteUserPreset(id: String) {
        let filtered = userPresets.filter { $0.id != id }
        persistUserPresets(filtered)
    }

    private func persistUserPresets(_ presets: [UserPersonalityPreset]) {
        do {
            customPresetsJSON = try UserPersonalityPreset.encode(presets)
        } catch {
            // If encoding fails, do not overwrite existing storage.
        }
    }

    private func importPresets(from text: String) {
        do {
            let imported = try UserPersonalityPreset.decodeList(from: text).map(sanitizedPreset)
            guard !imported.isEmpty else {
                importErrorMessage = String(localized: "No presets found in this text.")
                return
            }
            var merged = userPresets
            for preset in imported {
                if let idx = merged.firstIndex(where: { $0.id == preset.id }) {
                    merged[idx] = preset
                } else {
                    merged.insert(preset, at: 0)
                }
            }
            persistUserPresets(merged)
            isImportPresented = false
        } catch {
            importErrorMessage = String(localized: "That doesn’t look like valid preset JSON.")
        }
    }

    private var shareSheetPresentedBinding: Binding<Bool> {
        Binding(
            get: { sharePayload != nil },
            set: { if !$0 { sharePayload = nil } }
        )
    }

    private func responseLengthLabel(for limit: Int) -> String {
        switch limit {
        case 0:
            return String(localized: "Unlimited")
        default:
            return String(format: String(localized: "%lld chars", defaultValue: "%lld chars"), Int64(limit))
        }
    }

    private var lockedOverlay: some View {
        RoundedRectangle(cornerRadius: cardCornerRadius)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text(String(localized: "Own AI Pro"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "Unlock custom prompts and response tuning."))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Unlock Pro")) {
                        showUpgradeSheet = true
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(20)
            }
    }
}

private extension View {
    @ViewBuilder
    func locked<LockOverlay: View>(if isLocked: Bool, overlay lockOverlay: LockOverlay) -> some View {
        ZStack {
            self
                .disabled(isLocked)
                .accessibilityHidden(isLocked)

            if isLocked {
                lockOverlay
            }
        }
    }
}



#Preview {
    NavigationStack {
        AIPersonalityView()
    }
    .environment(MonetizationManager())
}
