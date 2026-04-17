// Copyright 2026 David Sansome
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import WaniKaniAPI

enum TaskType {
  case reading
  case meaning

  static func random() -> TaskType {
    arc4random_uniform(2) == 0 ? .reading : .meaning
  }
}

class ReviewItem: NSObject {
  private static let supportedLessonTypes: [TKMSubject.TypeEnum] = [
    .radical,
    .kanji,
    .vocabulary,
  ]

  private class func filterReadyItems(assignments: [TKMAssignment],
                                      localCachingClient: LocalCachingClient,
                                      _ isIncluded: (TKMAssignment) -> Bool) -> [ReviewItem] {
    var ret = [ReviewItem]()
    guard localCachingClient.getUserInfo() != nil else {
      return ret
    }

    let showKanaOnlyVocab = Settings.showKanaOnlyVocab
    for assignment in assignments {
      if !localCachingClient.isValid(subjectId: assignment.subjectID) {
        continue
      }
      if !showKanaOnlyVocab, assignment.isKanaOnlyVocab {
        continue
      }
      if !isIncluded(assignment) {
        continue
      }
      ret.append(ReviewItem(assignment: assignment))
    }
    return ret
  }

  class func readyForReview(assignments: [TKMAssignment],
                            localCachingClient: LocalCachingClient) -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.isReviewStage && assignment.availableAtDate.timeIntervalSinceNow < 0
    }
  }

  class func readyForRecentMistakesReview(assignments: [TKMAssignment],
                                          localCachingClient: LocalCachingClient) -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.isReviewStage
    }
  }

  class func readyForRecentLessonReview(assignments: [TKMAssignment],
                                        localCachingClient: LocalCachingClient) -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.isReviewStage
    }
  }

  class func readyForAlreadyPassedApprenticeReview(assignments: [TKMAssignment],
                                                   localCachingClient: LocalCachingClient)
    -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.hasPassedAt && assignment.srsStage < .guru1
    }
  }

  class func readyForLeechReview(assignments: [TKMAssignment],
                                 localCachingClient: LocalCachingClient)
    -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.hasPassedAt && !assignment.hasBurnedAt
    }
  }

  class func readyForBurnedReview(assignments: [TKMAssignment],
                                  localCachingClient: LocalCachingClient) -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.isBurned
    }
  }

  class func readyForLessons(assignments: [TKMAssignment],
                             localCachingClient: LocalCachingClient) -> [ReviewItem] {
    filterReadyItems(assignments: assignments,
                     localCachingClient: localCachingClient) { assignment -> Bool in
      assignment.isLessonStage
    }
  }

  class func orderedForLessons(_ items: [ReviewItem], limit: Int? = nil) -> [ReviewItem] {
    let orderedItems: [ReviewItem]
    switch Settings.lessonOrderMode {
    case .fixed:
      orderedItems = items.sorted(by: { a, b in a.compareForLessons(other: b) })
    case .weightedShuffle:
      orderedItems = weightedShuffleLessonItems(items)
    }

    guard let limit, orderedItems.count > limit else {
      return orderedItems
    }
    return Array(orderedItems.prefix(limit))
  }

  let assignment: TKMAssignment
  let subject: TKMSubject?

  var answeredReading = false
  var answeredMeaning = false
  var answer = TKMProgress()
  var returnDelay = 0

  init(assignment: TKMAssignment, subject: TKMSubject? = nil) {
    self.assignment = assignment
    self.subject = subject
    answer.assignment = assignment
    answer.isLesson = assignment.isLessonStage
  }

  private class func getSubjectTypeIndex(_ subjectType: TKMSubject.TypeEnum) -> Int {
    for (idx, typeValue) in Settings.lessonOrder.enumerated() {
      if typeValue == subjectType {
        return idx
      }
    }
    return 0
  }

  private class func weightedShuffleLessonItems(_ items: [ReviewItem]) -> [ReviewItem] {
    var itemsByType = [TKMSubject.TypeEnum: [ReviewItem]]()
    var nextIndexByType = [TKMSubject.TypeEnum: Int]()
    var initialCountByType = [TKMSubject.TypeEnum: Int]()

    for type in supportedLessonTypes {
      let sortedItems = items.filter { $0.assignment.subjectType == type }
        .sorted(by: { a, b in a.compareForLessonLevelThenSubjectID(other: b) })
      itemsByType[type] = sortedItems
      nextIndexByType[type] = 0
      initialCountByType[type] = sortedItems.count
    }

    var orderedItems = [ReviewItem]()
    var previousType: TKMSubject.TypeEnum?
    while let nextType = nextWeightedLessonType(itemsByType: itemsByType,
                                                nextIndexByType: nextIndexByType,
                                                initialCountByType: initialCountByType,
                                                previousType: previousType) {
      let nextIndex = nextIndexByType[nextType]!
      orderedItems.append(itemsByType[nextType]![nextIndex])
      nextIndexByType[nextType] = nextIndex + 1
      previousType = nextType
    }

    return orderedItems
  }

  private class func nextWeightedLessonType(itemsByType: [TKMSubject.TypeEnum: [ReviewItem]],
                                            nextIndexByType: [TKMSubject.TypeEnum: Int],
                                            initialCountByType: [TKMSubject.TypeEnum: Int],
                                            previousType: TKMSubject.TypeEnum?)
    -> TKMSubject.TypeEnum? {
    let prioritizedLevel = prioritizedLessonLevel(itemsByType: itemsByType,
                                                  nextIndexByType: nextIndexByType)
    var bestType: TKMSubject.TypeEnum?
    var bestScore = -1.0
    var bestRemaining = -1
    var bestAvoidsRepeat = false

    for type in supportedLessonTypes {
      let items = itemsByType[type] ?? []
      let nextIndex = nextIndexByType[type] ?? 0
      let remaining = items.count - nextIndex
      if remaining <= 0 {
        continue
      }
      if let prioritizedLevel, items[nextIndex].assignment.level != prioritizedLevel {
        continue
      }

      let score = Double(remaining) / Double(max(initialCountByType[type] ?? 0, 1))
      let avoidsRepeat = previousType != type

      if bestType == nil ||
        score > bestScore ||
        (score == bestScore && avoidsRepeat && !bestAvoidsRepeat) ||
        (score == bestScore && avoidsRepeat == bestAvoidsRepeat && remaining > bestRemaining) ||
        (score == bestScore && avoidsRepeat == bestAvoidsRepeat && remaining == bestRemaining &&
          getSubjectTypeIndex(type) < getSubjectTypeIndex(bestType!)) {
        bestType = type
        bestScore = score
        bestRemaining = remaining
        bestAvoidsRepeat = avoidsRepeat
      }
    }

    return bestType
  }

  private class func prioritizedLessonLevel(itemsByType: [TKMSubject.TypeEnum: [ReviewItem]],
                                            nextIndexByType: [TKMSubject.TypeEnum: Int]) -> Int32? {
    var prioritizedLevel: Int32?

    for type in supportedLessonTypes {
      let items = itemsByType[type] ?? []
      let nextIndex = nextIndexByType[type] ?? 0
      if nextIndex >= items.count {
        continue
      }

      let level = items[nextIndex].assignment.level
      guard let currentLevel = prioritizedLevel else {
        prioritizedLevel = level
        continue
      }

      if Settings.prioritizeCurrentLevel {
        prioritizedLevel = max(currentLevel, level)
      } else {
        prioritizedLevel = min(currentLevel, level)
      }
    }

    return prioritizedLevel
  }

  func compareForLessonLevel(other: ReviewItem) -> Bool {
    if assignment.level < other.assignment.level {
      return Settings.prioritizeCurrentLevel ? false : true
    } else if assignment.level > other.assignment.level {
      return Settings.prioritizeCurrentLevel ? true : false
    }

    return false
  }

  func compareForLessonLevelThenSubjectID(other: ReviewItem) -> Bool {
    if compareForLessonLevel(other: other) {
      return true
    } else if other.compareForLessonLevel(other: self) {
      return false
    }

    return assignment.subjectID < other.assignment.subjectID
  }

  func compareForLessons(other: ReviewItem) -> Bool {
    if compareForLessonLevel(other: other) {
      return true
    } else if other.compareForLessonLevel(other: self) {
      return false
    }

    let myIndex = Self.getSubjectTypeIndex(assignment.subjectType)
    let otherIndex = Self.getSubjectTypeIndex(other.assignment.subjectType)
    if myIndex < otherIndex {
      return true
    } else if myIndex > otherIndex {
      return false
    }
    return assignment.subjectID < other.assignment.subjectID
  }

  func hasAttempts() -> Bool {
    answer.hasMeaningWrong || answer.hasReadingWrong ||
      answeredMeaning || answeredReading
  }

  func reset() {
    answer.clearMeaningWrong()
    answer.clearReadingWrong()
    answer.clearMeaningWrongCount()
    answer.clearReadingWrongCount()
    answeredMeaning = false
    answeredReading = false
  }
}
