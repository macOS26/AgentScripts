# AgentScripts

Dynamic Swift scripts for the [Agent!](https://github.com/macOS26/Agent) macOS app. These scripts compile at runtime as dynamic libraries (`.dylib`) and are loaded into the app via `dlopen`.

## How It Works

1. On first launch, the Agent! app clones this repo to `~/Documents/AgentScript/agents/`
2. Each script is compiled individually via `swift build` as a dynamic library
3. The app loads the compiled `.dylib` and calls the `script_main()` entry point
4. Scripts can import bridges from [AgentEventBridges](https://github.com/macOS26/AgentEventBridges) to control macOS apps via Apple Events

## Writing a Script

Every script must export a C-callable `script_main` function:

```swift
import Foundation

@_cdecl("script_main")
public func scriptMain() -> Int32 {
    print("Hello from my script!")
    return 0  // exit code
}
```

### Importing Bridges

To control macOS apps, import the corresponding bridge:

```swift
import Foundation
import ScriptingBridge
import MusicBridge

@_cdecl("script_main")
public func scriptMain() -> Int32 {
    guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else { return 1 }
    // Use the Music scripting bridge...
    return 0
}
```

### Input / Output

Scripts receive input via the `AGENT_SCRIPT_ARGS` environment variable or JSON files:

- **Input**: `~/Documents/AgentScript/json/<ScriptName>_input.json`
- **Output**: `~/Documents/AgentScript/json/<ScriptName>_output.json`

### Output Directories

Scripts can write files to these organized folders under `~/Documents/AgentScript/`:

| Folder | Purpose |
|--------|---------|
| `json/` | JSON input/output |
| `photos/` | Captured photos |
| `images/` | Generated images |
| `screenshots/` | Screen captures |
| `html/` | HTML output |
| `applescript/` | Saved AppleScripts |
| `javascript/` | Saved JXA scripts |
| `logs/` | Log files |
| `recordings/` | Recordings |

## Included Scripts

| Script | Description |
|--------|-------------|
| Hello | Test script for verifying setup |
| SystemInfo | System information report |
| RunningApps | List running applications |
| NowPlaying | Current Music track info |
| CheckMail | Check Mail.app for new messages |
| ListNotes | List notes from Notes.app |
| ListReminders | List reminders from Reminders.app |
| TodayEvents | Today's Calendar events |
| SafariSearch | Perform a Safari search |
| SendMessage | Send an iMessage |
| CapturePhoto | Capture a photo from the camera |
| GenerateBridge | Generate a new scripting bridge from an app's SDEF |

## Managing Scripts

The Agent! app provides tools to create, update, delete, and run scripts:

- `create_agent_script` - Create a new script
- `update_agent_script` - Modify an existing script
- `delete_agent_script` - Remove a script
- `run_agent_script` - Compile and execute a script
- `list_agent_scripts` - List all available scripts

## License

MIT
