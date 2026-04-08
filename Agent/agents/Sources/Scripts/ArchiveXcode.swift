import Foundation

@_cdecl("script_main")
public func scriptMain() -> Int32 {
    // Dynamic Archive & Notarization for any Xcode project
    //
    // Usage via AGENT_SCRIPT_ARGS:
    //   "/path/to/project [scheme] [teamID]"
    //
    // If only a project path is given, scheme and teamID are auto-detected:
    //   - scheme: derived from the .xcodeproj bundle name
    //   - teamID: read from DEVELOPMENT_TEAM in project.pbxproj
    //   - projectFile: first .xcodeproj found in the directory
    
    let args = ProcessInfo.processInfo.environment["AGENT_SCRIPT_ARGS"] ?? ""
    let parts = args.split(separator: " ").map(String.init)
    
    // --- Dynamic project detection helpers ---
    
    // Find first .xcodeproj in a directory
    func findXcodeProject(in dir: String) -> String? {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir)
        return contents?.first(where: { $0.hasSuffix(".xcodeproj") })
    }
    
    // Derive scheme name from .xcodeproj filename
    func schemeFromProject(_ projName: String) -> String {
        return (projName as NSString).deletingPathExtension
    }
    
    // Read DEVELOPMENT_TEAM from project.pbxproj
    func teamIDFromProject(_ pbxprojPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: pbxprojPath),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "DEVELOPMENT_TEAM\\s*=\\s*([A-Z0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[range])
    }
    
    // Detect build configuration (first Release-like config from project.pbxproj)
    func buildConfigFromProject(_ pbxprojPath: String) -> String {
        guard let data = FileManager.default.contents(atPath: pbxprojPath),
              let content = String(data: data, encoding: .utf8) else { return "Release" }
        // Look for build configuration names in the xcconfig list
        let pattern = "buildSettings\\s*=\\s*\\{[^}]*?DEBUG_INFORMATION_FORMAT[^}]*?\\}"
        // Simpler: find all configuration names
        let configPattern = "(/\\*\\s*)(\\w+(?:\\s+\\w+)*)(\\s*-\\s*Build configuration\\s*\\*/)"
        if let regex = try? NSRegularExpression(pattern: configPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            var configs: [String] = []
            for match in matches {
                if let range = Range(match.range(at: 2), in: content) {
                    configs.append(String(content[range]))
                }
            }
            // Prefer "Release", then anything with "Release" in it, then first non-Debug config
            if configs.contains("Release") { return "Release" }
            if let rel = configs.first(where: { $0.localizedCaseInsensitiveContains("release") }) { return rel }
            if let nonDebug = configs.first(where: { !$0.localizedCaseInsensitiveContains("debug") }) { return nonDebug }
        }
        return "Release"
    }
    
    // Detect export method from project.pbxproj (look for provisioning profile hints)
    func exportMethodFromProject(_ pbxprojPath: String) -> String {
        guard let data = FileManager.default.contents(atPath: pbxprojPath),
              let content = String(data: data, encoding: .utf8) else { return "developer-id" }
        // Check for hints of distribution type
        if content.contains("app-store") || content.contains("APP_STORE") { return "app-store" }
        if content.contains("developer-id") || content.contains("DEVELOPER_ID") { return "developer-id" }
        // If it's a command-line tool target, default to developer-id
        if content.contains("productType = \"com.apple.product-type.tool\"") { return "developer-id" }
        return "developer-id"
    }
    
    // Find stored notarytool credential profile name
    func findNotaryCredential() -> String? {
        // Check common credential store locations
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["notarytool", "list-profiles"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // Try stored-credentials instead
        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task2.arguments = ["notarytool", "history"]
        // Try common names
        for name in ["App Store Connect Profile", "notarytool", "AC_PASSWORD", "altool"] {
            let checkTask = Process()
            checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            checkTask.arguments = ["notarytool", "history", "-p", name]
            let checkPipe = Pipe()
            checkTask.standardOutput = checkPipe
            checkTask.standardError = checkPipe
            do {
                try checkTask.run()
                checkTask.waitUntilExit()
                if checkTask.terminationStatus == 0 {
                    return name
                }
            } catch { continue }
        }
        return nil
    }
    
    // --- Resolve configuration dynamically ---
    
    // 1) Project path: from arg, AGENT_PROJECT_FOLDER env, or current directory
    let projectPath: String
    if parts.count > 0 && !parts[0].isEmpty {
        projectPath = (parts[0] as NSString).standardizingPath
    } else if let envFolder = ProcessInfo.processInfo.environment["AGENT_PROJECT_FOLDER"], !envFolder.isEmpty {
        projectPath = (envFolder as NSString).standardizingPath
    } else {
        projectPath = FileManager.default.currentDirectoryPath
    }

    
    // Verify project directory exists
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
        print("Error: Project directory not found: \(projectPath)")
        return 1
    }
    
    // 2) Auto-detect .xcodeproj
    let detectedProjectName = findXcodeProject(in: projectPath)
    let projectFile: String
    if parts.count > 2 && !parts[2].isEmpty {
        projectFile = (parts[2] as NSString).standardizingPath
    } else if let projName = detectedProjectName {
        projectFile = "\(projectPath)/\(projName)"
    } else {
        print("Error: No .xcodeproj found in \(projectPath)")
        print("Usage: AGENT_SCRIPT_ARGS=\"/path/to/project [scheme] [projectFile] [archivePath] [teamID]\"")
        return 1
    }
    
    // 3) Scheme: from arg or auto-detect from project name
    let scheme: String
    if parts.count > 1 && !parts[1].isEmpty {
        scheme = parts[1]
    } else {
        scheme = schemeFromProject((projectFile as NSString).lastPathComponent)
    }
    
    // 4) Archive path: default to build/<scheme>.xcarchive
    let archivePath = parts.count > 3 && !parts[3].isEmpty
        ? (parts[3] as NSString).standardizingPath
        : "\(projectPath)/build/\(scheme).xcarchive"
    
    // 5) Team ID: from arg or auto-detect from project.pbxproj
    let teamID: String
    if parts.count > 4 && !parts[4].isEmpty {
        teamID = parts[4]
    } else if let detected = teamIDFromProject("\(projectFile)/project.pbxproj") {
        teamID = detected
    } else {
        print("Error: Could not auto-detect DEVELOPMENT_TEAM from project.pbxproj")
        print("Pass team ID as an argument: AGENT_SCRIPT_ARGS=\"/path/to/project scheme teamID\"")
        return 1
    }
    
    let exportPath = "\(projectPath)/build/export"
    let appName = scheme
    
    // Auto-detect build configuration from project
    let buildConfig = buildConfigFromProject("\(projectFile)/project.pbxproj")
    // Auto-detect export method from project
    let exportMethod = exportMethodFromProject("\(projectFile)/project.pbxproj")
    // Auto-detect notarytool credential profile
    let credentialName = findNotaryCredential() ?? "App Store Connect Profile"
    
    print("=== Starting Archive and Notarization Process ===")
    print("Project Path:  \(projectPath)")
    print("Scheme:        \(scheme)")
    print("Project File:  \(projectFile)")
    print("Archive Path:  \(archivePath)")
    print("Team ID:       \(teamID)")
    print("Build Config:  \(buildConfig)")
    print("Export Method: \(exportMethod)")
    print("Export Path:   \(exportPath)")
    print("")
    fflush(stdout)
    
    // Create build directory if needed
    let buildDir = URL(fileURLWithPath: archivePath).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
    
    // Helper function to run process with live output
    func runProcess(executable: String, arguments: [String], workingDir: String? = nil) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let dir = workingDir {
            task.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        
        // Stream stdout live
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print(output, terminator: "")
                fflush(stdout)
            }
        }
        
        // Stream stderr live
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                print(output, terminator: "")
                fflush(stdout)
            }
        }
        
        do {
            try task.run()
            task.waitUntilExit()
            
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            
            return task.terminationStatus
        } catch {
            print("Error running \(executable): \(error)")
            return 1
        }
    }
    
    // Step 1: Create Archive
    print("Step 1: Creating Archive...")
    let archiveResult = runProcess(
        executable: "/usr/bin/xcodebuild",
        arguments: [
            "-scheme", scheme,
            "-project", projectFile,
            "-configuration", buildConfig,
            "-archivePath", archivePath,
            "archive"
        ],
        workingDir: projectPath
    )
    
    if archiveResult != 0 {
        print("\n=== Archive Failed ===")
        print("Exit status: \(archiveResult)")
        return 1
    }
    print("\nArchive created successfully!\n")
    
    // Step 2: Export Archive
    print("Step 2: Exporting Archive...")
    
    let exportOptionsContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>method</key>
        <string>\(exportMethod)</string>
        <key>teamID</key>
        <string>\(teamID)</string>
        <key>signingStyle</key>
        <string>automatic</string>
    </dict>
    </plist>
    """
    
    let exportOptionsPath = "\(projectPath)/ExportOptions.plist"
    FileManager.default.createFile(atPath: exportOptionsPath, contents: exportOptionsContent.data(using: .utf8), attributes: nil)
    
    // Clean export directory
    try? FileManager.default.removeItem(atPath: exportPath)
    try? FileManager.default.createDirectory(atPath: exportPath, withIntermediateDirectories: true)
    
    let exportResult = runProcess(
        executable: "/usr/bin/xcodebuild",
        arguments: [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportOptionsPlist", exportOptionsPath,
            "-exportPath", exportPath
        ],
        workingDir: projectPath
    )
    
    if exportResult != 0 {
        print("\n=== Export Failed ===")
        print("Exit status: \(exportResult)")
        return 1
    }
    print("\nArchive exported successfully!\n")
    
    // Find the exported app dynamically — scan the export directory for any .app bundle
    let exportedAppPath: String
    if let exportContents = try? FileManager.default.contentsOfDirectory(atPath: exportPath),
       let foundApp = exportContents.first(where: { $0.hasSuffix(".app") }) {
        exportedAppPath = "\(exportPath)/\(foundApp)"
        print("Found exported app: \(foundApp)")
    } else {
        // Fallback to scheme-derived name
        let fallbackPath = "\(exportPath)/\(appName).app"
        if FileManager.default.fileExists(atPath: fallbackPath) {
            exportedAppPath = fallbackPath
        } else {
            print("Error: No .app bundle found in export directory \(exportPath)")
            return 1
        }
    }
    
    // Derive actual app name from discovered bundle (may differ from scheme name)
    let actualAppName = (exportedAppPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    print("Exported app: \(exportedAppPath)\n")
    
    // Step 3: Create ZIP for notarization
    print("Step 3: Creating ZIP for Notarization...")
    let zipPath = "\(exportPath)/\(actualAppName)-notarize.zip"
    
    let zipResult = runProcess(
        executable: "/usr/bin/ditto",
        arguments: ["-c", "-k", "--keepParent", exportedAppPath, zipPath]
    )
    
    if zipResult != 0 {
        print("ZIP creation failed")
        return 1
    }
    print("ZIP created: \(zipPath)\n")
    
    // Step 4: Submit for notarization
    print("Step 4: Submitting for Notarization...")
    print("Note: This requires App Store Connect API key or app-specific password\n")
    
    // Check if credentials are stored
    let checkCredsResult = runProcess(
        executable: "/usr/bin/xcrun",
        arguments: ["notarytool", "history", "-p", credentialName]
    )
    
    if checkCredsResult != 0 {
        print("""
        ========================================
        NOTARIZATION CREDENTIALS NOT CONFIGURED
        ========================================
        
        To set up notarization, run:
        
        xcrun notarytool store-credentials "\(credentialName)" \\
            --apple-id YOUR_APPLE_ID \\
            --team-id \(teamID) \\
            --password YOUR_APP_SPECIFIC_PASSWORD
        
        Get app-specific password from:
        https://appleid.apple.com/account/manage
        
        Then run this script again.
        """)
        return 1
    }
    
    // Submit for notarization
    print("Submitting for notarization (this may take several minutes)...\n")
    let submitResult = runProcess(
        executable: "/usr/bin/xcrun",
        arguments: ["notarytool", "submit", "-p", credentialName, "--wait", "--timeout", "7200", zipPath]
    )
    
    if submitResult != 0 {
        print("\nNotarization submission failed")
        return 1
    }
    print("\nNotarization successful!\n")
    
    // Step 5: Staple ticket
    print("Step 5: Stapling Notarization Ticket...")
    
    let stapleResult = runProcess(
        executable: "/usr/bin/xcrun",
        arguments: ["stapler", "staple", exportedAppPath]
    )
    
    if stapleResult != 0 {
        print("Stapling failed")
        return 1
    }
    print("Ticket stapled successfully!\n")
    
    print("=== COMPLETE ===")
    print("Notarized app: \(exportedAppPath)")
    print("Open folder: \(exportPath)")
    
    // Open Finder to the export directory
    _ = runProcess(executable: "/usr/bin/open", arguments: [exportPath])
    
    return 0
}
