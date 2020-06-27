//===--------------- JobExecutorTests.swift - Swift Execution Tests -------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import XCTest
import TSCBasic
import TSCUtility

import SwiftDriver

extension Job.ArgTemplate: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .flag(value)
  }
}

class JobCollectingDelegate: JobExecutionDelegate {
  struct StubProcess: ProcessProtocol {
    static func launchProcess(arguments: [String], env: [String : String]) throws -> StubProcess {
      return .init()
    }

    var processID: TSCBasic.Process.ProcessID { .init(-1) }

    func waitUntilExit() throws -> ProcessResult {
      return ProcessResult(
        arguments: [],
        environment: [:],
        exitStatus: .terminated(code: EXIT_SUCCESS),
        output: Result.success(ByteString("test").contents),
        stderrOutput: Result.success([])
      )
    }
  }

  var started: [Job] = []
  var finished: [(Job, ProcessResult)] = []

  func jobFinished(job: Job, result: ProcessResult, pid: Int) {
    finished.append((job, result))
  }

  func jobStarted(job: Job, arguments: [String], pid: Int) {
    started.append(job)
  }
}

final class JobExecutorTests: XCTestCase {
  func testDarwinBasic() throws {
#if os(macOS)
    let toolchain = DarwinToolchain(env: ProcessEnv.vars)
    try withTemporaryDirectory { path in
      let foo = path.appending(component: "foo.swift")
      let main = path.appending(component: "main.swift")

      try localFileSystem.writeFileContents(foo) {
        $0 <<< "let foo = 5"
      }
      try localFileSystem.writeFileContents(main) {
        $0 <<< "print(foo)"
      }

      let exec = path.appending(component: "main")

      var resolver = try ArgsResolver(fileSystem: localFileSystem)
      resolver.pathMapping = [
        .relative(RelativePath("foo.swift")): foo,
        .relative(RelativePath("main.swift")): main,
        .relative(RelativePath("main")): exec,
      ]

      let compileFoo = Job(
        moduleName: "main",
        kind: .compile,
        tool: .absolute(try toolchain.getToolPath(.swiftCompiler)),
        commandLine: [
          "-frontend",
          "-c",
          "-primary-file",
          .path(.relative(RelativePath("foo.swift"))),
          .path(.relative(RelativePath("main.swift"))),
          "-target", "x86_64-apple-darwin18.7.0",
          "-enable-objc-interop",
          "-sdk",
          .path(.absolute(try toolchain.sdk.get())),
          "-module-name", "main",
          "-o", .path(.temporary(RelativePath("foo.o"))),
        ],
        inputs: [
          .init(file: .relative(RelativePath("foo.swift")), type: .swift),
          .init(file: .relative(RelativePath("main.swift")), type: .swift),
        ],
        outputs: [.init(file: .temporary(RelativePath("foo.o")), type: .object)]
      )

      let compileMain = Job(
        moduleName: "main",
        kind: .compile,
        tool: .absolute(try toolchain.getToolPath(.swiftCompiler)),
        commandLine: [
          "-frontend",
          "-c",
          .path(.relative(RelativePath("foo.swift"))),
          "-primary-file",
          .path(.relative(RelativePath("main.swift"))),
          "-target", "x86_64-apple-darwin18.7.0",
          "-enable-objc-interop",
          "-sdk",
          .path(.absolute(try toolchain.sdk.get())),
          "-module-name", "main",
          "-o", .path(.temporary(RelativePath("main.o"))),
        ],
        inputs: [
          .init(file: .relative(RelativePath("foo.swift")), type: .swift),
          .init(file: .relative(RelativePath("main.swift")), type: .swift),
        ],
        outputs: [.init(file: .temporary(RelativePath("main.o")), type: .object)]
      )

      let link = Job(
        moduleName: "main",
        kind: .link,
        tool: .absolute(try toolchain.getToolPath(.dynamicLinker)),
        commandLine: [
          .path(.temporary(RelativePath("foo.o"))),
          .path(.temporary(RelativePath("main.o"))),
          .path(.absolute(try toolchain.clangRT.get())),
          "-syslibroot", .path(.absolute(try toolchain.sdk.get())),
          "-lobjc", "-lSystem", "-arch", "x86_64",
          "-force_load", .path(.absolute(try toolchain.compatibility50.get())),
          "-force_load", .path(.absolute(try toolchain.compatibilityDynamicReplacements.get())),
          "-L", .path(.absolute(try toolchain.resourcesDirectory.get())),
          "-L", .path(.absolute(try toolchain.sdkStdlib(sdk: toolchain.sdk.get()))),
          "-rpath", "/usr/lib/swift", "-macosx_version_min", "10.14.0", "-no_objc_category_merging", "-o",
          .path(.relative(RelativePath("main"))),
        ],
        inputs: [
          .init(file: .temporary(RelativePath("foo.o")), type: .object),
          .init(file: .temporary(RelativePath("main.o")), type: .object),
        ],
        outputs: [.init(file: .relative(RelativePath("main")), type: .image)]
      )

      let delegate = JobCollectingDelegate()
      let executor = MultiJobExecutor(jobs: [compileFoo, compileMain, link], resolver: resolver, executorDelegate: delegate, diagnosticsEngine: DiagnosticsEngine())
      try executor.execute(env: toolchain.env, fileSystem: localFileSystem)

      let output = try TSCBasic.Process.checkNonZeroExit(args: exec.pathString)
      XCTAssertEqual(output, "5\n")
      XCTAssertEqual(delegate.started.count, 3)

      let fooObject = try resolver.resolve(.path(.temporary(RelativePath("foo.o"))))
      XCTAssertTrue(localFileSystem.exists(AbsolutePath(fooObject)), "expected foo.o to be present in the temporary directory")
      try resolver.removeTemporaryDirectory()
      XCTAssertFalse(localFileSystem.exists(AbsolutePath(fooObject)), "expected foo.o to be removed from the temporary directory")
    }
#endif
  }

  func testStubProcessProtocol() throws {
    let job = Job(
      moduleName: "main",
      kind: .compile,
      tool: .absolute(AbsolutePath("/usr/bin/swift")),
      commandLine: [.flag("something")],
      inputs: [],
      outputs: [.init(file: .temporary(RelativePath("main")), type: .object)]
    )

    let delegate = JobCollectingDelegate()
    let executor = MultiJobExecutor(
      jobs: [job], resolver: try ArgsResolver(fileSystem: localFileSystem),
      executorDelegate: delegate,
      diagnosticsEngine: DiagnosticsEngine(),
      processType: JobCollectingDelegate.StubProcess.self
    )
    try executor.execute(env: ProcessEnv.vars, fileSystem: localFileSystem)

    XCTAssertEqual(try delegate.finished[0].1.utf8Output(), "test")
  }

  func testSwiftDriverExecOverride() throws {
    var env = ProcessEnv.vars
    let envVarName = "SWIFT_DRIVER_SWIFT_EXEC"
    let dummyPath = "/some/garbage/path/fnord"

    // DarwinToolchain
    env.removeValue(forKey: envVarName)
    let normalSwiftPath = try DarwinToolchain(env: env).getToolPath(.swiftCompiler)
    XCTAssertEqual(normalSwiftPath.basenameWithoutExt, "swift")

    env[envVarName] = dummyPath
    let overriddenSwiftPath = try DarwinToolchain(env: env).getToolPath(.swiftCompiler)
    XCTAssertEqual(overriddenSwiftPath, AbsolutePath(dummyPath))

    // GenericUnixToolchain
    env.removeValue(forKey: envVarName)
    let unixSwiftPath = try GenericUnixToolchain(env: env).getToolPath(.swiftCompiler)
    XCTAssertEqual(unixSwiftPath.basenameWithoutExt, "swift")

    env[envVarName] = dummyPath
    let unixOverriddenSwiftPath = try GenericUnixToolchain(env: env).getToolPath(.swiftCompiler)
    XCTAssertEqual(unixOverriddenSwiftPath, AbsolutePath(dummyPath))
  }

  func testInputModifiedDuringSingleJobBuild() throws {
    try withTemporaryDirectory { path in
      let main = path.appending(component: "main.swift")
      try localFileSystem.writeFileContents(main) {
        $0 <<< "let foo = 1"
      }

      var driver = try Driver(args: ["swift", main.pathString])
      let jobs = try driver.planBuild()
      XCTAssertTrue(jobs.count == 1 && jobs[0].requiresInPlaceExecution)

      // Change the file
      try localFileSystem.writeFileContents(main) {
        $0 <<< "let foo = 1"
      }

      XCTAssertThrowsError(try driver.run(jobs: jobs)) {
        XCTAssertEqual($0 as? Job.InputError,
                       .inputUnexpectedlyModified(TypedVirtualPath(file: .absolute(main), type: .swift)))
      }

    }
  }

  func testInputModifiedDuringMultiJobBuild() throws {
    try withTemporaryDirectory { path in
      let main = path.appending(component: "main.swift")
      try localFileSystem.writeFileContents(main) {
        $0 <<< "let foo = 1"
      }
      let other = path.appending(component: "other.swift")
      try localFileSystem.writeFileContents(other) {
        $0 <<< "let bar = 2"
      }
      try assertDriverDiagnostics(args: ["swiftc", main.pathString, other.pathString]) {driver, verifier in
        let jobs = try driver.planBuild()
        XCTAssertTrue(jobs.count > 1)

        // Change the file
        try localFileSystem.writeFileContents(other) {
          $0 <<< "let bar = 3"
        }

        // FIXME: It's unfortunate we diagnose this twice, once for each job which uses the input.
        verifier.expect(.error("input file '\(other.description)' was modified during the build"))
        verifier.expect(.error("input file '\(other.description)' was modified during the build"))
        XCTAssertThrowsError(try driver.run(jobs: jobs))
      }
    }
  }
}
