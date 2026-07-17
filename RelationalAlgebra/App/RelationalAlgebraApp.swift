//
//  RelationalAlgebraApp.swift
//  RelationalAlgebra
//
//  App entry point. Targets iPadOS (also runs on iPhone and Mac Catalyst).
//

import SwiftUI

@main
struct RelationalAlgebraApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
