import Foundation

/// How well what was heard matches the sentence being practised, word by word.
enum SpeechScore {
    struct Result: Equatable {
        /// One per word of the target: said or missed.
        let words: [(word: String, said: Bool)]
        let percent: Int

        static func == (a: Result, b: Result) -> Bool {
            a.percent == b.percent && a.words.map(\.word) == b.words.map(\.word) && a.words.map(\.said) == b.words.map(\.said)
        }
    }

    /// Target words found, in order, in what was heard (longest common subsequence), so an extra
    /// or skipped word costs only itself.
    static func score(target: String, heard: String) -> Result {
        let t = Pronunciation.tokens(target)
        let h = Pronunciation.tokens(heard).map { $0.lowercased() }
        let tl = t.map { $0.lowercased() }
        guard !t.isEmpty else { return Result(words: [], percent: 0) }
        var dp = Array(repeating: Array(repeating: 0, count: h.count + 1), count: tl.count + 1)
        for i in stride(from: tl.count - 1, through: 0, by: -1) {
            for j in stride(from: h.count - 1, through: 0, by: -1) {
                dp[i][j] = tl[i] == h[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var said = Array(repeating: false, count: tl.count)
        var i = 0, j = 0
        while i < tl.count, j < h.count {
            if tl[i] == h[j] { said[i] = true; i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        let hits = said.filter { $0 }.count
        return Result(words: zip(t, said).map { ($0, $1) }, percent: Int((Double(hits) / Double(t.count) * 100).rounded()))
    }
}
