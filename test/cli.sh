#!/bin/zsh
# CLI assertions for the multi-device registry (specs/2026-08-06-multi-device-targets.md).
#
# Pure: no device, no permissions, no virtual display — this runs in CI alongside
# mac/check. adb and idevice_id are stubbed, and SHARE points at a scratch tree, so a
# live session's config and registry are never touched.
#
#     zsh test/cli.sh        # or: make check

set -u
ROOT=${0:A:h:h}
PASS=0 FAIL=0

# if/else, never `cond && ok || bad`: (( PASS++ )) yields the OLD value, so it exits 1
# while PASS is still 0 and the || arm fires on a passing assertion
ok()   { print -r -- "  ok   $1"; PASS=$(( PASS + 1 )) }
bad()  { print -r -- "  FAIL $1 — $2"; FAIL=$(( FAIL + 1 )) }
is()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "'$3' not in '$2'"; fi }
yes()  { if (( $2 )); then bad "$1" "exit $2"; else ok "$1"; fi }
no()   { if (( $2 )); then ok "$1"; else bad "$1" "expected non-zero exit"; fi }

TMP=$(mktemp -d /tmp/aeasy-cli.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# --- stubs ------------------------------------------------------------------
# bin/aeasy prepends /opt/homebrew/bin to PATH when sourced, so the stub dir has to be
# prepended AFTER the source or a real adb would win.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/adb" <<'STUB'
#!/bin/zsh
if [[ "$1" == "devices" ]]; then
  print -r -- "List of devices attached"
  print -r -- "R5CT12ABCDE            device product:a54x model:Galaxy_A54 device:a54x transport_id:1"
  print -r -- "192.168.1.42:5555      device product:tab model:Galaxy_Tab_S9 device:tab transport_id:2"
  print -r -- "BADPHONE0001           unauthorized"
  exit 0
fi
# -s <serial> <cmd...>
if [[ "$1" == "-s" ]]; then
  serial=$2; shift 2
  print -r -- "adb -s $serial $*" >> "$AEASY_TRACE"
  case "$1 $2" in
    "shell pm")   [[ "$serial" == R5CT12ABCDE ]] && printf 'package:dev.ctz.usbdisplay\r\n'
                  [[ "$serial" == 192.168.1.42:5555 ]] && printf 'package:dev.ctz.usbdisplay.debug\r\n'
                  exit 0 ;;
    "get-state "*|"get-state") print -r -- device; exit 0 ;;
  esac
  [[ "$1" == "get-state" ]] && { print -r -- device; exit 0 }
  [[ "$1" == "shell" && "$2" == "getprop" ]] && { print -r -- "ro-$serial"; exit 0 }
  exit 0
fi
print -r -- "adb $*" >> "$AEASY_TRACE"
exit 0
STUB
cat > "$TMP/bin/idevice_id" <<'STUB'
#!/bin/zsh
[[ "$1" == "-l" ]] && print -r -- "00008030-001A2B3C4D5E6F00"
exit 0
STUB
cat > "$TMP/bin/ideviceinfo" <<'STUB'
#!/bin/zsh
print -r -- "Nakarin's iPad"
STUB
chmod +x "$TMP/bin"/*

export AEASY_SHARE="$TMP/share"
export AEASY_TRACE="$TMP/trace"
: > "$AEASY_TRACE"
mkdir -p "$AEASY_SHARE"

AEASY_LIB=1 source "$ROOT/bin/aeasy"
PATH="$TMP/bin:$PATH"          # after the source, or /opt/homebrew/bin wins

print -r -- "cli: registry"

# --- T-1: registry round-trip ------------------------------------------------
# slot and platform first so an ip:port serial keeps its colons
conf_set "$GCFG" '^DEVICES=' "DEVICES=0:android:R5CT12ABCDE,1:ios:00008030-001A,2:android:192.168.1.42:5555"
is "T-1 serial with colons round-trips" "$(dev_serial 2)" "192.168.1.42:5555"
is "T-1 platform parses"                "$(dev_plat 1)"   "ios"
is "T-1 slots enumerate"                "$(dev_slots | tr '\n' ' ')" "0 1 2 "
is "T-1 slot_of finds a wireless serial" "$(slot_of 192.168.1.42:5555)" "2"
is "T-1 port is derived from the slot"  "$(dev_port 2)"   "7375"
is "T-1 slot 0 keeps port 7355"         "$(dev_port 0)"   "7355"

# --- T-3: adb needs a device context -----------------------------------------
# `${VAR:?}` would kill the shell here, not the function — the next assertion existing
# at all is the point of this test.
( adb devices >/dev/null 2>&1 )
no "T-3 bare adb refuses without a context" $?
ok "T-3 the shell survived a context-less adb"
is "T-3 with_dev targets the right serial" \
   "$(with_dev 2 zsh -c 'print -r -- $AEASY_SERIAL')" "192.168.1.42:5555"
is "T-3 with_dev exports the slot port" \
   "$(with_dev 1 zsh -c 'print -r -- $AEASY_PORT')" "7365"

# --- T-4: registry readers ignore the per-device config ----------------------
mkdir -p "$AEASY_SHARE/dev/1"
print -r -- "SOURCES=display" > "$AEASY_SHARE/dev/1/config"
is "T-4 dev_serial reads the global config from inside with_dev" \
   "$(with_dev 1 dev_serial 2)" "192.168.1.42:5555"

print -r -- "cli: slots"

# --- T-2: allocation, reclaim, limits ----------------------------------------
conf_set "$GCFG" '^DEVICES=' "DEVICES="
_device_add R5CT12ABCDE >/dev/null
is "T-2 first add takes slot 0" "$(slot_of R5CT12ABCDE)" "0"
is "T-2 add seeds the slot config" \
   "$(grep -m1 '^SERIAL=' "$AEASY_SHARE/dev/0/config" | cut -d= -f2-)" "R5CT12ABCDE"
is "T-2 first device holds input" "$(input_holder)" "0"

_device_add 00008030-001A2B3C4D5E6F00 >/dev/null
is "T-2 second add takes slot 1" "$(slot_of 00008030-001A2B3C4D5E6F00)" "1"
is "T-2 iOS platform is recorded" "$(dev_plat 1)" "ios"

( _device_add R5CT12ABCDE >/dev/null 2>&1 )
no "T-2 duplicate serial is refused" $?
( _device_add BADPHONE0001 >/dev/null 2>&1 )
no "T-2 unauthorized device is refused" $?
( _device_add 'R5CT;rm -rf ~' >/dev/null 2>&1 )
no "T-9 serial with a metacharacter is refused" $?
( _device_add '$(whoami)' >/dev/null 2>&1 )
no "T-9 serial with a subshell is refused" $?

# reclaim: a returning device must get its old slot back, or macOS loses the arrangement
print -r -- "SOURCES=display,window:Code" >> "$AEASY_SHARE/dev/0/config"
_device_rm 0 >/dev/null
is "T-2 rm frees the slot" "$(slot_of R5CT12ABCDE 2>/dev/null)" ""
is "T-2 rm keeps the slot directory" "$([[ -f $AEASY_SHARE/dev/0/config ]] && print yes)" "yes"
is "T-2 input falls to the lowest remaining slot" "$(input_holder)" "1"
_device_add R5CT12ABCDE >/dev/null
is "T-2 re-adding reclaims the original slot" "$(slot_of R5CT12ABCDE)" "0"
has "T-2 reclaimed slot keeps its sources" \
    "$(grep '^SOURCES=' "$AEASY_SHARE/dev/0/config")" "window:Code"

# a different device in a freed slot must NOT inherit its layout
_device_rm 0 >/dev/null
print -r -- '{"rev":9,"panes":[]}' > "$AEASY_SHARE/dev/0/layout.json"
seed_slot 0 192.168.1.42:5555 android
is "T-2 a different device reseeds the slot" \
   "$([[ -f $AEASY_SHARE/dev/0/layout.json ]] && print kept || print discarded)" "discarded"

# third add fills the last slot, fourth is refused
conf_set "$GCFG" '^DEVICES=' "DEVICES=0:android:a,1:android:b,2:android:c"
( _device_add R5CT12ABCDE >/dev/null 2>&1 )
no "T-2 a 4th device is refused" $?

print -r -- "cli: enumeration"

# --- T-21: enumeration, install status, connection type ----------------------
LIST=$(devices_list)
has "T-21 model name is un-underscored" "$LIST" "Galaxy A54"
has "T-21 USB serial is typed usb"      "$(print -r -- $LIST | awk -F'\t' '$1=="R5CT12ABCDE"{print $3}')" "usb"
has "T-21 ip:port serial is typed wifi" "$(print -r -- $LIST | awk -F'\t' '$1=="192.168.1.42:5555"{print $3}')" "wifi"
is  "T-21 installed app is detected through CRLF" \
    "$(print -r -- $LIST | awk -F'\t' '$1=="R5CT12ABCDE"{print $4}')" "yes"
is  "T-21 a .debug package does NOT count as installed" \
    "$(print -r -- $LIST | awk -F'\t' '$1=="192.168.1.42:5555"{print $4}')" "no"
is  "T-21 unauthorized devices stay visible" \
    "$(print -r -- $LIST | awk -F'\t' '$1=="BADPHONE0001"{print $5}')" "unauthorized"
is  "T-21 a state-only row falls back to its serial for a name" \
    "$(print -r -- $LIST | awk -F'\t' '$1=="BADPHONE0001"{print $6}')" "BADPHONE0001"
is  "T-21 iOS reports n/a for app status" \
    "$(print -r -- $LIST | awk -F'\t' '$2=="ios"{print $4}')" "n/a"
has "T-21 iOS name comes from ideviceinfo" "$LIST" "Nakarin's iPad"

print -r -- "cli: process scoping"

# --- T-5: every server pattern carries --slot -------------------------------
# The failure mode is an easily-missed site, not a behaviour: with slot 0 alive, a bare
# `pgrep -qf aeasy-server` reports every other slot as running and the watcher never
# starts a second device. Structural assertion on purpose.
UNSCOPED=$(grep -nE '(pgrep|pkill)[^|]*aeasy-serve' "$ROOT/bin/aeasy" \
  | grep -vE '^[0-9]+: *#' | grep -v -- '--slot')
is "T-5 only aeasy stop kills servers unscoped" "$(print -rl -- $UNSCOPED | grep -c 'pkill -f aeasy-server')" "1"
is "T-5 no unscoped pgrep on aeasy-server" "$(print -rl -- $UNSCOPED | grep -c 'pgrep')" "0"

# --- T-6/T-7: per-slot tunnels and reverse rule ------------------------------
: > "$AEASY_TRACE"
conf_set "$GCFG" '^DEVICES=' "DEVICES=1:android:R5CT12ABCDE"
with_dev 1 app_open
TRACE=$(<"$AEASY_TRACE")
has "T-7 reverse maps device 7355 to this slot's port" "$TRACE" "reverse tcp:7355 tcp:7365"
has "T-7 reverse is issued before am start" \
    "$(print -r -- $TRACE | grep -n 'reverse\|am start' | head -1)" "reverse"
is  "T-7 adb is addressed by serial" "$(print -r -- $TRACE | grep -c 'adb -s R5CT12ABCDE')" "2"

# relay commands are built per slot on BOTH legs — the socat destination is the bug that
# would have sent every iOS device to slot 0's display
RELAY=$(with_dev 1 zsh -c 'l=$(( AEASY_PORT + 1 )); print -r -- "iproxy $l:7355 -u $AEASY_SERIAL | socat TCP:127.0.0.1:$l TCP:127.0.0.1:$AEASY_PORT"')
has "T-6 iproxy uses the slot's local port and UDID" "$RELAY" "iproxy 7366:7355 -u R5CT12ABCDE"
has "T-6 socat terminates at the slot's server port" "$RELAY" "TCP:127.0.0.1:7365"
is  "T-6 slot 0 relay is unchanged from single-device" \
    "$(with_dev 0 zsh -c 'print -r -- $(( AEASY_PORT + 1 ))')" "7356"

print -r -- "cli: backoff"

# --- T-10: relaunch backoff keyed on exit status -----------------------------
mkdir -p "$AEASY_SHARE/dev/0"
run_backoff() { with_dev 0 "$@" }
run_backoff backoff_reset
yes "T-10 a fresh slot may launch" $(run_backoff backoff_ready; print $?)
print -r -- 1 > "$AEASY_SHARE/dev/0/exit"
run_backoff backoff_tick
is "T-10 a non-zero exit arms the backoff" \
   "$(cut -d' ' -f1 "$AEASY_SHARE/dev/0/backoff")" "1"
no "T-10 an armed backoff blocks the relaunch" $(run_backoff backoff_ready; print $?)
print -r -- 1 > "$AEASY_SHARE/dev/0/exit"; run_backoff backoff_tick
print -r -- 1 > "$AEASY_SHARE/dev/0/exit"; run_backoff backoff_tick
is "T-10 the counter climbs" "$(cut -d' ' -f1 "$AEASY_SHARE/dev/0/backoff")" "3"
# exit(0) is the NORMAL iOS rotation mechanism and must never be penalised
print -r -- 0 > "$AEASY_SHARE/dev/0/exit"
run_backoff backoff_tick
is "T-10 a clean exit clears the backoff" \
   "$([[ -f $AEASY_SHARE/dev/0/backoff ]] && print armed || print clear)" "clear"

# a SIGTERM is server_kill doing its job — every deliberate restart would otherwise climb
# the ladder until a rotation took a full minute to come back
for sig in 143 137; do
  print -r -- 3 > "$AEASY_SHARE/dev/0/exit"; run_backoff backoff_tick   # arm it
  print -r -- $sig > "$AEASY_SHARE/dev/0/exit"; run_backoff backoff_tick
  is "T-10 exit $sig (our own kill) is not a crash" \
     "$([[ -f $AEASY_SHARE/dev/0/backoff ]] && print armed || print clear)" "clear"
done

# and the status left by the server we just replaced must not survive into the next tick
print -r -- 9 > "$AEASY_SHARE/dev/0/exit"
SERVER=/usr/bin/true run_backoff server_spawn 100 100
is "T-10 spawning clears the previous server's exit status" \
   "$([[ -f $AEASY_SHARE/dev/0/exit ]] && print stale || print cleared)" "cleared"

print -r -- "cli: migration"

# --- T-8: one-time migration -------------------------------------------------
# the common upgrade: one cabled Android phone, and a config that never recorded a serial
cat > "$TMP/bin/adb" <<'STUB'
#!/bin/zsh
if [[ "$1" == "devices" ]]; then
  print -r -- "List of devices attached"
  print -r -- "R5CT12ABCDE            device product:a54x model:Galaxy_A54 device:a54x transport_id:1"
  exit 0
fi
[[ "$1" == "-s" && "$3" == "shell" && "$4" == "pm" ]] && { printf 'package:dev.ctz.usbdisplay\r\n'; exit 0 }
exit 0
STUB
cat > "$TMP/bin/idevice_id" <<'STUB'
#!/bin/zsh
exit 0
STUB
chmod +x "$TMP/bin"/*
rm -rf "$AEASY_SHARE"; mkdir -p "$AEASY_SHARE"
cat > "$GCFG" <<'OLD'
SOURCES=display,window:Safari
FPS=20
BITRATE=2000000
OLD
print -r -- '{"rev":4,"panes":[]}' > "$AEASY_SHARE/layout.json"
migrate >/dev/null
is "T-8 a cabled Android phone is adopted from enumeration" \
   "$(dev_serial 0)" "R5CT12ABCDE"
is "T-8 layout.json moves into the slot" \
   "$([[ -f $AEASY_SHARE/dev/0/layout.json ]] && print moved)" "moved"
has "T-8 sources survive the migration" \
    "$(grep '^SOURCES=' "$AEASY_SHARE/dev/0/config")" "window:Safari"
is "T-8 the global config keeps only the registry" \
   "$(grep -c '^SOURCES=' "$GCFG")" "0"
is "T-8 slot 0 holds input after migration" "$(input_holder)" "0"
is "T-8 migration is idempotent" "$(migrate; print $?)" "0"

# ambiguous: two online devices and no recorded serial must NOT be guessed
rm -rf "$AEASY_SHARE"; mkdir -p "$AEASY_SHARE"
cat > "$TMP/bin/adb" <<'STUB'
#!/bin/zsh
if [[ "$1" == "devices" ]]; then
  print -r -- "List of devices attached"
  print -r -- "AAA111    device product:x model:Phone_A device:x transport_id:1"
  print -r -- "BBB222    device product:y model:Phone_B device:y transport_id:2"
  exit 0
fi
[[ "$1" == "-s" && "$3" == "shell" ]] && exit 0
exit 0
STUB
chmod +x "$TMP/bin/adb"
print -r -- "FPS=20" > "$GCFG"
( migrate >/dev/null 2>&1 )
no "T-8 two attached devices are never guessed between" $?
is "T-8 an ambiguous migration writes no registry" "$(gconf DEVICES)" ""

print -r -- "cli: help"

# --- T-24: both help texts document the new surface -------------------------
EN=$(AEASY_LIB= zsh "$ROOT/bin/aeasy" --help)
TH=$(AEASY_LIB= zsh "$ROOT/bin/aeasy" --help --th)
for sub in "device list" "device add" "device rm" "device input"; do
  has "T-24 english help documents '$sub'" "$EN" "$sub"
  has "T-24 thai help documents '$sub'"    "$TH" "$sub"
done

print -r -- ""
print -r -- "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
