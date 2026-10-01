import Testing
import Foundation
@testable import ColimaKit

@Suite struct ParsingTests {
    @Test func parsesColimaProfiles() {
        let profiles = Parsing.profiles(from: Sample.colimaList)
        #expect(profiles.count == 2)
        #expect(profiles[0].name == "default")
        #expect(profiles[0].isRunning)
        #expect(profiles[0].cpus == 4)
        #expect(profiles[0].memoryBytes == 8 * 1_073_741_824)
        #expect(profiles[0].dockerContext == "colima")
        #expect(profiles[1].status == .stopped)
        #expect(profiles[1].dockerContext == "colima-k8s")
        #expect(profiles[1].kubernetes)
        #expect(profiles[1].runtime == "containerd")
    }

    @Test func profilesIgnoreBlankAndMalformedLines() {
        let text = "\n{not json}\n{\"name\":\"x\",\"status\":\"Broken\"}\n"
        let profiles = Parsing.profiles(from: text)
        #expect(profiles.count == 1)
        #expect(profiles[0].status == .unknown)
    }

    @Test func parsesLabelsWithCommasInValues() {
        let raw = "com.docker.compose.project=shop,com.docker.compose.project.config_files=/a/one.yml,/a/two.yml,com.docker.compose.service=web"
        let labels = Parsing.labels(raw)
        #expect(labels["com.docker.compose.project"] == "shop")
        #expect(labels["com.docker.compose.project.config_files"] == "/a/one.yml,/a/two.yml")
        #expect(labels["com.docker.compose.service"] == "web")
    }

    @Test func parsesEmptyLabels() {
        #expect(Parsing.labels("").isEmpty)
    }

    @Test func dedupesIPv4AndIPv6Ports() {
        let ports = Parsing.ports("0.0.0.0:3001->3001/tcp, [::]:3001->3001/tcp")
        #expect(ports.count == 1)
        #expect(ports[0].hostPort == 3001)
        #expect(ports[0].containerPort == 3001)
        #expect(ports[0].browserURL?.absoluteString == "http://localhost:3001")
        #expect(ports[0].label == "3001:3001")
    }

    @Test func parsesUnpublishedAndUDPPorts() {
        let ports = Parsing.ports("5432/tcp, 0.0.0.0:53->53/udp, 127.0.0.1:8080->80/tcp")
        #expect(ports.count == 3)
        #expect(!ports[0].isPublished)
        #expect(ports[0].label == "5432")
        #expect(ports[1].proto == "udp")
        #expect(ports[1].browserURL == nil)
        #expect(ports[2].hostIP == "127.0.0.1")
        #expect(ports[2].hostPort == 8080)
        #expect(ports[2].containerPort == 80)
    }

    @Test func parsesPortRanges() {
        let ports = Parsing.ports("0.0.0.0:8000-8001->9000-9001/tcp")
        #expect(ports.count == 1)
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9000)
    }

    @Test func parsesContainers() {
        let containers = Parsing.containers(from: Sample.ps)
        #expect(containers.count == 4)
        let web = containers[0]
        #expect(web.name == "shop-web-1")
        #expect(web.composeProject == "shop")
        #expect(web.composeService == "web")
        #expect(web.displayName == "web")
        #expect(web.composeConfigFiles == ["/tmp/shop/compose.yml"])
        #expect(web.isRunning)
        #expect(containers[2].state == .exited)
        #expect(!containers[2].isRunning)
        #expect(containers[3].composeProject == nil)
        #expect(containers[3].displayName == "redis-dev")
    }

    @Test func parsesRealisticDockerPsLine() {
        let line = #"{"Command":"\"docker-entrypoint.s…\"","ID":"e13aa099cb99","Image":"cv-builder-apexcv","Labels":"com.docker.compose.project=cv-builder,com.docker.compose.service=apexcv","Names":"apexcv-app","Ports":"0.0.0.0:3001->3001/tcp, [::]:3001->3001/tcp","State":"running","Status":"Up 25 hours"}"#
        let c = Parsing.containers(from: line)
        #expect(c.count == 1)
        #expect(c[0].ports.first?.hostPort == 3001)
        #expect(c[0].composeProject == "cv-builder")
    }

    @Test func parsesImagesVolumesNetworksAndStats() {
        let images = Parsing.images(from: #"{"ID":"0625848aea11","Repository":"cv-builder-apexcv","Tag":"latest","Size":"274MB","CreatedSince":"25 hours ago"}"#)
        #expect(images[0].reference == "cv-builder-apexcv:latest")
        #expect(!images[0].isDangling)

        let volumes = Parsing.volumes(from: #"{"Name":"cv_data","Driver":"local","Labels":"com.docker.compose.project=cv-builder"}"#)
        #expect(volumes[0].composeProject == "cv-builder")

        let nets = Parsing.networks(from: #"{"ID":"1af","Name":"bridge","Driver":"bridge","Scope":"local","Labels":""}"#)
        #expect(nets[0].isBuiltIn)

        let stats = Parsing.stats(from: #"{"ID":"e13aa099cb99","Name":"apexcv-app","CPUPerc":"1.25%","MemUsage":"66.19MiB / 7.737GiB","MemPerc":"0.84%"}"#)
        #expect(stats[0].cpuPercent == 1.25)
        #expect(stats[0].memoryUsage == "66.19MiB")
        #expect(stats[0].memoryPercent == 0.84)
    }

    @Test func parsesSizes() {
        #expect(Parsing.parseSize("8GiB") == 8_589_934_592)
        #expect(Parsing.parseSize("512MB") == 512_000_000)
        #expect(Parsing.parseSize("1.5 GiB") == 1_610_612_736)
        #expect(Parsing.parseSize("junk") == nil)
        #expect(Format.bytes(8_589_934_592) == "8 GiB")
        #expect(Format.bytes(1_610_612_736) == "1.5 GiB")
        #expect(Format.bytes(536_870_912) == "512 MiB")
    }

    @Test func lineSplitterCarriesPartialLines() {
        let s = LineSplitter()
        #expect(s.feed(Data("hel".utf8)).isEmpty)
        #expect(s.feed(Data("lo\nwor".utf8)) == ["hello"])
        #expect(s.feed(Data("ld\r\nrest".utf8)) == ["world"])
        #expect(s.flush() == "rest")
        #expect(s.flush() == nil)
    }

    @Test func stripsColimaLogPrefix() {
        let line = #"time="2026-10-01T16:25:18-03:00" level=info msg="starting colima""#
        #expect(ColimaStore.stripLogPrefix(line) == "starting colima")
        #expect(ColimaStore.stripLogPrefix("plain") == "plain")
    }
}
