//
//  AIIChunker.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A record's text, split into the partitions Thread embeds one by one.
//  OUT:  Pieces of about `target` characters, never more than `maximum`: whole paragraphs
//        packed together, a long paragraph cut at sentence ends, a long sentence cut hard.
//  PIN:  Nothing is dropped but the whitespace a split happens at, and no piece is empty.
//        Thread reads the best three partitions of a document, so a long document still
//        ranks by its best passages.
//

import Foundation

public enum AIIChunker {

    public static func split(_ text: String, target: Int = 1_500, maximum: Int = 2_000) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for paragraph in paragraphs {
            if paragraph.count > maximum {
                flush()
                pieces += sentences(of: paragraph, target: target, maximum: maximum)
            } else if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= target {
                current += "\n\n" + paragraph
            } else {
                flush()
                current = paragraph
            }
        }
        flush()
        return pieces
    }

    /// A paragraph too long for one piece: packed sentence by sentence.
    private static func sentences(of paragraph: String, target: Int, maximum: Int) -> [String] {
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        var pieces: [String] = []
        var current = ""
        for sentence in sentences {
            for part in hardSplit(sentence, maximum: maximum) {
                if current.isEmpty {
                    current = part
                } else if current.count + 1 + part.count <= target {
                    current += " " + part
                } else {
                    pieces.append(current)
                    current = part
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func hardSplit(_ sentence: String, maximum: Int) -> [String] {
        guard sentence.count > maximum else { return [sentence] }
        var parts: [String] = []
        var rest = Substring(sentence)
        while !rest.isEmpty {
            parts.append(String(rest.prefix(maximum)))
            rest = rest.dropFirst(maximum)
        }
        return parts
    }
}
