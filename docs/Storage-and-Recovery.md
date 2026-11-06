# Storage and recovery

CPaste 0.5 preserves the legacy flat history fields and keeps the complete text in `ClipboardItem.text` in memory. Text bodies larger than 65,536 UTF-8 bytes are stored in `Text/<sha256>.txt`. Their index record contains an empty `text` field and a `textStorage` object with `filename`, `sha256`, and `byteCount`. Loading validates the referenced regular file, byte count, SHA-256, and UTF-8 before exposing a history version as valid.

Short text, IDs, content hashes, pin state, source metadata, timestamps, file URLs, and attachment names retain their existing meaning. Preview limits affect rendering only. Full-text search, copy, paste, and drag out continue to use the entire original text.

## Writes and migration

UI mutations publish the new items and a monotonically increasing revision, then enqueue a copy-on-write snapshot. A serial worker merges pending snapshots and persists body files before publishing the new index atomically. `ClipboardStore.save()` is an explicit synchronous durability barrier; normal quit calls it and remains open if saving fails.

Legacy arrays load without trimming or changing metadata. Migration retains the original legacy index, creates the separate bodies, and publishes the smaller index only after its dependencies are present. Repeated saves do not repeat the migration or rotate unchanged indexes.

| Path | Purpose |
| --- | --- |
| `history.json` | Current index |
| `history.backup.json` | Previous valid index |
| `history.legacy-backup.json` | Original index retained when migrating large inline text |
| `Text/*.txt` | Complete UTF-8 text bodies |
| `Blobs/*` | PNG images and captured PDF files |
| `Recovery/*.json` | Preserved invalid index bytes |

Directories use owner-only `0700` permissions and files use `0600`. Index references must be local filenames, and managed storage paths must not be symbolic links.

## Recovery

When loading the current index fails, CPaste preserves its bytes before replacement and tries a validated backup. If it cannot safely read or preserve the original, it blocks replacement writes and reports the storage problem. Missing or invalid text bodies invalidate that history version; they are never silently converted into empty text.

Attachment and body cleanup runs after a successful commit and retains files referenced by the current, backup, migration, and pending snapshots. If invalid indexes remain in `Recovery`, their potentially unknown dependencies are retained as well.

Backup rotation revalidates old snapshot dependencies, including bodies removed from the next snapshot. Recovery archives use a content-derived name and are verified before reuse, so repeated saves or restarts do not create duplicate copies of the same damaged index.

Back up or move the entire data directory. Older releases do not read separate text bodies; rolling back requires restoring the complete pre-upgrade backup. Clearing unpinned history removes those entries from the current history; retained recovery and backup files may still contain previous entries. To remove all local data, quit CPaste and remove the entire data directory.

## Background search

Nonempty queries run on a serial worker after an 80 ms input merge interval. Matching preserves case-insensitive substring semantics across full text, metadata, and file references. Empty queries apply only lightweight type and pin filters.

Each result belongs to both a query and a store revision. The view validates both before displaying rows or performing actions, including before its input change callback runs. New input, history mutations, cancellation, and hidden panels invalidate prior work. Results publish on the main thread.

## Verification

Run the core checks with `swift run CPasteCoreChecks`, or the full packaging gate with `./scripts/quality_gate.sh`. The checks cover legacy migration, full Unicode content, corruption protection, backup dependencies, ordered background saves, and stale search completion handling.

To verify a legacy data set without modifying it:

```sh
swift run CPasteCoreChecks --migration-source "/path/to/legacy/CPaste"
```

The command creates a disposable copy, migrates and reloads it, compares every history item and binary attachment, verifies that the source index is unchanged, and removes its temporary copy. Never commit real clipboard fixtures.
