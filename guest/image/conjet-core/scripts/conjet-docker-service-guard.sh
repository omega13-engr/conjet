#!/bin/sh
set -eu

RUN_DIR="${CONJET_RUN_DIR:-/run/conjet}"
LOG="${CONJET_DOCKER_SERVICE_GUARD_LOG:-${RUN_DIR}/docker-service-guard.log}"
DOCKER_DIR="${CONJET_DOCKER_DIR:-/var/lib/docker}"
CONTAINERS_DIR="${CONJET_DOCKER_CONTAINERS_DIR:-${DOCKER_DIR}/containers}"
CLEAN_MARKER="${CONJET_DOCKER_CLEAN_MARKER:-${DOCKER_DIR}/.conjet-clean-shutdown}"
REPAIR_REQUIRED_MARKER="${CONJET_DOCKER_REPAIR_REQUIRED_MARKER:-${RUN_DIR}/docker-metadata-repair-required}"
MODE="${1:-repair-if-required}"

mkdir -p "${RUN_DIR}"

log() {
    echo "conjet-docker-service-guard: $*"
}

emit() {
    action="$1"
    id="$2"
    reason="$3"
    backup="${4:-}"
    printf 'conjet-docker-metadata\t%s\t%s\t%s\t%s\n' "${action}" "${id}" "${reason}" "${backup}"
}

mark_start() {
    mkdir -p "${DOCKER_DIR}"
    if [ -f "${CLEAN_MARKER}" ]; then
        rm -f "${REPAIR_REQUIRED_MARKER}"
        log "previous Docker shutdown was clean"
    else
        : >"${REPAIR_REQUIRED_MARKER}"
        log "previous Docker shutdown was not clean; metadata consistency repair required"
    fi

    rm -f "${CLEAN_MARKER}"
    log "Docker state marked dirty for this VM session"
}

mark_stop() {
    mkdir -p "${DOCKER_DIR}"
    date -u +%Y-%m-%dT%H:%M:%SZ >"${CLEAN_MARKER}"
    rm -f "${REPAIR_REQUIRED_MARKER}"
    log "Docker state marked clean"
}

containerd_has_container_or_task() {
    id="$1"

    if ctr -n moby containers info "${id}" >/dev/null 2>&1; then
        return 0
    fi

    ctr -n moby tasks ls 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fx "${id}" >/dev/null 2>&1
}

repair_stale_metadata() {
    if [ ! -f "${REPAIR_REQUIRED_MARKER}" ]; then
        log "clean lifecycle marker present; skipping Docker metadata repair"
        return 0
    fi

    if [ ! -d "${CONTAINERS_DIR}" ]; then
        log "${CONTAINERS_DIR} is missing; nothing to repair"
        rm -f "${REPAIR_REQUIRED_MARKER}"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log "docker CLI is missing; skipping"
        return 0
    fi

    if ! command -v ctr >/dev/null 2>&1; then
        log "containerd CLI is missing; skipping"
        return 0
    fi

    candidate_file="$(mktemp)"
    repaired_file="$(mktemp)"
    trap 'rm -f "${candidate_file}" "${repaired_file}"' EXIT

    if ! docker ps -a --no-trunc --format '{{.ID}}' >"${candidate_file}" 2>/dev/null; then
        log "docker ps failed; keeping repair marker for next start"
        return 0
    fi

    if [ ! -s "${candidate_file}" ]; then
        log "no Docker metadata candidates"
        rm -f "${REPAIR_REQUIRED_MARKER}"
        return 0
    fi

    backup_base="${CONTAINERS_DIR}/.conjet-stale-backup/$(date -u +%Y%m%dT%H%M%SZ)"

    sort -u "${candidate_file}" | while IFS= read -r id; do
        [ -n "${id}" ] || continue
        case "${id}" in
            *[!0123456789abcdefABCDEF]*)
                emit skipped "${id}" invalid-container-id ""
                continue
                ;;
        esac

        if docker inspect "${id}" >/dev/null 2>&1; then
            emit healthy "${id}" inspect-ok ""
            continue
        fi

        if containerd_has_container_or_task "${id}"; then
            emit skipped "${id}" containerd-object-present ""
            continue
        fi

        dir="${CONTAINERS_DIR}/${id}"
        if [ ! -d "${dir}" ]; then
            emit skipped "${id}" docker-container-dir-missing ""
            continue
        fi

        mkdir -p "${backup_base}"
        backup="${backup_base}/${id}.tgz"
        tar -czf "${backup}" -C "${CONTAINERS_DIR}" "${id}"
        rm -rf "${dir}"
        printf '.\n' >>"${repaired_file}"
        emit repaired "${id}" backed-up-and-removed-stale-docker-metadata "${backup}"
    done

    repaired="$(wc -l <"${repaired_file}" | tr -d ' ')"
    rm -f "${REPAIR_REQUIRED_MARKER}"
    if [ "${repaired}" -gt 0 ]; then
        log "repaired ${repaired} stale Docker metadata record(s)"
        return 2
    fi

    log "Docker metadata consistency verified"
    return 0
}

{
    log "start mode=${MODE}"
    case "${MODE}" in
        mark-start)
            mark_start
            ;;
        mark-stop)
            mark_stop
            ;;
        repair-if-required)
            set +e
            repair_stale_metadata
            status="$?"
            set -e
            if [ "${status}" -eq 2 ]; then
                log "restarting Docker so repaired metadata is reloaded"
                systemctl restart docker.service
                log "Docker restarted"
                exit 0
            fi
            exit "${status}"
            ;;
        repair-before-stop)
            : >"${REPAIR_REQUIRED_MARKER}"
            repair_stale_metadata || true
            ;;
        *)
            log "unknown mode=${MODE}"
            exit 64
            ;;
    esac
} >>"${LOG}" 2>&1
