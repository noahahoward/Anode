import Foundation

// ── Downloading a link into the library ─────────────────────────────────────
//
// One https download at a time per instance, with progress, cancel, and a size cap that is checked twice: against the length
// the server declares (refused before the bytes flow) and against the bytes actually received (a server can lie, or send no
// length at all). A redirect to anything but https is refused. Nothing here knows about video sites; it fetches the URL it is given.

final class WallpaperDownloader: NSObject, URLSessionDownloadDelegate {

    /// Redirects may only land on https.
    static func allowsRedirect(to url: URL) -> Bool { url.scheme?.lowercased() == "https" }

    /// Whether a download is over the cap, from the declared length (negative when unknown) and the bytes received so far.
    static func exceeds(maxBytes: Int64, declared: Int64, received: Int64) -> Bool {
        declared > maxBytes || received > maxBytes
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var maxBytes: Int64 = 0
    private var progress: ((Double) -> Void)?

    func download(_ url: URL, to destination: URL, maxBytes: Int64, progress: @escaping (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = cont
            self.destination = destination
            self.maxBytes = maxBytes
            self.progress = progress
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let t = s.downloadTask(with: url)
            self.session = s
            self.task = t
            lock.unlock()
            t.resume()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    /// Ends the download exactly once, whichever callback gets there first.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        let s = session, t = task
        continuation = nil; session = nil; task = nil; progress = nil
        lock.unlock()
        t?.cancel()
        s?.invalidateAndCancel()
        guard let cont else { return }
        switch result {
        case .success: cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let cap = maxBytes; let report = progress; lock.unlock()
        if Self.exceeds(maxBytes: cap, declared: totalBytesExpectedToWrite, received: totalBytesWritten) {
            finish(.failure(WallpaperImportError.tooLarge))
            return
        }
        if totalBytesExpectedToWrite > 0 { report?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let next = request.url, Self.allowsRedirect(to: next) {
            completionHandler(request)
        } else {
            completionHandler(nil)
            finish(.failure(WallpaperImportError.downloadFailed))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so it is moved here and now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(WallpaperImportError.downloadFailed))
            return
        }
        lock.lock(); let dest = destination; lock.unlock()
        guard let dest else { finish(.failure(WallpaperImportError.downloadFailed)); return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(WallpaperImportError.downloadFailed))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
