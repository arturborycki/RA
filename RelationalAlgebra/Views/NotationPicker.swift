//
//  NotationPicker.swift
//  RelationalAlgebra
//
//  The notation axis of the results pane.
//
//  Notation and view are kept orthogonal — three notations times three views
//  would be nine tabs, which is unusable. Each notation declares which views it
//  can offer, and the view picker is hidden when there is only one, so the
//  chrome grows only as the notations do.
//

import SwiftUI

enum Notation: String, CaseIterable, Identifiable {
    case ra = "RA"
    case trc = "TRC"

    var id: String { rawValue }

    var label: String { rawValue }

    var title: String {
        switch self {
        case .ra:  return "Relational Algebra"
        case .trc: return "Tuple Relational Calculus"
        }
    }

    /// The views this notation can currently show, in display order.
    var availableTabs: [ResultTab] {
        switch self {
        case .ra:  return ResultTab.allCases
        case .trc: return [.formula]
        }
    }
}

struct NotationPicker: View {
    @Binding var notation: Notation

    var body: some View {
        Picker("Notation", selection: $notation) {
            ForEach(Notation.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}
