#!/bin/bash
#
# hpss-backup.sh - Backup and restore directories to/from HPSS using htar
#

RC_FILE="$HOME/.hpss_backuprc"

# Load defaults from RC file
if [[ -f "$RC_FILE" ]]; then
    source "$RC_FILE"
else
    echo "Warning: RC file not found at $RC_FILE" >&2
    echo "Create it with at minimum: HPSS_BACKUP_DIR=/path/on/hpss" >&2
fi

# Optionally load an environment module (e.g. HPSS_MODULE=hpss)
if [[ -n "${HPSS_MODULE:-}" ]]; then
    module add "$HPSS_MODULE"
fi

usage() {
    echo "Usage: $(basename "$0") [options] <command> [args]"
    echo
    echo "All HPSS paths (hpss_subdir, archive_name) are relative to \$HPSS_BACKUP_DIR."
    echo
    echo "Commands:"
    echo "  backup <local_src> [hpss_subdir] Archive a local directory to HPSS"
    echo "  list [hsi_ls_opts...]            List archives (default: -l, filtered to *.tar)"
    echo "  restore <archive_name> [dest]    Restore an archive from HPSS (dest default: ./<archive_name>/)"
    echo "  rm <archive_name>                Removes an archive file from HPSS"
    echo
    echo "Options:"
    echo "  -t DIR        HPSS backup directory (default: \$HPSS_BACKUP_DIR from $RC_FILE)"
    echo "  -k KEYTAB     Path to Kerberos keytab file (default: \$HPSS_KEYTAB from $RC_FILE)"
    echo "  -p PRINCIPAL  Kerberos principal (default: \$HPSS_PRINCIPAL from $RC_FILE)"
    echo "  -h            Show this help message"
    echo
    echo "Examples:"
    echo "  $(basename "$0") backup /data/myproject"
    echo "  $(basename "$0") backup /data/myproject archives/2026"
    echo "  $(basename "$0") list"
    echo "  $(basename "$0") list -la       # pass any hsi ls options through"
    echo "  $(basename "$0") restore myproject_20260422_120000.tar"
    echo "  $(basename "$0") restore myproject_20260422_120000.tar /tmp/restore"
    exit 1
}

# Parse options
TARGET_DIR="${HPSS_BACKUP_DIR:-}"
KEYTAB="${HPSS_KEYTAB:-}"
PRINCIPAL="${HPSS_PRINCIPAL:-}"

while getopts "t:k:p:h" opt; do
    case "$opt" in
        t) TARGET_DIR="$OPTARG" ;;
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

require_target_dir() {
    if [[ -z "$TARGET_DIR" ]]; then
        echo "Error: No HPSS backup directory specified." >&2
        echo "Set HPSS_BACKUP_DIR in $RC_FILE or use -t." >&2
        exit 1
    fi
}

case "$COMMAND" in
    backup)
        require_target_dir
        LOCAL_DIR="${1:?Missing local directory. See -h for usage.}"
        HPSS_SUBDIR="${2:-}"

        if [[ "$HPSS_SUBDIR" == /* ]]; then
            echo "Error: HPSS paths must be relative to \$HPSS_BACKUP_DIR ($TARGET_DIR)." >&2
            echo "       Got absolute path: $HPSS_SUBDIR" >&2
            exit 1
        fi

        if [[ ! -d "$LOCAL_DIR" ]]; then
            echo "Error: $LOCAL_DIR is not a directory." >&2
            exit 1
        fi

        DIR_NAME="$(basename $(abspath "$LOCAL_DIR"))"
        DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
        ARCHIVE_NAME="${DIR_NAME}_${DATE_STAMP}.tar"
        if [[ -n "$HPSS_SUBDIR" ]]; then
            HPSS_PATH="${TARGET_DIR}/${HPSS_SUBDIR}/${ARCHIVE_NAME}"
        else
            HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"
        fi

        echo "Backing up: $LOCAL_DIR"
        echo "       To: $HPSS_PATH"

        # htar can hang holding an open HPSS NDAPI session after a successful
        # verify. Watch its output for "Verify complete"; after a grace period,
        # SIGTERM the process and treat the kill as success.
        HTAR_LOG="$(mktemp -t hpss-backup.XXXXXX)"
        VERIFIED_FLAG="${HTAR_LOG}.verified"
        GRACE_SECONDS=120
        HTAR_PID=
        WATCHDOG_PID=

        cleanup() {
            if [[ -n "$WATCHDOG_PID" ]]; then
                kill "$WATCHDOG_PID" 2>/dev/null
                wait "$WATCHDOG_PID" 2>/dev/null
            fi
            if [[ -n "$HTAR_PID" ]] && kill -0 "$HTAR_PID" 2>/dev/null; then
                kill -TERM "$HTAR_PID" 2>/dev/null
                sleep 2
                kill -KILL "$HTAR_PID" 2>/dev/null
                wait "$HTAR_PID" 2>/dev/null
            fi
            rm -f "$HTAR_LOG" "$VERIFIED_FLAG"
        }
        trap cleanup EXIT INT TERM

        htar -cvf "$HPSS_PATH" -H crc:verify=all "$LOCAL_DIR" < /dev/null \
            > >(tee "$HTAR_LOG") 2>&1 &
        HTAR_PID=$!

        (
            while kill -0 "$HTAR_PID" 2>/dev/null; do
                if grep -q "Verify complete" "$HTAR_LOG" 2>/dev/null; then
                    sleep "$GRACE_SECONDS"
                    kill -0 "$HTAR_PID" 2>/dev/null || exit 0
                    touch "$VERIFIED_FLAG"
                    kill -TERM "$HTAR_PID" 2>/dev/null
                    sleep 5
                    kill -KILL "$HTAR_PID" 2>/dev/null
                    exit 0
                fi
                sleep 5
            done
        ) &
        WATCHDOG_PID=$!

        wait "$HTAR_PID"
        HTAR_RC=$?

        if [[ -f "$VERIFIED_FLAG" ]]; then
            echo "Backup complete (htar terminated ${GRACE_SECONDS}s after verify): $HPSS_PATH"
        elif [[ $HTAR_RC -eq 0 ]]; then
            echo "Backup complete: $HPSS_PATH"
        else
            echo "Error: htar failed." >&2
            exit 1
        fi
        ;;

    list)
        require_target_dir
        echo "Archives in: $TARGET_DIR"
        echo
        if [[ $# -gt 0 ]]; then
            # Caller passed hsi ls options — pass them through verbatim, no filtering
            hsi "ls $* $TARGET_DIR" 2>&1
        else
            hsi "ls -l $TARGET_DIR" 2>&1 | grep '\.tar'
        fi
        ;;

    rm)
        require_target_dir
        ARCHIVE_NAME="${1:?Missing archive name. Use 'list' to see available archives.}"

        if [[ "$ARCHIVE_NAME" == /* ]]; then
            echo "Error: HPSS paths must be relative to \$HPSS_BACKUP_DIR ($TARGET_DIR)." >&2
            echo "       Got absolute path: $ARCHIVE_NAME" >&2
            exit 1
        fi

        HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"

        echo "Removing: $HPSS_PATH"
        echo
        hsi " rm $HPSS_PATH" 2>&1
        ;;

    restore)
        require_target_dir
        ARCHIVE_NAME="${1:?Missing archive name. Use 'list' to see available archives.}"

        if [[ "$ARCHIVE_NAME" == /* ]]; then
            echo "Error: HPSS paths must be relative to \$HPSS_BACKUP_DIR ($TARGET_DIR)." >&2
            echo "       Got absolute path: $ARCHIVE_NAME" >&2
            exit 1
        fi

        HPSS_PATH="${TARGET_DIR}/${ARCHIVE_NAME}"

        # Default dest: ./<archive_basename_without_.tar>/
        if [[ -n "$2" ]]; then
            RESTORE_DIR="$2"
        else
            archive_base="$(basename "$ARCHIVE_NAME")"
            RESTORE_DIR="./${archive_base%.tar}"
        fi

        mkdir -p "$RESTORE_DIR" || exit 1

        echo "Restoring: $HPSS_PATH"
        echo "      To: $RESTORE_DIR"

        cd "$RESTORE_DIR" || exit 1
        htar -xvf "$HPSS_PATH" < /dev/null

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
