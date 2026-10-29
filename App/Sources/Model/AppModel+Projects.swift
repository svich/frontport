import FrontportCore
import Foundation

extension AppModel {
    /// "Jak and Daxter, Jak II and Jak 3".
    func gameNames(of project: Project) -> String {
        project.ports.map { gameName(for: $0) }.formatted(.list(type: .and))
    }

    /// "Super Mario 64" for one Game, "3 Games" for more.
    func gamesText(of project: Project) -> String {
        project.ports.count == 1 ? gameName(for: project.ports[0]) : Format.count(project.ports.count, "Game")
    }

    /// The Library Ports of a Project.
    func libraryPorts(of project: Project) -> [CatalogEntry] {
        project.ports.filter { survey.installation($0.id) != nil }
    }
}
