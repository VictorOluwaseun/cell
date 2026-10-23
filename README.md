# Cell

A native macOS battery monitor built with Swift 6, SwiftUI, Swift Charts, IOKit, and SQLite. No third-party dependencies or network services.

## Run

Requires macOS 14 or later and Xcode with a Swift 6 toolchain and a recent macOS SDK (including `RUSAGE_INFO_V6`).

```sh
make app
open dist/Cell.app
```

The build creates an optimized, locally ad-hoc-signed app for the build machine’s architecture. Packaging verifies a separate staged bundle before replacing the previous app, so it never overwrites a running executable in place. Open the bundled app rather than `swift run`: macOS notifications and login items require an app identity. Move `dist/Cell.app` to Applications before enabling **Open at login**.

For development, open `Package.swift` in Xcode, or use `make build`. `make test` runs the core calculation, alert, CSV, SQLite, startup-controller and release-packaging tests. `./scripts/build-app.sh debug` packages a debug build. The wrapper keeps compiler and SwiftPM caches inside `.build` so builds also work in restricted workspaces.

`dist/Cell.app/Contents/MacOS/Cell --diagnostics` prints a live battery snapshot and the count of readable user processes without opening a window or requesting notification permission. Exit status 2 means no internal battery was found.

## Features

- Live percentage, charging state, estimated time remaining when available, lifetime hardware cycle count, battery health and temperature.
- Signed battery watts, milliamps, voltage, instantaneous percentage change per hour, C-rate, and a least-squares 15-minute charge trend.
- Adapter rating and system input power when exposed by the hardware.
- Interactive charge and power charts for one hour, 24 hours, seven days, or 30 days. Sleep and missing readings appear as gaps.
- Recorded battery time, integrated charge/discharge energy, average drain, equivalent discharge cycles and cycles per recorded day.
- App/process activity with search, app-only filtering, and sorting by power, CPU, wakeups or memory. Helpers are grouped with a running app when an ancestor can be identified.
- Confirmed Quit actions for running apps, with normal save prompts and exit feedback.
- Persistent high and low percentage reminders, optional notification sound, a test notification, and a 2-percentage-point rearm threshold.
- Clock reminders to plug in or unplug once, every day, or on weekdays, with optional skipping when the action is already done.
- Audible charge alarms with three tones, independent volume, a floating reminder window, Stop/Snooze controls, and configurable ringing duration.
- Optional automatic charging limit (20–100%) with a separate administrator-approved helper, 3% hysteresis, and a one-time full-charge override.
- Menu bar summary, configurable sampling, launch at login, CSV export of the selected period, and confirmed deletion of local history.
- Desk, Travel and custom charging profiles, including separate profile reminders.
- Sleep/wake battery comparisons, daily health trends, sustained-drain alerts, and runtime forecasts with uncertainty ranges.
- App energy history, charging-session segments, a power-event timeline, and weekly reports with text/CSV export.
- Charging explanations that distinguish confirmed Cell pauses from macOS states and unknown causes.

## Feature settings

Open **Settings** in the sidebar or **Cell → Settings… (⌘,)** to choose optional features. Controls cover the menu bar, detailed readings, charging explanations, process sampling, app energy history, battery history/statistics, forecasts, sleep comparisons, daily health history, timeline/sessions, reports, profiles, unusual-drain notifications, weekly notifications and charge reminders. Alarm enablement, tone, volume and ringing duration are also available here.

**Settings → Startup → Open at login** registers the current Cell.app with macOS so it opens after you sign in, including after restarting your Mac. Keep the app in Applications before enabling it. Startup is opt-in and needs no charging helper or administrator installation. If macOS requires approval, Cell shows a pending state and a button to open Login Items settings. Turning the switch off unregisters the login item. Both Settings windows share the system-reported state and refresh when Cell becomes active; Cell never silently re-enables an item disabled in System Settings. The current app stays running when startup is disabled.

**App activity → Live activity → Quit…** asks a running app to close after confirmation. The app can show save prompts or decline the request. Cell shows “Quitting…” until it observes the exit, then removes that instance from the live list. After 20 seconds without an exit, it reports that the app is still running and stops waiting; it never escalates to force quit. Quit controls can be hidden with **Settings → Activity & history → Quit applications**. Plain processes, system services, Finder, Cell itself, embedded helpers and historical energy rows do not offer Quit. The selected PID, launch date and bundle identity are checked again at confirmation, so a stale row cannot target a restarted app. Exit observation and the bounded wait run only for pending requests.

Choices persist across launches, and existing installations retain their current preferences. Turning off a feature stops its collection or calculations and hides its optional views. Saved data and reminder rules are kept, subject to normal retention. Turning off battery history also pauses dependent history features; their individual choices are retained for when recording resumes. Live battery status, percentage reminders and forecasts can run without stored history. Recording sessions have distinct identifiers so charts, energy totals and charging sessions never join across a recording pause, even a short one.

The **Charge reminders** master switch stops percentage and time reminders, active alarms and snoozes without deleting rules. Enabling it again can fire a percentage rule on the next sample if its threshold is already met; clock occurrences missed while paused are not replayed. **Alert sound** controls sounds for both reminders and insight notifications; **Cell alarm** separately controls the floating window and repeating tone. Disabling charging profiles hides profile controls while retaining the current hardware limit and existing profile reminders.

**Charge alerts → Add a time reminder** lets you choose Plug in or Unplug, a time, and Once, Every day or Weekdays (Monday–Friday). Once includes a date. Saved reminders can be paused, deleted, or have their time and “skip if already done” setting changed. Recurring times follow the Mac’s current local clock; one-time dates keep the selected absolute date. During a daylight-saving gap, a recurring reminder uses the next valid time; during a repeated hour it uses the first occurrence only. Clock and time-zone changes rebuild the next deadlines.

Cell must remain running for clock reminders and their audible alarms. It checks recent missed occurrences on launch or wake, up to 15 minutes late, and skips older ones. Creating, editing, or re-enabling a rule starts its schedule from that moment. Last-handled occurrences persist so normal restarts do not replay a delivered or skipped reminder. “Skip if already done” omits Plug in when external power is detected and Unplug when the Mac is already on battery; unknown readings still allow a reminder. These conditions also dismiss an active or snoozed time alarm once the action is done. With skipping disabled, dismiss the alarm yourself. Clock reminders share the existing tone, volume, Stop and Snooze controls and do not change charging hardware.

Time schedules use one non-repeating timer for the earliest deadline, with up to one second of timer tolerance. There is no scheduled timer when no future reminder is enabled. Upcoming dates are cached for the UI; checking a due schedule uses one battery read for all due reminders. Up to 32 clock rules are saved locally, separately from percentage rules and charging profiles. macOS can delay work under load, and Cell cannot ring while the Mac is asleep or the app is closed.

**Settings → Automatic charging limit** changes the helper's real configuration, with its confirmed state shown in the switch. It requires an installed, reachable helper; installation and removal remain on the Charging limit page. Turning off the limit asks the helper to release its charging pause. Turning off another display or history feature does not change charging hardware.

## Insights, profiles and reports

**Charging profiles** live on the Charging limit page. Desk defaults to 80%, Travel to 100%; create up to 20 named profiles with a target and optional low/charge reminders. Applying a profile first requires a successful, confirmed helper configuration. It then replaces only reminders previously managed by profiles, preserves independent reminders, and avoids duplicating an already-enabled reminder at the same threshold. Saving/editing a profile never changes hardware by itself. Deleting a saved profile leaves the active charging limit and existing reminders intact.

**Sleep drain** compares the most recent battery reading before a workspace sleep notification with the first reading after wake. Endpoints are persisted across restarts. A recovered comparison is labeled with an unknown actual wake time and excluded from rate flags. Only sessions at least an hour long with battery at both endpoints get a percentage-per-hour rate; more than 1%/hour is highlighted. Power could still have changed between the endpoints. Short sessions and externally powered endpoints are shown without comparable rates. Sleep data starts with this version; Cell does not infer historical sleep events from missing samples.

**App activity → Energy history** aggregates process-counter deltas into hourly buckets. Sampling uses the existing reader, every 10–30 seconds while active (depending on the configured battery refresh interval) and every 30 seconds in the background. Up to 32 leading energy consumers and 32 leading CPU consumers are considered per interval, then grouped by a stable bundle path or process name. At most 128 identities are retained per hour for 90 days. Energy is OS-reported process Wh; CPU minutes are CPU core time. Unknown power stays unavailable, and recorded process energy excludes some system/GPU/device work. Coverage is per identity. Boundary hours can be included in a selected period. In-memory batches flush once per minute and on normal quit; abrupt termination can lose the last unflushed minute. App history CSV export quotes names and neutralizes spreadsheet formula prefixes.

**Timeline** records source changes, macOS charge states, observed helper changes, profile application, sleep/wake, and alerts. It shows up to 300 events in the selected period and retains at most 10,000 for 90 days. Helper events are timestamped when the app observes them, not necessarily at the physical switch time. Session rows are continuous recorded segments on external power, with integrated battery charge energy; sleep or gaps over three minutes split segments. Cell does not reconstruct events while its UI process was closed.

**Health trends** keep the latest valid capacity/cycle reading for each local day, for up to two years. Daily capacity can fluctuate with temperature or calibration. Two distinct days are needed to show a change. The app does not predict a replacement date.

**Runtime forecasts** require at least three continuous minutes on battery and enough valid current readings. They use the median observed percentage-consumption rate in the past ten minutes, with a range from rate quantiles and a minimum ±20% rate spread. A transient spike does not dominate the estimate. Sleep, charging and missing sensors interrupt the forecast. Published estimates refresh at most every 30 seconds and appear in Overview, Insights and the menu bar. These are recent-use estimates, not guaranteed future runtime.

**Unusual-drain alerts** compare current battery watts with the median of at least 30 minutes of recorded battery use in the past seven days, excluding the latest 15 minutes. A reading must exceed both twice that baseline and baseline +5 W, with an absolute 8 W floor, continuously for five minutes. Gaps reset the sustained period. Alerts rearm below 1.3 times baseline and have a persisted two-hour cooldown. They appear in the app/timeline and use existing notification permission. They do not attribute a cause; different workloads can explain a change. Manage them in Settings.

**Reports** compare a selected seven-day period with the preceding seven days, with observed battery runtime, charge/discharge energy, daily bars, average-drain change, sleep comparisons, health change and top recorded apps. The default period is the past seven days; eleven earlier ending weeks can be selected. Totals depend on coverage; the average-drain comparison requires 30 measured battery minutes in each period. Reports are computed on the database actor from retained records and can be exported as plain text. Optional report notifications are limited to once per ISO calendar week, while Cell is running, after 30 minutes of recorded coverage. macOS notification permission and Focus still apply.

**Charging explained** reports the observed source and charge state, distinguishes a confirmed helper pause, and identifies net discharge while connected. It does not claim to identify private macOS optimization decisions. Unknown paused states direct the user to Battery settings rather than inventing a specific cause.

Storage schema v2 migrates v1 samples in place and rejects databases from newer versions. Minute battery records, events, sleep comparisons and hourly app aggregates share one actor-owned WAL connection. Writes use prepared statements; app batches use short transactions, daily health writes skip unchanged values, and pruning runs hourly. Insight/report computations and runtime processing run off the main thread. Stored reports are derived on demand rather than duplicated. Clearing history removes every recorded data category while keeping profiles and reminder preferences.

## Measurements and limits

`IOPowerSources` provides the user-visible battery status. Additional `AppleSmartBattery` registry properties are optional and vary across Mac models and macOS releases. Cell validates readings and shows a dash when a field is unavailable. Battery watts are `voltage × current`; negative means discharge. This is battery flow, not total wall power. Adapter wattage is its reported rating. System input power is a distinct hardware reading.

Battery health is reported full capacity divided by design capacity, capped at 100%. C-rate is absolute current divided by full capacity. Instantaneous percentage change uses signed current divided by full capacity, multiplied by 100. Extra decimal places describe the calculation, not guaranteed sensor accuracy. The trend needs at least two minutes of continuous readings in the same state.

Process power uses deltas of `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` where available; the reader falls back to v2 CPU counters when v6 fails. A missing power counter is never converted into invented watts. CPU percentages can exceed 100% because 100% represents one core. Processes denied by macOS or owned by another user are omitted. App watts are OS-attributed process energy, not a complete measurement of an app’s system, GPU, display or device consumption. App counters refresh every 10–30 seconds while Cell is active and every 30 seconds in the background; the first interval is a baseline.

History starts when Cell runs. Sampling defaults to five seconds (configurable from two to 30); the background interval is at least 15 seconds. Power-source changes trigger an immediate refresh. Persistence is limited to one reading per minute plus state transitions, with 90-day retention. Charts are downsampled; statistics use original records. Energy integration uses trapezoids and skips gaps over three minutes and state transitions. Equivalent cycles sum observed percentage decreases; they are approximate and separate from the lifetime controller counter. Cycle rate divides by recorded continuous time, not calendar time.

Reminders require Cell to remain running. Closing the window leaves the menu bar active. The app cannot monitor while the Mac sleeps; it checks again after wake. Enabling a reminder whose threshold is already met can trigger it on the next sample. The separate Charging limit page controls charging.

**Charge alerts → A reminder you can hear** enables Cell's own audible alarm, independently of macOS notification permission and Focus. A threshold opens a floating reminder window and repeats a generated tone for one minute by default. Choose Chime, Bell or Pulse, set the app-relative volume, and choose 30 seconds, one minute or until stopped. The window remains until dismissed. **Stop alarm** dismisses it; **Snooze 5 minutes** pauses it and checks the reminder again after five minutes. Plugging in cancels a low-battery alarm; unplugging cancels a charge-target alarm. Disabling/deleting a rule also cancels its active or snoozed alarm. Simultaneous reminders share one sound. Alarms and snoozes are session-only and stop when Cell quits. Test alarm uses the same playback path for five seconds without changing your battery rules. The existing Alert sound/Play sound preference remains the master sound control. Muted system audio, disconnected output devices and headphones can affect what you hear; Cell does not change system volume or mute settings.

macOS notifications remain available alongside the Cell alarm. The Charge alerts page reports the actual banner and notification-sound settings; allowed permission alone does not guarantee pop-ups. For system banners and sounds, open **System Settings → Notifications → Cell**, choose a banner/alert style, and enable notification sounds. Focus and other system settings can still suppress system notifications. When Cell is ringing it omits the duplicate macOS chime. System notifications offer Stop/Snooze actions for the matching active alarm. Weekly reports and unusual-drain notifications keep their existing notification behavior; they do not start a repeating charge alarm.

## Automatic charging limit

Open **Charging limit → Install charging helper…** and approve the macOS administrator prompt. Installing the helper leaves the limit disabled. Select a target (20–100%) and click **Enable limit**. At 80%, for example, the helper inhibits charging at or above 80% and releases its inhibition at or below 77%. **Charge to full** bypasses Cell’s limit until the next charger disconnect; other macOS charging rules still apply. It never forces battery discharge. The limit applies to this Mac, and monitoring continues after Cell quits.

The helper checks every five seconds while awake. It pauses charging before sleep when a limit is enabled, including below the target, then reevaluates on wake. This trades overnight charging progress for avoiding an unmonitored charge past the target. Firmware changes and sampling delay mean this is not an exact hardware-enforced percentage guarantee. Unsupported registers, unfamiliar register values, denied writes and readback failures produce visible errors. Use one charge-controller app at a time. Apple’s native charge limit or Optimized Battery Charging can also hold charging independently of Cell.

**Disable limit** releases only an inhibition recorded as owned by Cell. **Remove helper…** first disables the limit and confirms it has been released, then asks for administrator authorization to remove the daemon. A normal daemon stop also attempts to restore charging. Launchd restarts the helper after a crash; durable ownership metadata allows it to recover a pause made before the crash. A full-charge override ends when the daemon restarts. Moving or updating a locally signed build can require **Reinstall helper…** to approve its new code signature.

The installer is bundled, runs once with administrator authorization, uses fixed destinations, and makes no network or sudoers changes. It stages and verifies the helper, pins Cell’s designated code-signing requirement and console user in a private root-owned trust directory, and installs a launch daemon. The XPC connection enforces that requirement on messages; the client also pins the bundled helper’s requirement. Requests expose only status, a validated percentage/enabled setting, and the full-charge override. No paths, shell commands, SMC keys, fan controls or adapter-disconnect operations can be requested through IPC.

Installed files: `/Library/PrivilegedHelperTools/com.cellapp.charge-helper`, `/Library/LaunchDaemons/com.cellapp.charge-helper.plist`, and root-only state/trust in `/Library/Application Support/CellChargeHelper`. Removal retains the state/trust directory for recovery. The packaged installer scripts can also be run manually with administrator privileges; use only a bundle you trust. Production deployment should use a stable Developer ID signature and notarization; the local installer deliberately pins an exact ad-hoc build.

`dist/Cell.app/Contents/Library/HelperTools/com.cellapp.charge-helper --probe` only reads controller support/state; it never writes. The unprivileged probe may be denied even when the approved root helper can access the device. A successful probe establishes readable register support, not that writes will succeed. Hardware writes and an actual charge/discharge crossing require testing after the helper is installed and authorized.

This uses the reverse-engineered AppleSMC message ABI and only known `CHTE` (four-byte) or `CH0B`/`CH0C` (one-byte) charge-inhibition values. It is not an Apple-supported charging API. References: [SMCKit’s public ABI](https://github.com/zackelia/bclm/blob/main/Sources/bclm/SMC.swift), [Battery’s maintained charge-switch implementation](https://github.com/actuallymentor/battery/blob/main/battery.sh), [Apple’s XPC peer validation](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)).

Apple silicon Macs with macOS 26.4 or later also provide a native 80–100% charge-limit option in Battery settings. Cell links to those settings as an alternative. [Apple’s charge-limit documentation](https://support.apple.com/en-nz/102338).

## Architecture

- `BatteryCore`: sendable data models, calculations, pure alert evaluator, CSV encoder, and an actor-owned SQLite connection.
- `Cell`: native UI and platform integration. A main-actor observable monitor coordinates a telemetry actor, notification service, sleep/wake events and IOKit power-source notifications.
- `CPlatform`: small libproc bridge that reads same-user process counters and checks process start identity to avoid deltas across reused PIDs.
- `CellChargeHelper`, `ChargeIPC`, `ChargeHardware`, `CChargeControl`: authenticated root daemon, narrow IPC interface, battery/switch reader, and whitelisted SMC charge-control bridge. Mutable daemon state and hardware operations are serialized.
- `InsightsController`: batches app usage, observes sleep/wake and state changes, coordinates profiles, publishes forecasts, and requests cached-period insight views.
- `Tests/BatteryCoreTests`: deterministic tests for units, missing sensors, energy integration, sleep gaps, forecasts, baselines, alert cooldowns, profile validation, schema migration, retention, report comparisons and export.

SQLite uses WAL, prepared statements and a busy timeout. The telemetry actor keeps hardware and process enumeration off the main thread. Sampling is serialized to avoid overlapping refreshes. History queries are versioned so a slower response cannot overwrite a newer range selection. All data stays in `~/Library/Application Support/Cell/history.sqlite`; preferences use the `com.cellapp.battery` defaults domain. No serial numbers or command-line arguments are stored.

## Distribution

Pushing a version tag such as `v1.2.0` runs the macOS release workflow and publishes a universal Apple Silicon/Intel **DMG, PKG and app ZIP**, with installation notes, release metadata and SHA-256 checksums. The PKG has native welcome/completion pages; the DMG includes an Applications shortcut. Both include the optional charging helper inside Cell.app.

By default these are explicitly marked **unsigned prereleases**. Configure your own Developer ID certificates and notarization credentials to produce signed, notarized stable releases. See [Releasing Cell](docs/RELEASING.md) for tag commands, required GitHub secrets, manual build-only runs and local packaging (`make release VERSION=1.2.0`). No version tag is created automatically.

The app intentionally runs without App Sandbox because system/process visibility is limited in sandboxed apps. Test Intel and Apple Silicon hardware, older supported macOS releases, permission denial, Focus, sleep/wake and actual charge/discharge crossings before public distribution.

Platform references: [Apple IOPowerSources](https://developer.apple.com/documentation/iokit/iopowersources_h), [Apple notifications](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter).
