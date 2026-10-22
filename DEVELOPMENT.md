# Cursor Replay CLI developer guide

This guide is for maintaining and extending the application. Start with the
[overview](README.md); installation, permissions, and everyday controls are in
the [usage guide](docs/USAGE.md).

## Project map

The project uses Swift Package Manager and Swift 6 concurrency checking. It
declares macOS 15 as its minimum platform and has no external package dependencies.
The display name is **Cursor Replay CLI**, the repository name is
**cursor-replay-cli**, and the package name is `CursorReplayCLI`. Executable
products are `cursor-replay` and `cursor-replay-probe`. Internal Swift targets,
module names, and source paths remain `MouseRecorderCore` and `MouseRecorderCLI`;
the product rename is not a core API or recording-format migration.

| File | Responsibility |
| --- | --- |
| `Package.swift` | Core target, CLI and probe products, and core/CLI Swift Testing targets |
| `README.md` / `docs/USAGE.md` | Product overview and detailed installation/usage guide |
| `Sources/MouseRecorderCLI/MouseRecorderCLI.swift` | Argument parsing, command dispatch, signal handling, countdowns, file checks, and reports |
| `Sources/MouseRecorderCLI/TerminalInterface.swift` | Terminal input settings, single-key menu, action controls, and last-file selection |
| `Sources/MouseRecorderCLI/TerminalScreen.swift` | Compact alternate-screen rendering, presentation thread, capability fallbacks, and output restoration |
| `Sources/MouseRecorderCLI/AppIdentity.swift` | Public display/command names, release version, and menu data-directory resolution |
| `Sources/MouseRecorderCore/Recording.swift` | Codable model, event reconstruction, display layout, validation, atomic JSON I/O, and legacy conversion |
| `Sources/MouseRecorderCore/Recorder.swift` | Listen-only HID event tap, dedicated run loop, callback state, observations, and capture boundaries |
| `Sources/MouseRecorderCore/Playback.swift` | Absolute scheduling, event submission, loops, held-input tracking, and cleanup |
| `Sources/MouseRecorderCore/Runtime.swift` | Locked cancellation, permission checks, mach clock conversion, deadline waits, and countdown helper |
| `Sources/MouseRecorderCore/Verification.swift` | Event-tag matching, field comparisons, delta sums, statistics, and strict pass/fail rules |
| `Sources/CGEventProbe/main.swift` | Compiled diagnostic that posts and observes one tagged move at the current cursor position |
| `Tests/MouseRecorderCoreTests/RecordingTests.swift` | Model, serialization, reconstruction, clock-unit regression, and session-boundary validation |
| `Tests/MouseRecorderCoreTests/TimingAndCleanupTests.swift` | Clock/scaling, cleanup-event construction, scheduling, looping, and cancellation |
| `Tests/MouseRecorderCoreTests/VerificationTests.swift` | Matching, missing/reordered data, flags, errors, and failure conditions |
| `Tests/MouseRecorderCoreTests/TimelineHarnessTests.swift` | Optional real-file scheduler check with system posting disabled |
| `Tests/MouseRecorderCLITests/TerminalScreenTests.swift` | Rendering, progress, clipping, terminal-text sanitization, error visibility, and color policy |
| `Tests/MouseRecorderCLITests/AppIdentityTests.swift` | Default storage identity and data-directory override validation |
| `scripts/build.sh` | Release build with an external scratch cache; copies the CLI to `bin/cursor-replay` |
| `scripts/install.sh` | Builds and installs `~/.local/bin/cursor-replay` without editing `PATH` |
| `scripts/test.sh` | External-cache Swift Testing runner, including bundled macro-plugin workaround |
| `Formula/cursor-replay.rb` | Homebrew tap formula; HEAD-only until the first stable release |
| `scripts/prepare-release.rb` | Allowlisted, reproducible committed-source archive, checksum, and stable formula generator |
| `scripts/test-release.rb` | Release archive, checksum, version/tag, and formula-update regression tests |
| `scripts/test-homebrew.sh` | Temporary local tap installation/test with cleanup |
| `.github/workflows/ci.yml` | macOS 15 Apple Silicon/Intel tests, release build, and Homebrew installation checks |
| `.github/workflows/release.yml` | Stable-tag release publication and same-repository formula update |

The core does not know about menu key letters or terminal rendering. The CLI
uses the same core recorder/player for direct commands, menu actions, and
verification. There is no AppKit application lifecycle or main-window event loop.

## Build and development cycle

```sh
./scripts/build.sh
./scripts/test.sh
./bin/cursor-replay --help
./bin/cursor-replay doctor
```

Build and test scripts share a SwiftPM scratch directory at
`~/Library/Caches/cursor-replay-cli/swiftpm`, overridden by
`CURSOR_REPLAY_BUILD_DIR`. `scripts/build.sh` copies the runnable release product
to `./bin/cursor-replay`, which is ignored by Git. Avoid bare `swift build` or
`swift test` in the source tree, since they create a local `.build/`.

For a debug build, retain the same external-cache convention:

```sh
build_dir="${CURSOR_REPLAY_BUILD_DIR:-$HOME/Library/Caches/cursor-replay-cli/swiftpm}"
swift build --scratch-path "$build_dir" --product cursor-replay
debug_bin="$(swift build --scratch-path "$build_dir" --show-bin-path)"
"$debug_bin/cursor-replay" --help
```

Use release builds for realistic timing measurements. The wrapper deliberately
preserves a runnable `bin/cursor-replay` separately from SwiftPM output. Before
removing an old in-tree `.build` cache, preserve and check the replacement
executable first; never remove a cache that contains the only working copy.
The clean source folder should contain no build cache, recordings, or private
JSON. Keep generated `bin/` output out of source archives and version control.

To refresh an optional installed copy, quit running instances and use
`./scripts/install.sh`. It builds and installs to `~/.local/bin/cursor-replay`
without changing `PATH`. Do not mix an old installed executable with new source
when diagnosing permissions or behavior. Record the executable path and build
configuration with performance observations. Source and cache folders should
be outside cloud sync: generated signing files such as `.xcent.der` may be
blocked by extension-based sync policies.

### Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) handles pushes to `main`,
pull requests, manual dispatch, and calls from the release workflow. Its
`macos-15` (Apple Silicon) and `macos-15-intel` jobs use read-only repository
contents permissions. Each runs release-tooling tests, Swift tests, a release
build, help/version smoke checks, and a real source-based Homebrew install/test.
The Homebrew test uses a temporary local tap and uninstalls it on exit; it
refuses to replace an existing Homebrew installation of `cursor-replay`.

The checks archive the checked-out commit, not the potentially dirty worktree.
Homebrew receives that archive through a local `file://` URL with the same
SHA-256 as the release formula. This exercises the formula without depending
on an already published tag or release URL.

The workflows become active when committed and pushed with authorization to
update workflow files. Do not describe the project as passing remote CI or add
a passing status badge before a successful run is verified. No check requests
Accessibility/Input Monitoring or posts system input. The optional private-file
timeline harness is not enabled.

### Diagnostic probe

```sh
build_dir="${CURSOR_REPLAY_BUILD_DIR:-$HOME/Library/Caches/cursor-replay-cli/swiftpm}"
swift build --scratch-path "$build_dir" --product cursor-replay-probe
probe_bin="$(swift build --scratch-path "$build_dir" --show-bin-path)"
"$probe_bin/cursor-replay-probe"
```

The probe checks permissions, creates optional CoreGraphics objects with guards,
posts exactly one tagged `mouseMoved` event at the current cursor location, and
waits up to two seconds to observe its tag and exact location at a HID tap.
It does not test a movement trajectory, a target app, clicks, drags, or scrolling.

No crash was observed in this project's compiled probe. Early runs stopped
before posting because permissions were missing. That does not establish the
cause of any earlier prototype crash; do not infer one from permission failures.
If a future run crashes, inspect macOS DiagnosticReports/Console and reproduce
with the smallest compiled case before changing the full pipeline.

## Execution and concurrency

| Context | Work |
| --- | --- |
| CLI/main thread | Arguments, action orchestration, menu state, file I/O after capture, direct-command reports |
| Recorder thread | User-interactive thread with its own CFRunLoop and listen-only HID tap |
| Playback thread | User-interactive, high-priority thread; waits and posts events |
| Menu control thread | Polls stdin, recognizes S/Q, and propagates session cancellation |
| Presentation thread | Snapshots UI state and owns menu terminal output, animation, sizing, and restoration |
| Dispatch signal sources | Handle SIGINT/SIGTERM by setting locked cancellation state |

`Cancellation` uses `Synchronization.Mutex`; the first reason wins. A menu
session has its own cancellation object, and every action gets a fresh one.
Do not reset and reuse an action's cancellation while another thread may still
observe it.

Recorder mutable state is protected by a mutex. A semaphore communicates startup,
and a dispatch group allows stop to wait for teardown. The tap's C callback uses
an `Unmanaged` context pointer. The recorder is retained by its worker thread
until the tap and run-loop source are disabled and invalidated.

The callback stores event data and timestamps, not formatted JSON. Encoding,
disk writes, and user-facing reports happen outside the callback. Avoid blocking
or adding unrelated work to the tap callback.

In menu mode, stdin is noncanonical and echo is disabled, while signal generation
is retained. The original terminal settings are restored on a controlled exit.
Only one context reads stdin at a time: the menu when idle, action controls while
an action runs. Stop and join the control reader before returning to the menu or
restoring terminal settings.

### Terminal presentation is not capture or playback

The menu has a single compact alternate-screen view, with a subtly pulsing
recording dot, elapsed time, bounded playback progress, and one friendly current
message. A new state replaces the old message; do not add a scrolling event or
notification log. R/S/P/Q accept either case, with Ctrl+C to quit and Esc as an
alternative stop. There are no numeric aliases.

The title is injected into `TerminalScreen` by its caller, not hardcoded by the
renderer. The recording indicator repeats a one-second Unicode `·/•/●/•`
cycle, with an ASCII `./o/O/o` fallback. Updates remain within the same alternate
screen; the pulse does not open additional screens or change capture timing.

`TerminalScreen` hands state across a mutex to a dedicated presentation thread.
Rendering, terminal writes, resize checks, and animation do not belong on the
recorder callback or playback scheduling thread. Workers may publish small
state updates; they must not perform UI I/O or wait for a rendered frame.
Keep state updates lightweight enough not to disturb event timing.

ANSI-capable terminals use an alternate screen and hide only the terminal text
caret while active, restoring it on exit. Shortcut rows are white when color is
enabled. The Ctrl+C hint sentence is not shown; the shortcut still works.
The activity/message, progress, and filename slots reserve fixed rows, so changes
in phase, message length, or file availability cannot move the shortcut footer.
The quit control also keeps a fixed column on full-width layouts.
Animation writes only rows whose contents changed. Do not clear and repaint the
whole terminal on each tick or rewrite the static shortcut footer for a dot pulse.
Terminal caret visibility is separate from the macOS mouse pointer. The renderer
must not post extra mouse events, warp the pointer, or change global hide counts
merely to change mouse-pointer visibility.
`NO_COLOR` disables color without changing the controls or error meaning.
`TERM=dumb` falls back to a single-line terminal presentation; redirected
presentation output is a short plain summary, not an animation. The menu still
requires terminal input. Text is sanitized and clipped for terminal dimensions,
and filenames are displayed without exposing full capture paths.

Controlled shutdown joins presentation and restores cursor/screen state as well
as input settings. These guarantees do not extend to SIGKILL or a process crash.
Report terminal-output failures rather than presenting a successful operation
when the UI has failed.

`Runtime.countdown` has an optional `onTick` callback for presentation updates.
This does not change countdown timing. Keep callback work small and publish
state rather than printing from UI callers; direct commands retain their
textual countdown behavior.

### Storage identity and legacy discovery

`AppIdentity` resolves new menu captures to
`~/Library/Application Support/Cursor Replay CLI/recordings`. If
`CURSOR_REPLAY_DATA_DIR` is set, it must be a nonempty absolute **base directory**;
append `recordings/` to it. Do not reinterpret the override as an output filename
or as the recordings directory itself.

The menu considers both this folder and legacy current-directory `recordings/`,
`recording.json`, and `movement.json`, choosing the most recently modified
recording and excluding `.verification.json`. Direct file-based commands retain
current-working-directory semantics and the `recording.json` default. Neither
the executable location nor the menu data override changes direct file paths.

Discovery is not migration. Before relocating private captures, preserve their
bytes, names where possible, and metadata needed for last-file selection.
Keep relocated originals under a private `legacy-originals/` folder in the
application data area, not in source or public fixtures. Do not claim a
migration is complete until byte preservation is checked. Recording contents
and verification reports remain private local data.

The local cleanup checkpoint on 2026-10-20 completed byte-identical relocation
of six normal captures into the application-support recordings folder and
preserved two early files under `legacy-originals/`. The old root `.build/`
cache, about 576 MiB, was removed after preserving `./bin/cursor-replay`; the
remaining project folder was about 1 MiB. Generated source-tree artifacts and
recordings are ignored by Git. This housekeeping is not a physical replay
fidelity result, and private captures are not part of the source distribution.

## Recording lifecycle

1. Check required permissions and the output path before starting.
2. Create a keyboard-only listener for Esc during the countdown.
3. After countdown, obtain display metadata and start the full recorder.
4. Enable a listen-only `.cghidEventTap` on the recorder's dedicated run loop.
5. Capture every delivered supported mouse event; never decimate movement.
6. On S/Esc/Ctrl+C, timeout, or failure, stop and join the recorder.
7. Validate and atomically save the buffered JSON, reporting partial/error states.

The full mouse mask contains `mouseMoved`, each left/right/other
down/up/dragged type, and `scrollWheel`. Key-down is additionally observed only to
recognize Esc; keyboard events do not enter the saved event list.

`tapDisabledByTimeout` and `tapDisabledByUserInput` increment an interruption
counter and request re-enabling on the worker loop. Re-enabling is recovery,
not evidence that no events were lost. The saved header retains the counter,
and capture/verification surfaces it as a problem.

Events and native snapshots remain in memory until stop. There is no streaming
JSON Lines writer or memory limit. Plan a streaming implementation carefully
before using this for very long sessions; do not silently drop events under load.

## Time model: invariants and earlier mistakes

### Raw timestamp units are not interchangeable

On the development system, physical HID callbacks carried raw mach ticks while
posted synthetic events carried nanoseconds. The initial implementation assumed
both were nanoseconds. A roughly one-second physical recording was consequently
replayed in about 24 milliseconds.

`MachClock.eventTimestamp(_:near:)` now considers two candidates:

- The raw value interpreted directly as nanoseconds.
- The raw value converted using `mach_timebase_info` numerator/denominator.

It chooses the candidate closer to the current monotonic clock epoch. The
callback's clock reading chooses **units only**. The event timestamp itself
remains the source of recording time; callback arrival time must not replace it.
Both the raw value and selected unit are retained.

The development timebase was `125/3`. That is an observation, not a portable
constant. Obtain the timebase from the OS, use full-width integer arithmetic,
and avoid `Double` for default-speed event offsets.

An epoch-selection heuristic is not a universal guarantee for all macOS releases,
hardware, or unusual injected events. If investigating another timing problem,
compare raw values, normalized values, mach uptime, callback arrival, and source
provenance before adding another conversion.

### Relative events and full-session boundaries

Each event's `timeNS` is relative to the first captured event, so the first
event remains at zero. `timestampOriginNS` is that first event's normalized
absolute timestamp.

The header additionally stores `captureStartedNS` and `captureEndedNS`.

```text
leading idle = timestampOriginNS - captureStartedNS
event span   = lastEvent.timeNS
session span = captureEndedNS - captureStartedNS
trailing idle = session span - leading idle - event span
```

Capture boundaries must be paired and ordered, and must contain the event span.
The recorder includes an earlier buffered first event if necessary rather than
discarding it. Stop time is captured before run-loop teardown or JSON saving,
so shutdown/encoding work does not become intentional trailing idle.

Earlier files retained only first-to-last event timing. That omitted surrounding
pauses and made a replay finish sooner than the whole recording session, even
when between-event timestamps were correct. Do not fix this by arbitrarily
lowering playback speed. Preserve boundaries for new captures, and report that
old missing boundaries cannot be recovered exactly.

### Absolute scheduling

For a recording with session metadata:

```text
event offset = leading idle + event.timeNS
loop span    = full session duration
target = one playback origin
         + clockTicks((loopIndex * loopSpan + event offset) / speed)
loop end = one playback origin
           + clockTicks(((loopIndex + 1) * loopSpan) / speed)
```

The implementation applies integer nanosecond scaling first, then converts the
combined absolute offset to mach ticks. At speed exactly `1.0`, scaling returns
the original integer value without a floating-point round trip. Other positive
finite speeds are rounded to integer nanoseconds.

The worker prepares events before selecting a start origin, allows a short
startup lead, uses `mach_wait_until` for coarse waits, and spins for the final
100 microseconds. Coarse waits are split into at most two-millisecond slices
for cancellation. Do not chain relative sleeps or use main-queue `asyncAfter`.

Late events are still submitted at their original absolute targets as soon as
possible; none are skipped or interpolated. Each loop includes its trailing
idle wait. The minimum loop span is one millisecond for zero/sub-millisecond
timelines. Duration and deadline arithmetic is checked for overflow.

Actual submission time, not the ideal target, is written into the posted event's
timestamp. Stamping the ideal deadline would make timestamp comparisons look
better without making delivery more accurate. Keep submission time, `CGEvent.post`
return time, and recorder callback arrival distinct.

macOS is not a hard real-time system. Thread priority and spinning cannot promise
that the OS or target app will process every event within two milliseconds.

## CoreGraphics reconstruction and cleanup

Playback creates a `.hidSystemState` event source and fresh mouse/scroll events.
Every optional event/source creation is checked. All events are prepared before
the scheduled sequence starts, so an invalid native payload fails before any of
that sequence is posted.

The stored native payload remains useful for archival and unmodeled device
fields, but playback does not blindly repost the archived object. It explicitly
restores locations, raw flags, button/click state, pressure, mouse deltas, event
numbers, and scroll fields. Unknown/private native metadata is not promised to
have identical replay semantics.

### Source tags must be assigned before construction

An observed failure during development was that retagging an already-built
event left its original source tag visible at the HID tap. Changing source data
immediately before posting did not fix that case.

Set source metadata before constructing each fresh event. Verification uses
`tagBase + eventIndex`, and a pre-post readback guard rejects an unexpected tag.
Do not replace this guard with a success-shaped fallback. There is a regression
test for independent tags on multiple events built from a shared source.

### Scroll and pressure details

Line, point, and fixed-point deltas are distinct representations and must remain
distinct. The fixed-point fields store signed 16.16 values through the integer
accessor. All three axes are retained. Continuous/discrete mode, scroll count,
scroll phase, momentum phase, and auxiliary public deltas are restored.

Momentum is replayed from the captured events, not regenerated from a gesture.
For cleanup, scroll phases use an ended bit of `4`; momentum uses
begin `1`, continue `2`, end `3`. Do not treat the two as one shared bitmask.

CoreGraphics can quantize pressure. Compare reconstruction with the value
actually captured, not the literal value originally passed into a synthetic
event constructor. The pressure regression tests check the full 8-bit range.

### Held-input cleanup

`HeldInput` tracks down/dragged buttons, releases, active scroll and momentum,
and the latest event location/flags. On stop, error, or an incomplete recording
boundary, cleanup attempts:

- A matching up event for every held button, including buttons beyond the
  Swift enum's named left/right/center cases.
- Zero-delta endings for active scroll and momentum phases.

Cleanup also runs if cancellation happens during a trailing idle wait. Failures
are surfaced, and multiple releases are attempted rather than silently stopping
after the first creation failure. Complete balanced recordings need no added
safety events; strict verification rejects extra safety input as nonidentical.

An attempted post is not confirmation that the target app accepted it.
SIGKILL, crashes, shutdown, or permission revocation cannot guarantee cleanup.

## Coordinates, displays, and target state

`Position` stores `Double` global CoreGraphics coordinates. Display frames and
mode backing scales are recorded separately. Negative coordinates are valid
on multi-display layouts.

Do not multiply the event coordinates by the Retina scale or remap them to a
new screen/window. The player warns if the current active display layout differs,
but retains the original trajectory. The first submitted position may differ
from the current cursor location.

The target application and its contents are external state. The tool does not
focus it, open documents, reset scroll positions, restore windows, or record
screenshots. Before comparing runs, manually restore that state.

## JSON format and compatibility

The root object is `{ "header": ..., "events": [...] }`. Output is pretty-printed,
key-sorted JSON written atomically. Native `Data` is encoded as Base64. Use a
parser that preserves 64-bit integers; JavaScript `Number` cannot represent every
possible nanosecond timestamp exactly.

### Header

| Field | Meaning |
| --- | --- |
| `formatVersion` | Current writer uses `3`; reader accepts `1`, `2`, and `3` |
| `recordedAt` | ISO 8601 recording date |
| `macOSVersion` | OS description; a mismatch warns before playback |
| `displays` | Active display IDs, global frames, backing scales, pixel mode sizes |
| `timestampOriginNS` | Optional normalized absolute timestamp of the first event |
| `timebaseNumerator`, `timebaseDenominator` | Optional mach conversion ratio |
| `captureStartedNS`, `captureEndedNS` | Optional paired monotonic session boundaries |
| `stopReason` | Completion, stop key/signal, duration limit, or capture failure |
| `tapInterruptions` | Number of tap-disable notifications |
| `captureError` | Optional explicit capture error |
| `coordinateSpace` | Human-readable coordinate convention |
| `timestampNormalization` | Optional legacy conversion explanation |

Each `DisplayFrame` contains `id`, `x`, `y`, `width`, `height`, `scaleFactor`,
`pixelWidth`, and `pixelHeight`.

### Event

| Field | Type / meaning |
| --- | --- |
| `type` | Supported mouse/drag/scroll type as an English string |
| `timeNS` | `UInt64`, relative to the first event; nondecreasing |
| `location` | `{ "x": Double, "y": Double }` in global coordinates |
| `flags` | Raw `UInt64` event flags |
| `button`, `clickState` | `Int64` button number and click count/state |
| `pressure` | Captured `Double` pressure |
| `deltaX`, `deltaY` | `Int64` mouse deltas |
| `mouseEventNumber` | Native mouse event number, including down/up association |
| `sourceUserData` | Original `Int64` source metadata; verification overrides its replay tag |
| `scroll` | Optional `ScrollFields` object |
| `nativeData` | Base64 native CGEvent snapshot; not a cross-OS interchange guarantee |
| `rawTimestamp` | Optional original absolute timestamp before normalization |
| `timestampUnit` | Optional `nanoseconds` or `machAbsoluteTicks` |

`ScrollFields` contains three-element `pointDelta`, `fixedDeltaRaw`, and
`lineDelta` arrays; `isContinuous`, `scrollPhase`, `momentumPhase`, `scrollCount`;
and auxiliary integer/double dictionaries keyed by public numeric CGEvent field
IDs. The implementation currently retains integer IDs 14, 173, 175, 176, 177,
and 178 where available, and floating-point deltas for IDs 175 through 178.

### Older files

Format 1 could contain unnormalized raw mach ticks. When the recording date and
current clock establish an unambiguous epoch, the loader converts those offsets
in memory, returns a normalized format-2 model, and prints a warning. The
original file is not changed.

The legacy origin must be close to the date-derived reference epoch. Sleep,
reboot, clock changes, another machine, or long initial inactivity can make that
ambiguous; loading then fails instead of guessing.

Format 2 has normalized timestamps but may lack session boundaries. The reader
preserves its event span and warns that surrounding idle cannot be recovered.
New format-3 captures include boundaries. Missing boundary pairs, a first event
outside the session, a last event beyond its end, nonmonotonic times, unsupported
versions, malformed scroll axes, and invalid payload fields are rejected.

Changing this schema requires an explicit compatibility decision, focused
regressions, and documentation updates. Do not rewrite a user's recording
silently on load.

## Verification design

`verify` captures one speed-1 replay with the same `Recorder`. A unique source-tag
range isolates the replay. Each observed event is matched to its exact index;
missing data is not concealed by pairing the next event or interpolating.

The comparison tracks counts, missing/duplicate/reordered events, Euclidean
position errors, known payload differences, and scroll sums. Sums use `Decimal`
so integer accumulation does not silently overflow an `Int64`. Statistics report
max, arithmetic mean, and nearest-rank p95.

Three timing errors are separate:

1. Submission versus the target deadline.
2. The observed event timestamp versus that target.
3. Callback arrival versus that target, including system delivery.

Raw flags and public modifier-key differences are reported separately. Physical
events with flags `0` were observed coming back as `0x20000000` after posting,
without a public modifier-key difference. The reserved bit's exact platform
semantics were not established. Do not relabel it as a particular OS feature
without evidence, remove arbitrary bits, or hide the strict mismatch.

The strict result requires matching counts/order/known fields/positions, matching
scroll sums, no capture problems or interfering mouse input, no extra safety
events, and maximum timing errors at or below 2 ms. An empty observation set does
not become a zero-error pass. HID verification cannot certify application
rendering, actual scrolling effects, or complete private metadata equivalence.

The full CLI decision combines `VerificationReport.passed` with checks on the
original recording's warnings, cleanup count, and cancellation. Preserve those
additional checks if verification is reused behind another interface.

## Automated tests and non-posting timing checks

```sh
./scripts/test.sh
./scripts/test.sh --filter RecordingTests
./scripts/test.sh --filter PlaybackTests
./scripts/test.sh --filter 'TerminalScreenTests|AppIdentityTests'
```

The script disables XCTest and uses the installed Swift Testing framework. On
the development Command Line Tools installation, XCTest was absent and the
Swift Testing macro plugin needed explicit loading. The script finds the
toolchain through `xcrun` and loads its bundled plugin when present. No testing
package is downloaded.

The normal core tests construct and inspect events, or inject a post function
into the real scheduler. They do not post clicks, drags, or scrolls to the system.
CLI tests cover frame content, pulsing/progress math, narrow terminals, Unicode
clipping, control-sequence sanitization, color policy, and storage identity.
Rendered-frame assertions are not an end-to-end menu or physical-input test.

To exercise a real recording's timeline **without any `CGEvent.post` call**:

```sh
CURSOR_REPLAY_TIMELINE_FILE=/absolute/path/to/recording.json \
  ./scripts/test.sh --filter TimelineHarnessTests
```

This uses the same scheduler, waits the real timeline duration, substitutes a
no-op submission function, and prints planned/simulated timing. Its comparison
is useful for clock math and drift, but excludes CoreGraphics posting overhead,
HID delivery, and application response. The case is skipped when neither
supported environment variable is set.

The harness prefers `CURSOR_REPLAY_TIMELINE_FILE` and retains
`MOUSEREC_TIMELINE_FILE` as a compatibility alias. If both are set, the preferred
variable wins. Use a private local file; do not copy real captures into tests
or an archive.

The production entry point always supplies the real HID post function. Keep the
test seam internal, and route cleanup through it too so tests cannot accidentally
post a release to the desktop.

## Validation evidence and known limits

Automated coverage and historical HID observations are different kinds of
evidence. None of the results below certifies physical trajectory, click,
scroll, or target-app fidelity for the new presentation.

### Current automated checkpoint

An integration test invocation during the product update on 2026-10-20 passed
**47 test functions**, including an explicitly enabled non-posting timeline
harness:

| Suite | Functions |
| --- | ---: |
| RecordingTests | 14 |
| TimingTests | 5 |
| CleanupTests | 4 |
| PlaybackTests | 4 |
| VerificationTests | 7 |
| TimelineHarnessTests, explicitly enabled | 1 |
| TerminalScreenTests | 10 |
| AppIdentityTests | 2 |

This is 35 core functions plus 12 CLI functions. Source tests and the release
build have been validated locally, not through GitHub Actions. Automated results
do not certify physical trajectory, scroll, click, or target-app fidelity.
Keep real-app checks separate from local build/test evidence.

### Historical observations

The following observations are from 2026-10-19, not fresh measurements of the
new terminal interface. The historical development environment was Apple
Silicon with macOS 27.0.1 and Swift 6.4; that does not validate all supported
macOS releases or Intel Macs.

#### User-reported real use

The user subsequently reported that the app was working after trying it.
This is useful real-use feedback, not a controlled per-event accuracy result.
Exact trajectory/timing equivalence, all button/drag combinations, trackpad
inertia effects, held-input abort behavior, multiple displays, and a mixed
30-second target-app run have not been comprehensively certified.

#### Observed in compiled executables

- The compiled one-move probe posted and observed its tagged event at exactly
  the requested current position.
- Recording stop/save, Ctrl+C/SIGTERM paths, overwriting guards, and menu
  transitions were exercised with compiled tools.
- One optimized verification run used 120 synthetic stationary events:
  120/120 were observed, positions matched exactly, and known payloads matched.
  Its strict timing result still failed.

| Optimized 120-event run | Max (ms) | Mean (ms) | p95 (ms) |
| --- | ---: | ---: | ---: |
| Submission / event timestamp error | 0.134500 | 0.076502 | 0.090042 |
| HID callback arrival error | 9.011458 | 0.407690 | 0.702000 |
| `CGEvent.post` call duration | 4.729541 | 0.064158 | 0.036959 |

The first post took 4.729541 ms, compared with a subsequent-call maximum of
0.038667 ms. An earlier debug 120-event run measured callback max/mean/p95 of
19.589750 / 3.336792 / 4.151292 ms and a maximum post call of 8.054291 ms.
This establishes observed cold-post overhead and delivery latency, not a complete
explanation or a fix. No extra warm-up mouse events or idealized timestamps are
used to improve the score.

#### Data audits and harnesses only

- An audit of 5,000 saved events across five real recordings found 0 ns maximum
  disagreement between retained raw timestamps and their stored normalization.
  This does not prove no physical events were missed.
- The latest audited first-to-last span was 14.517512583 s. Roughly 2.06 s
  separated its last event and file save, including write overhead. That old
  file lacked exact surrounding session boundaries.
- In the final of two no-post scheduler runs using its 1,516 events, scheduled
  span was 14.517512583 s and simulated submission span was 14.517439625 s.
  Error max/mean/p95 was 0.162625 / 0.058557 / 0.113333 ms. No system input
  was posted in those runs.

Historical menu harness results are development observations, not a permanent
end-to-end menu suite included in `scripts/test.sh`. The final feedback harness
passed seven scenarios with two recorder runs and three one-position synthetic
playback runs, two completed and one stopped. It covered letter-only controls,
persistent status,
repeat playback, cancellation/error feedback, and Ctrl+C save-and-quit.
Earlier menu harnesses also covered terminal restoration, failed saves,
countdown cancellation, and last-file selection across launches.

**Unresolved:** cold first-post latency, downstream delivery jitter, raw OS flag
differences, application coalescing/rendering, and native-payload compatibility
across OS versions. Do not describe those as solved because a unit test or the
non-posting scheduler check passed.

## Making improvements without regressing behavior

1. Reproduce the specific issue with a small recording and keep that source
   unchanged. Back up user data before changing formats or file handling.
2. Identify the layer involved: capture, clock units, reconstruction, scheduling,
   HID delivery, terminal UI, or target-app state. Do not rewrite the whole
   pipeline to fix one layer.
3. Add a focused regression that would fail without the change. For posting
   logic, first use the injected post function to avoid desktop side effects.
4. Run the narrow relevant suite, then the release build. For timing work,
   separately measure the no-post scheduler and an authorized HID replay.
5. Recheck S/Esc stop, Q/Ctrl+C quit, cancellation during countdown/leading/trailing
   waits, save failure, and held-input cleanup when relevant.
6. Update this guide, user-facing help, and the README together if controls,
   semantics, schema, or installation change.

Keep these invariants:

- No movement interpolation, decimation, silent event loss, or fabricated
  momentum.
- No shell-command fallback or GUI application lifecycle.
- No forced unwraps for optional CoreGraphics creation.
- No callback-wall-clock replacement for event timestamps.
- No default-speed floating-point round trip or relative-delay scheduling.
- No silent fallback for invalid data, failed saves, or failed cleanup.
- No dropping capture-health warnings or weakening verification to get a pass.
- No numeric menu aliases; use R/S/P/Q, Ctrl+C quit, and Esc alternative stop.
- No success notification before the corresponding operation actually succeeded.
- No terminal rendering or UI I/O on capture callbacks or playback scheduling
  threads.
- No real captures, private paths, or machine-specific metadata in source
  fixtures or release archives.

Natural improvement areas include streaming large captures, a permanent
pseudo-terminal regression suite, broader display/OS coverage, and investigation
of first-post/delivery latency. These are not implemented features.

### Manual real-app sequence

Use a disposable target, reset its state between record/play/verify, and test
separately: one move, continuous movement, left click, right click, double click,
drag, slow scroll, fast scroll with inertia, then mixed input for about 30 s.
Include right/other-button drags where hardware supports them.

Also test stop during a held button and during scrolling, and compare the
first-to-last event span with full-session duration. For each report identify
the executable/build, OS/display setup, speed, number of **runs**, and whether
the evidence is real-app observation, a HID check, a harness, or source review.
Report errors over 2 ms and every position difference rather than rounding them
away or describing the entire app as faithful.

## Packaging and release checklist

The public display name is Cursor Replay CLI. The chosen owner and repository
are [Just-Jan/cursor-replay-cli](https://github.com/Just-Jan/cursor-replay-cli),
with [releases](https://github.com/Just-Jan/cursor-replay-cli/releases) under
the same project. An [MIT license](LICENSE) is included. Complete final
validation and the source-content audit before publishing.

Follow the [allowlisted source archive command](docs/USAGE.md#share-source-safely),
or use the committed-source release generator described below.
It uses `COPYFILE_DISABLE=1`, explicitly includes `Package.swift`, `Sources`,
`Tests`, `scripts`, `Formula`, `docs`, `.github`, `README.md`, `DEVELOPMENT.md`, `LICENSE`, and
`.gitignore`, and excludes `.DS_Store` and `._*`. Inspect the allowlisted folders
before sharing; `.gitignore` is not a sharing filter.

Exclude compiled executables, `bin/`, `.build/`, `.swiftpm/`, all caches,
Finder/cloud metadata, private captures, verification output, and
machine-specific artifacts. Keep source archives free of private account details,
emails, user-specific absolute paths, and private design links. Data migration
and old-cache removal are separate local housekeeping tasks, never implicit
side effects of packaging. Preserve a working executable before removing old
build output, and verify capture bytes before removing an old data copy.

The current executable links Apple/system frameworks and Swift libraries; the
core is not a separate bundled runtime framework. A copied executable's `--help`
can check relocation, but does not establish permissions or replay on another Mac.
The inspected development binary is arm64 only.

Before an external release:

1. Review the included MIT license and public source allowlist.
2. Build the final integrated source and rerun the relevant core and CLI suites.
3. Recheck compact-screen controls, countdown cancellation, stop/save, repeat
   playback, color/dumb-terminal fallbacks, and controlled terminal restoration.
4. Run authorized real-app checks separately from non-posting tests; document
   tested OS versions, architectures, input hardware, and unresolved failures.
5. Confirm source-based Homebrew distribution is appropriate. Developer ID
   signing/notarization, bottles, universal binaries, and a desktop installer
   are not configured; those require a separate distribution/signing policy.
6. Inspect archive contents and links for private data before sharing.

Never include signing credentials or private keys in a source archive.

### Publishing a release

This repository doubles as the Homebrew tap. No separate repository, PAT,
Developer ID certificate, or notarization secret is needed for the source-built
formula. The workflow uses GitHub's built-in `GITHUB_TOKEN`, with `contents: write`
only in its publishing job. GitHub Actions must be enabled, permitted to use
`actions/checkout`, and permitted to push the formula update to `main`.

Before the first release, commit and push the packaging changes to `main`.
Use an appropriately authorized login/token for `.github/workflows/` files.
The initial version is `0.1.0`; for later releases, change
`AppIdentity.version` in `Sources/MouseRecorderCLI/AppIdentity.swift`, commit,
and push. Use stable, strictly increasing `X.Y.Z` versions without prerelease
suffixes. Do not manually edit the generated stable URL or checksum.

From the committed release source, preview the assets and install locally:

```sh
ruby scripts/test-release.rb
./scripts/test.sh
./scripts/build.sh
ruby scripts/prepare-release.rb HEAD dist/preview
sh scripts/test-homebrew.sh dist/preview/cursor-replay-cli-0.1.0.tar.gz dist/preview/cursor-replay.rb
```

Use the actual version in the archive filename for subsequent releases.
The output directory must not already contain an archive for that version;
choose a fresh directory for another preview. The generator uses `git archive`
on an explicit path allowlist and `gzip -n`, excludes uncommitted files, and
produces these files in `dist/preview`:

| File | Purpose |
| --- | --- |
| `cursor-replay-cli-X.Y.Z.tar.gz` | Source used by Homebrew, including license and tests |
| `SHA256SUMS` | Source archive SHA-256; check with `shasum -a 256 -c SHA256SUMS` in the output directory |
| `cursor-replay.rb` | Stable formula pointing to that archive's future GitHub Release URL |

The formula tracked on `main` starts HEAD-only. The preview's stable formula is
not meant to be copied back until its source archive has actually been published.
After reviewing the preview, create and push the tag:

```sh
git tag -a v0.1.0 -m "Cursor Replay CLI 0.1.0"
git push origin v0.1.0
```

The [release workflow](.github/workflows/release.yml) requires the tag to match
the embedded CLI version and belong to `main`'s history. It validates a pinned
commit on both architectures, prepares the source archive and formula, uploads
all three assets to a draft release, publishes it, then commits the formula to
`main`. Publishing happens only after both Homebrew installation tests pass.
Never move a published tag or replace its source archive: the installed formula
pins its SHA-256.

If a run fails, fix the underlying problem and rerun the workflow, or manually
dispatch **Release** with the existing `vX.Y.Z` tag. Draft assets can be retried;
already published source is compared byte-for-byte and never overwritten.
The workflow refuses to downgrade the stable formula. If a failed source needs
changes, make a new version/tag rather than moving the old one.

If branch protection prevents the bot's final push, the release remains
published but the tap is not updated. Download `cursor-replay.rb` from that
release, place it in `Formula/cursor-replay.rb` through a normal reviewed PR,
and merge it into `main`. No bypass or personal token is required. Consumers
can then use the [Homebrew installation guide](docs/USAGE.md#install-with-homebrew).
The GitHub-generated source links also exist, but the formula uses the explicit
allowlisted release asset.
