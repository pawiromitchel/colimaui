import Testing
@testable import ColimaKit

@Suite struct ProfileDraftTests {
    let profile = ColimaProfile(name: "default", status: .running, arch: "aarch64", cpus: 4,
                                memoryBytes: 8 * 1_073_741_824, diskBytes: 60 * 1_073_741_824, runtime: "docker")

    @Test func newProfilePassesEverything() {
        var d = ProfileDraft.new()
        d.name = "dev"
        d.rosetta = true
        let args = ColimaClient.startArguments(profile: d.name, options: d.options)
        #expect(args == ["start", "--profile", "dev", "--cpu", "2", "--memory", "4", "--disk", "60",
                         "--runtime", "docker", "--vm-type", "vz", "--vz-rosetta", "--kubernetes=false"])
    }

    @Test func rosettaIsDroppedForQemu() {
        var d = ProfileDraft.new()
        d.vmType = "qemu"
        d.rosetta = true
        #expect(d.options.rosetta == nil)
    }

    @Test func unchangedEditSendsNothing() {
        let d = ProfileDraft(profile: profile)
        #expect(d.options == StartOptions())
        #expect(ColimaClient.startArguments(profile: "default", options: d.options) == ["start", "--profile", "default"])
    }

    @Test func editSendsOnlyChangedFields() {
        var d = ProfileDraft(profile: profile)
        d.cpus = 6
        d.kubernetes = true
        #expect(d.options == StartOptions(cpus: 6, kubernetes: true))
    }

    @Test func diskNeverShrinks() {
        var d = ProfileDraft(profile: profile)
        d.diskGiB = 20
        #expect(d.options.diskGiB == 60)
        d.diskGiB = 100
        #expect(d.options.diskGiB == 100)
        #expect(d.minimumDiskGiB == 60)
    }

    @Test func validatesNames() {
        var d = ProfileDraft.new()
        for ok in ["dev", "k8s-1", "my_profile", "A1"] { d.name = ok; #expect(d.nameIsValid) }
        for bad in ["", "-x", "has space", "a/b", "ünï"] { d.name = bad; #expect(!d.nameIsValid) }
    }
}
