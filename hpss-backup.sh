#!/bin/bash
#
# hpss-backup.sh - Backup and restore directories to/from HPSS using htar
#

module add hpss

RC_FILE="$HOME/.hpss_backuprc"

# Load defaults from RC file
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Warning: RC file not found at $RC_FILE" >&2
    echo "Create it with at minimum: HPSS_BACKUP_DIR=/path/on/hpss" >&2
fi

usage() {
    echo "Usage: $(basename "$0") [options] <command> [args]"
    echo
    echo "Commands:"
    echo "  backup <local_directory>    Archive a local directory to HPSS"
    echo "  list                        List archives in the HPSS backup directory"
    echo "  restore <archive_name>      Restore an archive from HPSS"
    echo "  rm <archive_name>           Removes an archive file from HPSS"
    echo
    echo "Options:"
    echo "  -t DIR        HPSS backup directory (default: \$HPSS_BACKUP_DIR from $RC_FILE)"
    echo "  -r DIR        Local restore directory (default: \$HPSS_RESTORE_DIR from $RC_FILE)"
    echo "  -k KEYTAB     Path to Kerberos keytab file (default: \$HPSS_KEYTAB from $RC_FILE)"
    echo "  -p PRINCIPAL  Kerberos principal (default: \$HPSS_PRINCIPAL from $RC_FILE)"
    echo "  -h            Show this help message"
    echo
    echo "Examples:"
    echo "  $(basename "$0") backup /data/myproject"
    echo "  $(basename "$0") list"
    echo "  $(basename "$0") restore myproject_20260422_120000.tar"
    echo "  $(basename "$0") -r /tmp/restore restore myproject_20260422_120000.tar"
    exit 1
}

# Parse options
TARGET_DIR="${HPSS_BACKUP_DIR:-}"
RESTORE_DIR="${HPSS_RESTORE_DIR:-}"
KEYTAB="${HPSS_KEYTAB:-}"
PRINCIPAL="${HPSS_PRINCIPAL:-}"

while getopts "t:r:k:p:h" opt; do
    case "$opt" in
        t) TARGET_DIR="$OPTARG" ;;
        r) RESTORE_DIR="$OPTARG" ;;
        k) KEYTAB="$OPTARG" ;;
        p) PRINCIPAL="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

COMMAND="${1:-}"
shift 2>/dev/null

# Authenticate via keytab if configured
if [[ -n "$KEYTAB" ]]; then
    if [[ ! -f "$KEYTAB" ]]; then
        echo "Error: Keytab file not found: $KEYTAB" >&2
        exit 1
    fi
    if [[ -z "$PRINCIPAL" ]]; then
        echo "Error: Kerberos principal required when using a keytab." >&2
        echo "Set HPSS_PRINCIPAL in $RC_FILE or use -p." >&2
        exit 1
    fi
    echo "Authenticating as $PRINCIPAL using keytab..."
    kinit -kt "$KEYTAB" "$PRINCIPAL"
    if [[ $? -ne 0 ]]; then
        echo "Error: kinit failed." >&2
        exit 1
    fi
fi

if [[ -z "$TARGET_DIR" ]]; then
    echo "Error: No HPSS backup directory specified." >&2
    echo "Set HPSS_BACKUP_DIR in $RC_FILE or use -t." >&2
    exit 1
fi

case "$COMMAND" in
    backup)
        LOCAL_DIR="${1:?Missing local directory. See -h for usage.}"

        if [[ ! -d "$LOCAL_DIR" ]]; then
            echo "Error: $LOCAL_DIR is not a directory." >&2
            exit 1
        fi

        DIR_NAME="$(basename $(abspath "$LOCAL_DIR"))"
        DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
        ARCHIVE_NAME="${DIR_NAME}_${DATE_STAMP}.tar"
        HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"

        echo "Backing up: $LOCAL_DIR"
        echo "       To: $HPSS_PATH"

        htar -cvf "$HPSS_PATH" -H crc:verify=all "$LOCAL_DIR"

        if [[ $? -eq 0 ]]; then
            echo "Backup complete: $HPSS_PATH"
        else
            echo "Error: htar failed." >&2
            exit 1
        fi
        ;;

    list)
        echo "Archives in: $TARGET_DIR"
        echo
        hsi "ls -l $TARGET_DIR" 2>&1 | grep '\.tar'
        ;;

    rm)
        ARCHIVE_NAME="${1:?Missing archive name. Use 'list' to see available archives.}"

        # If it's not a full path, prepend the target dir
        if [[ "$ARCHIVE_NAME" != /* ]]; then
            HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"
        else
            HPSS_PATH="$ARCHIVE_NAME"
        fi

        echo "Removing: $HPSS_PATH"
        echo
        hsi " rm $HPSS_PATH" 2>&1
        ;;

    restore)
        ARCHIVE_NAME="${1:?Missing archive name. Use 'list' to see available archives.}"

        # If it's not a full path, prepend the target dir
        if [[ "$ARCHIVE_NAME" != /* ]]; then
            HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"
        else
            HPSS_PATH="$ARCHIVE_NAME"
        fi

        if [[ -z "$RESTORE_DIR" ]]; then
            echo "Error: No restore directory specified." >&2
            echo "Set HPSS_RESTORE_DIR in $RC_FILE or use -r." >&2
            exit 1
        fi

        if [[ ! -d "$RESTORE_DIR" ]]; then
            echo "Error: Restore directory does not exist: $RESTORE_DIR" >&2
            exit 1
        fi

        echo "Restoring: $HPSS_PATH"
        echo "      To: $RESTORE_DIR"

        cd "$RESTORE_DIR" || exit 1
        htar -xvf "$HPSS_PATH"

        if [[ $? -eq 0 ]]; then
            echo "Restore complete."
        else
            echo "Error: htar extract failed." >&2
            exit 1
        fi
        ;;

    *)
        echo "Error: Unknown command '$COMMAND'" >&2
        usage
        ;;
esac
