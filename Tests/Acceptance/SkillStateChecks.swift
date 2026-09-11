import CleanupCore
import Foundation

@main struct SkillStateChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Sweep-skill-state-\(UUID())").standardizedFileURL
        let name = "sweep-skills-state-\(UUID())"
        let isolated = UserDefaults(suiteName: name)!
        defer { isolated.removePersistentDomain(forName: name); try? fm.removeItem(at: root) }
        for tool in ["claude", "codex"] {
            let skill = root.appendingPathComponent(".\(tool)/skills/fixture")
            try fm.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("---\nname: \(tool)-skill\ndescription: isolated fixture\n---\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        }
        let state = SkillManagementState(preferences: isolated, restorePreferences: false, discovery: nil)
        guard state.roots.isEmpty, state.entries.isEmpty, state.selected.isEmpty else { fatalError("Skill roots must require separate authorization") }
        print("PASS: skills start disconnected and do not reuse history authorization")
        state.connect(root.appendingPathComponent(".claude/skills"), tool: .claude, location: .personal)
        for _ in 0..<1_000 where state.scanning { try await Task.sleep(for: .milliseconds(10)) }
        guard state.error == nil, let entry = state.entries.first, state.visible.count == 1 else { fatalError("Authorized skills did not load: \(state.error ?? "")") }
        state.toggle(entry); state.inspectedID = entry.id; state.search = "no-match"
        guard state.selected == [entry.id], state.visible.isEmpty, state.hiddenSelectionCount == 1 else { fatalError("Skill search cleared selection") }
        state.search = ""; state.onlySelected = true
        guard state.visible.count == 1, state.selected == [entry.id] else { fatalError("Only-selected lost skill") }
        state.prepareReview()
        guard state.review?.entries.count == 1, state.review?.entries.first?.root.tool == .claude else { fatalError("Confirmation has wrong AI") }
        print("PASS: search, inspection and only-selected preserve skill choices; confirmation keeps AI identity")
        state.tool = .codex
        guard state.selected.isEmpty, state.inspectedID == nil else { fatalError("AI switch kept stale selection") }
        state.connect(root.appendingPathComponent(".codex/skills"), tool: .codex, location: .personal)
        for _ in 0..<1_000 where state.scanning { try await Task.sleep(for: .milliseconds(10)) }
        state.onlySelected = false
        guard state.visible.count == 1, state.visible.first?.root.tool == .codex, state.entries.count == 2 else { fatalError("AI scope is mixed") }
        print("PASS: switching AI clears its old selection and presents only the chosen AI")
        let restored = SkillManagementState(preferences: isolated, discovery: nil)
        guard restored.roots.count == 2, restored.entries.isEmpty, restored.selected.isEmpty else { fatalError("Restored grants reused a stale inventory") }
        state.toggle(state.visible[0]); state.scan(); state.cancel()
        try await Task.sleep(for: .milliseconds(80))
        guard !state.scanning, state.entries.isEmpty, state.selected.isEmpty, state.review == nil, state.status.contains("取消") else { fatalError("Cancelled scan accepted late items") }
        print("PASS: saved sources restore without stale choices; cancellation rejects late scan results")
        for source in state.roots { state.disconnect(source) }
        guard state.roots.isEmpty, state.entries.isEmpty, state.selected.isEmpty, state.review == nil else { fatalError("Disconnect kept old removal plan") }
        guard fm.fileExists(atPath: root.appendingPathComponent(".codex/skills/fixture/SKILL.md").path) else { fatalError("Disconnect changed skills") }
        print("PASS: disconnect revokes scope and clears plans without modifying skills")
        try await automaticChecks(root: root, preferences: isolated)
    }

    @MainActor private static func wait(_ state: SkillManagementState) async throws {
        for _ in 0..<1_000 where state.scanning { try await Task.sleep(for: .milliseconds(10)) }
        guard !state.scanning, state.error == nil else { fatalError("Automatic scan did not complete: \(state.error ?? "")") }
    }

    @MainActor private static func automaticChecks(root: URL, preferences: UserDefaults) async throws {
        let fm = FileManager.default
        let discovery = SkillDiscovery(home: root, environment: [:])
        let automatic = SkillManagementState(preferences: preferences, discovery: discovery)
        guard automatic.roots.isEmpty, !automatic.scanning else { fatalError("Discovery must wait for the skills page") }
        automatic.activate()
        guard automatic.scanning, automatic.countLabel(for: .claude) == "扫描中" else { fatalError("Missing initial discovery progress") }
        try await wait(automatic)
        guard automatic.roots.count == 2, automatic.entries.count == 2, automatic.selected.isEmpty,
              automatic.roots.allSatisfy({ automatic.isAutomatic($0) }), automatic.warnings.isEmpty else {
            fatalError("Default skills were not automatically loaded and scoped")
        }
        guard let data = preferences.data(forKey: "skillSources"),
              try JSONDecoder().decode([SkillRoot].self, from: data).isEmpty else { fatalError("Automatic discovery saved manual grants") }
        print("PASS: opening skills automatically scans both AI defaults without file pickers or saving grants")

        automatic.connect(root.appendingPathComponent(".claude/skills"), tool: .claude, location: .personal)
        try await wait(automatic)
        guard automatic.roots.count == 2, automatic.entries.count == 2,
              !automatic.isAutomatic(automatic.toolRoots[0]) else { fatalError("Manual/default overlap was duplicated") }
        let reopened = SkillManagementState(preferences: preferences, discovery: discovery)
        reopened.activate(); try await wait(reopened)
        guard reopened.roots.count == 2, reopened.entries.count == 2 else { fatalError("Saved custom sources were not merged on reopen") }
        print("PASS: automatic and manual sources deduplicate; reopening loads saved and default sources together")

        automatic.toggle(automatic.visible[0])
        automatic.tool = .codex
        guard automatic.selected.isEmpty, automatic.visible.count == 1,
              automatic.visible[0].root.tool == .codex else { fatalError("Automatic scan mixed AI selection") }
        automatic.toggle(automatic.visible[0]); automatic.prepareReview()
        automatic.scan(); automatic.cancel()
        try await Task.sleep(for: .milliseconds(80))
        guard !automatic.scanning, automatic.entries.isEmpty, automatic.selected.isEmpty,
              automatic.review == nil, automatic.status.contains("取消") else { fatalError("Discovery accepted stale results after cancellation") }
        print("PASS: AI switching and automatic discovery cancellation invalidate stale removal choices")

        let shared = root.appendingPathComponent(".agents/skills/shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("---\nname: shared\n---\n".utf8).write(to: shared.appendingPathComponent("SKILL.md"))
        automatic.activate(); try await wait(automatic)
        guard automatic.roots.count == 3, automatic.visible.contains(where: { $0.name == "shared" && !$0.selectable }) else { fatalError("New shared installation not discovered safely") }
        try fm.removeItem(at: shared.deletingLastPathComponent())
        automatic.scan(); try await wait(automatic)
        guard automatic.roots.count == 2, !automatic.entries.contains(where: { $0.name == "shared" }) else { fatalError("Removed default source was retained") }
        print("PASS: rescanning finds newly installed default sources and removes missing sources; shared originals stay read-only")

        let plugin = root.appendingPathComponent(".claude/plugins/cache/vendor/1/skills/plugin")
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data("---\nname: plugin\n---\n".utf8).write(to: plugin.appendingPathComponent("SKILL.md"))
        automatic.connect(root.appendingPathComponent(".claude/plugins"), tool: .claude, location: .plugins)
        try await wait(automatic)
        guard automatic.roots.count == 3, automatic.entries.filter({ $0.name == "plugin" }).count == 1 else { fatalError("Plugin parent and discovered cache scanned twice") }
        print("PASS: a manually connected plugin parent covers its automatic cache without duplicate skills")

        let empty = root.appendingPathComponent("empty-home")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let absent = SkillManagementState(preferences: preferences, restorePreferences: false,
                                          discovery: SkillDiscovery(home: empty, environment: [:]))
        absent.activate(); try await wait(absent)
        guard absent.scanned, absent.entries.isEmpty, absent.warnings.isEmpty,
              absent.countLabel(for: .claude) == "未发现", absent.status.contains("默认位置") else { fatalError("No-install state is misleading") }
        print("PASS: no default installation reports not found and leaves refresh/custom-source recovery available")

        let lost = SkillRoot(tool: .claude, url: root.appendingPathComponent("custom/skills"), location: .personal)
        preferences.set(try JSONEncoder().encode([lost]), forKey: "skillSources")
        let recovery = SkillManagementState(preferences: preferences, discovery: discovery)
        recovery.activate(); try await wait(recovery)
        guard !recovery.warnings.isEmpty, recovery.entries.allSatisfy({ !$0.selectable }) else { fatalError("Automatic scan hid an invalid custom authorization") }
        try fm.createDirectory(at: lost.url, withIntermediateDirectories: true)
        recovery.connect(lost.url, tool: .claude, location: .personal)
        try await wait(recovery)
        guard recovery.warnings.isEmpty, recovery.entries.contains(where: \.selectable) else { fatalError("Reauthorizing custom source did not clear its old failure") }
        print("PASS: invalid saved authorizations stay visible and protect originals until reconnected")
    }
}
