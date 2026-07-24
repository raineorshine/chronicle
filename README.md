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
  "subtaskSeparators": [" - ", " | "],
  "subtractiveCalendars": ["Instagram"],
  "aliasChains": [["VP of Engineering", "em - Code Reviews"]],
  "windowPastDays": 60,
  "windowFutureDays": 14,
  "weeklyMetricsCutoff": 6
}
```

- **calendarAllowlist** — only these calendar names are extracted (matched
  case-insensitively). Managed via the in-app **Calendars** picker; an empty
  list extracts nothing.
- **subtaskSeparators** — substrings treated as Task/Subtask dividers; a title
  is split on the leftmost occurrence of any of them (default `[" - ", " | "]`).
- **subtractiveCalendars** — calendar names (case-insensitive) treated as
  *subtractive*: their time is subtracted from overlapping events in other
  calendars, while their own time is still counted in full (see below). A
  subtractive calendar is always extracted, even if not in the allowlist.
- **aliasChains** — rename chains that merge titles referring to the same task
  (see [Aliases](#aliases-renamed-tasks)). Managed via the in-app **Aliases**
  picker.
- **windowPastDays / windowFutureDays** — the rolling window that is rebuilt on
  every run (previous 60 days, today, next 14 days by default).
- **weeklyMetricsCutoff** — the weekday (1 = Sunday … 7 = Saturday) when the
  sidebar and legend hour tallies roll over to the current week. Before it, the
  tallies show the whole previous week (Mon–Sun); on or after it, they show the
  current week (Mon–today). Defaults to `6` (Friday), so Mon–Thu show last week
  and Fri–Sun show this week.

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

## Aliases (renamed tasks)

When you rename a task in your calendar, its old and new titles would otherwise
count as two separate activities. **Aliases** link them so they roll up as one
task for every metric — hours, occurrences, the sidebar, the chart, and
drill-downs.

Open the **Aliases** button in the toolbar and add an `old title → new title`
pair. Renames form a **chain over time**: if the old title you enter matches the
newest title of an existing chain, the new title extends that chain, so a task
renamed repeatedly still collapses to its latest name. For example:

```text
VP of Engineering  →  em - Code Reviews  →  em - Engineering Lead
```

all count as `em - Engineering Lead` (which shows up under the `em` activity and
its `Engineering Lead` subtask).

Notes:

- Aliases are applied **at read time**, so they take effect immediately on
  already-extracted data — no re-extraction or Calendar access needed.
- Matching is by **exact title**: an alias from a bare task (`VP of
  Engineering`, no subtask) only remaps events with that exact title. Subtasked
  variants like `VP of Engineering - accounting` need their own alias.
- Titles merge across **all dates** and across calendars.

## Granting Calendar access

EventKit requires permission. The **first time** the app touches your calendar
(via the Calendars picker or Refresh), macOS shows a prompt — click **Allow**.
You can review it later under **System Settings → Privacy & Security →
Calendars**.

The standalone extractor binary run from a plain terminal may not be able to
show the prompt; grant access from the app first, or run it via the installed
LaunchAgent.

### Why the grant used to get stuck (and how it's fixed)

Two separate problems both broke Calendar access:

1. **Missing entitlement (why no prompt appeared).** The app runs with the
   **hardened runtime**, and under hardened runtime macOS refuses to even show
   the Calendar prompt unless the binary carries the
   `com.apple.security.personal-information.calendars` entitlement. Without it,
   `tccd` logs *"Policy disallows prompt … access to kTCCServiceCalendar
   denied"*, nothing shows in System Settings, and the button does nothing.
   `App/Chronicle.entitlements` and `Extractor/Extractor.entitlements` now
   declare that entitlement.

2. **Unstable signature (why a granted permission broke on the next build).**
   Without an Apple Developer account, Xcode signs the app **ad-hoc**, whose
   code hash changes on every build. macOS ties the grant to that hash, so after
   a rebuild the running app no longer matched and could not re-prompt.
   `scripts/install-app.sh` and `scripts/install-agent.sh` now sign with a
   **stable, self-signed certificate** (`Chronicle Local Signing`, created
   automatically by `scripts/create-signing-cert.sh`). Its Designated
   Requirement is pinned to the certificate rather than the build hash, so the
   permission you grant **persists across rebuilds**. When switching away from an
   old ad-hoc build, the installer runs `tccutil reset Calendar` once to clear
   the poisoned grant so the prompt appears again.

If you ever get stuck, reset the grant manually and relaunch:

```sh
tccutil reset Calendar com.chronicle.app
tccutil reset Calendar com.chronicle.extract
```


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
and each bar is split into colored segments. At the top level, **each visible
calendar** is configured (in the Calendars picker) as one of two segment modes:
**by task** (the default) breaks the calendar out into its individual activities,
merged across calendars, so nothing meaningful hides in an aggregate; **whole
calendar** folds all of that calendar's events into a single segment, colored
with the calendar's own color. Task segments come first, ordered alphabetically
for week-to-week visual continuity, followed by the whole-calendar segments. A
legend names each segment and hovering a week shows a tooltip with its per-segment
hours and total. The current (in-progress) week is drawn dimmed and marked with a
dot.

The header shows **this week's hours** with a colored **▲/▼ delta versus last
week**, plus the window's occurrence count. The **sidebar** on the left is a flat
list of **activities** (Tasks) merged across all calendars — every activity in
the selected window is listed, but each row shows its **current-week** hours
(`0.0h` if idle this week) and the list is **sorted by those current-week hours**,
each expandable to its subtasks.
Segments **adapt to scope**: at the top level they are task segments plus any
whole-calendar segments; click a legend entry — or a task in the sidebar — to
drill into an activity and re-stack it by its **subtasks** (this subtask view
keeps the top activities plus a neutral **Other** bucket). Whole-calendar
segments are not drillable. The back chevron in the header moves the scope up a
level. **Refresh** re-extracts from your selected calendars (in-process) and
reloads.

**⌘→ / ⌘←** step the selection down and up the sidebar exactly as it is drawn:
**All Tasks**, each activity, and the subtasks of any activity whose disclosure
triangle is open — collapsed subtasks are skipped. Selecting a subtask another
way (say from Search) opens its activity, so it joins the walk.

The **Search** button in the toolbar (or ⌘F) finds an activity by name without
scrolling the sidebar. It opens on the week's busiest activities; type any part of
a name and the suggestions filter live, covering both activities and their
subtasks (shown as `Task / Subtask`, and also matchable together — `em code` finds
`em / Code Reviews`). ↑/↓ move through the suggestions and **Enter** opens the
highlighted one, landing on exactly the scope its sidebar row would. Only
activities in the selected window are searchable.

## Trying it without Calendar access (demo data)

To see the dashboard populated before wiring up real calendars, seed synthetic
data:

```bash
# build once, then run the binary with --demo
xcodebuild build -scheme chronicle-extract -destination 'platform=macOS'
# ask xcodebuild where it put the binary (correct even with many worktrees /
# DerivedData dirs — don't glob DerivedData and take the first match, it's usually stale)
PRODUCTS_DIR=$(xcodebuild -showBuildSettings -scheme chronicle-extract -destination 'platform=macOS' 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
"$PRODUCTS_DIR/chronicle-extract" --demo
```

This writes ~two weeks of plausible events (including a midnight-crossing one)
into the rolling window. Because it targets the same window a real run rebuilds,
the demo rows are automatically replaced the first time you extract real data.

## How it works

- **Parsing.** Titles are split on `" - "` or `" | "` into Task/Subtask, then each part is
  NFC-normalized, with parenthesized metadata and bare `%n` tokens (e.g. `%2`) removed,
  whitespace-collapsed, and trimmed. Punctuation and emoji are preserved in the display
  **label**; the grouping **key** lowercases the label with emoji and punctuation removed.
- **Aggregation.** All-day events are skipped; events are clipped to the window
  and split across local midnight into per-day duration segments. One occurrence
  is counted on the day the event starts. Time from **subtractive** calendars is
  removed from overlapping events in other calendars before bucketing, while the
  subtractive events themselves are counted in full.
- **Rolling rebuild.** Each run deletes and regenerates the window's rows in a
  single transaction, so edited/moved/deleted/detached recurring events are
  handled automatically.
- **Views.** The dashboard shows a trailing window of **N weeks** (4/8/12). A
  per-day series is read from the single `daily_time` table with SQL aggregation,
  then bucketed into weeks in Swift (weeks start on **Monday**). At the top level,
  task-mode calendars become individual activity segments while whole-calendar-mode
  calendars fold into one segment each; drilling into an activity re-stacks it by
  subtask (top subtasks plus an **Other** bucket).

## Tests

```bash
xcodebuild test -scheme ChronicleCore -destination 'platform=macOS'
```

Covers normalization/parsing, event aggregation (midnight splits, clipping,
occurrence counting), and the SQLite storage + rollup queries.
