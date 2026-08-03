#!/usr/bin/env bash
set -euo pipefail

RECOVERY_POKE='[DING] unread st2 messages remain; check your inbox'

monotonic_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}

log_count() {
  local pattern="$1"
  awk -v pattern="$pattern" 'index($0, pattern) { count += 1 } END { print count + 0 }' \
    "$REPRO_ATTEMPT_LOG"
}

wait_for_count() {
  local pattern="$1"
  local minimum="$2"
  local timeout_ms="$3"
  local label="$4"
  local deadline=$(( $(monotonic_ms) + timeout_ms ))
  local count

  while true; do
    count="$(log_count "$pattern")"
    if (( count >= minimum )); then
      return 0
    fi
    if (( $(monotonic_ms) >= deadline )); then
      printf 'FAIL: collected %s %s; expected at least %s\n' "$count" "$label" "$minimum" >&2
      return 1
    fi
    sleep 0.05
  done
}

wait_for_counter() {
  local file="$1"
  local minimum="$2"
  local timeout_ms="$3"
  local label="$4"
  local deadline=$(( $(monotonic_ms) + timeout_ms ))
  local count

  while true; do
    count="$(read_counter "$file")"
    if (( count >= minimum )); then
      return 0
    fi
    if (( $(monotonic_ms) >= deadline )); then
      printf 'FAIL: collected %s %s; expected at least %s\n' "$count" "$label" "$minimum" >&2
      return 1
    fi
    sleep 0.05
  done
}

read_counter() {
  local file="$1"
  [[ -f "$file" ]] && tr -d '[:space:]' < "$file" || printf '0'
}

fixture_main() {
  local fixture_pid_file="$1"
  local acceptance_file="$2"
  local second_nonce="$3"
  local rule
  local input
  local notice
  local last_notice=""
  local acceptance_count=0
  rule="$(printf '─%.0s' {1..80})"

  render_idle() {
    printf '\033[2J\033[H%s\n%s\n❯\u00a0\n%s\n  ⏵⏵ bypass permissions on\nFIXTURE_STATE=IDLE\n' \
      'Synthetic provider fixture' "$rule" "$rule"
  }

  render_unproven() {
    printf '\033[2J\033[H%s\nFIXTURE_STATE=UNPROVEN\n' 'Synthetic provider fixture'
  }

  render_accepted() {
    local accepted_notice="$1"
    printf '\033[2J\033[H❯ %s\n%s\n❯\u00a0\n%s\n  ⏵⏵ bypass permissions on\nFIXTURE_STATE=ACCEPTED\n' \
      "$accepted_notice" "$rule" "$rule"
  }

  release_recovery() {
    [[ -n "$last_notice" ]] || return 0
    acceptance_count=$((acceptance_count + 1))
    printf '%s\n' "$acceptance_count" > "$acceptance_file"
    render_accepted "$last_notice"
  }

  printf '%s\n' "$$" > "$fixture_pid_file"
  printf '0\n' > "$acceptance_file"
  trap release_recovery USR1
  render_idle

  while true; do
    if ! IFS= read -r input; then
      continue
    fi
    notice="${input#$'\033[200~'}"
    notice="${notice%$'\033[201~'}"
    last_notice="$notice"
    if [[ "$notice" == "$RECOVERY_POKE" ]]; then
      render_unproven
    elif [[ "$notice" == *"$second_nonce"* ]]; then
      acceptance_count=$((acceptance_count + 1))
      printf '%s\n' "$acceptance_count" > "$acceptance_file"
      render_accepted "$notice"
    else
      render_unproven
    fi
  done
}

capture_pty_main() {
  local operation="${1:-unknown}"
  local started
  local status
  local kind="other"
  local has_return="no"
  local phase="setup"
  local output

  started="$(monotonic_ms)"
  [[ -f "$REPRO_PHASE_FILE" ]] && phase="$(<"$REPRO_PHASE_FILE")"
  if [[ "$*" == *"$RECOVERY_POKE"* ]]; then
    kind="recovery"
  elif [[ "$*" == *"$REPRO_SECOND_NONCE"* ]]; then
    kind="second"
  fi
  for argument in "$@"; do
    [[ "$argument" == "key:return" ]] && has_return="yes"
  done

  if [[ "$operation" == "send" ]]; then
    printf '%s op=send-start phase=%s kind=%s has_return=%s\n' \
      "$started" "$phase" "$kind" "$has_return" >> "$REPRO_ATTEMPT_LOG"
    set +e
    "$REPRO_REAL_PTY" "$@"
    status=$?
    set -e
    printf '%s op=send-end phase=%s status=%s kind=%s has_return=%s\n' \
      "$(monotonic_ms)" "$phase" "$status" "$kind" "$has_return" \
      >> "$REPRO_ATTEMPT_LOG"
    return "$status"
  fi

  if [[ "$operation" == "peek" ]]; then
    set +e
    output="$("$REPRO_REAL_PTY" "$@" 2>&1)"
    status=$?
    set -e
    if [[ "$phase" == "setup" && "$status" == 0 && \
      "$output" == *'FIXTURE_STATE=UNPROVEN'* ]] && \
      ( set -o noclobber; printf 'observed\n' > "$REPRO_INITIAL_RECEIPT_FILE" ) 2>/dev/null; then
      printf '%s op=initial-receipt-boundary phase=setup observed_status=0 forced_status=42 frame=unproven\n' \
        "$(monotonic_ms)" >> "$REPRO_ATTEMPT_LOG"
      printf '%s\n' "$output"
      printf 'experiment forced the first unproven post-transport receipt observation to fail\n' >&2
      return 42
    fi
    printf '%s op=peek-end phase=%s status=%s unproven=%s\n' \
      "$(monotonic_ms)" "$phase" "$status" \
      "$([[ "$output" == *'FIXTURE_STATE=UNPROVEN'* ]] && printf yes || printf no)" \
      >> "$REPRO_ATTEMPT_LOG"
    printf '%s\n' "$output"
    return "$status"
  fi

  "$REPRO_REAL_PTY" "$@"
}

cleanup() {
  local status=$?
  if [[ -n "${REPRO_SIDECAR_PID:-}" ]]; then
    kill "$REPRO_SIDECAR_PID" >/dev/null 2>&1 || true
    wait "$REPRO_SIDECAR_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REPRO_REAL_PTY:-}" && -n "${REPRO_RECIPIENT:-}" ]]; then
    PTY_ROOT="${REPRO_PTY_ROOT:-}" "$REPRO_REAL_PTY" kill "$REPRO_RECIPIENT" >/dev/null 2>&1 || true
    PTY_ROOT="${REPRO_PTY_ROOT:-}" "$REPRO_REAL_PTY" rm "$REPRO_RECIPIENT" >/dev/null 2>&1 || true
  fi
  if [[ -n "${REPRO_ROOT:-}" ]]; then
    case "$REPRO_ROOT" in
      "${TMPDIR:-/tmp}"/st2-staged-fifo.*) rm -rf -- "${REPRO_ROOT:?}" ;;
      *) printf 'REFUSING cleanup outside reproduction prefix: %s\n' "$REPRO_ROOT" >&2; status=1 ;;
    esac
  fi
  if (( status != 0 )); then
    printf 'RUN_RESULT=INCONCLUSIVE\n' >&2
  fi
  exit "$status"
}

run_case() {
  local mode="$1"
  local self
  local real_st2
  local st2_version
  local bus_root
  local state_root
  local shim_dir
  local fixture_pid_file
  local acceptance_file
  local sidecar_log
  local first_file
  local second_file
  local direct_peek
  local recovery_transports
  local provider_acceptances
  local retry_cycles
  local second_transports

  self="$(readlink -f "$0")"
  case "$mode" in
    baseline) real_st2="$REPRO_BASELINE_ST2" ;;
    candidate) real_st2="$REPRO_CANDIDATE_ST2" ;;
    *) printf 'FAIL: unknown case %s\n' "$mode" >&2; return 1 ;;
  esac
  st2_version="$("$real_st2" --version)"
  REPRO_REAL_PTY="$(command -v pty)"
  REPRO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/st2-staged-fifo.XXXXXX")"
  REPRO_PTY_ROOT="$REPRO_ROOT/pty"
  REPRO_RECIPIENT="repro.recipient"
  REPRO_SECOND_NONCE="second-$(date +%s%N)-$$"
  REPRO_ATTEMPT_LOG="$REPRO_ROOT/attempts.log"
  REPRO_PHASE_FILE="$REPRO_ROOT/phase"
  REPRO_INITIAL_RECEIPT_FILE="$REPRO_ROOT/initial-receipt-boundary"
  bus_root="$REPRO_ROOT/bus"
  state_root="$REPRO_ROOT/state"
  shim_dir="$REPRO_ROOT/shim"
  fixture_pid_file="$REPRO_ROOT/fixture.pid"
  acceptance_file="$REPRO_ROOT/acceptances"
  sidecar_log="$REPRO_ROOT/sidecar.log"
  export RECOVERY_POKE REPRO_ATTEMPT_LOG REPRO_PHASE_FILE REPRO_INITIAL_RECEIPT_FILE REPRO_PTY_ROOT
  export REPRO_REAL_PTY REPRO_RECIPIENT REPRO_ROOT REPRO_SECOND_NONCE
  mkdir -p "$REPRO_PTY_ROOT" "$bus_root" "$state_root" "$shim_dir"
  : > "$REPRO_ATTEMPT_LOG"
  printf 'setup\n' > "$REPRO_PHASE_FILE"
  ln -s "$self" "$shim_dir/pty"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  case "$mode:$st2_version" in
    baseline:*'+509ffb4'*) ;;
    candidate:*'+509ffb4-unproven-deferred'*) ;;
    *) printf 'FAIL: realized st2 version does not match %s: %s\n' "$mode" "$st2_version" >&2; return 1 ;;
  esac

  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" run -d \
    --id "$REPRO_RECIPIENT" --name 'Synthetic staged-FIFO provider' --tag keep=true \
    -- bash "$self" --fixture "$fixture_pid_file" "$acceptance_file" "$REPRO_SECOND_NONCE" \
    >/dev/null
  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" peek \
    --wait 'FIXTURE_STATE=IDLE' -t 10 --plain "$REPRO_RECIPIENT" >/dev/null

  first_file="$(printf 'synthetic first payload\n' | \
    "$real_st2" message send "$REPRO_RECIPIENT" --root "$bus_root" --host repro \
      --as repro.sender --subject 'seeded backlog')"

  PATH="$shim_dir:$PATH" PTY_ROOT="$REPRO_PTY_ROOT" XDG_STATE_HOME="$state_root" \
    "$real_st2" ding "$REPRO_RECIPIENT" --identity "$REPRO_RECIPIENT" \
      --root "$bus_root" --host repro --interval 50 > "$sidecar_log" 2>&1 &
  REPRO_SIDECAR_PID=$!

  wait_for_count 'op=send-start phase=setup kind=recovery has_return=yes' 1 10000 \
    'initial recovery transports'
  wait_for_count 'op=send-end phase=setup status=0 kind=recovery has_return=yes' 1 10000 \
    'completed initial recovery transports'
  wait_for_count \
    'op=initial-receipt-boundary phase=setup observed_status=0 forced_status=42 frame=unproven' \
    1 10000 'completed initial receipt observations'

  recovery_transports="$(log_count 'op=send-start phase=setup kind=recovery has_return=yes')"
  provider_acceptances="$(read_counter "$acceptance_file")"
  [[ "$recovery_transports" == 1 ]] || {
    printf 'FAIL: expected exactly one initial recovery transport, got %s\n' "$recovery_transports" >&2
    return 1
  }
  [[ "$provider_acceptances" == 0 ]] || {
    printf 'FAIL: expected zero initial provider acceptances, got %s\n' "$provider_acceptances" >&2
    return 1
  }

  "$real_st2" message archive "$REPRO_RECIPIENT" "$first_file" \
    --root "$bus_root" --host repro >/dev/null
  second_file="$(printf 'synthetic second payload\n' | \
    "$real_st2" message send "$REPRO_RECIPIENT" --root "$bus_root" --host repro \
      --as repro.sender --subject "later $REPRO_SECOND_NONCE")"
  printf '%s\n' "$mode" > "$REPRO_PHASE_FILE"

  direct_peek="$(PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" peek --plain "$REPRO_RECIPIENT")"
  [[ "$direct_peek" == *'FIXTURE_STATE=UNPROVEN'* ]] || {
    printf 'FAIL: direct healthy peek did not observe the unproven screen\n' >&2
    return 1
  }
  if [[ "$mode" == candidate ]]; then
    wait_for_count 'op=send-start phase=candidate kind=second has_return=yes' 1 20000 \
      'candidate second transports'
    wait_for_counter "$acceptance_file" 1 5000 'candidate provider acceptances'
    second_transports="$(log_count 'op=send-start phase=candidate kind=second has_return=yes')"
    provider_acceptances="$(read_counter "$acceptance_file")"
    [[ "$second_transports" == 1 ]] || {
      printf 'FAIL: expected exactly one candidate second transport, got %s\n' \
        "$second_transports" >&2
      return 1
    }
    [[ "$provider_acceptances" == 1 ]] || {
      printf 'FAIL: expected exactly one candidate provider acceptance, got %s\n' \
        "$provider_acceptances" >&2
      return 1
    }
    kill -0 "$REPRO_SIDECAR_PID"
    printf 'CANDIDATE_ST2_VERSION=%s\n' "$st2_version"
    printf 'CANDIDATE_SEMANTICS=retry_staged_unproven_to_deferred\n'
    printf 'CANDIDATE_SECOND_NONCE=%s\n' "$REPRO_SECOND_NONCE"
    printf 'CANDIDATE_INITIAL_RECOVERY_TRANSPORTS=%s\n' "$recovery_transports"
    printf 'CANDIDATE_INITIAL_PROVIDER_ACCEPTANCES=0\n'
    printf 'CANDIDATE_HEALTHY_UNPROVEN_PEEK=yes\n'
    printf 'CANDIDATE_SECOND_TRANSPORTS=%s\n' "$second_transports"
    printf 'CANDIDATE_SECOND_PROVIDER_ACCEPTANCES=%s\n' "$provider_acceptances"
    printf 'CANDIDATE_RESULT=GREEN\n'
    return 0
  fi

  wait_for_count 'op=peek-end phase=baseline status=0 unproven=yes' 2 35000 \
    'production staged retry cycles'

  retry_cycles="$(log_count 'op=peek-end phase=baseline status=0 unproven=yes')"
  second_transports="$(log_count 'op=send-start phase=baseline kind=second has_return=yes')"
  kill -0 "$REPRO_SIDECAR_PID"
  PTY_ROOT="$REPRO_PTY_ROOT" "$REPRO_REAL_PTY" list --json | \
    jq -e --arg id "$REPRO_RECIPIENT" 'any(.name == $id and .status == "running")' >/dev/null
  [[ "$second_transports" == 0 ]] || {
    printf 'FAIL: baseline unexpectedly transported the second message %s time(s)\n' \
      "$second_transports" >&2
    return 1
  }
  [[ "$retry_cycles" == 2 ]] || {
    printf 'FAIL: expected exactly two collected staged retry cycles, got %s\n' \
      "$retry_cycles" >&2
    return 1
  }

  printf 'BASELINE_ST2_VERSION=%s\n' "$st2_version"
  printf 'BASELINE_SECOND_NONCE=%s\n' "$REPRO_SECOND_NONCE"
  printf 'BASELINE_INITIAL_RECOVERY_TRANSPORTS=%s\n' "$recovery_transports"
  printf 'BASELINE_INITIAL_PROVIDER_ACCEPTANCES=%s\n' "$provider_acceptances"
  printf 'BASELINE_HEALTHY_UNPROVEN_PEEK=yes\n'
  printf 'BASELINE_STAGED_RETRY_CYCLES=%s\n' "$retry_cycles"
  printf 'BASELINE_SECOND_TRANSPORTS=%s\n' "$second_transports"
  printf 'BASELINE_TARGET_ALIVE=yes\n'
  printf 'BASELINE_SIDECAR_ALIVE=yes\n'
  printf 'BASELINE_RESULT=RED\n'

  printf 'control\n' > "$REPRO_PHASE_FILE"
  kill -USR1 "$(<"$fixture_pid_file")"
  wait_for_count 'op=send-start phase=control kind=second has_return=yes' 1 20000 \
    'positive-control second transports'
  wait_for_counter "$acceptance_file" 2 5000 'positive-control provider acceptances'
  second_transports="$(log_count 'op=send-start phase=control kind=second has_return=yes')"
  provider_acceptances="$(read_counter "$acceptance_file")"
  [[ "$second_transports" == 1 ]] || {
    printf 'FAIL: expected exactly one positive-control second transport, got %s\n' \
      "$second_transports" >&2
    return 1
  }
  [[ "$provider_acceptances" == 2 ]] || {
    printf 'FAIL: expected two positive-control provider acceptances, got %s\n' \
      "$provider_acceptances" >&2
    return 1
  }
  printf 'CONTROL_RELEASE_SCREEN=adapter_accepted_recovery\n'
  printf 'CONTROL_SECOND_TRANSPORTS=%s\n' "$second_transports"
  printf 'CONTROL_PROVIDER_ACCEPTANCES=%s\n' "$provider_acceptances"
  printf 'CONTROL_RESULT=GREEN\n'
  [[ -n "$second_file" ]]
}

repro_main() {
  local self
  self="$(readlink -f "$0")"
  printf 'ST2_PIN=509ffb4cdcc1805a1ccd566e87b5d373bb4c47d4\n'
  printf 'PTY_PIN=504ac7332895fe1fa3767b530dcd99f091f56cda\n'
  "$self" --case baseline
  "$self" --case candidate
}

case "${1:-}" in
  --fixture)
    shift
    fixture_main "$@"
    ;;
  --case)
    shift
    run_case "$@"
    ;;
  *)
    if [[ "$(basename "$0")" == pty ]]; then
      capture_pty_main "$@"
    else
      repro_main
    fi
    ;;
esac
