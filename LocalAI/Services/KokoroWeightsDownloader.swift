//
//  KokoroWeightsDownloader.swift
//  LocalAI
//
//  Background download of the ~315 MB Kokoro weights file. An ordinary
//  in-process URLSession is suspended a few seconds after the app is
//  backgrounded, which stalls (and usually fails) a download this large. A
//  background URLSession is handed to the system's `nsurlsessiond` daemon, so
//  the transfer keeps running while the app is suspended or terminated, and
//  the system relaunches the app in the background to finish it. The file
//  lands at `KokoroModelStore.weightsURL` regardless of whether any Swift
//  task is still awaiting it.
//
//  The small per-voice style tensors still go through HubApi in
//  `KokoroModelStore.download` — they are a rounding error and don't need to
//  survive backgrounding.
//

import Foundation
import UIKit

/// Downloads the shared Kokoro weights on a background URLSession and bridges
/// the delegate callbacks to an `async` API. Callbacks arrive on the session's
/// private serial delegate queue; a lock guards the shared state.
final class KokoroWeightsDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = KokoroWeightsDownloader()

    /// Must stay stable across launches: the system uses it to reconnect a
    /// relaunched app to the transfer that was already in flight.
    static let sessionIdentifier = "com.localai.kokoro.weights.download"

    private let lock = NSLock()

    /// One awaiter of the in-flight download. Several callers can await the
    /// same transfer; each gets its own progress handler and continuation.
    private struct Awaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let progress: @Sendable (Double) -> Void
    }
    private var awaiters: [Awaiter] = []

    /// The running download task, if any. Also set when a relaunched session
    /// re-adopts a transfer that was already in flight.
    private var downloadTask: URLSessionDownloadTask?

    /// True while an async `getAllTasks` probe is deciding whether to start or
    /// adopt a transfer, so concurrent callers don't each start one.
    private var isResolvingStart = false

    /// Set by `cancelAndReset` while a cancellation is in flight, so the
    /// completion callback drops the resume data instead of parking it.
    private var discardResumeDataOnCompletion = false

    /// Set in `didFinishDownloadingTo` so the error (or success) is delivered
    /// from `didCompleteWithError`, the one callback guaranteed to fire last.
    private var finishError: Error?

    /// The system completion handler from `handleEventsForBackgroundURLSession`.
    /// Retained until the session reports it has finished delivering events.
    /// UIKit hands it over on the main thread and it is called there too.
    private var backgroundEventsCompletionHandler: (() -> Void)?

    /// Built once in `init`, before the singleton is visible to any other
    /// thread — not a `lazy var`, so two threads can never race to construct
    /// two sessions sharing one background identifier (undefined behaviour).
    /// Implicitly unwrapped only because `self` (the delegate) can't be
    /// referenced until after `super.init()`.
    private var session: URLSession!

    /// Where a failed transfer's resume data is parked so an interrupted
    /// download continues from where it stopped instead of restarting the full
    /// ~315 MB. On disk, so it survives app termination too.
    private var resumeDataURL: URL {
        KokoroModelStore.downloadBase.appendingPathComponent("kokoro-weights.resume", isDirectory: false)
    }

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        // Start immediately rather than deferring to a "good" time — the user
        // is waiting on a voice they just selected.
        configuration.isDiscretionary = false
        // Cellular is gated per-request at start time (see startDownloadIfNeeded);
        // leaving the session permissive keeps that the single decision point.
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// Resolves once the weights are present and valid on disk. Downloads them
    /// on the background session if they are missing. Safe to call from several
    /// tasks at once — they share the single transfer.
    ///
    /// `allowsCellular` / `isCellularRestricted` come from the app's download
    /// settings; a fresh transfer is refused (thrown `cellularRestricted`) when
    /// the link is metered and cellular downloads are off, matching how MLX
    /// model downloads behave. An already-running transfer is never interrupted.
    ///
    /// If the awaiting task is cancelled, this throws `CancellationError` but
    /// deliberately leaves the OS download running, so it can still finish (and
    /// land the file) while the app is backgrounded.
    func downloadWeights(
        allowsCellular: Bool,
        isCellularRestricted: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if KokoroModelStore.isWeightsDownloaded {
            progress(1)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                // A late completion could have landed the file between the
                // guard above and acquiring the lock.
                if KokoroModelStore.isWeightsDownloaded {
                    lock.unlock()
                    progress(1)
                    continuation.resume()
                    return
                }
                // If cancellation raced ahead of registration, `onCancel` has
                // already run and found no awaiter to resume; without this
                // check the continuation below would never be resumed. The
                // flag is set before the handler runs, and the handler takes
                // the same lock, so a cancellation after this point always
                // sees the appended awaiter.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                awaiters.append(Awaiter(id: id, continuation: continuation, progress: progress))
                lock.unlock()
                startDownloadIfNeeded(allowsCellular: allowsCellular, isCellularRestricted: isCellularRestricted)
            }
        } onCancel: {
            resumeAndRemove(id: id, with: .failure(CancellationError()))
        }
    }

    /// True when the system is still running (or has suspended, awaiting
    /// connectivity) a weights transfer. Lets the app reattach progress after a
    /// background relaunch instead of starting a new download.
    func isDownloadInFlight() async -> Bool {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let live = tasks.contains {
                    ($0 is URLSessionDownloadTask) && ($0.state == .running || $0.state == .suspended)
                }
                continuation.resume(returning: live)
            }
        }
    }

    /// Cancels an in-flight transfer and forgets any saved resume data. Called
    /// when the user deletes the Kokoro model, so a background download can't
    /// re-land the file after a "delete".
    func cancelAndReset() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = tasks.filter { $0.state == .running || $0.state == .suspended }
            self.lock.lock()
            self.downloadTask = nil
            // `task.cancel()` is asynchronous: its `didCompleteWithError`
            // arrives later, carrying resume data that would otherwise be
            // written straight back after the delete below.
            self.discardResumeDataOnCompletion = !live.isEmpty
            self.lock.unlock()
            for task in live { task.cancel() }
            self.clearResumeData()
        }
    }

    /// Called from the app delegate when the system relaunches the app to
    /// deliver background-session events. Storing the handler reconnects the
    /// (already-created) session's delegate to the transfer in flight.
    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletionHandler = completionHandler
        lock.unlock()
        KokoroDiagnostics.log("bgDownload", "reconnected for background events")
    }

    // MARK: - Starting / adopting the transfer

    private func startDownloadIfNeeded(allowsCellular: Bool, isCellularRestricted: Bool) {
        lock.lock()
        guard downloadTask == nil, !isResolvingStart else {
            lock.unlock()
            return
        }
        isResolvingStart = true
        lock.unlock()

        // getAllTasks reports transfers the system kept running across a
        // suspension or relaunch, so a fresh session adopts the existing one
        // instead of starting a duplicate.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            self.isResolvingStart = false
            if self.downloadTask != nil {
                self.lock.unlock()
                return
            }
            if let existing = tasks.first(where: { $0 is URLSessionDownloadTask }) as? URLSessionDownloadTask {
                // Already running from before — never re-gate an in-flight
                // transfer on connectivity; just adopt it.
                self.downloadTask = existing
                self.lock.unlock()
                KokoroDiagnostics.log("bgDownload", "adopted in-flight task state=\(existing.state.rawValue)")
                return
            }
            // About to start (or resume) a fresh transfer: honour the app's
            // metered-network policy the same way MLX model downloads do.
            if !allowsCellular, isCellularRestricted {
                self.lock.unlock()
                KokoroDiagnostics.log("bgDownload", "refused: cellular restricted and cellular downloads off")
                self.resumeAll(with: .failure(KokoroError.cellularRestricted))
                return
            }
            let task: URLSessionDownloadTask
            if let resumeData = self.loadResumeData() {
                task = self.session.downloadTask(withResumeData: resumeData)
                KokoroDiagnostics.log("bgDownload", "RESUME \(resumeData.count) bytes")
            } else {
                // A stale partial at the destination would otherwise be
                // reported as present by the size check.
                try? FileManager.default.removeItem(at: KokoroModelStore.weightsURL)
                var request = URLRequest(url: KokoroModelStore.weightsRemoteURL)
                request.allowsCellularAccess = allowsCellular
                task = self.session.downloadTask(with: request)
                KokoroDiagnostics.log("bgDownload", "START \(KokoroModelStore.weightsRemoteURL.absoluteString)")
            }
            self.downloadTask = task
            self.lock.unlock()
            task.resume()
        }
    }

    // MARK: - Resume-data persistence

    private func loadResumeData() -> Data? {
        try? Data(contentsOf: resumeDataURL)
    }

    private func saveResumeData(_ data: Data) {
        try? FileManager.default.createDirectory(
            at: resumeDataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: resumeDataURL, options: .atomic)
    }

    private func clearResumeData() {
        try? FileManager.default.removeItem(at: resumeDataURL)
    }

    // MARK: - Delivering results

    private func resumeAndRemove(id: UUID, with result: Result<Void, Error>) {
        lock.lock()
        guard let index = awaiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let awaiter = awaiters.remove(at: index)
        lock.unlock()
        awaiter.continuation.resume(with: result)
    }

    private func resumeAll(with result: Result<Void, Error>) {
        lock.lock()
        let pending = awaiters
        awaiters.removeAll()
        lock.unlock()
        for awaiter in pending {
            awaiter.continuation.resume(with: result)
        }
    }

    private func notifyProgress(_ fraction: Double) {
        lock.lock()
        let handlers = awaiters.map(\.progress)
        lock.unlock()
        for handler in handlers { handler(fraction) }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        notifyProgress(min(1, max(0, fraction)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted the moment this method
        // returns, so the move must happen synchronously here.
        let destination = KokoroModelStore.weightsURL
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lock.lock(); finishError = KokoroError.incompleteDownload; lock.unlock()
            KokoroDiagnostics.log("bgDownload", "HTTP \(http.statusCode) — treating as failure")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            if KokoroModelStore.isPlausibleWeightsFile(at: destination) {
                lock.lock(); finishError = nil; lock.unlock()
                KokoroDiagnostics.log("bgDownload", "finished, file in place")
            } else {
                try? FileManager.default.removeItem(at: destination)
                lock.lock(); finishError = KokoroError.incompleteDownload; lock.unlock()
                KokoroDiagnostics.log("bgDownload", "downloaded file too small — discarded")
            }
        } catch {
            lock.lock(); finishError = error; lock.unlock()
            KokoroDiagnostics.log("bgDownload", "move FAILED: \(error)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        downloadTask = nil
        let resolved = finishError ?? error
        finishError = nil
        let discardResumeData = discardResumeDataOnCompletion
        discardResumeDataOnCompletion = false
        lock.unlock()

        if let resolved {
            // Park resume data so the next attempt continues instead of
            // restarting; if none came back after a resume attempt, the parked
            // data is stale and is cleared so we restart clean next time.
            let nsError = resolved as NSError
            if discardResumeData {
                clearResumeData()
                KokoroDiagnostics.log("bgDownload", "END cancelled by reset, resume data discarded")
            } else if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                saveResumeData(resumeData)
                KokoroDiagnostics.log("bgDownload", "END error, saved resume \(resumeData.count) bytes")
            } else if !(resolved is CancellationError) {
                clearResumeData()
                KokoroDiagnostics.log("bgDownload", "END error=\(resolved) (no resume data)")
            }
            resumeAll(with: .failure(resolved))
        } else {
            clearResumeData()
            KokoroDiagnostics.log("bgDownload", "END ok")
            resumeAll(with: .success(()))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        // UIKit requires the stored completion handler to be called on the
        // main thread.
        DispatchQueue.main.async { handler?() }
    }
}
