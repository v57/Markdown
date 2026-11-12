import Foundation

/// Made-up notes a reviewer, a tester or a first-time user can add from the welcome or the notes card's Add menu (Add
/// Sample Notes), so the editor can be tried with no notes of one's own and no account: a start note, a trip plan
/// with a table and tasks, a reading list, meeting notes and a small documentation folder with code and links. Plain
/// Markdown in one folder (`folderName`) of the notes folder, removed like any other folder. The screenshots
/// (`ScreenshotDemo`) show the same notes.
enum SampleNotes {
  /// The folder the notes go in, inside the notes folder.
  static let folderName = "Sample Notes"
  /// The note shown once they're added.
  static let firstNote = "Start Here.md"

  /// Writes the notes into `folder`, which is made here.
  static func write(into folder: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
    for (path, text) in files {
      let relative = path.hasPrefix("Notes/") ? String(path.dropFirst("Notes/".count)) : path
      let url = folder.appendingPathComponent(relative)
      try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }
  }

  /// Each note's path and text. The screenshots keep the paths (`Notes/…` and `Atlas Docs/…`); in the notes folder
  /// they all go into `folderName`, `Notes/` dropped.
  static let files: [(String, String)] = [
    (
      "Notes/Start Here.md",
      """
      # Start here

      These notes were added by **Add Sample Notes**, so there's something to read and edit right away. They're \
      ordinary Markdown files in the *Sample Notes* folder: change them, or delete the folder when you're done.

      ## Try

      - [ ] Click or tap into this note and type: the formatting stays live as you write
      - [ ] Tick a task in a list like this one
      - [ ] Open [Trip to Lisbon](Trip%20to%20Lisbon.md) for a table, a quote and a packing list
      - [ ] Open the [Atlas docs](Atlas%20Docs/README.md) for code and links between documents
      - [ ] Find a note by what it says with the search at the bottom of the sidebar (or Quick Open, ⌘K on a keyboard)

      ## Markdown at a glance

      - `**bold**` makes **bold**, `*italic*` makes *italic* and `~~struck~~` makes ~~struck~~
      - `# ` starts a heading, `- [ ] ` a task and `> ` a quote
      - `[a link](Ideas.md)` makes [a link](Ideas.md) to another note

      > New notes you make yourself are encrypted, unless you turn off *Encrypt new notes* on the welcome screen.
      """
    ),
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

      See also the [reading list](Reading%20list.md) for the books to bring.
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
