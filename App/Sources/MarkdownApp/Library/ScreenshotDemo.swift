import DevScreenshots
import Foundation
import VaultKit
#if os(Windows)
  import WinSDK
#endif

/// Debug builds: `--screenshot-demo` runs the app on made-up notes for the screenshots (`.dev/screenshots.json`),
/// never the user's. A debug build shares the installed app's container, defaults and vault, so in this mode the
/// sidebar store is in memory, preferences use their own defaults, the vault is a fresh one of the demo's own (secrets
/// and keys in memory, never the keychain) that doesn't sync, GitHub repositories stay hidden and the shared projects
/// are the demo's. The notes are written into the app's temporary folder, which the
/// sandbox lets it read on the Mac and on iOS.
///
///   --screenshot-demo        the demo notes and projects ("Atlas Docs" open in the sidebar)
///   --open <path>            shows a note, relative to the demo folder (`Notes/Trip to Lisbon.md`)
///   --quick-open             opens Quick Open
///   --welcome                the welcome (no note open)
///   --open-sheet <name>      over the note: `github` (Connect GitHub), `rename` or `delete` (the kit's overlays)
///   --settings               opens the Settings window too (Mac)
///   --add-folder <folder>    the shared projects are the folder's repositories instead, in groups as Git adds them
///                            (repeatable); picking one opens it without asking for the folder
///   --asks-for-folders       picking a project goes through the open panel as outside the demo (remembered access)
///   --keeps-defaults         the demo's defaults last until the next launch (remembered access across launches)
///
/// `dev-screenshots` takes every scene in one launch: the window opens each next scene's arguments in place.
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  /// Quick Open's field takes focus, except in the demo on iOS: the simulator's software keyboard would cover half the
  /// picture.
  static var focusesFields: Bool {
    #if os(iOS)
      !isOn
    #else
      true
    #endif
  }

  /// The shown scene's arguments: the launch's, then each later scene's.
  static var arguments = CommandLine.arguments

  /// Opens a later scene's arguments in the window and returns once it has loaded (`ContentView`).
  static var openScene: ((_ arguments: [String]) async -> Void)?

  /// At launch, before any window: the capture's appearance and window, and in the demo every scene in this launch.
  /// The window calls `Screenshots.ready()` once the first scene has loaded.
  static func prepareCapture() {
    if isOn {
      Screenshots.prepare(waitsForReady: true) { scene in await openScene?(scene.arguments) }
    } else {
      Screenshots.prepare(waitsForReady: true)
    }
  }

  /// Before anything opens the vault: a fresh store of the demo's own (with the `--add-folder` projects), and secrets
  /// and keys in memory, so the demo never touches the user's vault or keychain.
  @MainActor static func prepareVault() {
    VaultSecrets.useInMemoryStore()
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotDemoVault", isDirectory: true)
    try? FileManager.default.removeItem(at: vault)
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    #if os(Windows)
      _ = "VAULT_DIRECTORY".withCString(encodedAs: UTF16.self) { name in
        vault.path.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
      }
    #else
      setenv("VAULT_DIRECTORY", vault.path, 1)
    #endif
    guard let store = Vault.shared.store else { return }
    for folder in addedFolders {
      let root = URL(fileURLWithPath: folder, isDirectory: true)
      let found = VaultProjectDiscovery.scan(root)
      // A folder the sandbox hides from the scan is a project itself (`--asks-for-folders`).
      if found.repositories.isEmpty { _ = try? store.addProject(path: root.path) }
      for repository in found.repositories { _ = try? store.addProject(path: repository.path) }
      try? store.arrangeProjects(found.repositories.map(\.path), roots: [root.path])
    }
  }

  /// `--add-folder`'s folders: the shared projects come from the demo's vault instead of `projectTree`.
  static var addedFolders: [String] {
    zip(CommandLine.arguments, CommandLine.arguments.dropFirst()).filter { $0.0 == "--add-folder" }.map(\.1)
  }

  static func value(_ option: String) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ option: String) -> Bool { isOn && arguments.contains(option) }

  static let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotDemo", isDirectory: true)
  static var notes: URL { root.appendingPathComponent("Notes", isDirectory: true) }
  static var docs: URL { root.appendingPathComponent("Atlas Docs", isDirectory: true) }

  /// The demo's shared projects, in place of the vault's: Atlas Docs (open in the sidebar) and two the app hasn't
  /// opened, in a group and outside one.
  static let projectTree = VaultProjectTree(
    projects: [
      VaultProject(id: "atlas-docs", name: "Atlas Docs", groupID: "work", order: 0, addedBy: nil, added: nil),
      VaultProject(id: "website", name: "Website", groupID: "work", order: 1, addedBy: nil, added: nil),
      VaultProject(id: "recipes", name: "Recipes", order: 2, addedBy: nil, added: nil),
    ],
    groups: [VaultProjectGroup(id: "work", name: "Work")])

  /// Where the demo's projects are (the ones the app hasn't opened don't exist).
  static var projectFolders: [String: URL] {
    [
      "atlas-docs": docs, "website": root.appendingPathComponent("Website", isDirectory: true),
      "recipes": root.appendingPathComponent("Recipes", isDirectory: true),
    ]
  }

  /// The windows' settings (`KitStorage`'s store, which doesn't read `defaultAppStorage`): the demo's own while it runs.
  static var settings: UserDefaults { isOn ? defaults : .standard }

  /// Pins and recents of the demo, apart from the user's.
  static let defaults: UserDefaults = {
    let name = "dev.v57.md.screenshot-demo"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    if !CommandLine.arguments.contains("--keeps-defaults") { defaults.removePersistentDomain(forName: name) }
    return defaults
  }()

  /// Writes the demo afresh; called once, before anything reads it.
  static func write() {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: root)
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? text.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private static let files: [(String, String)] = [
    (
      "Notes/Trip to Lisbon.md",
      """
      # Trip to Lisbon

      Four days in **October**, flying in on Thursday morning. The plan is loose on purpose: one thing a day, \
      the rest is walking.

      ## Days

      | Day | Morning | Evening |
      |-----|---------|---------|
      | Thu | Alfama and the castle | Fado in Mouraria |
      | Fri | Tram 28 to Estrela | Dinner at Cais do Sodré |
      | Sat | Sintra by train | Sunset at Miradouro da Graça |
      | Sun | LX Factory market | Fly home |

      ## Packing

      - [x] Passport and tickets
      - [x] Walking shoes
      - [ ] Rain jacket, *just in case*
      - [ ] Adapter for the camera charger

      > The hills are steep. Take the tram up and walk down.

      See also [[Reading list]] for the books to bring.
      """
    ),
    (
      "Notes/Reading list.md",
      """
      # Reading list

      1. *The Book of Disquiet* — Fernando Pessoa
      2. *Blindness* — José Saramago
      3. *Journey to Portugal* — José Saramago

      Finished this year: **7** of 12.
      """
    ),
    (
      "Notes/Ideas.md",
      """
      # Ideas

      - A weekly note that collects the links I saved
      - Plant watering reminders by room
      - ~~Rewrite the blog in a static generator~~ done in March
      """
    ),
    (
      "Notes/Meetings/Design review.md",
      """
      # Design review — Atlas 2.0

      **Attendees:** Maya, Jonas, Aiko

      ## Decisions

      - The trip list becomes the first screen.
      - Offline maps ship in 2.1, not 2.0.

      ## Follow-ups

      - [ ] Jonas: measure the map cache on older iPhones
      - [ ] Aiko: new empty state for a trip without stops
      """
    ),
    (
      "Atlas Docs/README.md",
      """
      # Atlas

      Atlas plans trips: stops, bookings and the days between them, synced across your devices.

      ## Getting started

      ```swift
      let store = TripStore(folder: .documentsDirectory)
      let trip = try await store.create(named: "Lisbon", from: .now, days: 4)
      trip.add(Stop(name: "Alfama", on: trip.days[0]))
      ```

      ## Modules

      | Module | What it does |
      |--------|--------------|
      | `AtlasCore` | Trips, stops and bookings |
      | `AtlasSync` | Sync through iCloud |
      | `AtlasMaps` | Offline map tiles |

      Read [Getting started](Guides/Getting%20started.md) next, or the [changelog](CHANGELOG.md).
      """
    ),
    (
      "Atlas Docs/Guides/Getting started.md",
      """
      # Getting started

      1. Add the package to your project.
      2. Create a `TripStore` in your app's model.
      3. Show the trips with `TripList`.

      > **Note:** `AtlasSync` needs the iCloud capability.
      """
    ),
    (
      "Atlas Docs/CHANGELOG.md",
      """
      # Changelog

      ## 2.0

      - Trips start on the first screen
      - Faster sync for large trips

      ## 1.4

      - Bookings show their confirmation number
      """
    ),
  ]
}
