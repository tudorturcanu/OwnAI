# Own AI

Own AI is a native SwiftUI assistant for private, on-device conversations on iPhone. It can run downloadable MLX language and vision models, use Apple's Foundation Models where available, answer questions about imported documents, and provide local speech input and output.

The Xcode target and some internal types retain the original `LocalAI` name.

## Features

- On-device chat with bundled, downloadable, or user-imported MLX models
- Automatic model selection based on device capabilities
- Apple Foundation Models support on compatible iOS 26 devices
- Document-grounded answers with local retrieval and optional OCR
- Image input for supported vision models
- Voice conversations, speech recognition, and local text-to-speech
- Conversation history, search, export, saved prompts, and optional memory
- Siri and Shortcuts integration
- Apple Watch companion app
- English, German, Spanish, and French localization

## Privacy

Conversation history, imported documents, retrieval indexes, saved prompts, and assistant memory are stored locally on the device. The app's privacy manifest declares no tracking or collected data.

Local MLX inference does not send prompts to a model provider. Features that explicitly use Apple Intelligence, web search, or model downloads may communicate with their respective services and are subject to those services' behavior and terms.

## Requirements

- Xcode 26 or later
- iOS 18 or later for the main app
- iOS 26 and an Apple Intelligence-compatible device for Apple Foundation Models
- watchOS 11 or later for the companion app
- [Git LFS](https://git-lfs.com/) for the bundled starter-model weights
- A physical iPhone is recommended for MLX inference and required for representative performance testing

## Build and Run

1. Install Git LFS and clone the repository:

   ```sh
   git lfs install
   git clone https://github.com/tudorturcanu/OwnAI.git
   cd OwnAI
   ```

2. Open `LocalAI.xcodeproj` in Xcode.
3. Allow Xcode to resolve the Swift package dependencies.
4. Select the `LocalAI` scheme and configure a development team for code signing if needed.
5. Choose an iPhone or simulator and run the app. Use a physical device for MLX models.

The repository includes a roughly 302 MB Qwen starter model stored through Git LFS. If the checkout contains an LFS pointer instead of the model, run `git lfs pull`.

## Project Structure

- `LocalAI/` — main iOS application
- `LocalAIWatchApp/` — watchOS companion application
- `Shared/` — models shared between the iOS and watchOS targets
- `Packages/KokoroSwiftLocal/` — local Kokoro text-to-speech package
- `Packages/MisakiSwiftLocal/` — local text-processing dependency for speech
- `Packages/LocalAIKit/` — package anchor for MLX framework linkage
- `scripts/` — lightweight source and behavior regression checks
- `docs/` — performance and App Store documentation

## Architecture

- `LLMEngine` manages local model loading, inference sessions, and streaming output.
- `ModelManager` handles the model catalog, downloads, imports, selection, and device compatibility.
- `ChatRuntimeCoordinator` coordinates the active conversation and generation lifecycle.
- `ChatHistoryStore` persists conversations as an index plus one JSON file per conversation.
- `DocumentManager` imports and extracts conversation documents.
- `RAGEngine` builds and searches the local retrieval index.
- `AppleFoundationModelBridge` integrates Apple's system language model on supported devices.

Chat history is stored under the app's Documents directory:

```text
chat_history/
├── index.json
└── <conversation-id>.json
```

The legacy `Documents/chat_history.json` format is migrated automatically on first launch.

## Regression Checks

The scripts in `scripts/` provide lightweight regression checks for important source and runtime policies. Run all of them from the repository root with:

```sh
check_dir=$(mktemp -d)
for script in scripts/*Regression.swift; do
  name=$(basename "$script" .swift)
  xcrun swiftc -parse-as-library "$script" -o "$check_dir/$name" && "$check_dir/$name"
done
```

These checks complement normal Xcode builds and device testing; they are not a complete app test suite.

## License

Own AI's original source code is available under the [GNU Affero General Public License version 3](LICENSE). Third-party dependencies, bundled model files, and other incorporated assets remain subject to their own license terms.
