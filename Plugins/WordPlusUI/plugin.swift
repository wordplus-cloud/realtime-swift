// `swift package wordplus-ui <add|diff|update|accept>`: the call screen's code copied into an app, to change as far as
// it needs. From Xcode: the project's context menu, under the
// package's plugins, with the same words as arguments.
//
//   add [--target App]   copies the screen into the target's WordPlusUI folder (the first app or library target by default)
//   diff                 what changed in ours since the copy, file by file, as a unified diff
//   update               takes ours into every file the app never changed; the rest is left to merge (diff)
//   accept               records that the app's copy now has ours (after merging what diff showed)
//
// Only the screen is copied: the calls under it stay in WordPlusRealtimeCalls, so their fixes still reach the app.
// wordplus-ui.json beside the package (or the project) records each copied file's version and the hash of ours as it was
// copied, and .wordplus-ui/call-screen.json keeps ours as it was, which diff compares with ours now.
import Foundation
import PackagePlugin

@main
struct WordPlusUI: CommandPlugin {
    func performCommand( context: PluginContext, arguments: [ String ] ) async throws {
        let wanted = value( of: "--target", in: arguments )
        let targets = context.package.targets.compactMap { $0 as? SourceModuleTarget }.filter { $0.kind != .test }
        guard let target = wanted.map( { name in targets.first { $0.name == name } } ) ?? targets.first( where: { $0.name != "WordPlusRealtimeUI" } ) ?? nil else {
            throw Failure( "No target to copy into: --target <name> (one of \( targets.map( \.name ).joined( separator: ", " ) ))." )
        }
        let root = URL( fileURLWithPath: context.package.directory.string )
        // The tests go in a test target of the copy's target, under WordPlusUITests/.
        let testTarget = context.package.targets.compactMap { $0 as? SourceModuleTarget }.first { candidate in
            candidate.kind == .test && candidate.dependencies.contains { dependency in
                if case .target( let on ) = dependency { return on.name == target.name }
                return false
            }
        }
        var copies = Copies(
            root: root,
            into: URL( fileURLWithPath: target.directory.string ).appendingPathComponent( "WordPlusUI" ),
            tests: ( testTarget.map { URL( fileURLWithPath: $0.directory.string ) }
                ?? root.appendingPathComponent( "Tests" ).appendingPathComponent( target.name + "Tests" ) ).appendingPathComponent( "WordPlusUITests" ),
            module: target.moduleName
        )
        if testTarget == nil {
            copies.testsNote = "Declare the test target \( target.name )Tests in Package.swift, depending on \( target.name ), to run them."
        }
        try copies.run( arguments.filter { $0 != "--target" && $0 != wanted } )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension WordPlusUI: XcodeCommandPlugin {
    func performCommand( context: XcodePluginContext, arguments: [ String ] ) throws {
        let root = URL( fileURLWithPath: context.xcodeProject.directory.string )
        let wanted = value( of: "--target", in: arguments )
        let apps = context.xcodeProject.targets.filter { target in
            if case .application? = target.product?.kind { return true }
            return false
        }
        guard let target = wanted.map( { name in context.xcodeProject.targets.first { $0.displayName == name } } ) ?? apps.first ?? nil else {
            throw Failure( "No app target to copy into: --target <name>." )
        }
        // The tests go in the project's unit test target (a UI test target can't reach the app's code), under
        // WordPlusUITests/; without one, in a folder of their own beside the project.
        let unitTests = context.xcodeProject.targets.first { candidate in
            if case .other( let kind )? = candidate.product?.kind { return kind.hasSuffix( "unit-test" ) }
            return false
        }
        var copies = Copies(
            root: root,
            into: root.appendingPathComponent( target.displayName ).appendingPathComponent( "WordPlusUI" ),
            tests: unitTests.map { root.appendingPathComponent( $0.displayName ).appendingPathComponent( "WordPlusUITests" ) }
                ?? root.appendingPathComponent( "WordPlusUITests" ),
            module: String( target.displayName.map { $0.isLetter || $0.isNumber ? $0 : "_" } )
        )
        copies.testsNote = unitTests == nil
            ? "Add them to a unit test target hosted by \( target.displayName ) (File > New > Target > Unit Testing Bundle) to run them."
            : "In \( unitTests!.displayName ): add the folder to the target if Xcode hasn't, then run them on a simulator."
        try copies.run( arguments.filter { $0 != "--target" && $0 != wanted } )
    }
}
#endif

private func value( of flag: String, in arguments: [ String ] ) -> String? {
    guard let at = arguments.firstIndex( of: flag ), at + 1 < arguments.count else { return nil }
    return arguments[ at + 1 ]
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init( _ description: String ) { self.description = description }
}
