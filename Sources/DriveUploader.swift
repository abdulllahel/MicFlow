import Foundation

/// Uploads a recording to the person's own Google Drive, makes it viewable by anyone with the link,
/// and returns that link. The video goes straight from this Mac to their Drive: MicFlow's server
/// never sees it. Needs only Google's "drive.file" permission, asked the first time.
@MainActor
final class DriveUploader {
    struct Failure: LocalizedError { let errorDescription: String? }

    private var token: String?
    private var tokenExpires = Date.distantPast
    /// Gets a Drive access token (opens Google's permission screen the first time).
    var accessToken: () async -> String? = { nil }

    func upload(_ file: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let token = try await validToken()
        // 1) Start a resumable upload, so big videos are fine.
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["name": file.lastPathComponent, "mimeType": "video/mp4"])
        let (_, started) = try await URLSession.shared.data(for: start)
        guard let http = started as? HTTPURLResponse, http.statusCode == 200,
              let location = http.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw Failure(errorDescription: "Google Drive didn't accept the upload. Try again, or check that you allowed MicFlow to save files to your Drive.")
        }
        // 2) Send the file, reporting progress.
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let watcher = ProgressWatcher(progress)
        let (data, sent) = try await URLSession.shared.upload(for: put, fromFile: file, delegate: watcher)
        guard let done = sent as? HTTPURLResponse, (200..<300).contains(done.statusCode),
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw Failure(errorDescription: "The upload to Google Drive didn't finish. Check your internet connection and try again.")
        }
        // 3) Anyone with the link can watch it.
        var share = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/permissions")!)
        share.httpMethod = "POST"
        share.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        share.setValue("application/json", forHTTPHeaderField: "Content-Type")
        share.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        let (_, shared) = try await URLSession.shared.data(for: share)
        guard (shared as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(errorDescription: "The video is in your Drive, but MicFlow couldn't make its link public. Open it in Drive and share it from there.")
        }
        return URL(string: "https://drive.google.com/file/d/\(id)/view")!
    }

    private func validToken() async throws -> String {
        if let token, tokenExpires > Date() { return token }
        guard let fresh = await accessToken() else {
            throw Failure(errorDescription: "MicFlow needs your permission to save the video to your Google Drive. Try again and allow it on Google's screen.")
        }
        token = fresh
        tokenExpires = Date().addingTimeInterval(50 * 60)
        return fresh
    }

    private final class ProgressWatcher: NSObject, URLSessionTaskDelegate {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            DispatchQueue.main.async { self.report(fraction) }
        }
    }
}
