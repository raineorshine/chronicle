# Chronicle

Calendar Metrics Dashboard Specification

## Goal

Build a local calendar metrics pipeline using **EventKit** on macOS. The
system extracts time allocation from Apple Calendar, stores normalized
daily aggregates, and serves them to a native macOS dashboard.

This project has a deliberately narrow scope. It only tracks:

-   Hours spent
-   Event occurrence count
-   Hierarchical rollups by Calendar → Task → Subtask

Do **not** add additional metrics (productivity scores, free/busy time,
meeting overlap, fragmentation, etc.).

------------------------------------------------------------------------

# Architecture

``` text
iCloud Calendar
        ↓
macOS Calendar (automatic sync)
        ↓
EventKit
        ↓
Daily extraction job
        ↓
SQLite
        ↓
Native macOS dashboard (SwiftUI + Swift Charts)
```

The project is built as three Swift targets (see `project.yml`):

-   `ChronicleCore` — a static library holding title normalization/parsing,
    models, the SQLite layer, and aggregation queries.
-   `chronicle-extract` — a command-line tool, the only EventKit consumer, run
    once daily by a launchd agent.
-   `Chronicle` — a read-only SwiftUI viewer app.

The extractor is written in Swift using EventKit. It runs once
per day and rebuilds a rolling window of aggregates.

------------------------------------------------------------------------

# Hierarchy

Every event belongs to:

``` text
Calendar
└── Task
    └── Subtask (optional)
```

Examples:

``` text
Personal
└── Code Reviews
```

``` text
Work
└── em
    └── accounting
```

The EventKit calendar name determines the Calendar.

The event title determines Task and optional Subtask.

------------------------------------------------------------------------

# Event Parsing

Examples:

    ⚙️ Code Reviews (%2)

becomes

    Code Reviews

    em - accounting

becomes

    Task: em
    Subtask: accounting

## Normalization Rules

Apply in this order:

1.  Unicode normalize.
2.  Remove emoji.
3.  Remove parenthesized metadata (for example `(%2)`).
4.  Remove punctuation except the configured subtask separator.
5.  Collapse whitespace.
6.  Trim.
7.  Compare case-insensitively.
8.  Preserve canonical display labels separately.

> Note: parenthesized metadata is removed **before** generic punctuation.
> Stripping punctuation first would delete the parentheses and make the
> `(...)` metadata undetectable.

Treat `" - "` (space-hyphen-space) as the only subtask separator.

Do not split ordinary hyphenated words.

------------------------------------------------------------------------

# Event Processing

For every EventKit event:

1.  Only consider events from calendars the user has selected (the allowlist,
    chosen via the in-app **Calendars** picker and persisted to config).
2.  Ignore all-day events.
3.  Clip to the extraction window.
4.  Split events crossing midnight into one segment per local day.
5.  Normalize and parse the title.
6.  Add duration to the corresponding daily bucket.
7.  Count one occurrence per event occurrence (not per split segment).
    The single occurrence is attributed to the local day the event **starts**,
    so multi-day ranges never double-count it.

Recurring events should **not** be expanded manually.

Instead, query EventKit for the requested date range and count the
returned occurrences.

## Subtractive Calendars

Any calendar may be designated **subtractive**. A subtractive calendar
subtracts its time from any overlapping event in a non-subtractive calendar,
while its own events are always counted in full — regardless of whether they
overlap another calendar.

Examples:

    Calendar A:               12–5pm  Swim
    Calendar B (subtractive):  2–5pm  Instagram
    ⇒ Swim = 2h (12–2),  Instagram = 3h

    Calendar A:               12–5pm  Swim
    Calendar B (subtractive):  4–7pm  Instagram
    ⇒ Swim = 4h (12–4),  Instagram = 3h (counted in full)

Rules:

-   Subtraction is applied at the interval level, before splitting across
    midnight and bucketing into days. Only `duration_seconds` is affected;
    occurrence counts are unchanged (one occurrence on the event's start day).
-   A subtractive calendar subtracts from **all** non-subtractive calendars.
-   Subtractive calendars do **not** subtract from one another.
-   A subtractive calendar is always extracted so it can subtract and so its own
    time is counted, even when not listed in `calendarAllowlist`.

------------------------------------------------------------------------

# Storage

Use SQLite.

## Daily Aggregate Table

``` sql
CREATE TABLE daily_time (
    date TEXT NOT NULL,

    calendar_key TEXT NOT NULL,
    calendar_label TEXT NOT NULL,
    calendar_color TEXT,

    task_key TEXT NOT NULL,
    task_label TEXT NOT NULL,

    subtask_key TEXT,
    subtask_label TEXT,

    duration_seconds INTEGER NOT NULL,
    occurrence_count INTEGER NOT NULL,

    PRIMARY KEY (
        date,
        calendar_key,
        task_key,
        subtask_key
    )
);
```

One row represents one local day and one hierarchy path.

Example:

  Date         Calendar   Task           Subtask        Hours   Count
  ------------ ---------- -------------- ------------ ------- -------
  2026-07-07   Personal   Code Reviews                    4.5       3
  2026-07-07   Work       em             accounting      1.25       1

------------------------------------------------------------------------

# Aggregation

The daily table is the only source of truth.

Week, month, and year views should be generated by SQL aggregation.

Do not store separate weekly/monthly/yearly tables.

------------------------------------------------------------------------

# Hierarchical Rollups

Selecting a parent includes all descendants.

Example:

``` text
Work / em
```

includes

``` text
Work / em
Work / em / accounting
Work / em / design
...
```

Events named simply

    em

have no subtask.

Events named

    em - accounting

contribute to:

-   em
-   em → accounting

------------------------------------------------------------------------

# Queries

Support aggregation by:

-   Calendar
-   Calendar + Task
-   Calendar + Task + Subtask

Support time ranges:

-   Week
-   Month
-   Year
-   Custom

The graph always plots daily hours. Bars are colored to match each source
calendar's color (persisted as `calendar_color`). A single-calendar (or
task/subtask) selection renders bars in that calendar's color; **All Calendars**
stacks each day into per-calendar segments, each in its own color, with a
legend.

The selected range displays total hours and occurrence count.

------------------------------------------------------------------------

# Synchronization

Run once daily.

Rather than incremental synchronization, rebuild a rolling window:

-   Previous 60 days
-   Current day
-   Next 14 days (planned work)

Delete and regenerate aggregates for this window.

This automatically handles edited, moved, deleted, and detached
recurring events.

------------------------------------------------------------------------

# Configuration & Data Locations

Configuration is a JSON file created on first run:

`~/Library/Application Support/Chronicle/config.json`

-   `calendarAllowlist` — calendar names to include (case-insensitive). Normally
    managed from the app's **Calendars** toolbar picker (checkboxes with the
    calendar's color); the app reads and writes this field. Hand-editing is
    optional.
-   `subtaskSeparator` — defaults to `" - "`.
-   `subtractiveCalendars` — calendar names (case-insensitive) treated as
    subtractive (see **Subtractive Calendars**). Managed from the same picker
    via a per-calendar minus toggle. Marking a calendar subtractive also
    includes it.
-   `windowPastDays` / `windowFutureDays` — the rolling window (default 60 / 14).

The SQLite database lives at
`~/Library/Application Support/Chronicle/chronicle.db`.

------------------------------------------------------------------------

# Out of Scope

Do **not** implement:

-   Productivity scores
-   Focus scores
-   Meeting analysis
-   Free/busy calculations
-   Fragmentation metrics
-   Time estimation
-   AI categorization
-   Automatic renaming
-   Tag inference
-   Additional analytics

The dashboard is intentionally limited to time allocation by Calendar →
Task → Subtask.
