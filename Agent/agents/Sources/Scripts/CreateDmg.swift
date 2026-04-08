import Foundation

@_cdecl("script_main")
public func scriptMain() -> Int32 {
    let fileManager = FileManager.default
    
    // Get arguments from AGENT_SCRIPT_ARGS env var or command line
    let envArgs = ProcessInfo.processInfo.environment["AGENT_SCRIPT_ARGS"] ?? ""
    var args: [String]
    if envArgs.isEmpty {
        args = ProcessInfo.processInfo.arguments
    } else {
        // Parse the env var string into individual arguments (handle quoted strings)
        args = ["CreateDmg"] // Add script name as first arg
        var currentArg = ""
        var inQuotes = false
        for char in envArgs {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == " " && !inQuotes {
                if !currentArg.isEmpty {
                    args.append(currentArg)
                    currentArg = ""
                }
            } else {
                currentArg.append(char)
            }
        }
        if !currentArg.isEmpty {
            args.append(currentArg)
        }
    }
    
    // Parse arguments: --app <path> --output <path> [--name <volume-name>] [--size <mb>] [--compress]
    var appPath: String?
    var outputPath: String?
    var volumeName: String? // nil = auto-detect from app bundle name
    var sizeMB = 0 // 0 = auto-detect from app bundle size
    var compress = false
    var signIdentity: String? // code-signing identity
    var notarize = false
    var windowSize: String? // WxH (e.g. "640x480")
    var iconSize: Int? // icon grid size (e.g. 128)
    var backgroundPath: String? // path to background image
    
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--app":
            appPath = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        case "--output":
            outputPath = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        case "--name":
            volumeName = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        case "--size":
            if let sizeStr = i + 1 < args.count ? args[i + 1] : nil {
                sizeMB = Int(sizeStr) ?? 0
            }
            i += 2
        case "--compress":
            compress = true
            i += 1
        case "--sign":
            signIdentity = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        case "--notarize":
            notarize = true
            i += 1
        case "--window-size":
            windowSize = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        case "--icon-size":
            iconSize = i + 1 < args.count ? Int(args[i + 1]) : nil
            i += 2
        case "--background":
            backgroundPath = i + 1 < args.count ? args[i + 1] : nil
            i += 2
        default:
            i += 1
        }
    }
    
    guard let appPath = appPath else {
        print("Usage: CreateDmg --app <path-to-app> --output <dmg-path> [--name <volume-name>] [--size <mb>] [--compress]")
        print("Options:")
        print("  --app      Path to the .app bundle (required)")
        print("  --output   Output DMG path (optional, defaults to app path with .dmg extension)")
        print("  --name     Volume name shown when mounted (default: auto-detected from app name)")
        print("  --size     Size in MB (default: auto-detected from app size + 20%)")
        print("  --compress Convert to compressed read-only UDZO format")
        print("  --sign     Code-sign the DMG with the given identity (e.g. \"Developer ID Application: ...\")")
        print("  --notarize Notarize the DMG via notarytool (requires --sign and stored credentials)")
        print("  --window-size WxH  Set Finder window dimensions when opened (e.g. \"640x480\")")
        print("  --icon-size N      Set icon grid size in the DMG window (e.g. 128)")
        print("  --background <path> Set a background image for the DMG Finder window")
        print("\nExample: CreateDmg --app /path/to/MyApp.app --output /path/to/MyApp.dmg --name \"MyApp\" --compress")
        return 1
    }
    
    // Resolve paths
    let resolvedAppPath = (appPath as NSString).expandingTildeInPath
    let resolvedOutputPath = outputPath ?? resolvedAppPath.replacingOccurrences(of: ".app$", with: ".dmg", options: .regularExpression)
    
    // Auto-detect volume name from app bundle name if not specified
    let finalVolumeName: String
    if let volumeName = volumeName {
        finalVolumeName = volumeName
    } else {
        let bundleName = (resolvedAppPath as NSString).lastPathComponent
        finalVolumeName = (bundleName as NSString).deletingPathExtension
    }
    
    // Check if app exists
    guard fileManager.fileExists(atPath: resolvedAppPath) else {
        print("Error: App not found at \(resolvedAppPath)")
        return 1
    }
    
    // Auto-detect size from app bundle if not specified
    if sizeMB == 0 {
        if let enumerator = fileManager.enumerator(atPath: resolvedAppPath) {
            var totalBytes: UInt64 = 0
            for case let file as String in enumerator {
                if let attrs = try? fileManager.attributesOfItem(atPath: resolvedAppPath + "/" + file),
                   let size = attrs[.size] as? UInt64 {
                    totalBytes += size
                }
            }
            let appMB = Double(totalBytes) / 1024 / 1024
            sizeMB = max(10, Int(ceil(appMB * 1.2))) // 20% padding, min 10 MB
            print("Auto-detected app size: \(String(format: "%.1f", appMB)) MB → DMG size: \(sizeMB) MB")
        } else {
            sizeMB = 200 // fallback
        }
    }
    
    // Remove existing DMG if present
    if fileManager.fileExists(atPath: resolvedOutputPath) {
        do {
            try fileManager.removeItem(atPath: resolvedOutputPath)
            print("Removed existing DMG: \(resolvedOutputPath)")
        } catch {
            print("Error removing existing DMG: \(error)")
            return 1
        }
    }
    
    // Create temporary directory
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent("dmg_build_\(UUID().uuidString)").path
    
    do {
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    } catch {
        print("Error creating temp directory: \(error)")
        return 1
    }
    
    defer {
        try? fileManager.removeItem(atPath: tempDir)
    }
    
    // Copy app to temp directory
    let appName = (resolvedAppPath as NSString).lastPathComponent
    let tempAppPath = (tempDir as NSString).appendingPathComponent(appName)
    
    do {
        try fileManager.copyItem(atPath: resolvedAppPath, toPath: tempAppPath)
        print("Copied \(appName) to temp directory")
        
        // Create Applications symlink for drag-to-install UX
        let appsLink = (tempDir as NSString).appendingPathComponent("Applications")
        try fileManager.createSymbolicLink(
            atPath: appsLink,
            withDestinationPath: "/Applications"
        )
        print("Created Applications symlink")
    } catch {
        print("Error copying app: \(error)")
        return 1
    }
    
    // Create DMG
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    task.arguments = [
        "create",
        "-volname", finalVolumeName,
        "-srcfolder", tempDir,
        "-ov",
        "-format", "UDRW",
        "-size", "\(sizeMB)m",
        resolvedOutputPath
    ]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    
    do {
        print("Creating DMG: \((resolvedOutputPath as NSString).lastPathComponent)...")
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !output.isEmpty {
            print(output)
        }
        
        if task.terminationStatus == 0 {
            print("\n✓ Successfully created: \(resolvedOutputPath)")
            print("  Volume name: \(finalVolumeName)")
            print("  Format: Read/Write (UDRW)")
            print("  Size: \(sizeMB) MB")
            
            // Set Finder window properties if specified (mount, set properties, unmount)
            if windowSize != nil || iconSize != nil || backgroundPath != nil {
                print("\nConfiguring DMG window properties...")
                // Mount the DMG
                let mountTask = Process()
                mountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                mountTask.arguments = ["attach", resolvedOutputPath, "-noverify", "-nobrowse", "-quiet"]
                try mountTask.run()
                mountTask.waitUntilExit()
                if mountTask.terminationStatus == 0 {
                    let volPath = "/Volumes/\(finalVolumeName)"
                    var scriptLines = ["tell application \"Finder\"", "open POSIX file \"\(volPath)\""]
                    if let ws = windowSize {
                        let parts = ws.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 {
                            let (w, h) = (parts[0], parts[1])
                            scriptLines.append("set bounds of front window to {100, 100, \(100 + w), \(100 + h)}")
                            print("  Window size: \(w)x\(h)")
                        }
                    }
                    if let iconSz = iconSize {
                        scriptLines.append("set icon size of front window to \(iconSz)")
                        print("  Icon size: \(iconSz)")
                    }
                    if let bgPath = backgroundPath {
                        let bgResolved = (bgPath as NSString).expandingTildeInPath
                        if fileManager.fileExists(atPath: bgResolved) {
                            let bgDir = volPath + "/.background"
                            let bgFileName = (bgResolved as NSString).lastPathComponent
                            let destPath = bgDir + "/" + bgFileName
                            // Create hidden background dir and copy image
                            try? fileManager.createDirectory(atPath: bgDir, withIntermediateDirectories: true)
                            try? fileManager.copyItem(atPath: bgResolved, toPath: destPath)
                            // Use relative path for portability
                            scriptLines.append("set background picture of front window to POSIX file \"\(destPath)\"")
                            print("  Background: \(bgFileName)")
                        } else {
                            print("Warning: Background image not found at \(bgResolved)")
                        }
                    }
                    scriptLines.append("close front window")
                    scriptLines.append("end tell")
                    let script = NSAppleScript(source: scriptLines.joined(separator: "\n"))
                    var err: NSDictionary?
                    script?.executeAndReturnError(&err)
                    if let err = err {
                        print("Warning: Could not set window properties: \(err)")
                    } else {
                        print("✓ Window properties configured")
                    }
                    // Unmount
                    let detachTask = Process()
                    detachTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detachTask.arguments = ["detach", volPath, "-quiet"]
                    try detachTask.run()
                    detachTask.waitUntilExit()
                }
            }
            
            let compressedPath = resolvedOutputPath
            if compress {
                // Convert to compressed UDZO format
                let tempRwPath = (resolvedOutputPath as NSString).deletingPathExtension + "_temp.dmg"
                
                // Rename the RW DMG temporarily
                do {
                    try fileManager.moveItem(atPath: resolvedOutputPath, toPath: tempRwPath)
                } catch {
                    print("Error preparing for compression: \(error)")
                    return 1
                }
                
                let convertTask = Process()
                convertTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                convertTask.arguments = [
                    "convert",
                    tempRwPath,
                    "-format", "UDZO",
                    "-o", compressedPath,
                    "-imagekey", "zlib-level=9"
                ]
                
                let convertPipe = Pipe()
                convertTask.standardOutput = convertPipe
                convertTask.standardError = convertPipe
                
                do {
                    print("\nConverting to compressed format...")
                    try convertTask.run()
                    convertTask.waitUntilExit()
                    
                    let convertData = convertPipe.fileHandleForReading.readDataToEndOfFile()
                    let convertOutput = String(data: convertData, encoding: .utf8) ?? ""
                    if !convertOutput.isEmpty {
                        print(convertOutput)
                    }
                    
                    // Remove temp RW DMG
                    try? fileManager.removeItem(atPath: tempRwPath)
                    
                    if convertTask.terminationStatus == 0 {
                        print("\n✓ Compressed DMG created: \(compressedPath)")
                        
                        // Show size savings
                        if let compressedAttrs = try? fileManager.attributesOfItem(atPath: compressedPath),
                           let compressedSize = compressedAttrs[.size] as? UInt64 {
                            let compressedMB = Double(compressedSize) / 1024 / 1024
                            print("  Final size: \(String(format: "%.2f", compressedMB)) MB")
                        }
                    } else {
                        print("Error compressing DMG, exit code: \(convertTask.terminationStatus)")
                        return 1
                    }
                } catch {
                    print("Error during compression: \(error)")
                    return 1
                }
            } else {
                print("\nTo customize:")
                print("  1. Open the DMG")
                print("  2. In Finder, use View > Show View Options")
                print("  3. Set background color/image")
                print("  4. Convert to compressed: hdiutil convert \"\(resolvedOutputPath)\" -format UDZO -o final.dmg")
            }
        } else {
            print("Error creating DMG, exit code: \(task.terminationStatus)")
        }
        
        // Code-sign the final DMG if requested
        if let identity = signIdentity, task.terminationStatus == 0 {
            let dmgToSign = resolvedOutputPath
            print("\nSigning DMG with identity: \(identity)...")
            let signTask = Process()
            signTask.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signTask.arguments = ["--sign", identity, dmgToSign]
            let signPipe = Pipe()
            signTask.standardError = signPipe
            try signTask.run()
            signTask.waitUntilExit()
            if signTask.terminationStatus == 0 {
                print("✓ DMG signed successfully")
            } else {
                let errData = signPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
                print("Error signing DMG: \(errMsg)")
                return 1
            }
        }
        
        // Notarize the DMG if requested (requires signing first)
        if notarize, signIdentity != nil, task.terminationStatus == 0 {
            print("\nSubmitting DMG for notarization...")
            let notaryTask = Process()
            notaryTask.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            notaryTask.arguments = ["notarytool", "submit", resolvedOutputPath, "--wait"]
            let notaryPipe = Pipe()
            notaryTask.standardOutput = notaryPipe
            notaryTask.standardError = notaryPipe
            do {
                try notaryTask.run()
                notaryTask.waitUntilExit()
                let notaryData = notaryPipe.fileHandleForReading.readDataToEndOfFile()
                let notaryOutput = String(data: notaryData, encoding: .utf8) ?? ""
                if !notaryOutput.isEmpty { print(notaryOutput) }
                if notaryTask.terminationStatus == 0 {
                    print("\n✓ DMG notarized successfully")
                    // Staple the ticket
                    let stapleTask = Process()
                    stapleTask.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                    stapleTask.arguments = ["stapler", "staple", resolvedOutputPath]
                    let staplePipe = Pipe()
                    stapleTask.standardOutput = staplePipe
                    stapleTask.standardError = staplePipe
                    try stapleTask.run()
                    stapleTask.waitUntilExit()
                    let stapleData = staplePipe.fileHandleForReading.readDataToEndOfFile()
                    let stapleOutput = String(data: stapleData, encoding: .utf8) ?? ""
                    if !stapleOutput.isEmpty { print(stapleOutput) }
                    if stapleTask.terminationStatus == 0 {
                        print("✓ Notarization ticket stapled")
                    } else {
                        print("Warning: Stapling failed (DMG is still notarized)")
                    }
                } else {
                    print("Error: Notarization failed")
                    return 1
                }
            } catch {
                print("Error during notarization: \(error)")
                return 1
            }
        }
        
        return task.terminationStatus
    } catch {
        print("Error: \(error)")
        return 1
    }
}