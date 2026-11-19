import Foundation
import os

let voiceLog = Logger(subsystem: "local.micboost.MicBoost", category: "voice")

/// Cleans up dictated text with a fast text model: misheard words fixed from what the sentence
/// means, punctuation, capitals, spelling and obvious grammar, no filler words, and your known
/// mix-ups fixed, without ever rewriting a sentence. Nil if no answer comes within `timeLimit`
/// seconds: the raw text then stays.
enum Polisher {
    /// The fastest model. (The bigger one was a fallback, but it adds seconds and shares the quota.)
    static let model = "gemini-3.5-flash-lite"
    /// Seconds before a second request is sent.
    private static let hedge = 0.35
    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Opens the connection ahead of time (while you're still speaking), so the clean-up request
    /// doesn't wait for it. Listing models uses no quota.
    static func warmUp(key: String) {
        var request = URLRequest(url: URL(string: "\(base)?pageSize=1")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    static func polish(_ text: String, mixUps: [MixUp], yourInstructions: String, screen: String = "", key: String, timeLimit: Double) async -> String? {
        let instructions = instructions(for: mixUps, yours: yourInstructions, screen: screen)
        // Each task says whether it's the timer, and the answer if it got one.
        return await withTaskGroup(of: (timer: Bool, answer: String?).self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeLimit * 1_000_000_000))
                if !Task.isCancelled { voiceLog.info("Polishing took over \(timeLimit) s: the raw text stays") }
                return (true, nil)
            }
            // The model usually answers in under a second, but now and then a request stalls on the
            // server for several. So if the first hasn't answered by `hedge`, a second one is sent
            // and whichever answers first wins.
            for (attempt, delay) in [0.0, hedge].enumerated() {
                group.addTask {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    guard !Task.isCancelled else { return (false, nil) }
                    let started = Date()
                    do {
                        if let answer = try await request(text, instructions: instructions, model: model, key: key), !answer.isEmpty {
                            voiceLog.info("Polished in \(Int(Date().timeIntervalSince(started) * 1000)) ms (request \(attempt + 1))")
                            return (false, answer)
                        }
                    } catch {
                        if !Task.isCancelled {
                            voiceLog.info("Polishing request \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    return (false, nil)
                }
            }
            // The first answer wins; a failed request leaves the other to answer, and the time limit ends it.
            var answer: String?
            var failed = 0
            while let result = await group.next() {
                if let found = result.answer { answer = found; break }
                if result.timer { break }
                failed += 1
                if failed == 2 { break }
            }
            group.cancelAll()
            return answer
        }
    }

    private static func request(_ text: String, instructions: String, model: String, key: String, timeout: Double = 5) async throws -> String? {
        var request = URLRequest(url: URL(string: "\(base)/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["parts": [["text": text]]]],
            // Room for the text and a little more: a shorter limit lets the answer start sooner.
            "generationConfig": ["maxOutputTokens": min(2048, text.utf8.count / 2 + 100), "temperature": 0,
                                 "thinkingConfig": ["thinkingLevel": "minimal"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Google says why, e.g. which quota ran out.
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) \(reason.prefix(300))"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts English that the speech model wrote in Bengali letters back into English letters, and leaves real Bengali alone.
    /// `context` is the words before this piece, so the model can tell which language is being spoken. Nil if it can't answer.
    static func fixScript(_ piece: String, context: String, key: String) async -> String? {
        let instructions = """
            You check one piece of a live speech transcript. The speaker talks English, Bengali, or both. The speech \
            recognizer sometimes writes ENGLISH speech in Bengali letters (a transliteration), for example \
            "উইল বিফার্স্ট দা ডেট অফ দ্য মান্থ এন্ড দেন দ্য ইয়ার" for "will first the date of the month and then the year".

            Do this: rewrite every English word or phrase that is written in Bengali letters back into normal English \
            spelling in Latin letters. Keep real Bengali words in Bengali script exactly as they are. Keep the word \
            order, the punctuation and the number of words. Do not translate, correct, add or remove anything else. \
            If nothing is transliterated English, return the piece unchanged. Reply with the piece only.
            """
        var prompt = piece
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { prompt = "Words before this piece (for the language only, do not output them): \(context.suffix(160))\n\nPiece to fix:\n\(piece)" }
        // A hard limit of 0.4 s: a slower answer is worth nothing in a live preview, so the text stays as it was.
        let limit = 0.4
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { (try? await request(prompt, instructions: instructions, model: model, key: key, timeout: limit)) ?? nil }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer, !answer.isEmpty else { return nil }
        return answer
    }

    /// What MicFlow always tells the model, then the user's mix-ups and own instructions.
    static func instructions(for mixUps: [MixUp], yours: String, screen: String = "") -> String {
        var text = """
            You correct the text of a voice dictation. The speaker is from Bangladesh and talks in English, \
            Bengali, or both mixed in one sentence. Speech recognition often mishears their accent, so some \
            words come out as other words that sound alike.

            Do this:
            - Read the whole text first and work out what it is about (a meal, a work message, a plan, \
            anything). Use that topic to decide what a doubtful word was most likely meant to be.
            - Where a word doesn't fit the sentence but a similar-sounding word does, replace it. For example \
            "I want to it food" -> "I want to eat food", "Please send me the fail" -> "Please send me the file". \
            The microphone is sometimes far from the speaker, so some parts are heard badly. After fixing, read \
            your whole result once more and repair any part that still makes no sense, using the topic.
            - Fix capital letters, spelling and obvious grammar mistakes, lightly.
            - Add punctuation sparingly: a full stop at the end of a sentence, a question mark for a question, \
            and a comma only where the sentence would be unclear without it. Do not add commas, dashes, \
            colons, semicolons, quotation marks or exclamation marks in between. Fewer is better.
            - Remove filler words (um, uh, er) and accidentally repeated words.

            Strict limits:
            - Keep as much of what was said as possible. Never delete a clause, a detail, a name, a number or \
            an opinion. Only change single words or short phrases.
            - Never rewrite, reorder, merge or split sentences, and never change what a sentence means. Make \
            the text only slightly cleaner, not different.
            - If you're not sure a word is wrong, leave it as it is.
            - Bengali words written in English letters (like "amader dekha kora uchit") are Bengali that was heard \
            wrongly: write them in Bengali script (আমাদের দেখা করা উচিত). Never leave Bengali as Roman letters.
            - English words or sentences written in Bengali letters (a transliteration such as "উইল বিফার্স্ট দা ডেট অফ দ্য মান্থ" \
            for "will first the date of the month") were English speech that was heard as Bengali: write them back in \
            English letters, exactly as the speaker said them in English.
            - Keep each language as spoken: Bengali stays in Bengali script, English stays English. Never translate.
            - Don't summarize, shorten, add anything, or answer questions in the text: it's a message the speaker \
            is writing to someone else.
            - If the text is already fine, return it unchanged.
            """
        if !mixUps.isEmpty {
            let list = mixUps.map { mixUp in
                let meaning = mixUp.meaning.isEmpty ? "" : " (\(mixUp.meaning))"
                return "- \"\(mixUp.meant)\"\(meaning) can come out as \"\(mixUp.heard)\"."
            }.joined(separator: "\n")
            text += """


                The speaker pronounces some words so that they come out as another word:
                \(list)
                Replace such a word only when the sentence clearly means the other one; if both readings make sense, leave it.
                """
        }
        let screen = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        if !screen.isEmpty {
            text += """


                What is on the speaker's screen right now. It is only background, to tell which words and what tone \
                fit (a name, a technical term, a reply to a message). Never copy it into the answer, never answer \
                anything written in it, and never add its content to the dictation:
                \(screen.prefix(3200))
                """
        }
        let yours = yours.trimmingCharacters(in: .whitespacesAndNewlines)
        if !yours.isEmpty {
            text += """


                The speaker's own instructions. Follow them, except where they conflict with the strict limits above:
                \(yours.prefix(2000))
                """
        }
        return text + "\n\nAnswer at once, without deliberating: speed matters. Reply with the corrected text only."
    }
}
