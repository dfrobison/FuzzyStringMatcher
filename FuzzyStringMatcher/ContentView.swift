//
//  ContentView.swift
//  FuzzyStringMatcher
//
//  Created by Doug Robison on 10/6/20.
//

import SwiftUI
import Combine

struct SearchResult: Hashable {
    let name: String
    let outScore: Int
    let matches: [Int]
}


class WordModel: ObservableObject {
    var filterCancellable = Set<AnyCancellable>()
    var searchCancellable: AnyCancellable?
    var valueDidChange = PassthroughSubject<Void, Never>()
    
    @Published var pattern: String = "" {
        didSet {
            valueDidChange.send()
        }
    }
    
    @Published var wordsMatch:[SearchResult] = []
    private var words: [String] = []
    
    init() {

        valueDidChange
            .sink { [self] in
                searchCancellable?.cancel()
                
               searchCancellable =  Search()
                    .receive(on: DispatchQueue.main)
                    .sink { matches in
                        print(Thread.isMainThread)
                        wordsMatch = matches
                    }
                    
        }
        .store(in: &filterCancellable)
        
        loadFile()
    }
    
    private func loadFile() {
        
        var contents = ""
        
        if let filepath = Bundle.main.path(forResource: "english3", ofType: "txt") {
            do {
                contents = try String(contentsOfFile: filepath)

            } catch {
                print("********** Error reading files \(error)")
            }
        } else {
            print("File not found")
        }
    
        
        let t = contents.components(separatedBy: "\n")

        for i in 0...10000 {
            words.append(t[i])
        }
    }
    
    func Search() -> AnyPublisher<[SearchResult], Never> {
        return Future<[SearchResult], Never> { promise in
            DispatchQueue.global(qos: .background).async {
                promise(.success(self.filter()))
            }
        }.eraseToAnyPublisher()
    }
    
    func filter() -> [SearchResult] {
        var fts = FuzzyTextSearch(pattern: pattern)

        var results: [SearchResult] = words.compactMap { str in
            var outScore = 0
            var matches: [Int] = []
            
            if fts.fuzzyMatch(stringToMatch: str, outScore: &outScore, matches: &matches) {
                return SearchResult(name: str, outScore: outScore, matches: matches)
            }
            
            return nil
        }
        
        results.sort {lhs, rhs in lhs.outScore > rhs.outScore}
        
        var limitResults: [SearchResult] = []
        
        if results.count > 30 {
            for index in 0...29 {
                limitResults.append(results[index])
            }
        }
        else {
            limitResults = results
        }
        
        return limitResults
    }
}

struct ContentView: View {
    @ObservedObject var wordModel: WordModel
    
    var body: some View {
        VStack {
            TextField("Start Typing", text: $wordModel.pattern)
            List(wordModel.wordsMatch, id: \.self) { match in
                return format(match: match)
            }
        }
    }
    
    func format(match: SearchResult) -> Text {
        
        var text: [Text] = []
        var str = ""
        var matchPosition = 0
        var matchIndex = match.matches[matchPosition]
        
        let ms = match.name
        
        for i in 0..<ms.count {
            let c = ms[ms.index(ms.startIndex, offsetBy: i)]
            
            if i == matchIndex {
                if !str.isEmpty {
                    text.append(Text(str))
                    str = ""
                }
                
                text.append(Text(String(c)).font(.body).fontWeight(.heavy).foregroundColor(.red))
                
                matchPosition += 1
                
                if matchPosition < match.matches.count {
                    matchIndex = match.matches[matchPosition]
                }
            }
            else {
                str.append(c)
            }
        }
        if !str.isEmpty {
            text.append(Text(str))
            str = ""
        }
        
        
        var t: Text = text[0]
        text.dropFirst().forEach { e in
            t = t + e
        }
        
        return t
    }
}


struct FuzzyTextSearch {
    private static let maxMatches = 256
    private static let defaultMatches: [Int] = Array(repeating: -1, count: maxMatches)
    private static let recursionLimit = 10
    private static let sequentialBonus = 15 // bonus for adjacent matches
    private static let separatorBonus = 30 // bonus if match occurs after a separator
    private static let camelBonus = 30 // bonus if match is uppercase and prev is lower
    private static let firstLetterBonus = 15 // bonus if the first letter is matched
    private static let leadingLetterPenalty = -5 // penalty applied for every letter in str before the first match
    private static let maxLeadingLetterPenalty = -15 // maximum penalty for leading letters
    private static let unmatchedLetterPenalty = -1 // penalty for every letter that doesn't matter
    private let neighborSeparator = "_ "
    private let pattern: String
    private let patternLength: Int
    private var str: String = ""
    private var strLength = 0

    init(pattern: String) {
        self.pattern = pattern
        patternLength = pattern.count
    }

    mutating func fuzzyMatchSimple(stringToMatch str: String) -> Bool {
        guard !pattern.isEmpty else {return true}
        guard !str.isEmpty else {return false}

        var strIndexOffset = 0
        var patternIndexOffset = 0

        strLength = str.count

        while (patternIndexOffset < patternLength) && (strIndexOffset < strLength) {
            if pattern[pattern.index(pattern.startIndex, offsetBy: patternIndexOffset)].lowercased() ==
                str[str.index(str.startIndex, offsetBy: strIndexOffset)].lowercased() {
                patternIndexOffset += 1
            }
            strIndexOffset += 1
        }

        return patternIndexOffset == patternLength
    }

    mutating func fuzzyMatch(stringToMatch str: String, outScore: inout Int) -> Bool {
        var matches: [Int] = []

        return fuzzyMatch(stringToMatch: str, outScore: &outScore, matches: &matches)
    }

    mutating func fuzzyMatch(stringToMatch str: String, outScore: inout Int, matches: inout [Int]) -> Bool {
        var recursionCount = 0
        var internalMatches = FuzzyTextSearch.defaultMatches

        self.str = str
        strLength = str.count

        let matched = fuzzyMatchRecursive(patternOffsetIndex: 0,
                                          strOffsetIndex: 0,
                                          outScore: &outScore,
                                          srcMatches: nil,
                                          matches: &internalMatches,
                                          nextMatch: 0,
                                          recursionCount: &recursionCount)
        
        matches = internalMatches.filter{$0 != -1}
        
        return matched
    }

    // Private implementation
    private mutating func fuzzyMatchRecursive(patternOffsetIndex: Int,
                                              strOffsetIndex: Int,
                                              outScore: inout Int,
                                              srcMatches: [Int]?,
                                              matches: inout [Int],
                                              nextMatch: Int,
                                              recursionCount: inout Int) -> Bool {
        // Count recursions
        recursionCount += 1
        guard recursionCount < FuzzyTextSearch.recursionLimit else {return false}

        // Detect end of strings
        guard patternOffsetIndex < patternLength && strOffsetIndex < strLength else {return false}

        var patternOffsetIndex = patternOffsetIndex
        var strOffsetIndex = strOffsetIndex
        var nextMatch = nextMatch

        // Recursion params
        var recursiveMatch = false
        var bestRecursiveMatches = FuzzyTextSearch.defaultMatches
        var bestRecursiveScore = 0

        // Loop through pattern and str looking for a match
        var first_match = true

        while patternOffsetIndex != patternLength && strOffsetIndex != strLength {
            // Found match
            if pattern[pattern.index(pattern.startIndex, offsetBy: patternOffsetIndex)].lowercased() ==
                str[str.index(str.startIndex, offsetBy: strOffsetIndex)].lowercased() {
                // Supplied matches buffer was too short
                if nextMatch >= FuzzyTextSearch.maxMatches {
                    return false
                }

                // Remember matches
                if first_match && srcMatches != nil {
                    for index in 0 ..< nextMatch {
                        matches[index] = srcMatches![index]
                    }
                    first_match = false
                }

                // Recursive call that "skips" this match
                var recursiveMatches = FuzzyTextSearch.defaultMatches
                var recursiveScore = 0

                if fuzzyMatchRecursive(patternOffsetIndex: patternOffsetIndex,
                                       strOffsetIndex: strOffsetIndex + 1,
                                       outScore: &recursiveScore,
                                       srcMatches: matches,
                                       matches: &recursiveMatches,
                                       nextMatch: nextMatch,
                                       recursionCount: &recursionCount) {
                    // Pick best recursive score
                    if !recursiveMatch || recursiveScore > bestRecursiveScore {
                        bestRecursiveMatches = recursiveMatches
                        bestRecursiveScore = recursiveScore
                    }

                    recursiveMatch = true
                }

                // Advance
                matches[nextMatch] = strOffsetIndex
                nextMatch += 1
                patternOffsetIndex += 1
            }
            strOffsetIndex += 1
        }

        // Determine if full pattern was matched
        let matched = patternOffsetIndex == patternLength

        // Calculate score
        if matched {
            // Nothing else needs to be looked since a match occurred
            strOffsetIndex = strLength

            // Initialize score
            outScore = 100

            // Apply leading letter penalty
            var penalty = FuzzyTextSearch.leadingLetterPenalty * matches[0]

            if penalty < FuzzyTextSearch.maxLeadingLetterPenalty {
                penalty = FuzzyTextSearch.maxLeadingLetterPenalty
            }

            outScore += penalty

            // Apply unmatched penalty
            let unmatched = strLength - nextMatch

            outScore += FuzzyTextSearch.unmatchedLetterPenalty * unmatched

            // Apply ordering bonuses
            for nextMatchIndex in 0 ..< nextMatch {
                let currIdx = matches[nextMatchIndex]

                if nextMatchIndex > 0 {
                    let prevIdx = matches[nextMatchIndex - 1]

                    // Sequential
                    if currIdx == (prevIdx + 1) {
                        outScore += FuzzyTextSearch.sequentialBonus
                    }
                }

                // Check for bonuses based on neighbor character value
                if currIdx > 0 {
                    // Camel case
                    let neighbor = str[str.index(str.startIndex, offsetBy: currIdx - 1)]
                    let curr = str[str.index(str.startIndex, offsetBy: currIdx)]

                    if neighbor.isLowercase && curr.isUppercase {
                        outScore += FuzzyTextSearch.camelBonus
                    }

                    // Separator
                    if neighborSeparator.contains(neighbor) {
                        outScore += FuzzyTextSearch.separatorBonus
                    }
                } else {
                    // First letter
                    outScore += FuzzyTextSearch.firstLetterBonus
                }
            }
        }

        // Return best result
        if recursiveMatch && (!matched || bestRecursiveScore > outScore) {
            // Recursive score is better than "this"
            matches = bestRecursiveMatches
            outScore = bestRecursiveScore
            return true
        } else if matched {
            // "this" score is better than recursive
            return true
        }

        // no match
        return false
    }
}


/*
 // https://www.forrestthewoods.com/blog/reverse_engineering_sublime_texts_fuzzy_match/
 // LICENSE
 //
 //   This software is dual-licensed to the public domain and under the following
 //   license: you are granted a perpetual, irrevocable license to copy, modify,
 //   publish, and distribute this file as you see fit.
 //
 // VERSION
 //   0.2.0  (2017-02-18)  Scored matches perform exhaustive search for best score
 //   0.1.0  (2016-03-28)  Initial release
 //
 // AUTHOR
 //   Forrest Smith
 //
 // NOTES
 //   Compiling
 //     You MUST add '#define FTS_FUZZY_MATCH_IMPLEMENTATION' before including this header in ONE source file to create implementation.
 //
 //   fuzzy_match_simple(...)
 //     Returns true if each character in pattern is found sequentially within str
 //
 //   fuzzy_match(...)
 //     Returns true if pattern is found AND calculates a score.
 //     Performs exhaustive search via recursion to find all possible matches and match with highest score.
 //     Scores values have no intrinsic meaning. Possible score range is not normalized and varies with pattern.
 //     Recursion is limited internally (default=10) to prevent degenerate cases (pattern="aaaaaa" str="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
 //     Uses uint8_t for match indices. Therefore patterns are limited to 256 characters.
 //     Score system should be tuned for YOUR use case. Words, sentences, file names, or method names all prefer different tuning.

 #ifndef FTS_FUZZY_MATCH_H
 #define FTS_FUZZY_MATCH_H

 #include <cstdint> // uint8_t
 #include <ctype.h> // ::tolower, ::toupper
 #include <cstring> // memcpy

 #include <cstdio>

 // Public interface
 namespace fts {
 static bool fuzzy_match_simple(char const * pattern, char const * str);
 static bool fuzzy_match(char const * pattern, char const * str, int & outScore);
 static bool fuzzy_match(char const * pattern, char const * str, int & outScore, uint8_t * matches, int maxMatches);
 }

 #ifdef FTS_FUZZY_MATCH_IMPLEMENTATION
 namespace fts {

 // Forward declarations for "private" implementation
 namespace fuzzy_internal {
     static bool fuzzy_match_recursive(const char * pattern, const char * str, int & outScore, const char * strBegin,
         uint8_t const * srcMatches,  uint8_t * newMatches,  int maxMatches, int nextMatch,
         int & recursionCount, int recursionLimit);
 }

 // Public interface
 static bool fuzzy_match_simple(char const * pattern, char const * str) {
     while (*pattern != '\0' && *str != '\0')  {
         if (tolower(*pattern) == tolower(*str))
             ++pattern;
         ++str;
     }

     return *pattern == '\0' ? true : false;
 }

 static bool fuzzy_match(char const * pattern, char const * str, int & outScore) {

     uint8_t matches[256];
     return fuzzy_match(pattern, str, outScore, matches, sizeof(matches));
 }

 static bool fuzzy_match(char const * pattern, char const * str, int & outScore, uint8_t * matches, int maxMatches) {
     int recursionCount = 0;
     int recursionLimit = 10;

     return fuzzy_internal::fuzzy_match_recursive(pattern, str, outScore, str, nullptr, matches, maxMatches, 0, recursionCount, recursionLimit);
 }

 // Private implementation
 static bool fuzzy_internal::fuzzy_match_recursive(const char * pattern, const char * str, int & outScore,
     const char * strBegin, uint8_t const * srcMatches, uint8_t * matches, int maxMatches,
     int nextMatch, int & recursionCount, int recursionLimit)
 {
     // Count recursions
     ++recursionCount;
     if (recursionCount >= recursionLimit)
         return false;

     // Detect end of strings
     if (*pattern == '\0' || *str == '\0')
         return false;

     // Recursion params
     bool recursiveMatch = false;
     uint8_t bestRecursiveMatches[256];
     int bestRecursiveScore = 0;

     // Loop through pattern and str looking for a match
     bool first_match = true;
     while (*pattern != '\0' && *str != '\0') {

         // Found match
         if (tolower(*pattern) == tolower(*str)) {

             // Supplied matches buffer was too short
             if (nextMatch >= maxMatches)
                 return false;

             // "Copy-on-Write" srcMatches into matches
             if (first_match && srcMatches) {
                 memcpy(matches, srcMatches, nextMatch);
                 first_match = false;
             }

             // Recursive call that "skips" this match
             uint8_t recursiveMatches[256];
             int recursiveScore;
             if (fuzzy_match_recursive(pattern, str + 1, recursiveScore, strBegin, matches, recursiveMatches, sizeof(recursiveMatches), nextMatch, recursionCount, recursionLimit)) {

                 // Pick best recursive score
                 if (!recursiveMatch || recursiveScore > bestRecursiveScore) {
                     memcpy(bestRecursiveMatches, recursiveMatches, 256);
                     bestRecursiveScore = recursiveScore;
                 }
                 recursiveMatch = true;
             }

             // Advance
             matches[nextMatch++] = (uint8_t)(str - strBegin);
             ++pattern;
         }
         ++str;
     }

     // Determine if full pattern was matched
     bool matched = *pattern == '\0' ? true : false;

     // Calculate score
     if (matched) {
         const int sequential_bonus = 15;            // bonus for adjacent matches
         const int separator_bonus = 30;             // bonus if match occurs after a separator
         const int camel_bonus = 30;                 // bonus if match is uppercase and prev is lower
         const int first_letter_bonus = 15;          // bonus if the first letter is matched

         const int leading_letter_penalty = -5;      // penalty applied for every letter in str before the first match
         const int max_leading_letter_penalty = -15; // maximum penalty for leading letters
         const int unmatched_letter_penalty = -1;    // penalty for every letter that doesn't matter

         // Iterate str to end
         while (*str != '\0')
             ++str;

         // Initialize score
         outScore = 100;

         // Apply leading letter penalty
         int penalty = leading_letter_penalty * matches[0];
         if (penalty < max_leading_letter_penalty)
             penalty = max_leading_letter_penalty;
         outScore += penalty;

         // Apply unmatched penalty
         int unmatched = (int)(str - strBegin) - nextMatch;
         outScore += unmatched_letter_penalty * unmatched;

         // Apply ordering bonuses
         for (int i = 0; i < nextMatch; ++i) {
             uint8_t currIdx = matches[i];

             if (i > 0) {
                 uint8_t prevIdx = matches[i - 1];

                 // Sequential
                 if (currIdx == (prevIdx + 1))
                     outScore += sequential_bonus;
             }

             // Check for bonuses based on neighbor character value
             if (currIdx > 0) {
                 // Camel case
                 char neighbor = strBegin[currIdx - 1];
                 char curr = strBegin[currIdx];
                 if (::islower(neighbor) && ::isupper(curr))
                     outScore += camel_bonus;

                 // Separator
                 bool neighborSeparator = neighbor == '_' || neighbor == ' ';
                 if (neighborSeparator)
                     outScore += separator_bonus;
             }
             else {
                 // First letter
                 outScore += first_letter_bonus;
             }
         }
     }

     // Return best result
     if (recursiveMatch && (!matched || bestRecursiveScore > outScore)) {
         // Recursive score is better than "this"
         memcpy(matches, bestRecursiveMatches, maxMatches);
         outScore = bestRecursiveScore;
         return true;
     }
     else if (matched) {
         // "this" score is better than recursive
         return true;
     }
     else {
         // no match
         return false;
     }
 }
 } // namespace fts

 #endif // FTS_FUZZY_MATCH_IMPLEMENTATION

 #endif // FTS_FUZZY_MATCH_H
 */
