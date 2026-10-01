import Testing
import Foundation
@testable import ColimaKit

@Suite struct GroupingTests {
    let containers = Parsing.containers(from: Sample.ps)

    @Test func groupsByStackWithStandaloneLast() {
        let groups = Grouping.group(containers, by: .stack)
        #expect(groups.map(\.title) == ["shop", "Standalone"])
        let shop = groups[0]
        #expect(shop.isStack)
        #expect(shop.projectName == "shop")
        #expect(shop.summary == "2/3")
        #expect(!shop.allRunning)
        #expect(shop.containers.map(\.displayName) == ["db", "web", "worker"])
        #expect(groups[1].containers.map(\.name) == ["redis-dev"])
        #expect(groups[1].allRunning)
    }

    @Test func groupsByImage() {
        let groups = Grouping.group(containers, by: .image)
        #expect(groups.count == 4)
        #expect(groups.map(\.title).contains("postgres:16"))
    }

    @Test func noGroupingIsFlat() {
        let groups = Grouping.group(containers, by: .none)
        #expect(groups.count == 1)
        #expect(groups[0].containers.count == 4)
    }

    @Test func emptyInputProducesNoStackGroups() {
        #expect(Grouping.group([], by: .stack).isEmpty)
    }

    @Test func filtersByNameImageProjectAndPort() {
        #expect(Grouping.filter(containers, query: "redis").count == 1)
        #expect(Grouping.filter(containers, query: "postgres").count == 1)
        #expect(Grouping.filter(containers, query: "SHOP").count == 3)
        #expect(Grouping.filter(containers, query: "6379").count == 1)
        #expect(Grouping.filter(containers, query: "  ").count == 4)
        #expect(Grouping.filter(containers, query: "nope").isEmpty)
    }

    @Test func composeUpRequiresFilesOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("compose.yml")
        try "services: {}".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = ContainerGroup(id: "s", title: "s", kind: .stack(project: "s", workingDir: dir.path, configFiles: [file.path]), containers: [])
        let missing = ContainerGroup(id: "s", title: "s", kind: .stack(project: "s", workingDir: dir.path, configFiles: ["/nope/compose.yml"]), containers: [])
        #expect(present.canComposeUp)
        #expect(!missing.canComposeUp)
        #expect(!ContainerGroup(id: "x", title: "x", kind: .standalone, containers: []).canComposeUp)
    }

    @Test func matchesImagesToContainers() {
        let nginx = DockerImage(id: "0625848aea11", repository: "nginx", tag: "latest")
        let pinned = DockerImage(id: "abcdef123456", repository: "postgres", tag: "16")
        #expect(nginx.matches(containerImage: "nginx"))
        #expect(nginx.matches(containerImage: "nginx:latest"))
        #expect(nginx.matches(containerImage: "0625848aea11"))
        #expect(nginx.matches(containerImage: "sha256:0625848aea11"))
        #expect(!pinned.matches(containerImage: "postgres"))
        #expect(pinned.matches(containerImage: "postgres:16"))
        let used = Grouping.containers(using: pinned, in: containers)
        #expect(used.map(\.name) == ["shop-db-1"])
    }

    @Test func volumeOwnersFollowComposeProject() {
        let vol = DockerVolume(name: "shop_data", labels: ["com.docker.compose.project": "shop"])
        #expect(Grouping.volumeOwner(vol, in: containers).count == 3)
        #expect(Grouping.volumeOwner(DockerVolume(name: "x"), in: containers).isEmpty)
    }
}
