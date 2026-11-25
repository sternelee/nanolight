# File search: the engine, and where it can go

Nanolight finds files by name in the launcher itself. This note is the
research behind the engine it uses now (Spotlight, on the Mac), the
alternatives weighed for Windows and Linux, and the shape the seam takes
when one of them is added.

## What it does now

- `src/files.zig` asks **Spotlight** through `/usr/bin/mdfind`, one
  `kMDItemFSName` predicate per tier, and merges the answers into five rows.
  Spotlight owns the index; Nanolight reads paths and names, nothing else.
- `src/files_scope.zig` is the set of folders it may look in: home-relative
  or absolute paths, eight at most, kept in the app's kv
  (`nanolight.files.locations`).
- `src/files_scope_view.zig` draws those folders as chips in the welcome's
  file step and on Settings' **Search Files In** page, with the system's
  folder picker behind `+ Add Folder…` (`nanoui.dialog.open`,
  `directories = true, multiple = true`). Both grow with the chips: three a
  row, eight at most.
- The switch is `nanolight.files`; off by default, on for a fresh install's
  welcome, and always scoped: no folders means no file rows rather than the
  whole disk.
- Skipping the welcome before its file step puts the switch and folders back
  as they were: the run's default is for the step, not for the session.
- Paths typed in full (`~/Desktop/`, `/Volumes/…`) list a folder's children
  without any index at all (`files.complete`), bounded at 2048 entries and
  five rows.

Tiers, best first: exact name, prefix, word start, letters in order
(subsequence). Each tier is its own `mdfind` run; all four share a
two-second wall-clock deadline, 256 paths and 1 MiB of output, and the
first rows that rank highest win. Results are filtered by
`files.excluded` (the home `Library`, `node_modules`, `.git`, `.Trash`,
caches, plus the user's own exclusions) before they are ranked.

## What the engine must fit

| Requirement | Why |
| --- | --- |
| No daemon, no database of ours | Nanolight ships as one ~2 MB binary; nothing to migrate, nothing to corrupt |
| Nothing polls | An idle launcher draws no frames and does no work |
| Off the main thread | Each keystroke must not wait on disk or a subprocess |
| Headless-testable | `zig build test` runs with no windows, on macOS and Linux containers |
| Cross-builds | `-Dtarget=x86_64-windows-gnu` and `-Dtarget=x86_64-linux-gnu` from any machine |
| Scoped | Only the folders chosen; privacy is the product's promise |

## The options, per platform

### macOS — Spotlight (chosen)

- `mdfind` with `-onlyin` per folder: what ships today. Zero index cost,
  covers `~/Desktop`, `~/Documents`, `~/Downloads` and anything else
  indexed; around 30–150 ms per query.
- `NSMetadataQuery`: the same index, in-process and asynchronous, no
  subprocess per keystroke. Worth doing if the spawn cost ever shows; it
  does not today because lookups run only after the typing pause.
- Building our own index (FSEvents + an on-disk b-tree): brings Spotlight's
  coverage problems along anyway (privacy exclusions are the user's, not
  ours) and adds the one thing this app avoids, state on disk.

### Windows — no index is guaranteed

- **Everything** ([voidtools](https://www.voidtools.com/support/everything/sdk/ipc)):
  filename search over the NTFS USN journal, effectively instant. Usable
  only when it is installed (its IPC, or the `es.exe` CLI), so it is an
  accelerator, never a requirement.
- **USN journal directly**: `FSCTL_ENUM_USN_DATA` for the whole volume's
  names, then `FSCTL_READ_USN_JOURNAL` to follow changes — this is how
  Everything is fast. Both need a volume handle with read access, which a
  plain user process does not have; the usual answer is a small service,
  which Nanolight will not install.
- **Windows Search** (`Search.CollatorDSO` over OLE DB): the OS index, no
  scanning; but it only covers the locations the user let Windows index,
  needs the service running, and talking OLE DB from Zig is a lot of COM
  for a feature that may return nothing.
- **A bounded walk** of the chosen folders, on a worker thread, with
  `ReadDirectoryChangesW` keeping it fresh: predictable, no privilege, no
  service. Tens of thousands of files are fine; millions are not.

### Linux — depends on the distribution

- **plocate** (`/var/lib/plocate/plocate.db`, `locate -i -b -l 256`):
  milliseconds, a drop-in `mlocate` successor, the default on Fedora,
  Debian/Ubuntu and Arch when `locate` is installed at all. The database is
  refreshed by a systemd timer, usually daily, so brand-new files lag.
- **tracker3 / TinySPARQL**: GNOME's index, filename and content, queried
  over SPARQL. Heavy dependency, absent outside GNOME.
- **A bounded walk** of the chosen folders, as on Windows, with `inotify`
  or a rescan on panel open: the fallback that always works.

### Rejected outright

- **`fd` / `rg --files` per keystroke**: a full tree scan per query
  (100–300 ms on a large home, worse cold), plus a binary to ship. Fine as a
  command, wrong as an input method.
- **An embedded database (SQLite FTS, LMDB)**: a second thing to corrupt,
  migrate and explain; the platforms above already keep an index.

## The recommendation

**System index first, bounded walk as the fallback, one scope for both.**

1. On the Mac, Spotlight (as now).
2. On Windows, Everything's IPC when it answers, else the bounded walk of
   the chosen folders.
3. On Linux, plocate when its database exists, else the bounded walk.
4. The scope is the same everywhere: the folders chosen in the welcome and
   Settings, `~`-relative, capped at eight.

The seam is `files.available()` plus `files.find`, which take a scope and a
query and fill a `files.List`; everything above them (rows, icons, the
folder chips, what is kept) is platform-neutral already.

## When Windows and Linux are added

- `files.available()` becomes "an engine exists here"; the welcome's step
  and Settings' row then show it on those platforms too.
- `files_scope.zig` keeps POSIX paths only today: `normalized` takes `/…` or
  `~…`, `expand` splits on `/`, and `files.find` hands `/`-rooted folders to
  `mdfind -onlyin`. Windows needs all three widened (`C:\…`, folding
  `%USERPROFILE%` into `~`, and a backend that takes paths instead of
  `mdfind` arguments).
- `files.find` gains a per-platform backend behind the same signature; the
  bounded walk is written once and used by both.
- Windows' folder picker is the gap: nanoui 0.12.0's Windows dialog is the
  old `GetOpenFileNameW`, which cannot choose folders. Either upgrade
  nanoui to a build whose Windows dialog uses `IFileOpenDialog` with
  `FOS_PICKFOLDERS`, or write that dialog here.
- `files.excluded` needs a per-platform list of never-search folders
  (`AppData`, `$Recycle.Bin`, `/proc`, `/sys`, `~/.cache`, …).

## Testing

- `src/tests_files.zig`: tiers, dedup, icon ownership, the paused/filtered
  handoff between queries, the home `Library` exclusions.
- `src/files_scope.zig`, `src/files_scope_view.zig`: scope parsing and
  bounds, home-relative folding, chip geometry.
- `src/tests.zig`: the welcome's file step (toggle, picker, ⌘O, what is
  kept, eight folders and no folders) and the step count.
- `src/tests_prefs.zig`: Settings still fits the panel, and its folders page
  holds eight chips without clipping.
