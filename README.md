# Chronicle

A local calendar metrics dashboard for macOS. Chronicle extracts time
allocation from Apple Calendar using **EventKit**, stores normalized daily
aggregates in SQLite, and displays them in a native SwiftUI app.

Scope is intentionally narrow — it tracks only:

- Hours spent
- Event occurrence count
- Hierarchical rollups by **Calendar → Task → Subtask**

See [`spec.md`](spec.md) for the full specification.

## Architecture

```text
iCloud Calendar → macOS Calendar → EventKit
        ↓
chronicle-extract (daily job, rebuilds a rolling window)
        ↓
SQLite  (~/Library/Application Support/Chronicle/chronicle.db)
        ↓
Chronicle.app (SwiftUI + Swift Charts viewer)
```

Three targets, defined in [`project.yml`](project.yml):

| Target             | Kind              | Role                                                        |
| ------------------ | ----------------- | ---------------------------------------------------------- |
| `ChronicleCore`    | static library    | Title normalization/parsing, models, SQLite layer, queries |
| `chronicle-extract`| command-line tool  | The only EventKit consumer; rebuilds the rolling window     |
| `Chronicle`        | SwiftUI app       | Read-only viewer with charts, filters, and a Refresh button |

## Requirements

- macOS 14+
- Xcode 16+ (uses Swift Charts, EventKit full-access API)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Building

The `.xcodeproj` is generated from `project.yml` and is git-ignored:

```bash
xcodegen generate
open Chronicle.xcodeproj
```

Or from the command line:

```bash
xcodegen generate
xcodebuild build -scheme Chronicle       -destination 'platform=macOS'
xcodebuild build -scheme chronicle-extract -destination 'platform=macOS'
xcodebuild test  -scheme ChronicleCore   -destination 'platform=macOS'
```

## Installing the app

Chronicle ships two install scripts, one per half of the system:

| Script                     | Builds                | Installs to                                   | Runs via              | Job                              |
| -------------------------- | --------------------- | --------------------------------------------- | --------------------- | -------------------------------- |
| `scripts/install-app.sh`   | `Chronicle` (GUI app) | `/Applications`                               | you open it manually  | **reads** & visualizes the DB    |
| `scripts/install-agent.sh` | `chronicle-extract` (CLI) | `~/Library/Application Support/Chronicle/bin` | `launchd` daily/at-login | **writes** metrics into the DB |

They're complementary: the agent gathers calendar data on a schedule, and the
app is what you open to look at it. See
[Daily extraction (LaunchAgent)](#daily-extraction-launchagent) for the agent.

To build a Release build and install **Chronicle.app** into `/Applications` (so
it appears in Spotlight and Launchpad), run:

```bash
./scripts/install-app.sh          # build + install
./scripts/install-app.sh --open   # build + install, then launch it
```

Re-run it any time to update the installed app after code changes. It builds
into the git-ignored `.build-xcode/` directory, so it won't clash with Xcode's
own DerivedData.

## Choosing calendars

Open **Chronicle.app** and click the **Calendars** button in the toolbar. The
first time, macOS prompts for calendar access — click **Allow**. You then get a
checklist of all your calendars (with their colors); tick the ones you want
included. Each row also has a minus-circle button to mark that calendar
**subtractive** (see [Subtractive calendars](#subtractive-calendars)).
Selections are saved and the dashboard re-extracts immediately.

## Configuration

Your choices are stored in a config file (you normally don't edit this by hand):

`~/Library/Application Support/Chronicle/config.json`

```json
{
  "calendarAllowlist": ["Work", "Personal"],
  "subtaskSeparator": " - ",
  "subtractiveCalendars": ["Instagram"],
  "windowPastDays": 60,
  "windowFutureDays": 14
}
```

- **calendarAllowlist** — only these calendar names are extracted (matched
  case-insensitively). Managed via the in-app **Calendars** picker; an empty
  list extracts nothing.
- **subtaskSeparator** — the only substring treated as a Task/Subtask divider.
- **subtractiveCalendars** — calendar names (case-insensitive) treated as
  *subtractive*: their time is subtracted from overlapping events in other
  calendars, while their own time is still counted in full (see below). A
  subtractive calendar is always extracted, even if not in the allowlist.
- **windowPastDays / windowFutureDays** — the rolling window that is rebuilt on
  every run (previous 60 days, today, next 14 days by default).

## Subtractive calendars

Any calendar can be marked **subtractive**. A subtractive calendar subtracts its
time from any overlapping event in a non-subtractive calendar, while its own
events are always counted in full — regardless of whether they overlap anything.

For example, with a subtractive **Instagram** calendar:

| Calendar A (Swim) | Instagram (subtractive) | Swim counts | Instagram counts |
| ----------------- | ----------------------- | ----------- | ---------------- |
| 12–5pm            | 2–5pm                   | 2h (12–2)   | 3h               |
| 12–5pm            | 4–7pm                   | 4h (12–4)   | 3h               |

To mark a calendar subtractive, open the **Calendars** picker and click the
minus-circle icon next to it. Marking a calendar subtractive also includes it,
since its own time is still counted. Subtractive calendars do not subtract from
each other.

## Granting Calendar access

EventKit requires permission. The **first time** the app touches your calendar
(via the Calendars picker or Refresh), macOS shows a prompt — click **Allow**.
You can review it later under **System Settings → Privacy & Security →
Calendars**.

The standalone extractor binary run from a plain terminal may not be able to
show the prompt; grant access from the app first, or run it via the installed
LaunchAgent.

## Daily extraction (LaunchAgent)

Install a LaunchAgent that runs the extractor daily at 02:00 (and once at login):

```bash
./scripts/install-agent.sh
```

This builds a Release binary, copies it to
`~/Library/Application Support/Chronicle/bin/`, installs
`~/Library/LaunchAgents/com.chronicle.extract.plist`, and loads it.
Logs are written to `~/Library/Application Support/Chronicle/logs/extract.log`.

To remove it:

```bash
launchctl bootout "gui/$(id -u)/com.chronicle.extract"
rm ~/Library/LaunchAgents/com.chronicle.extract.plist
```

## Using the dashboard

Launch **Chronicle.app**. The main view is a **weeks-on-X stacked bar chart**:
each bar is one week over a trailing window (**4 / 8 / 12 weeks**, selectable),
and each bar is split into colored segments — one per **activity** (Task) — so
you can read the current week's mix, compare it against previous weeks, and see
trends at a glance. The heaviest activities dominate each bar, so ranking is
implicit; the long tail folds into a neutral **Other** segment. A legend names
each segment and hovering a week shows a tooltip with its per-activity hours and
total. The current (in-progress) week is drawn dimmed and marked with a dot.

The header shows **this week's hours** with a colored **▲/▼ delta versus last
week**, plus the window's occurrence count. The **sidebar** on the left is a flat
list of **activities** (Tasks) merged across all calendars and **sorted by hours**
over the current window, each showing its total and expandable to its subtasks.
Segments **adapt to scope**: at the top level they are activities; click a legend
entry — or a task in the sidebar — to drill into an activity and re-stack it by
its **subtasks**. The back chevron in the header moves the scope up a level.
**Refresh** re-extracts from your selected calendars (in-process) and reloads.

## Trying it without Calendar access (demo data)

To see the dashboard populated before wiring up real calendars, seed synthetic
data:

```bash
# build once, then run the binary with --demo
xcodebuild build -scheme chronicle-extract -destination 'platform=macOS'
"$(find ~/Library/Developer/Xcode/DerivedData/Chronicle-*/Build/Products/Debug -name chronicle-extract | head -1)" --demo
```

This writes ~two weeks of plausible events (including a midnight-crossing one)
into the rolling window. Because it targets the same window a real run rebuilds,
the demo rows are automatically replaced the first time you extract real data.

## How it works

- **Parsing.** Titles are split on `" - "` into Task/Subtask, then each part is
  NFC-normalized, stripped of emoji, parenthesized metadata, and punctuation,
  whitespace-collapsed, and trimmed. A lowercased **key** is used for grouping;
  the cleaned original casing is kept as the **label**.
- **Aggregation.** All-day events are skipped; events are clipped to the window
  and split across local midnight into per-day duration segments. One occurrence
  is counted on the day the event starts. Time from **subtractive** calendars is
  removed from overlapping events in other calendars before bucketing, while the
  subtractive events themselves are counted in full.
- **Rolling rebuild.** Each run deletes and regenerates the window's rows in a
  single transaction, so edited/moved/deleted/detached recurring events are
  handled automatically.
- **Views.** The dashboard shows a trailing window of **N weeks** (4/8/12). A
  per-day, per-segment series is read from the single `daily_time` table with SQL
  aggregation, then bucketed into weeks in Swift (weeks start on **Monday**)
  and reduced to the top activities plus an **Other** bucket.

## Tests

```bash
xcodebuild test -scheme ChronicleCore -destination 'platform=macOS'
```

Covers normalization/parsing, event aggregation (midnight splits, clipping,
occurrence counting), and the SQLite storage + rollup queries.
