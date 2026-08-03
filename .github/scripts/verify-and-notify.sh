#!/usr/bin/env bash
#
# Second-opinion gate between Upptime and Telegram. See the header of
# .github/workflows/verify-and-notify.yml for the why.
#
# Contract:
#   - issue opened  -> re-probe the site from THIS (fresh) runner; alert only
#                      if the failure reproduces. Anything we cannot verify is
#                      alerted unverified (fail-open).
#   - issue closed  -> send the recovery message only if we alerted on the way
#                      down (label `alerted`).
#
set -uo pipefail

COOL_OFF="${COOL_OFF:-30}"     # let a momentary blip pass before re-probing
ATTEMPTS="${ATTEMPTS:-4}"
SPACING="${SPACING:-10}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
MAX_TIME="${MAX_TIME:-15}"
UA="AlphaAI-Upptime-Verify/1.0 (+https://status.alphai.io)"

log() { printf '%s\n' "$*"; }
summary() { printf '%s\n' "$*" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"; }

send_telegram() {
  local text="$1" chat
  if [[ -z "${TELEGRAM_BOT_KEY:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    log "!! Telegram secrets missing — cannot notify"
    return 1
  fi
  local IFS=,
  for chat in $TELEGRAM_CHAT_ID; do
    chat="${chat// /}"
    [[ -z "$chat" ]] && continue
    curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_KEY}/sendMessage" \
      -d chat_id="$chat" \
      -d parse_mode=HTML \
      -d disable_web_page_preview=true \
      --data-urlencode text="$text" >/dev/null ||
      log "!! Telegram send failed for chat $chat"
  done
}

add_label() {
  # Raw API, not `gh issue edit --add-label`: the CLI refuses labels that do not
  # exist in the repo yet, the API creates them. `alerted` is load-bearing — the
  # recovery message keys on it.
  gh api "repos/${GITHUB_REPOSITORY:-makeev/alphai-status}/issues/${ISSUE_NUMBER}/labels" \
    -X POST -f "labels[]=$1" >/dev/null 2>&1 ||
    log "!! could not add label $1"
}

comment() {
  gh issue comment "$ISSUE_NUMBER" --body "$1" >/dev/null 2>&1 ||
    log "!! could not comment (issue is locked by Upptime; needs a token with write access)"
}

human_duration() {
  local secs="$1"
  if ((secs < 60)); then
    printf '%ds' "$secs"
  elif ((secs < 3600)); then
    printf '%dm %ds' $((secs / 60)) $((secs % 60))
  else
    printf '%dh %dm' $((secs / 3600)) $(((secs % 3600) / 60))
  fi
}

# ---------------------------------------------------------------- recovery ---

if [[ "$EVENT_ACTION" == "closed" ]]; then
  if [[ "${HAS_ALERTED:-false}" != "true" ]]; then
    log "Issue #$ISSUE_NUMBER never produced an alert — staying silent on recovery"
    summary "Issue #$ISSUE_NUMBER closed, no alert had been sent — silent."
    exit 0
  fi
  down_for=""
  if [[ -n "${ISSUE_CREATED:-}" ]]; then
    # python3 rather than `date -d`: portable, and the script stays runnable
    # on a laptop for testing.
    secs="$(python3 -c '
import datetime, sys
parse = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
start = parse(sys.argv[1])
end = parse(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else datetime.datetime.now(datetime.timezone.utc)
print(int((end - start).total_seconds()))
' "$ISSUE_CREATED" "${ISSUE_CLOSED:-}" 2>/dev/null)"
    [[ "$secs" =~ ^[0-9]+$ ]] && down_for=" — down for $(human_duration "$secs")"
  fi
  name="${ISSUE_TITLE#🛑 }"
  name="${name% is down}"
  send_telegram "🟩 <b>${name}</b> is back up${down_for}"
  summary "Recovery alert sent for #$ISSUE_NUMBER."
  exit 0
fi

# ------------------------------------------------------------------- down ----

if [[ "$EVENT_ACTION" != "opened" ]]; then
  log "Ignoring action=$EVENT_ACTION"
  exit 0
fi

NAME="${ISSUE_TITLE#🛑 }"
NAME="${NAME% is down}"
export NAME

if [[ "$NAME" == "$ISSUE_TITLE" ]]; then
  # Not a plain down issue (degraded performance, or a human-opened one that
  # happens to carry the `status` label) — nothing to re-probe, alert as is.
  log "Title is not a down report, alerting unverified: $ISSUE_TITLE"
  send_telegram "⚠️ <b>${ISSUE_TITLE}</b>${ISSUE_URL:+
$ISSUE_URL}"
  add_label alerted
  exit 0
fi

URL="$(yq '.sites[] | select(.name == strenv(NAME)) | .url' .upptimerc.yml 2>/dev/null | head -1)"
CODES="$(yq '.sites[] | select(.name == strenv(NAME)) | .expectedStatusCodes | join(",")' .upptimerc.yml 2>/dev/null | head -1)"

if [[ -z "$URL" || "$URL" == "null" || -z "$CODES" || "$CODES" == "null" ]]; then
  # Cannot look the site up -> cannot verify -> do not swallow the alert.
  log "!! could not resolve url/expected codes for '$NAME' (url='$URL' codes='$CODES')"
  send_telegram "🟥 <b>${NAME}</b> is down (unverified — this monitor could not re-probe it)${ISSUE_URL:+
$ISSUE_URL}"
  add_label alerted
  summary "Fail-open alert for #$ISSUE_NUMBER — site '$NAME' not found in .upptimerc.yml."
  exit 0
fi

log "Re-probing $NAME ($URL), expecting one of [$CODES], from an independent runner"
log "Cooling off ${COOL_OFF}s first"
sleep "$COOL_OFF"

up=0
observed=""
for i in $(seq 1 "$ATTEMPTS"); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -A "$UA" "$URL" 2>/dev/null)"
  code="${code:-000}"
  log "attempt $i/$ATTEMPTS -> HTTP $code"
  observed="${observed:+$observed, }$code"
  case ",$CODES," in
  *",$code,"*)
    up=1
    break
    ;;
  esac
  ((i < ATTEMPTS)) && sleep "$SPACING"
done

if ((up == 1)); then
  log "NOT CONFIRMED — $NAME answered as expected from this runner. No alert."
  comment "**Not confirmed from a second vantage point.**

A fresh GitHub runner probed \`$URL\` ${COOL_OFF}s after this issue was opened and got an expected status code (observed: $observed). The service was answering while this issue claimed it was down, so no Telegram alert was sent.

This is the runner-network signature documented in \`issues/2026-07-27-upptime-false-positive-runner-blackhole.md\` (alphai_io repo): Upptime's retries all run on the same runner, so a black-holed egress path turns into a confirmed \"down\". Upptime will close this issue on its next successful check."
  add_label false-positive
  summary "Suppressed #$ISSUE_NUMBER — $NAME answered $observed from a second runner."
  exit 0
fi

log "CONFIRMED down from a second runner (observed: $observed)"
send_telegram "🟥 <b>${NAME}</b> is down
${URL}
Confirmed from a second runner (observed: ${observed}, expected: ${CODES})${ISSUE_URL:+
$ISSUE_URL}"
add_label alerted
summary "Alerted on #$ISSUE_NUMBER — $NAME confirmed down (observed: $observed)."
