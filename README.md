# hpss-backup

A small wrapper around `htar` and `hsi` for archiving directories to HPSS
(High Performance Storage System) and restoring them later.

## Requirements

- Access to an HPSS system with `htar` and `hsi` on `$PATH`
- Optionally, an environment module that provides them (configured via `HPSS_MODULE`)
- `kinit` if you plan to authenticate via a Kerberos keytab

## Configuration

Defaults are read from `~/.hpss_backuprc`. At minimum it should define the
HPSS path where archives live:

```sh
HPSS_BACKUP_DIR=/hpss/path/to/backups
HPSS_MODULE=hpss                         # optional: `module add` this before running
HPSS_KEYTAB=/path/to/user.keytab         # optional
HPSS_PRINCIPAL=user@REALM                # required if HPSS_KEYTAB is set
```

If `HPSS_MODULE` is set, the script runs `module add "$HPSS_MODULE"` after
loading the rc file. Leave it unset on systems where `htar`/`hsi` are already
on `$PATH`.

Any of these may be overridden on the command line — see `-h`.

## Usage

```
hpss-backup.sh [options] <command> [args]

All HPSS paths (hpss_subdir, archive_name) are relative to $HPSS_BACKUP_DIR.
Absolute paths on the HPSS side are not allowed.

Commands:
  backup <local_src> [hpss_subdir] Archive a local directory to HPSS
                                   (hpss_subdir is relative to $HPSS_BACKUP_DIR)
  list [hsi_ls_opts...]            List archives in $HPSS_BACKUP_DIR. Extra args
                                   are passed through to `hsi ls`. With no args,
                                   defaults to `-l` filtered to *.tar.
  restore <archive_name> [dest]    Restore an archive from HPSS
                                   (dest default: ./<archive_name>/)
  rm <archive_name>                Remove an archive from HPSS

Options:
  -t DIR        HPSS backup directory      (default: $HPSS_BACKUP_DIR)
  -k KEYTAB     Kerberos keytab file       (default: $HPSS_KEYTAB)
  -p PRINCIPAL  Kerberos principal         (default: $HPSS_PRINCIPAL)
  -h            Show help
```

### Examples

```sh
# Archive a directory to HPSS — archive name is <dirname>_<YYYYMMDD_HHMMSS>.tar
hpss-backup.sh backup /data/myproject

# Archive into a subdirectory under $HPSS_BACKUP_DIR
hpss-backup.sh backup /data/myproject archives/2026

# List archives on HPSS
hpss-backup.sh list

# Pass any hsi ls options through (-a, -j, -R, -T c, etc.)
hpss-backup.sh list -la
hpss-backup.sh list -j

# Restore an archive into ./myproject_20260422_120000/
hpss-backup.sh restore myproject_20260422_120000.tar

# Restore into an explicit local directory (created if needed)
hpss-backup.sh restore myproject_20260422_120000.tar /tmp/restore

# Remove an archive from HPSS
hpss-backup.sh rm myproject_20260422_120000.tar
```

## Notes

- Backups are written with `htar -H crc:verify=all`, so CRCs are verified on write.
- If `HPSS_KEYTAB` is configured, the script runs `kinit -kt` before any HPSS
  operation; otherwise it relies on an existing Kerberos ticket.
- All HPSS-side paths are interpreted relative to `$HPSS_BACKUP_DIR`. Absolute
  paths (anything starting with `/`) are rejected — `$HPSS_BACKUP_DIR` is the
  only root.
