import Foundation

final class HostRouter: ObservableObject {
    enum Route {
        case home
        case dictation
    }

    @Published var route: Route = .home

    func handle(url: URL) {
        if url.host == "dictation" || url.path == "/dictation" {
            route = .dictation
        }
    }
}
