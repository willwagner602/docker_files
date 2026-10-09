# Backblaze report formats (local validation)

Inspected read-only under the configured Backblaze data directory. Raw paths, identifiers, account values, and file contents are intentionally omitted.

## `bzfilelists/*_filelist.dat`

- UTF-8-compatible text observed; records are newline-delimited.
- Header/comment lines include:
  - `# GmtMillisThisListWasStarted: <decimal/hex-like value>, GmtDateTime: <YYYYMMDDhhmmss>`
  - `# Dir: <path>`
  - `# Files: <decimal count>`
- An `f` record is exactly 4 tab-separated fields in the observed files:
  1. literal `f`
  2. 16 lowercase hexadecimal characters (file identifier)
  3. decimal file size (variable width)
  4. source path (variable width; sensitive)
- Example shape: `f\t<16-hex-id>\t<decimal-size>\t<PATH>`.
- The two observed volumes had 406 and 19 lines respectively; this includes comments/directories, not just `f` records.

## Selection flags and scan metadata

Selection state was found in report testimony artifacts, not in the filelist records:

- `bzreports/bzhost_testimony_x.xml`: repeated attributes `selected_for_backup=<value>` and `vol_is_included_in_backup=<value>` (the XML contains volume/selection records; values are redacted here).
- `bzreports/bzhost_testimony_i.txt`: corresponding text representation with the same two key/value names.
- `bzfilelists/filestats.xml` has `<progress good_for_installer="true" totally_final="true"/>` and an `<info ... datetime="<YYYYMMDDhhmmss>" .../>` summary. It is scan-summary metadata, not a per-run completion token.
- `bzfilelists/topdirs.xml` has `<stats gmt_datetime="<YYYYMMDDhhmmss>" gmt_millis="<value>" millis_to_produce="<decimal>" next_to_index="<decimal>" num_times_mount_points_verified="<decimal>" numtopdirs="<decimal>"/>`.
- `bzfilelists/firstfilescantime.xml` has `<stat install_fscan_numsecs="0"/>`; this is an install/first-scan duration field, not a current scan timestamp.

## Last-files-transmitted XML

`bzlogs/bzreports_lastfilestransmitted/` contains per-volume XML plus an aggregate XML. Root is `<contents>`, with child `<lastfile_transmitted>`.

- Aggregate attributes: `filename`, `gmt_date`, `gmt_millis`, `kBitsPerSec_of_lastActualTransmission`.
- Per-volume adds `gmt_date_that_per_vol_filelist_was_generated` and `gmt_millis_that_per_vol_filelist_was_generated`.
- `gmt_date*` values are 14-digit `YYYYMMDDhhmmss`; `gmt_millis*` are decimal millisecond timestamps (the per-volume generated-millis field was observed as a 16-character value). Filename values are sensitive and omitted.
- These identify the latest transmitted file/list timing, not a complete backup-run boundary.

## Transmit completion evidence

- `bzreports/bztrack_bztransmit_lastrun.txt` is one newline-delimited compact timestamp-like token (14 characters observed).
- `bzreports/bztrack_bztransmit64.txt` is one line like `yes_win64_<date-token>`.
- `bzlogs/bztransmit/bztransmit09.log` contains timestamped process events. Observed success/completion wording includes `Leaving DoHttpPostSyncHostInfo ... after a successful run`, successful list-loading messages, and `Finished C reading ... bz_done_ files`. These are process/event evidence, not a single canonical end-of-backup marker.
- Datacenter `bz_done_<date>_0.dat` records are 14 tab-separated fields in the observed files. `bz_todo_<date>_0.dat` records are 6 tab-separated fields. Their timestamps and transfer identifiers can support event ordering but were not treated as a run ID.

## Correlation limits

The local artifacts expose overlapping timestamps (filelist generation, latest-file transmission, transmit process events, and datacenter completion records), but no validated shared run identifier linking all of them. A parser should therefore report independent timestamps/events and avoid asserting that a latest-files-transmitted XML record, a `bztransmit` successful process event, and a scan completion belong to one run unless additional evidence is available.
