# Storage and recovery

CPaste 0.5 preserves the legacy flat history fields and keeps the complete text in `ClipboardItem.text` in memory. Text bodies larger than 65,536 UTF-8 bytes are stored in `Text/<sha256>.txt`. Their index record contains an empty `text` field and a `textStorage` object with `filename`, `sha256`, and `byteCount`. Loading validates the referenced regular file, byte count, SHA-256, and UTF-8 before exposing a history version as valid.

Short text, IDs, content hashes, pin state, source metadata, timestamps, file URLs, and attachment names retain their existing meaning. Preview limits affect rendering only. Full-text search, copy, paste, and drag out continue to use the entire original text.

## Writes and migration

UI mutations publish the new items and a monotonically increasing revision, then enqueue a copy-on-write snapshot. A serial worker merges pending snapshots and persists body files before publishing the new index atomically. `ClipboardStore.save()` is an explicit synchronous durability barrier; normal quit calls it and remains open if saving fails.

Capture reads an immutable native pasteboard snapshot on the main thread and validates its generation before accepting it. Image validation/conversion, hashing and attachment staging then run off the main thread. Valid PNG representations retain their complete original bytes. A single accepted capture and a latest unread generation bound the capture queue. Once a stable snapshot has been accepted, a later copy does not revoke it; pause, stop and exact self-copy suppression can still cancel work before its main-thread decision.

Staged attachments have independent leases until they are committed or discarded. Garbage collection protects these leases and the complete live in-memory snapshot even if an index save fails. Captures preserve their observed time, so a late worker cannot move an older capture ahead of a newer explicit copy or roll back a newer duplicate's metadata.

Normal quit uses an asynchronous capture drain before the synchronous save barrier. A store save cannot report success while an asynchronous attachment insertion still needs its main-thread decision; callers must drain the monitor to include decoding work as well. Pause or restart does not delete an already accepted failed payload handed to the store for retry.

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

## Safe retry

Settings > Privacy exposes **Retry Saving**, **Open Folder**, and, when available, **View Copy**. Retry first drains accepted capture work. The explicit retry transaction rechecks directory protection and current disk history without requiring a successful save first. It can resume writing against the known disk baseline and replay accepted captures whose attachments previously failed to stage.

When history was initially unreadable, newly readable disk records and compatible new in-memory captures can be recovered together without trimming to capacity. Independently changed valid history that differs from a known baseline is treated as a conflict. The external primary and current memory remain unchanged, and a private recovery checkpoint contains full inline text plus attachment dependencies. If the checkpoint cannot be safely saved and verified, the app reports that the records remain in memory and keeps replacement writes blocked.

Every queued persistence report carries its originating operation epoch. A later capture failure or retry supersedes old successful and failed reports, so a delayed completion cannot clear a newer storage problem. Saving and retrying cannot claim success while an accepted failed payload remains unrecovered.

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
