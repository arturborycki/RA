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
    case drc = "DRC"
    case compare = "Compare"

    var id: String { rawValue }

    var label: String { rawValue }

    var title: String {
        switch self {
        case .ra:  return "Relational Algebra"
        case .trc: return "Tuple Relational Calculus"
        case .drc: return "Domain Relational Calculus"
        case .compare: return "All Three Notations"
        }
    }

    /// The views this notation can currently show, in display order. The third
    /// slot is notation-dependent: an operator tree for the algebra, a
    /// quantifier-scope tree for the calculus.
    var availableTabs: [ResultTab] {
        switch self {
        case .ra:        return ResultTab.allCases
        case .trc, .drc: return [.steps, .formula, .diagram]
        case .compare:   return []
        }
    }

    /// What the third tab is called here.
    var diagramLabel: String {
        switch self {
        case .ra:  return "Diagram"
        default:   return "Structure"
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
