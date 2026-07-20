import XCTest
@testable import Claudoscope

final class CanonEligibilityTests: XCTestCase {

    /// Build a `fileExists` probe from a list of git repo roots. The classifier
    /// only ever probes `<dir>/.git`, so the synthetic set holds just those markers
    /// — no real filesystem is touched.
    private func exists(gitRoots: [String]) -> (String) -> Bool {
        let markers = Set(gitRoots.map { $0 + "/.git" })
        return { markers.contains($0) }
    }

    // MARK: - gitRepoRoot

    func testGitRepoRootFindsNearestAncestor() {
        let fe = exists(gitRoots: ["/a", "/a/b"])
        XCTAssertEqual(CanonEligibility.gitRepoRoot(for: "/a/b/c", fileExists: fe), "/a/b")
    }

    func testGitRepoRootAtTheRootItself() {
        let fe = exists(gitRoots: ["/a/b"])
        XCTAssertEqual(CanonEligibility.gitRepoRoot(for: "/a/b", fileExists: fe), "/a/b")
    }

    func testGitRepoRootNilWhenNoGitUpToFilesystemRoot() {
        let fe = exists(gitRoots: [])
        XCTAssertNil(CanonEligibility.gitRepoRoot(for: "/a/b/c", fileExists: fe))
    }

    // MARK: - isStrictDescendant

    func testStrictDescendantTrailingSlashSafety() {
        XCTAssertFalse(CanonEligibility.isStrictDescendant("/a/projects-foo", of: "/a/projects"))
        XCTAssertTrue(CanonEligibility.isStrictDescendant("/a/projects/x", of: "/a/projects"))
        XCTAssertFalse(CanonEligibility.isStrictDescendant("/a/projects", of: "/a/projects"))
    }

    // MARK: - classify

    func testContainerWithNestedRepo() {
        let dirs = ["/r/projects", "/r/projects/repo"]
        let fe = exists(gitRoots: ["/r/projects/repo"])
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/projects", allDirs: dirs, fileExists: fe),
            .container(nested: ["/r/projects/repo"])
        )
        // The nested repo is independently installable even though its parent is a container.
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/projects/repo", allDirs: dirs, fileExists: fe),
            .installable(root: "/r/projects/repo")
        )
    }

    func testSubdirFoldsIntoRepoRootAndRepoStaysInstallable() {
        let dirs = ["/r/repo", "/r/repo/sub"]
        let fe = exists(gitRoots: ["/r/repo"])
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/repo/sub", allDirs: dirs, fileExists: fe),
            .foldedInto(root: "/r/repo")
        )
        // A stray session-subdir of the same repo must NOT make the repo a container.
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/repo", allDirs: dirs, fileExists: fe),
            .installable(root: "/r/repo")
        )
    }

    func testStandaloneNonGitLeafIsInstallable() {
        let dirs = ["/r/plain"]
        let fe = exists(gitRoots: [])
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/plain", allDirs: dirs, fileExists: fe),
            .installable(root: "/r/plain")
        )
    }

    func testNonGitContainerWithMixedChildren() {
        let dirs = ["/r/agents", "/r/agents/persona", "/r/agents/blog"]
        let fe = exists(gitRoots: ["/r/agents/blog"])
        // Container: holds a non-git leaf and a git-root child.
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/agents", allDirs: dirs, fileExists: fe),
            .container(nested: ["/r/agents/blog", "/r/agents/persona"])
        )
        // Non-git leaf under a container is still installable (non-git projects allowed).
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/agents/persona", allDirs: dirs, fileExists: fe),
            .installable(root: "/r/agents/persona")
        )
        // Git-root leaf under a container is installable.
        XCTAssertEqual(
            CanonEligibility.classify(dir: "/r/agents/blog", allDirs: dirs, fileExists: fe),
            .installable(root: "/r/agents/blog")
        )
    }

    /// The exact chain from the approved preview:
    /// ~/projects (container) > Claudoscope (repo) > Claudoscope/Claudoscope (subdir).
    func testProjectsClaudoscopeSubdirChain() {
        let projects = "/Users/liranb/projects"
        let repo = "/Users/liranb/projects/Claudoscope"
        let subdir = "/Users/liranb/projects/Claudoscope/Claudoscope"
        let noteme = "/Users/liranb/projects/noteme"
        let dirs = [projects, repo, subdir, noteme]
        let fe = exists(gitRoots: [repo, noteme])

        XCTAssertEqual(
            CanonEligibility.classify(dir: projects, allDirs: dirs, fileExists: fe),
            .container(nested: [repo, noteme])
        )
        XCTAssertEqual(
            CanonEligibility.classify(dir: repo, allDirs: dirs, fileExists: fe),
            .installable(root: repo)
        )
        XCTAssertEqual(
            CanonEligibility.classify(dir: subdir, allDirs: dirs, fileExists: fe),
            .foldedInto(root: repo)
        )
        XCTAssertEqual(
            CanonEligibility.classify(dir: noteme, allDirs: dirs, fileExists: fe),
            .installable(root: noteme)
        )
    }
}
