// On the Mac only: the plugin always runs there, and the command line tool (Sources/WordPlusUITool) that links this file
// is built for iOS too when the whole package is, as its tests do.
#if os(macOS)
import CryptoKit
import Foundation

/// The app's copy of the call screen: copied, compared with ours, brought up to date (plugin.swift says how).
struct Copies {
    /// The package's or the project's folder, where wordplus-ui.json and .wordplus-ui/ are kept.
    let root: URL
    /// Where the screen's files go in the app.
    let into: URL
    /// Where its tests go: the app's unit test target, or a folder of their own when it has none.
    let tests: URL
    /// The app's module, which the tests import in place of WordPlusRealtimeUI.
    let module: String
    /// What to say about the tests when the app has no unit test target to put them in.
    var testsNote: String? = nil
    /// The command its hints name: the plugin's, or the command line tool's for an Xcode project (Sources/WordPlusUITool).
    var command = "swift package wordplus-ui"

    static let component = "call-screen"

    /// A file of ours in the app: the screen's in `into`, its tests (`Tests/…`) in `tests`.
    private func fileOf( _ name: String ) -> URL {
        name.hasPrefix( "Tests/" ) ? tests.appendingPathComponent( String( name.dropFirst( "Tests/".count ) ) ) : into.appendingPathComponent( name )
    }

    private var recordFile: URL { root.appendingPathComponent( "wordplus-ui.json" ) }
    private var baseFile: URL { root.appendingPathComponent( ".wordplus-ui" ).appendingPathComponent( Copies.component + ".json" ) }

    func run( _ arguments: [ String ] ) throws {
        switch arguments.first {
        case "add": try add( force: arguments.contains( "--force" ) )
        case "diff": try diff()
        case "update": try update()
        case "accept": try accept()
        default:
            print( """
            \( command ) <command>   (\( embeddedVersion ))
              add [--target App] [--force]   copy the call screen into the target, to change as far as you need
              diff                           what changed in ours since you copied it
              update                         take ours into the files you never changed
              accept                         record that yours now has ours
            """ )
        }
    }

    // MARK: - The commands

    private func add( force: Bool ) throws {
        var record = try readRecord()
        if record.components[ Copies.component ] != nil, !force {
            print( "The call screen is already in \( relative( into ) ). `\( command ) diff` shows what changed in ours since; --force copies it again over yours." )
            return
        }
        try FileManager.default.createDirectory( at: into, withIntermediateDirectories: true )
        var base: [ String: String ] = [:]
        var files: [ String: Copied ] = [:]
        for ( name, text ) in ours() {
            try write( text, to: fileOf( name ) )
            base[ name ] = text
            files[ name ] = Copied( version: embeddedVersion, sha256: sha( text ) )
        }
        record.dir = relative( into )
        record.components[ Copies.component ] = Component( files: files )
        try writeRecord( record )
        try writeBase( base )
        print( """
        The call screen: copied into \( relative( into ) )/ (\( files.keys.filter { !$0.hasPrefix( "Tests/" ) }.count ) files). It is yours now: change anything.
        The calls under it stay in WordPlusRealtimeCalls, so their fixes still reach you.
        Its tests, on the preview's states with no call: \( relative( tests ) )/. \( testsNote ?? "Run them after a change, on a simulator." )
        Every state of your copy, with no call: CallScreenPreview() (in a UINavigationController), or `#Preview { CallScreenPreview( .video ) }`.

        In the target: take WordPlusRealtimeUI out of its dependencies (your copy is the screen now), and add LiveKit
        (this package's room client) and LiveKitWebRTC (webrtc-xcframework), which the screen draws with. Then use it as before:
        CallScreen.shared.attach( rt.calls ). When the package updates: \( command ) diff.
        """ )
    }

    private func diff() throws {
        let record = try readRecord()
        guard let component = record.components[ Copies.component ] else { throw Failure( "No copy here yet: \( command ) add." ) }
        let base = try readBase()
        var changed = 0
        for state in states( component, base ) where state.oursChanged {
            changed += 1
            let from = component.files[ state.name ]?.version ?? "none"
            print( "\n=== \( state.name ): ours changed since \( from ) (now \( embeddedVersion ))" + ( state.yoursChanged ? "; yours changed too: merge by hand" : "; yours is as copied: `update` takes ours" ) )
            print( try unified( state.then ?? "", state.now ?? "", from: "ours@\( from )/\( state.name )", to: "ours@\( embeddedVersion )/\( state.name )" ) )
        }
        print( changed == 0
            ? "Nothing changed in ours since your copy (\( embeddedVersion ))."
            : "\n\( changed ) file(s) changed in ours. Merge each into yours, build and try a call, then `\( command ) accept`." )
    }

    private func update() throws {
        var record = try readRecord()
        guard var component = record.components[ Copies.component ] else { throw Failure( "No copy here yet: \( command ) add." ) }
        var base = try readBase()
        for state in states( component, base ) where state.oursChanged {
            if state.yoursChanged {
                print( "\( state.name ): yours changed, and so did ours: `\( command ) diff` shows ours to merge." )
                continue
            }
            let path = fileOf( state.name )
            guard let now = state.now else {
                try? FileManager.default.removeItem( at: path )
                base[ state.name ] = nil
                component.files[ state.name ] = nil
                print( "\( state.name ): gone from ours, and you never changed it: removed." )
                continue
            }
            try write( now, to: path )
            base[ state.name ] = now
            component.files[ state.name ] = Copied( version: embeddedVersion, sha256: sha( now ) )
            print( "\( state.name ): you never changed it: now ours of \( embeddedVersion )." )
        }
        record.components[ Copies.component ] = component
        try writeRecord( record )
        try writeBase( base )
    }

    private func accept() throws {
        var record = try readRecord()
        guard var component = record.components[ Copies.component ] else { throw Failure( "No copy here yet: \( command ) add." ) }
        var base = try readBase()
        for state in states( component, base ) {
            guard let now = state.now else {
                base[ state.name ] = nil
                component.files[ state.name ] = nil
                continue
            }
            base[ state.name ] = now
            component.files[ state.name ] = Copied( version: embeddedVersion, sha256: sha( now ) )
            if state.yours == nil {
                try write( now, to: fileOf( state.name ) )
                print( "\( state.name ): new in ours, copied." )
            }
        }
        record.components[ Copies.component ] = component
        try writeRecord( record )
        try writeBase( base )
        print( "The call screen: yours has ours of \( embeddedVersion )." )
    }

    // MARK: - What each file is

    private struct State {
        let name: String
        let then: String?
        let now: String?
        let yours: String?
        let oursChanged: Bool
        let yoursChanged: Bool
    }

    private func states( _ component: Component, _ base: [ String: String ] ) -> [ State ] {
        let now = Dictionary( uniqueKeysWithValues: ours().map { ( $0.name, $0.text ) } )
        let names = Set( component.files.keys ).union( now.keys ).sorted()
        return names.map { name in
            let then = base[ name ]
            let yours = try? String( contentsOf: fileOf( name ), encoding: .utf8 )
            let recorded = component.files[ name ]?.sha256
            return State(
                name: name, then: then, now: now[ name ], yours: yours,
                oursChanged: then != now[ name ],
                yoursChanged: yours.map { sha( $0 ) != recorded } ?? false
            )
        }
    }

    /// Ours as a copy has it: each file with a line on top saying where it came from, the tests on the app's module.
    private func ours() -> [ ( name: String, text: String ) ] {
        embeddedFiles.map { file in
            let test = file.name.hasPrefix( "Tests/" )
            let from = test ? "Tests/WordPlusRealtimeUITests/" + file.name.dropFirst( "Tests/".count ) : "Sources/WordPlusRealtimeUI/" + file.name
            let text = test ? file.text.replacingOccurrences( of: "@testable import WordPlusRealtimeUI", with: "@testable import \( module )" ) : file.text
            // The same header whichever command copied it (the plugin's or the tool's), so `diff` from the other one
            // finds nothing changed.
            return ( file.name, "// call-screen: copied from WordPlusRealtime (\( from )) by `swift package wordplus-ui add`.\n"
                + "// It is yours now: change anything. `swift package wordplus-ui diff` shows what changed in ours since.\n" + text )
        }
    }

    // MARK: - Files

    private struct Copied: Codable {
        let version: String
        let sha256: String
    }

    private struct Component: Codable {
        var files: [ String: Copied ]
    }

    private struct Record: Codable {
        var dir: String = ""
        var components: [ String: Component ] = [:]
    }

    private func readRecord() throws -> Record {
        guard let data = try? Data( contentsOf: recordFile ) else { return Record() }
        return try JSONDecoder().decode( Record.self, from: data )
    }

    private func writeRecord( _ record: Record ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [ .prettyPrinted, .sortedKeys ]
        try encoder.encode( record ).write( to: recordFile )
    }

    private func readBase() throws -> [ String: String ] {
        guard let data = try? Data( contentsOf: baseFile ) else { return [:] }
        return try JSONDecoder().decode( [ String: String ].self, from: data )
    }

    private func writeBase( _ base: [ String: String ] ) throws {
        try FileManager.default.createDirectory( at: baseFile.deletingLastPathComponent(), withIntermediateDirectories: true )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [ .sortedKeys ]
        try encoder.encode( base ).write( to: baseFile )
    }

    private func write( _ text: String, to url: URL ) throws {
        try FileManager.default.createDirectory( at: url.deletingLastPathComponent(), withIntermediateDirectories: true )
        try text.write( to: url, atomically: true, encoding: .utf8 )
    }

    private func sha( _ text: String ) -> String {
        SHA256.hash( data: Data( text.utf8 ) ).map { String( format: "%02x", $0 ) }.joined()
    }

    private func relative( _ url: URL ) -> String {
        url.path.hasPrefix( root.path + "/" ) ? String( url.path.dropFirst( root.path.count + 1 ) ) : url.path
    }

    /// A unified diff of two texts, by the system's diff.
    private func unified( _ a: String, _ b: String, from: String, to: String ) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent( "wordplus-ui-" + UUID().uuidString )
        try FileManager.default.createDirectory( at: folder, withIntermediateDirectories: true )
        defer { try? FileManager.default.removeItem( at: folder ) }
        let left = folder.appendingPathComponent( "a" ), right = folder.appendingPathComponent( "b" )
        try a.write( to: left, atomically: true, encoding: .utf8 )
        try b.write( to: right, atomically: true, encoding: .utf8 )
        let process = Process()
        process.executableURL = URL( fileURLWithPath: "/usr/bin/diff" )
        process.arguments = [ "-u", "--label", from, "--label", to, left.path, right.path ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String( decoding: output, as: UTF8.self )
    }
}
#endif
