#!/usr/bin/env bash
# =============================================================================
# CDC Pipeline Stress Test
# =============================================================================
# Runs progressively larger INSERT waves against PostgreSQL and MongoDB,
# measures end-to-end latency (source DB → ClickHouse silver table), and
# records system health at each step.
#
# Usage:  bash scripts/stress_test.sh [pg|mongo|both]
#         Default: both
#
# Output: scripts/stress_test_output.log  (raw log)
#         Results are printed as a table to stdout for pasting into
#         docs/phase5-stress-test-results.md
# =============================================================================

set -euo pipefail

# Prevent Git-for-Windows from mangling /paths inside kubectl exec
export MSYS_NO_PATHCONV=1

MODE="${1:-both}"
LOGFILE="scripts/stress_test_output.log"

# -- Wave sizes (see methodology doc for rationale) --
WAVES=(1 10 100 500 2048 5000 10000 25000)

# -- Timeouts --
POLL_INTERVAL=2        # seconds between ClickHouse count polls
MAX_WAIT=120           # seconds before declaring TIMEOUT
STABILIZE_WAIT=30      # seconds between waves

# -- Pod names (resolved dynamically) --
KAFKA_POD="my-cluster-my-pool-0"
CH_POD="chi-chi-clickhouse-my-cluster-0-0-0"

# -- Namespaces --
NS_KAFKA="kafka"
NS_DB="database"

# Resolve Deployment-managed pod names via label selector
resolve_pod() {
    kubectl get pod -n "$1" -l "$2" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

PG_POD=""
MONGO_POD=""

# =============================================================================
# Helpers
# =============================================================================

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

ch_query() {
    kubectl exec -n "$NS_DB" "$CH_POD" -- \
        clickhouse-client --user default --password "" --query "$1" 2>/dev/null
}

ch_count() {
    ch_query "SELECT count() FROM $1" | tr -d '[:space:]'
}

check_broker() {
    local status restarts
    status=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    restarts=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    echo "${status}(restarts=${restarts})"
}

check_connectors() {
    local pg_state mongo_state
    pg_state=$(kubectl exec -n "$NS_KAFKA" my-connect-cluster-connect-0 -- \
        curl -s http://localhost:8083/connectors/postgres-connector/status 2>/dev/null \
        | grep -o '"state":"[A-Z]*"' | tail -1 | grep -o '[A-Z]*' || echo "?")
    mongo_state=$(kubectl exec -n "$NS_KAFKA" my-connect-cluster-connect-0 -- \
        curl -s http://localhost:8083/connectors/mongo-connector/status 2>/dev/null \
        | grep -o '"state":"[A-Z]*"' | tail -1 | grep -o '[A-Z]*' || echo "?")
    echo "pg=${pg_state} mongo=${mongo_state}"
}

# Wait for ClickHouse row count to reach target, return elapsed seconds or TIMEOUT
wait_for_count() {
    local table="$1"
    local target="$2"
    local elapsed=0
    while (( elapsed < MAX_WAIT )); do
        local current
        current=$(ch_count "$table")
        if (( current >= target )); then
            echo "$elapsed"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$(( elapsed + POLL_INTERVAL ))
    done
    echo "TIMEOUT"
    return 1
}

print_header() {
    printf "| %-5s | %-8s | %-16s | %-19s | %-22s | %-22s | %-30s |\n" \
        "Wave" "Rows" "e2e Latency (s)" "Throughput (rows/s)" "Broker Status" "Connect Status" "Notes"
    printf "|-------|----------|-----------------|---------------------|------------------------|------------------------|--------------------------------|\n"
}

print_row() {
    local wave="$1" rows="$2" latency="$3" throughput="$4" broker="$5" connect="$6" notes="$7"
    printf "| %-5s | %-8s | %-15s | %-19s | %-22s | %-22s | %-30s |\n" \
        "$wave" "$rows" "$latency" "$throughput" "$broker" "$connect" "$notes"
}

# =============================================================================
# PostgreSQL stress test
# =============================================================================

run_pg_waves() {
    log "========== PostgreSQL Stress Test =========="
    log ""
    print_header | tee -a "$LOGFILE"

    local broker_restarts_before
    broker_restarts_before=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

    local wave_num=0
    for n in "${WAVES[@]}"; do
        wave_num=$(( wave_num + 1 ))

        # Pre-wave: get current count
        local count_before
        count_before=$(ch_count "users_silver")
        local target=$(( count_before + n ))

        log "Wave $wave_num: inserting $n rows into PostgreSQL (current: $count_before, target: $target)"

        # Record start time
        local t_start
        t_start=$(date +%s)

        # INSERT N rows
        kubectl exec -n "$NS_DB" "$PG_POD" -- \
            psql -U postgres -d postgres -q -c \
            "INSERT INTO users (full_name, email) SELECT 'StressUser_' || g, 'stress_w${wave_num}_' || g || '@test.com' FROM generate_series(1, $n) AS g;" \
            2>/dev/null

        # Wait for rows to appear in ClickHouse
        local latency
        latency=$(wait_for_count "users_silver" "$target") || true

        # Calculate throughput
        local throughput="—"
        if [[ "$latency" != "TIMEOUT" && "$latency" -gt 0 ]]; then
            if command -v bc &>/dev/null; then
                throughput=$(echo "scale=1; $n / $latency" | bc)
            else
                throughput=$(( n / latency ))
            fi
        elif [[ "$latency" == "0" ]]; then
            throughput="instant"
        fi

        # Check system health
        local broker connect notes=""
        broker=$(check_broker)
        connect=$(check_connectors)

        # Check for broker restarts during this wave
        local restarts_now
        restarts_now=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        if (( restarts_now > broker_restarts_before )); then
            notes="BROKER RESTARTED"
        fi

        if [[ "$latency" == "TIMEOUT" ]]; then
            local actual_count
            actual_count=$(ch_count "users_silver")
            notes="TIMEOUT (got $actual_count/$target)"
        fi

        print_row "$wave_num" "$n" "$latency" "$throughput" "$broker" "$connect" "$notes" | tee -a "$LOGFILE"

        # If timeout or broker crashed, stop
        if [[ "$latency" == "TIMEOUT" ]]; then
            log "*** BREAKING POINT REACHED at wave $wave_num ($n rows) ***"
            break
        fi

        if [[ "$broker" == *"CrashLoopBackOff"* || "$broker" == *"Error"* ]]; then
            log "*** BROKER CRASHED at wave $wave_num ($n rows) ***"
            break
        fi

        broker_restarts_before="$restarts_now"

        # Stabilize between waves
        if (( wave_num < ${#WAVES[@]} )); then
            log "Waiting ${STABILIZE_WAIT}s for system to stabilize..."
            sleep "$STABILIZE_WAIT"
        fi
    done

    log ""
}

# =============================================================================
# MongoDB stress test
# =============================================================================

run_mongo_waves() {
    log "========== MongoDB Stress Test =========="
    log ""
    print_header | tee -a "$LOGFILE"

    # Get number of users for user_id distribution
    local num_users
    num_users=$(ch_count "users_silver")
    if (( num_users < 1 )); then num_users=4; fi

    local broker_restarts_before
    broker_restarts_before=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

    local wave_num=0
    for n in "${WAVES[@]}"; do
        wave_num=$(( wave_num + 1 ))

        # Pre-wave: get current count
        local count_before
        count_before=$(ch_count "events_silver")
        local target=$(( count_before + n ))

        log "Wave $wave_num: inserting $n docs into MongoDB (current: $count_before, target: $target)"

        # Record start time
        local t_start
        t_start=$(date +%s)

        # Build JS for insertMany
        local js_script
        js_script=$(cat <<MONGOSCRIPT
var docs = [];
for (var i = 0; i < $n; i++) {
    docs.push({
        user_id: (i % $num_users) + 1,
        event_type: "stress_test",
        ts: new Date(),
        metadata: { wave: $wave_num, seq: i }
    });
}
db.events.insertMany(docs);
print("inserted " + docs.length + " docs");
MONGOSCRIPT
)

        kubectl exec -n "$NS_DB" "$MONGO_POD" -- mongosh \
            "mongodb://root:rootpassword@localhost:27017/commerce?authSource=admin&replicaSet=rs0" \
            --quiet --eval "$js_script" 2>/dev/null || true

        # Wait for rows to appear in ClickHouse
        local latency
        latency=$(wait_for_count "events_silver" "$target") || true

        # Calculate throughput
        local throughput="—"
        if [[ "$latency" != "TIMEOUT" && "$latency" -gt 0 ]]; then
            if command -v bc &>/dev/null; then
                throughput=$(echo "scale=1; $n / $latency" | bc)
            else
                throughput=$(( n / latency ))
            fi
        elif [[ "$latency" == "0" ]]; then
            throughput="instant"
        fi

        # Check system health
        local broker connect notes=""
        broker=$(check_broker)
        connect=$(check_connectors)

        # Check for broker restarts during this wave
        local restarts_now
        restarts_now=$(kubectl get pod -n "$NS_KAFKA" "$KAFKA_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        if (( restarts_now > broker_restarts_before )); then
            notes="BROKER RESTARTED"
        fi

        if [[ "$latency" == "TIMEOUT" ]]; then
            local actual_count
            actual_count=$(ch_count "events_silver")
            notes="TIMEOUT (got $actual_count/$target)"
        fi

        print_row "$wave_num" "$n" "$latency" "$throughput" "$broker" "$connect" "$notes" | tee -a "$LOGFILE"

        # If timeout or broker crashed, stop
        if [[ "$latency" == "TIMEOUT" ]]; then
            log "*** BREAKING POINT REACHED at wave $wave_num ($n rows) ***"
            break
        fi

        if [[ "$broker" == *"CrashLoopBackOff"* || "$broker" == *"Error"* ]]; then
            log "*** BROKER CRASHED at wave $wave_num ($n rows) ***"
            break
        fi

        broker_restarts_before="$restarts_now"

        # Stabilize between waves
        if (( wave_num < ${#WAVES[@]} )); then
            log "Waiting ${STABILIZE_WAIT}s for system to stabilize..."
            sleep "$STABILIZE_WAIT"
        fi
    done

    log ""
}

# =============================================================================
# Pre-test checks
# =============================================================================

preflight() {
    log "========== Pre-Test Checks =========="

    # Resolve dynamic pod names
    PG_POD=$(resolve_pod "$NS_DB" "app=postgres")
    MONGO_POD=$(resolve_pod "$NS_DB" "app=mongo")

    if [[ -z "$PG_POD" ]]; then
        log "ERROR: Could not find PostgreSQL pod"
        exit 1
    fi
    if [[ -z "$MONGO_POD" ]]; then
        log "ERROR: Could not find MongoDB pod"
        exit 1
    fi

    log "Resolved pods: PG=$PG_POD  MONGO=$MONGO_POD"

    log "Checking pod status..."
    kubectl get pods -n "$NS_KAFKA" 2>/dev/null | tee -a "$LOGFILE"
    kubectl get pods -n "$NS_DB" 2>/dev/null | tee -a "$LOGFILE"

    log "Connector status (via REST API):"
    log "  $(check_connectors)"

    log "Silver table baseline counts:"
    log "  users_silver:  $(ch_count users_silver)"
    log "  events_silver: $(ch_count events_silver)"

    log ""
}

# =============================================================================
# Main
# =============================================================================

: > "$LOGFILE"  # truncate log file
log "CDC Pipeline Stress Test — $(date)"
log "Mode: $MODE"
log ""

preflight

case "$MODE" in
    pg)    run_pg_waves ;;
    mongo) run_mongo_waves ;;
    both)  run_pg_waves; run_mongo_waves ;;
    *)     echo "Usage: $0 [pg|mongo|both]"; exit 1 ;;
esac

log "========== Stress Test Complete =========="
log "Raw log saved to: $LOGFILE"
log "Copy the tables above into docs/phase5-stress-test-results.md"