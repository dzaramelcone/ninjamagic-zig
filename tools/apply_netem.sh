#!/bin/bash
set -e

# read env or defaults
IFACE=${NETEM_IFACE:-br_slow}
DELAY=${NETEM_DELAY:-120ms}
JITTER=${NETEM_JITTER:-20ms}
LOSS=${NETEM_LOSS:-0.0%}
RATE=${NETEM_RATE:-}

# build tc command
CMD=(tc qdisc add dev "$IFACE" root netem delay "$DELAY" "$JITTER")
[[ -n "$LOSS" && "$LOSS" != "0.0%" ]] && CMD+=(loss "$LOSS")
[[ -n "$RATE"                      ]] && CMD+=(rate "$RATE")

echo "› applying: ${CMD[*]}"
${CMD[@]}

# keep container alive; removing it will delete the qdisc automatically
tail -f /dev/null
