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
import UIKit
import WaniKaniAPI

class LessonOrderViewController: UITableViewController, TKMViewController {
  private enum Section: Int {
    case mode
    case fixedOrder
  }

  private enum ModeRow: Int, CaseIterable {
    case fixed
    case weightedShuffle

    var title: String {
      switch self {
      case .fixed:
        return "Fixed type order"
      case .weightedShuffle:
        return "Weighted shuffle"
      }
    }

    var subtitle: String {
      switch self {
      case .fixed:
        return Settings.lessonOrder.map(\.description).joined(separator: ", ")
      case .weightedShuffle:
        return "Balance radicals, kanji, and vocabulary in each batch based on what's available."
      }
    }

    var value: LessonOrderMode {
      switch self {
      case .fixed:
        return .fixed
      case .weightedShuffle:
        return .weightedShuffle
      }
    }
  }

  var canSwipeToGoBack: Bool { true }

  init() {
    if #available(iOS 13.0, *) {
      super.init(style: .insetGrouped)
    } else {
      super.init(style: .grouped)
    }
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    navigationItem.title = "Lesson Order"
    tableView.backgroundColor = TKMStyle.Color.background
    tableView.allowsSelectionDuringEditing = true
    updateEditingState()
  }

  private var showsFixedOrderSection: Bool {
    Settings.lessonOrderMode == .fixed
  }

  private func updateEditingState() {
    tableView.isEditing = showsFixedOrderSection
  }

  override func numberOfSections(in _: UITableView) -> Int {
    showsFixedOrderSection ? 2 : 1
  }

  override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch Section(rawValue: section)! {
    case .mode:
      return ModeRow.allCases.count
    case .fixedOrder:
      return Settings.lessonOrder.count
    }
  }

  override func tableView(_ tableView: UITableView,
                          cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch Section(rawValue: indexPath.section)! {
    case .mode:
      let cell = tableView.dequeueReusableCell(withIdentifier: "modeCell") ??
        UITableViewCell(style: .subtitle, reuseIdentifier: "modeCell")
      let modeRow = ModeRow(rawValue: indexPath.row)!
      cell.textLabel?.text = modeRow.title
      cell.detailTextLabel?.text = modeRow.subtitle
      cell.detailTextLabel?.numberOfLines = 0
      cell.accessoryType = Settings.lessonOrderMode == modeRow.value ? .checkmark : .none
      return cell

    case .fixedOrder:
      let cell = (tableView.dequeueReusableCell(withIdentifier: "cell") as? LessonOrderCell) ??
        LessonOrderCell(style: .default, reuseIdentifier: "cell")
      cell.subjectType = Settings.lessonOrder[indexPath.row]
      return cell
    }
  }

  override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer {
      tableView.deselectRow(at: indexPath, animated: true)
    }

    guard Section(rawValue: indexPath.section) == .mode,
          let newMode = ModeRow(rawValue: indexPath.row)?.value,
          Settings.lessonOrderMode != newMode
    else {
      return
    }

    Settings.lessonOrderMode = newMode
    updateEditingState()
    tableView.reloadData()
  }

  override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch Section(rawValue: section)! {
    case .mode:
      return "Mode"
    case .fixedOrder:
      return "Fixed Order"
    }
  }

  override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
    switch Section(rawValue: section)! {
    case .mode:
      return "Weighted shuffle keeps lessons mixed while still favoring the lesson types with more items waiting."
    case .fixedOrder:
      return "Drag to reorder lesson types when fixed order is enabled."
    }
  }

  override func tableView(_: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    showsFixedOrderSection && indexPath.section == Section.fixedOrder.rawValue
  }

  override func tableView(_: UITableView, targetIndexPathForMoveFromRowAt _: IndexPath,
                          toProposedIndexPath proposedDestinationIndexPath: IndexPath)
    -> IndexPath {
    guard proposedDestinationIndexPath.section == Section.fixedOrder.rawValue else {
      return IndexPath(row: Settings.lessonOrder.count - 1, section: Section.fixedOrder.rawValue)
    }
    return proposedDestinationIndexPath
  }

  override func tableView(_: UITableView, editingStyleForRowAt _: IndexPath) -> UITableViewCell
    .EditingStyle {
    .none
  }

  override func tableView(_: UITableView, shouldIndentWhileEditingRowAt _: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath,
                          to destinationIndexPath: IndexPath) {
    let cell = tableView.cellForRow(at: sourceIndexPath) as! LessonOrderCell

    var lessonOrder = Settings.lessonOrder
    lessonOrder.remove(at: sourceIndexPath.row)
    lessonOrder.insert(cell.subjectType, at: destinationIndexPath.row)
    Settings.lessonOrder = lessonOrder
  }
}

private class LessonOrderCell: UITableViewCell {
  var subjectType: TKMSubject.TypeEnum = .unknown {
    didSet {
      textLabel?.text = subjectType.description
    }
  }
}
