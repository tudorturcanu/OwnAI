# LocalAI

`LocalAI` is a SwiftUI iOS app for on-device chat, document-grounded answers, speech, and Apple Foundation Models / MLX model switching.

## Project Shape

- `LocalAI/`: main iOS app target
- `LocalAIWatchApp/`: watch companion app
- `Packages/LocalAIKit/`: shared speech/runtime package code
- `marketing/app-store-screenshots/`: marketing screenshot generator

## Main Runtime Pieces

- `LLMEngine`: model loading, session management, and streaming
- `ModelManager`: model availability, downloads, and selection
- `ChatHistoryManager`: conversations and persistence
- `DocumentManager`: per-chat document import
- `RAGEngine`: local retrieval index

## Persistence

- Chat history now uses:
  - `Documents/chat_history/index.json`
  - `Documents/chat_history/<conversation-id>.json`
- The old `Documents/chat_history.json` format is migrated automatically on first launch.
- Conversation documents and the RAG index are persisted by their own managers.

## Running

1. Open `LocalAI.xcodeproj`.
2. Select the `LocalAI` scheme.
3. Build on a physical device for MLX features.

## Gaps

- The repo has package-level tests for vendored speech code, but the app target still needs broader coverage around chat history, retrieval, and document workflows.
