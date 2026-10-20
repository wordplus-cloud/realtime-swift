// `swift run --package-path <this package> wordplus-ui <add|diff|update|accept> --project <folder> --target <App>`: the
// WordPlusUI command plugin's copies (Plugins/WordPlusUI) for an Xcode project from a command line, where only Xcode runs
// a project's command plugins: what an AI agent or a script reaches. The same files and records as the plugin's.
//
//   --project <folder>   the folder holding the .xcodeproj (the current one by default)
//   --target <App>       the app target, whose folder the screen goes in (<folder>/<App>/WordPlusUI)
//   --tests <folder>     where its tests go: <folder>/<App>Tests/WordPlusUITests when there is such a folder
//   --module <Name>      the app's module, which the tests import (the target's name, as Xcode makes it)
#if os(macOS)
import Foundation

/// A refusal Copies throws, as the plugin's own (plugin.swift) has it.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init( _ description: String ) { self.description = description }
}

let arguments = Array( CommandLine.arguments.dropFirst() )

func value( of flag: String ) -> String? {
    guard let at = arguments.firstIndex( of: flag ), at + 1 < arguments.count else { return nil }
    return arguments[ at + 1 ]
}

let here = URL( fileURLWithPath: FileManager.default.currentDirectoryPath )
let root = value( of: "--project" ).map { URL( fileURLWithPath: $0, relativeTo: here ).standardizedFileURL } ?? here

guard let target = value( of: "--target" ) else {
    print( "wordplus-ui <add|diff|update|accept> --project <folder holding the .xcodeproj> --target <App> [--tests <folder>] [--module <Name>]" )
    exit( 1 )
}

// The tests: where they are asked to go, else the app's unit test target's folder when the project has one by the usual
// name, else a folder of their own beside the project.
let testsFolder = root.appendingPathComponent( target + "Tests" )
let tests = value( of: "--tests" ).map { URL( fileURLWithPath: $0, relativeTo: here ).standardizedFileURL }
    ?? ( FileManager.default.fileExists( atPath: testsFolder.path ) ? testsFolder : root ).appendingPathComponent( "WordPlusUITests" )

var copies = Copies(
    root: root,
    into: root.appendingPathComponent( target ).appendingPathComponent( "WordPlusUI" ),
    tests: tests,
    module: value( of: "--module" ) ?? String( target.map { $0.isLetter || $0.isNumber ? $0 : "_" } )
)
copies.command = "swift run --package-path <WordPlusRealtime> wordplus-ui --project \( value( of: "--project" ) ?? "." ) --target \( target )"
if value( of: "--tests" ) == nil && !FileManager.default.fileExists( atPath: testsFolder.path ) {
    copies.testsNote = "Add them to a unit test target hosted by \( target ) (File > New > Target > Unit Testing Bundle) to run them."
}

let flags: Set<String> = [ "--project", "--target", "--tests", "--module" ]
var rest: [ String ] = []
var skip = false
for argument in arguments {
    if skip { skip = false; continue }
    if flags.contains( argument ) { skip = true; continue }
    rest.append( argument )
}

do {
    try copies.run( rest )
} catch {
    FileHandle.standardError.write( Data( ( String( describing: error ) + "\n" ).utf8 ) )
    exit( 1 )
}
#endif
