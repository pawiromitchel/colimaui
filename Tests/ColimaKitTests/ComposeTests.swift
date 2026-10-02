import Testing
import Foundation
@testable import ColimaKit

private func makeDir(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("My Shop \(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, content) in files { try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    return dir
}

private let simpleCompose = "services:\n  web:\n    image: nginx\n"

@Suite struct ComposeLocatorTests {
    @Test func acceptsAFile() throws {
        let dir = try makeDir(["compose.yml": simpleCompose])
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try #require(ComposeLocator.resolve([dir.appendingPathComponent("compose.yml")]))
        #expect(input.files == [dir.appendingPathComponent("compose.yml").path])
        #expect(input.workingDir == dir.path)
        #expect(input.suggestedName.hasPrefix("my-shop-"))
        #expect(ComposeLocator.isValidName(input.suggestedName))
    }

    @Test func acceptsAFolderAndFindsTheOverride() throws {
        let dir = try makeDir(["docker-compose.yml": simpleCompose, "docker-compose.override.yml": simpleCompose, "compose.override.yaml": simpleCompose])
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try #require(ComposeLocator.resolve([dir]))
        #expect(input.files.map { ($0 as NSString).lastPathComponent } == ["docker-compose.yml", "docker-compose.override.yml"])
    }

    @Test func prefersComposeYamlOverTheOlderNames() throws {
        let dir = try makeDir(["compose.yaml": simpleCompose, "docker-compose.yml": simpleCompose])
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try #require(ComposeLocator.resolve([dir]))
        #expect(input.files.map { ($0 as NSString).lastPathComponent } == ["compose.yaml"])
    }

    @Test func putsOverridesLastWhateverTheDropOrder() throws {
        let dir = try makeDir(["compose.yml": simpleCompose, "compose.override.yml": simpleCompose])
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try #require(ComposeLocator.resolve([dir.appendingPathComponent("compose.override.yml"), dir.appendingPathComponent("compose.yml")]))
        #expect(input.files.map { ($0 as NSString).lastPathComponent } == ["compose.yml", "compose.override.yml"])
    }

    @Test func rejectsThingsThatAreNotComposeFiles() throws {
        let dir = try makeDir(["notes.txt": "services:\n", "other.yml": "name: hello\n", "empty": ""])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ComposeLocator.resolve([dir.appendingPathComponent("notes.txt")]) == nil)
        #expect(ComposeLocator.resolve([dir.appendingPathComponent("other.yml")]) == nil)
        #expect(ComposeLocator.resolve([dir]) == nil)
        #expect(ComposeLocator.resolve([dir.appendingPathComponent("missing.yml")]) == nil)
        #expect(ComposeLocator.resolve([]) == nil)
    }

    @Test func dedupesRepeatedDrops() throws {
        let dir = try makeDir(["compose.yml": simpleCompose])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("compose.yml")
        #expect(ComposeLocator.resolve([file, dir, file])?.files.count == 1)
    }

    @Test func sanitizesProjectNames() {
        #expect(ComposeLocator.sanitizedName("My Shop!") == "my-shop-")
        #expect(ComposeLocator.sanitizedName("__api") == "api")
        #expect(ComposeLocator.sanitizedName("Shop_2") == "shop_2")
        #expect(ComposeLocator.sanitizedName("###") == "stack")
        #expect(ComposeLocator.sanitizedName("café") == "caf-")
        for ok in ["shop", "a1", "my_app-2"] { #expect(ComposeLocator.isValidName(ok)) }
        for bad in ["", "-x", "Shop", "a b", "a/b"] { #expect(!ComposeLocator.isValidName(bad)) }
    }
}

@Suite struct ComposePlanTests {
    static let json = """
    {"name":"shop","services":{
      "cache":{"image":"alpine:latest","privileged":true,"command":["sleep","600"]},
      "db":{"image":"postgres:16","volumes":[{"type":"volume","source":"pg","target":"/var/lib/postgresql/data"}]},
      "web":{"build":{"context":"/Users/demo/shop/web","dockerfile":"Dockerfile"},
             "ports":[{"mode":"ingress","target":80,"published":"3000","protocol":"tcp"},{"target":9229,"published":"9229-9230","protocol":"tcp"},{"target":53,"published":"5353","protocol":"udp"},{"target":8080}],
             "volumes":[{"type":"bind","source":"/Users/demo/shop/data","target":"/data","bind":{}}]}}}
    """
    let input = ComposeInput(files: ["/Users/demo/shop/compose.yml"], workingDir: "/nonexistent", suggestedName: "shop")

    @Test func readsServicesPortsAndMounts() throws {
        let plan = try ComposePlan.parse(configJSON: Self.json, stderr: "", input: input,
                                         localImages: [DockerImage(id: "i1", repository: "alpine", tag: "latest")])
        #expect(plan.services.map(\.name) == ["cache", "db", "web"])
        let byName = Dictionary(uniqueKeysWithValues: plan.services.map { ($0.name, $0) })
        #expect(byName["web"]?.action == .build)
        #expect(byName["web"]?.buildContext == "/Users/demo/shop/web")
        #expect(byName["db"]?.action == .pull)
        #expect(byName["cache"]?.action == .local)
        #expect(byName["web"]?.ports.compactMap(\.published) == [3000, 9229, 5353])
        #expect(byName["web"]?.ports.last?.published == nil)
        #expect(plan.browserPorts.map(\.published) == [3000, 9229])
        #expect(plan.binds == [ComposeBind(source: "/Users/demo/shop/data", target: "/data")])
        #expect(plan.buildCount == 1)
    }

    @Test func warnsAboutBuildsPrivilegeAndUnsetVariables() throws {
        let stderr = #"time="2026-10-02T03:31:18-03:00" level=warning msg="The \"GREETING\" variable is not set. Defaulting to a blank string.""#
        let plan = try ComposePlan.parse(configJSON: Self.json, stderr: stderr, input: input, localImages: [])
        #expect(plan.warnings.contains(#"The "GREETING" variable is not set. Defaulting to a blank string."#))
        #expect(plan.warnings.contains { $0.contains("cache runs privileged") })
        #expect(plan.warnings.contains("1 service builds from source, which can take a few minutes the first time."))
    }

    @Test func countsVariablesInTheEnvFile() throws {
        let dir = try makeDir(["compose.yml": simpleCompose, ".env": "A=1\n# note\n\nB = two\nnot a var\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let withEnv = ComposeInput(files: [], workingDir: dir.path, suggestedName: "x")
        #expect(try ComposePlan.parse(configJSON: Self.json, stderr: "", input: withEnv, localImages: []).envVariableCount == 2)
        #expect(try ComposePlan.parse(configJSON: Self.json, stderr: "", input: input, localImages: []).envVariableCount == nil)
    }

    @Test func rejectsOutputThatIsNotComposeJSON() {
        #expect(throws: (any Error).self) { try ComposePlan.parse(configJSON: "nope", stderr: "", input: input, localImages: []) }
        #expect(throws: (any Error).self) { try ComposePlan.parse(configJSON: "{}", stderr: "", input: input, localImages: []) }
    }

    @Test func separatesErrorsFromWarnings() {
        let stderr = "time=\"t\" level=warning msg=\"careful\"\nservices.api.ports contains an invalid port: \"80800:80\"\n"
        #expect(ComposePlan.composeError(from: stderr) == #"services.api.ports contains an invalid port: "80800:80""#)
    }
}

@Suite struct ComposeProgressTests {
    func make() throws -> ComposeProgress {
        let plan = try ComposePlan.parse(configJSON: ComposePlanTests.json, stderr: "", input: ComposePlanTests().input, localImages: [])
        return ComposeProgress(plan: plan, project: "shop")
    }

    @Test func startsWithEveryStagePending() throws {
        let p = try make()
        #expect(p.stages.map(\.id) == ["pull:cache", "pull:db", "build:web", "start"])
        #expect(p.stages.allSatisfy { $0.state == .pending })
    }

    @Test func followsPullsBuildsAndStartup() throws {
        var p = try make()
        p.apply(line: " Image postgres:16 Pulling ")
        #expect(p.stages.first { $0.id == "pull:db" }?.state == .running)
        p.apply(line: " Image postgres:16 Pulled ")
        #expect(p.stages.first { $0.id == "pull:db" }?.state == .done)

        p.apply(line: " Image shop-web Building ")
        p.apply(line: "#6 [2/4] RUN npm ci")
        let web = p.stages.first { $0.id == "build:web" }
        #expect(web?.state == .running)
        #expect(web?.detail == "step 2/4")
        #expect(web?.fraction == 0.5)
        p.apply(line: " Image shop-web Built ")
        #expect(p.stages.first { $0.id == "build:web" }?.state == .done)

        p.apply(line: " Network shop_default Creating ")
        #expect(p.stages.first { $0.id == "start" }?.state == .running)
        p.finish(success: true)
        #expect(p.stages.allSatisfy { $0.state == .done })
    }

    @Test func buildStepsAreAttachedEvenBeforeTheBuildingLine() throws {
        var p = try make()
        p.apply(line: "#5 [1/2] FROM docker.io/library/alpine:latest")
        #expect(p.stages.first { $0.id == "build:web" }?.state == .running)
    }

    @Test func marksTheRunningStageFailedOnError() throws {
        var p = try make()
        p.apply(line: " Image postgres:16 Pulling ")
        p.apply(line: " Image postgres:16 Error pull access denied")
        #expect(p.stages.first { $0.id == "pull:db" }?.state == .failed)
        #expect(p.failedMessage?.contains("pull access denied") == true)
        p.finish(success: false)
        #expect(p.stages.first { $0.id == "start" }?.state == .pending)
    }

    @Test func keepsTheLogAndIgnoresBlankLines() throws {
        var p = try make()
        p.apply(line: "   ")
        p.apply(line: "#1 [internal] load build definition")
        #expect(p.log == ["#1 [internal] load build definition"])
        for i in 0..<400 { p.apply(line: "line \(i)") }
        #expect(p.log.count == 300)
    }
}

@MainActor
@Suite struct ComposeDropModelTests {
    func makeModel(_ configure: (FakeRunner) -> Void = { _ in }) async -> (ComposeDropModel, ColimaStore, FakeRunner) {
        let runner = FakeRunner()
        runner.on("list", output: Sample.colimaList)
        runner.on("context", "show", output: "colima\n")
        runner.on("ps", output: Sample.ps)
        runner.when(contains: "version", output: "5.5.0\n")
        runner.when(contains: "config", output: ComposePlanTests.json, stderr: "")
        configure(runner)
        let store = ColimaStore(runner: runner, prerequisites: { .ready })
        await store.refresh()
        return (ComposeDropModel(store: store), store, runner)
    }

    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    func dropDir() throws -> URL { try makeDir(["compose.yml": simpleCompose]) }

    @Test func readingAFileLeadsToAReview() async throws {
        let (model, _, runner) = await makeModel()
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        guard case .review(let plan) = model.phase else { Issue.record("expected review, got \(model.phase)"); return }
        #expect(model.isPresented)
        #expect(plan.services.count == 3)
        #expect(model.projectName == ComposeLocator.sanitizedName(dir.lastPathComponent))
        #expect(model.nameIsValid)
        #expect(runner.commandLines.contains { $0.contains("compose --project-name") && $0.contains("config --format json") })
    }

    @Test func theStandaloneDockerComposeIsUsedWhenThePluginIsMissing() async throws {
        let (model, store, runner) = await makeModel { $0.when(contains: "compose", "version", output: "", exit: 1, stderr: "unknown command") }
        let standalone = ComposeDropModel(store: store, findTool: { $0 == "docker-compose" ? "/opt/homebrew/bin/docker-compose" : nil })
        _ = model
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        standalone.begin(urls: [dir])
        await until { if case .review = standalone.phase { true } else { false } }
        guard case .review = standalone.phase else { Issue.record("expected review, got \(standalone.phase)"); return }
        standalone.start(openLogs: false)
        await until { if case .done = standalone.phase { true } else { false } }
        let up = try #require(runner.calls.last { $0.arguments.contains("up") })
        #expect(up.executable == "docker-compose")
        #expect(up.arguments.first == "--project-name", "the standalone tool takes no `compose` word")
        let config = try #require(runner.calls.last { $0.arguments.contains("config") })
        #expect(config.executable == "docker-compose")
    }

    @Test func bothComposeFormsMissingIsReported() async throws {
        let (model, store, _) = await makeModel { $0.when(contains: "version", output: "", exit: 1, stderr: "unknown command") }
        _ = model
        let none = ComposeDropModel(store: store, findTool: { _ in nil })
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        none.begin(urls: [dir])
        await until { if case .failure = none.phase { true } else { false } }
        guard case .failure(let failure, _) = none.phase else { Issue.record("expected failure"); return }
        #expect(failure == .composeMissing)
    }

    @Test func composeRejectingTheFileShowsItsMessage() async throws {
        let (model, _, _) = await makeModel {
            $0.when(contains: "config", output: "", exit: 1, stderr: "time=\"t\" level=warning msg=\"w\"\nservices.api.ports contains an invalid port\n")
        }
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .failure = model.phase { true } else { false } }
        guard case .failure(let failure, _) = model.phase else { Issue.record("expected failure"); return }
        #expect(failure == .invalid("services.api.ports contains an invalid port"))
    }

    @Test func nonComposeDropsAreRefused() async throws {
        let (model, _, _) = await makeModel()
        let dir = try makeDir(["notes.txt": "hi"]); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir.appendingPathComponent("notes.txt")])
        await until { if case .failure = model.phase { true } else { false } }
        guard case .failure(let failure, _) = model.phase else { Issue.record("expected failure"); return }
        #expect(failure == .notComposeFile)
    }

    @Test func aStoppedVMIsReported() async throws {
        let store = ColimaStore(runner: FakeRunner(), prerequisites: { .ready })
        let model = ComposeDropModel(store: store)
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .failure = model.phase { true } else { false } }
        guard case .failure(let failure, _) = model.phase else { Issue.record("expected failure"); return }
        #expect(failure == .noVM)
    }

    @Test func startingRunsComposeUpAndAnnouncesIt() async throws {
        let (model, store, runner) = await makeModel { $0.streams = [" Image shop-web Building ", " Container shop-db-1 Started "] }
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.projectName = "brand-new"
        #expect(!model.isUpdate("brand-new"))
        model.start(openLogs: true)
        await until { if case .done = model.phase { true } else { false } }
        guard case .done(let project, let openLogs, let isUpdate) = model.phase else { Issue.record("expected done, got \(model.phase)"); return }
        #expect(project == "brand-new" && openLogs && !isUpdate)
        #expect(store.notice?.text == "Started brand-new")
        let up = try #require(runner.commandLines.last { $0.contains("up -d") })
        #expect(up.contains("--project-name brand-new"))
        #expect(up.contains("--progress plain up -d"))
    }

    @Test func anExistingStackIsUpdatedNotStarted() async throws {
        let (model, store, _) = await makeModel()
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.projectName = "shop" // the sample setup already has a stack called shop
        #expect(model.isUpdate("shop"))
        model.start(openLogs: false)
        await until { if case .done = model.phase { true } else { false } }
        #expect(store.notice?.text == "Updated shop")
    }

    @Test func invalidNamesCannotStart() async throws {
        let (model, _, runner) = await makeModel()
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.projectName = "Not Valid!"
        #expect(!model.nameIsValid)
        model.start(openLogs: false)
        #expect(runner.commandLines.allSatisfy { !$0.contains("up -d") })
        if case .review = model.phase {} else { Issue.record("should still be reviewing") }
    }

    @Test func aFailedUpShowsTheErrorAndSurfacesTheSheet() async throws {
        let (model, store, _) = await makeModel {
            $0.streams = [" Image x Pulling "]
            $0.streamError = CommandError(command: "docker compose up", exitCode: 1, message: "pull access denied for x")
        }
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.start(openLogs: false)
        model.runInBackground()
        await until { if case .failure = model.phase { true } else { false } }
        guard case .failure(let failure, _) = model.phase else { Issue.record("expected failure, got \(model.phase)"); return }
        #expect(failure == .failed("pull access denied for x"))
        #expect(model.isPresented, "a failure in the background must bring the sheet back")
        #expect(store.notice?.isError == true)
    }

    @Test func cancellingStopsWithoutClaimingSuccess() async throws {
        let (model, store, _) = await makeModel { $0.streams = [" Image shop-web Building "]; $0.streamHangs = true }
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.start(openLogs: false)
        await until { if case .running(let p, _, _) = model.phase { p.log.count == 1 } else { false } }
        model.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        if case .idle = model.phase {} else { Issue.record("cancel should reset, got \(model.phase)") }
        #expect(!model.isPresented)
        #expect(store.notice?.text.hasPrefix("Stopped starting") == true)
        // and a new drop works afterwards
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        if case .review = model.phase {} else { Issue.record("a drop after cancelling should work") }
    }

    @Test func aSecondDropWhileStartingIsIgnored() async throws {
        let (model, _, _) = await makeModel { $0.streams = ["x"]; $0.streamHangs = true }
        let dir = try dropDir(); defer { try? FileManager.default.removeItem(at: dir) }
        model.begin(urls: [dir])
        await until { if case .review = model.phase { true } else { false } }
        model.start(openLogs: false)
        await until { if case .running = model.phase { true } else { false } }
        model.begin(urls: [dir])
        if case .running = model.phase {} else { Issue.record("a running start must not be replaced") }
        model.cancel()
    }
}

@Suite struct ProcessStreamTests {
    let runner = ProcessRunner()

    @Test func aFailingCommandFailsTheStreamWithItsLastLines() async {
        var lines: [String] = []
        do {
            for try await l in runner.stream("sh", arguments: ["-c", "echo one; echo 'boom happened' >&2; exit 3"], environment: [:]) { lines.append(l) }
            Issue.record("expected an error")
        } catch let error as CommandError {
            #expect(error.exitCode == 3)
            #expect(error.localizedDescription.contains("boom happened"))
        } catch { Issue.record("wrong error \(error)") }
        #expect(lines.contains("one"))
    }

    @Test func aSuccessfulCommandFinishesQuietly() async throws {
        var lines: [String] = []
        for try await l in runner.stream("sh", arguments: ["-c", "echo a; echo b"], environment: [:]) { lines.append(l) }
        #expect(lines == ["a", "b"])
    }

    @Test func stoppingEarlyEndsTheProcessWithoutAnError() async throws {
        let start = Date()
        for try await l in runner.stream("sh", arguments: ["-c", "echo first; sleep 30"], environment: [:]) {
            if l == "first" { break }
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
