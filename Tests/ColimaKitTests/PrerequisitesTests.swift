import Testing
import Foundation
@testable import ColimaKit

@Suite struct PrerequisitesTests {
    private func check(installed: Set<String>) -> Prerequisites {
        Prerequisites.check(find: { installed.contains($0) ? "/opt/homebrew/bin/\($0)" : nil })
    }

    @Test func readyWhenBothToolsExist() {
        let p = check(installed: ["colima", "docker", "brew"])
        #expect(p.isReady)
        #expect(p.missing.isEmpty)
        #expect(p.brewAvailable)
    }

    @Test func missingColimaOnly() {
        let p = check(installed: ["docker", "brew"])
        #expect(p.missing == ["colima"])
        #expect(p.needsColima && !p.needsDocker)
        #expect(p.installCommand == "brew install colima")
        #expect(p.title == "Colima isn't installed")
    }

    @Test func missingDockerOnly() {
        let p = check(installed: ["colima", "brew"])
        #expect(p.missing == ["docker"])
        #expect(p.installCommand == "brew install docker")
        #expect(p.title.contains("Docker"))
    }

    @Test func missingBothInInstallOrder() {
        let p = check(installed: ["brew"])
        #expect(p.missing == ["colima", "docker"])
        #expect(p.installCommand == "brew install colima docker")
        #expect(p.title == "Colima and Docker aren't installed")
        #expect(!p.explanation.isEmpty)
    }

    @Test func reportsWhenHomebrewItselfIsMissing() {
        let p = check(installed: [])
        #expect(!p.brewAvailable)
        #expect(p.missing == ["colima", "docker"])
    }
}

@MainActor
@Suite struct MissingToolsStoreTests {
    @Test func skipsAllCommandsAndFlagsMissingTools() async {
        let runner = FakeRunner()
        runner.on("list", output: Sample.colimaList)
        let store = ColimaStore(runner: runner, prerequisites: { Prerequisites(missing: ["colima", "docker"], brewAvailable: true) })
        await store.refresh()
        #expect(runner.calls.isEmpty)
        #expect(!store.prerequisites.isReady)
        #expect(store.hasLoaded)
        #expect(store.profiles.isEmpty)
        #expect(store.docker == nil)
    }

    @Test func recoversOnceTheToolsAppear() async {
        let runner = FakeRunner()
        runner.on("list", output: Sample.colimaList)
        runner.on("ps", output: Sample.ps)
        final class Flag: @unchecked Sendable { var installed = false }
        let flag = Flag()
        let store = ColimaStore(runner: runner, prerequisites: {
            flag.installed ? .ready : Prerequisites(missing: ["colima"], brewAvailable: true)
        })
        await store.refresh()
        #expect(store.containers.isEmpty)
        flag.installed = true
        await store.refresh()
        #expect(store.prerequisites.isReady)
        #expect(store.profiles.count == 2)
        #expect(store.containers.count == 4)
    }
}
