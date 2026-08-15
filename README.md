# apple-photos-sync

Pushes externally rendered JPEGs (Lightroom exports, say) back onto the **existing** Apple
Photos assets they came from, instead of importing them as duplicates.

It uses the same PhotoKit path as Photos' own editing extensions — `PHContentEditingInput` →
`PHContentEditingOutput` → `PHAssetChangeRequest` — so each render is attached as the asset's
**edited version**:

- the asset keeps its identity: capture date, albums, faces, favorites, memories, iCloud sync;
- the **original RAW stays in the library** and is what "Revert to Original" restores;
- the edit propagates to iPhone/iPad through iCloud Photos like any other edit.

One tradeoff, unavoidable through any public API: the adjustment data is this tool's, not
Apple's. Photos will therefore offer to revert/discard if you open one of these photos in its
own editor. Nothing is lost — the original is still there — but the edit is not re-editable
as Apple-native adjustments.

## Build

```bash
make
```

Produces `ApplePhotosSync.app` (ad-hoc signed) and leaves the `apple-photos-sync` wrapper script as the
entry point.

## Use

```bash
./apple-photos-sync --dry-run "/Users/peter/Desktop/Muir woods"
```

```
  FILE              CAPTURED             ASSET DATE           ACTION
  L1037323.jpg      2026-08-08 18:21:07  2026-08-08 18:21:07  WOULD UPDATE
  ...
  would act on: 22
```

Then drop `--dry-run` to write.

| flag | effect |
| --- | --- |
| `--dry-run`, `-n` | report matches, write nothing |
| `--force` | rewrite even when the asset already holds this exact render |
| `--revert` | revert the matched assets to their originals — the undo button |
| `--verbose`, `-v` | print each asset's local identifier |
| `--log <file>` | mirror output to a file |

Re-running is safe: each write records the render's SHA-256 in its adjustment data, so an
unchanged file reports `UP TO DATE` and is skipped unless you pass `--force`. `--dry-run`
performs the same check, so it reports what would actually change rather than assuming
every match needs a write.

## Matching

Match key is the **filename stem** (`L1037323.jpg` → asset with resource `L1037323.DNG` or
`L1037323.JPG`), corroborated by EXIF `DateTimeOriginal` against the asset's creation date.
A RAW+JPG pair imported together is one asset carrying both resources, so one stem finds it.

Files that match **zero** assets report `NOT FOUND`; files that match **several** assets whose
capture times are within 60s of each other report `AMBIGUOUS`. Neither is guessed at — both
are skipped and counted in the summary, and the exit code is non-zero.

The capture-date check uses a deliberately wide ±26h window, because camera clocks are
routinely set to the wrong timezone. It is a sanity check, not the key; a match outside the
window is flagged in the output rather than rejected.

## Photos permission

The wrapper launches the app via `open -a` rather than executing the binary directly. This is
deliberate: TCC judges a directly-executed CLI by whatever process started the shell, which
usually means an instant denial with no prompt. Going through `open` makes launchd the parent,
so macOS evaluates the app on its own bundle identity (`com.ondruska.apple-photos-sync`) and can show
the permission dialog. Grant **full** Photos access — limited access is not enough.

If access ever gets stuck denied:

```bash
tccutil reset Photos com.ondruska.apple-photos-sync
```

`make` changes the binary's code hash, which can invalidate the grant and cause a fresh prompt
on the next run. That's expected.

PhotoKit writes to the **System Photo Library** — the one Photos.app opens by default.

## Undo

```bash
./apple-photos-sync --revert "/Users/peter/Desktop/Muir woods"
```

Equivalent to selecting the photos in Photos.app and choosing *Image → Revert to Original*.
It is a real undo, but it is not a backup — take a Time Machine snapshot before a large batch.
