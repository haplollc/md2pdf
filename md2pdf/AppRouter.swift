//
//  AppRouter.swift
//  md2pdf
//
//  Created by Jared Cassoutt on 3/11/25.
//

import SwiftUI

/// All possible routes in the app
enum AppRoute: Hashable {
    case home
    case editor
}

/// Any View/Module that needs router access implements this
protocol ModuleRouter {
    var appRouter: AppRouter { get }
}

/// The shared app router (ObservableObject so we can watch path changes)
public class AppRouter: ObservableObject {
    // For external URL opening (links, etc.); macOS can use NSWorkspace, but environment works too:
    @Environment(\.openURL) var openURL

    /// Singleton
    static let shared = AppRouter(with: NavigationPath())

    @Published var path: NavigationPath

    private init(with path: NavigationPath) {
        self.path = path
    }

    /// Push a new destination onto the NavigationStack
    func navigate(to destination: AppRoute) {
        path.append(destination)
    }

    /// Pop one step in the NavigationStack
    func pop() {
        path.removeLast()
    }

    /// Pop back to the very first view
    func popToOrigin() {
        while path.count > 0 {
            path.removeLast()
        }
    }

    /// Open an external URL
    func openURL(_ urlString: String?) {
        guard
            let urlString,
            let url = URL(string: urlString)
        else { return }

        openURL(url)
    }
}
