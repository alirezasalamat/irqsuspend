#!/bin/bash

source $(dirname $0)/util.sh

# Global variables
SCRIPT_DIR="$(dirname $0)"
NDCLI="../linux/net-next/tools/net/ynl/pyynl/cli.py --no-schema --output-json --spec ../linux/net-next/Documentation/netlink/specs/netdev.yaml"

# Configuration variables (will be set by parse_arguments)
declare -g IFACE IRQ_COUNT CPUSET GRO_TIMEOUT DEFER_IRQS SUSPEND_TIMEOUT
declare -g MEMCACHED_DIR OTHER_CPUS DRIVER_IP AGENT_IPS AGENTS_STRING IFACE_IP MEMCACHED_BIN
declare -g BUSY_POLL_USECS BUSY_POLL_BUDGET BUSY_POLL_PREFER
declare -g MEMCACHED_EXTRA_FLAGS MEMVAR MEMCACHED_PID

function usage() {
	echo "Usage: $(basename $0) <interface> <options>"
	echo ""
	echo "Required options:"
	echo "  -i, --irq-count <num>              Number of IRQs/queues to configure"
	echo "  -c, --cpuset <cpuset>              CPU set for 1:1 IRQ binding (e.g., 0-7 or 0,2,4,6)"
	echo "  -m, --memcached-dir <path>         Directory containing memcached binary"
	echo "  --driver-ip <ip>                   Driver client SSH IP address (coordinates mutilate)"
	echo "  --agent-ips <ip1,ip2,...>          Comma-separated agent IPs for mutilate (optional)"
	echo ""
	echo "Optional:"
	echo "  -o, --other-cpus <cpuset>          CPU set for other/non-queue IRQs (default: empty)"
    echo "  -g, --gro-flush-timeout <usec>     GRO flush timeout (microseconds)"
	echo "  -d, --defer-hard-irqs <count>      Defer hard IRQs count"
	echo "  -s, --irq-suspend-timeout <usec>   IRQ suspend timeout (microseconds)"
	echo "  --busy-poll-usecs <usec>           Set _MP_Usecs (busy poll microseconds)"
	echo "  --busy-poll-budget <num>           Set _MP_Budget (busy poll budget)"
	echo "  --busy-poll-prefer <0|1>           Set _MP_Prefer (busy poll prefer)"
	echo "  --memcached-extra-flags <flags>    Additional memcached flags"
	echo "  --fullbusy                         Enable fullbusy mode (sets gro=5000000, defer=100, suspend=0,"
	echo "                                     busy-poll-usecs=1000, busy-poll-budget=64, busy-poll-prefer=1,"
	echo "                                     adds -y flag to memcached)"
	echo "  -h, --help                         Show this help"
	echo ""
	echo "Examples:"
	echo "  ./$(basename $0) enp7s0 --irq-count 8 --cpuset 0-7 --driver-ip 192.168.1.100 --gro-flush-timeout 20000 --defer-hard-irqs 100 --irq-suspend-timeout 20000000 --memcached-dir ~/work/memcached"
	echo "  ./$(basename $0) enp7s0 -i 8 -c 0-7 --driver-ip 192.168.1.100 --agent-ips 192.168.1.101,192.168.1.102 --fullbusy -m ~/work/memcached"
	echo "  ./$(basename $0) enp7s0 -i 8 -c 0-7 --driver-ip 192.168.1.100 -g 20000 -d 100 -s 20000000 --busy-poll-usecs 64 --busy-poll-budget 64 --busy-poll-prefer 1 -m ~/work/memcached"
	exit 0
}

# Initialize default values
function initialize_defaults() {
	IRQ_COUNT=0
	CPUSET=0
	GRO_TIMEOUT=0
	DEFER_IRQS=0
	SUSPEND_TIMEOUT=0
	MEMCACHED_DIR=""
	OTHER_CPUS=""
	DRIVER_IP=""
	AGENT_IPS=""
	AGENTS_STRING=""
	BUSY_POLL_USECS=0
	BUSY_POLL_BUDGET=0
	BUSY_POLL_PREFER=0
	MEMCACHED_EXTRA_FLAGS=""
	opt_fullbusy=false
}

# Parse command-line arguments
function parse_arguments() {
	[ $# -lt 1 ] && usage
	IFACE=$1
	shift

	while [ $# -gt 0 ]; do
		case $1 in
			--irq-count|-i)
				IRQ_COUNT=$2; shift 2;;
			--cpuset|-c)
				CPUSET=$2; shift 2;;
			--gro-flush-timeout|-g)
				GRO_TIMEOUT=$2; shift 2;;
			--defer-hard-irqs|-d)
				DEFER_IRQS=$2; shift 2;;
			--irq-suspend-timeout|-s)
				SUSPEND_TIMEOUT=$2; shift 2;;
			--memcached-dir|-m)
				MEMCACHED_DIR=$2; shift 2;;
			--other-cpus|-o)
				OTHER_CPUS=$2; shift 2;;
			--busy-poll-usecs)
				BUSY_POLL_USECS=$2; shift 2;;
			--busy-poll-budget)
				BUSY_POLL_BUDGET=$2; shift 2;;
			--busy-poll-prefer)
				BUSY_POLL_PREFER=$2; shift 2;;
			--memcached-extra-flags)
				MEMCACHED_EXTRA_FLAGS=$2; shift 2;;
			--driver-ip)
				DRIVER_IP=$2; shift 2;;
			--agent-ips)
				AGENT_IPS=$2; shift 2;;
			--fullbusy)
				opt_fullbusy=true; shift 1;;
			-h|--help)
				usage;;
			*)
				echo "Unknown option: $1"
				usage;;
		esac
	done
	
	# Build agents string if agent IPs provided
	if [ -n "$AGENT_IPS" ]; then
		AGENTS_STRING=""
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			AGENTS_STRING+=" -a $agent"
		done
	fi
}

# Build environment variables for memcached
function build_memvar() {
	MEMVAR=""
	[ -n "$BUSY_POLL_USECS" ] && MEMVAR+="_MP_Usecs=$BUSY_POLL_USECS "
	[ -n "$BUSY_POLL_BUDGET" ] && MEMVAR+="_MP_Budget=$BUSY_POLL_BUDGET "
	[ -n "$BUSY_POLL_PREFER" ] && MEMVAR+="_MP_Prefer=$BUSY_POLL_PREFER "
	MEMVAR=$(echo "$MEMVAR" | sed 's/ $//')
}

# Validate all configuration parameters
function validate_configuration() {
	[ -z "$IRQ_COUNT" ] && ERROR "IRQ count (-i) is required"
	[ -z "$CPUSET" ] && ERROR "CPU set (-c) is required"
	[ -z "$MEMCACHED_DIR" ] && ERROR "Memcached directory (-m) is required"
	[ -z "$DRIVER_IP" ] && ERROR "Driver IP (--driver-ip) is required"

	[ -d "$MEMCACHED_DIR" ] || ERROR "Memcached directory does not exist: $MEMCACHED_DIR"
	MEMCACHED_BIN="$MEMCACHED_DIR/memcached"
	[ -f "$MEMCACHED_BIN" ] || ERROR "Memcached binary not found: $MEMCACHED_BIN"

	ip -br l show $IFACE >/dev/null 2>&1 || ERROR "Interface $IFACE not found"

	IFACE_IP=$(ip -4 addr show $IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
	[ -z "$IFACE_IP" ] && ERROR "Could not determine IP address for interface $IFACE"
}

# Display experiment configuration
function display_configuration() {
	echo "========================================="
	echo "Experiment Configuration"
	echo "========================================="
	echo "Interface:        $IFACE"
	echo "Interface IP:     $IFACE_IP"
	echo "Driver IP:        $DRIVER_IP"
	echo "Agent IPs:        ${AGENT_IPS:-none (driver only)}"
	echo "IRQ Count:        $IRQ_COUNT"
	echo "CPU Set:          $CPUSET"
	echo "Other CPUs:       ${OTHER_CPUS:-none}"
	echo "GRO Timeout:      $GRO_TIMEOUT µs"
	echo "Defer IRQs:       $DEFER_IRQS"
	echo "Suspend Timeout:  $SUSPEND_TIMEOUT µs"
	echo "Busy Poll Usecs:  ${BUSY_POLL_USECS:-none}"
	echo "Busy Poll Budget: ${BUSY_POLL_BUDGET:-none}"
	echo "Busy Poll Prefer: ${BUSY_POLL_PREFER:-none}"
	echo "Memcached Dir:    $MEMCACHED_DIR"
	echo "Extra Flags:      ${MEMCACHED_EXTRA_FLAGS:-none}"
	echo "========================================="
	echo ""
}

# Configure IRQ settings
function configure_irq_settings() {
	echo ">>> Setting queue count to $IRQ_COUNT"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setq $IRQ_COUNT

	if [ -n "$OTHER_CPUS" ]; then
		echo ">>> Setting other IRQs to CPU set: $OTHER_CPUS"
		NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setirqN $OTHER_CPUS 0 0
	fi

	echo ">>> Binding IRQs 1:1 to CPU set: $CPUSET"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setirq1 $CPUSET 0 $IRQ_COUNT

	echo ">>> Setting poll parameters (gro=$GRO_TIMEOUT, defer=$DEFER_IRQS, suspend=$SUSPEND_TIMEOUT)"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setpoll $GRO_TIMEOUT $DEFER_IRQS $SUSPEND_TIMEOUT

	echo ""
	echo ">>> Current IRQ configuration:"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE show

	echo ""
	echo "========================================="
	echo "Configuration complete!"
	echo "========================================="
	echo ""
}

# Start memcached server
function start_memcached() {
	local MEMCACHED_ARGS="-t $IRQ_COUNT -N $IRQ_COUNT -p 11212 -b 16384 -c 32768 -m 2048"
	MEMCACHED_ARGS+=" -o hashpower=24,no_lru_maintainer,no_lru_crawler"
	MEMCACHED_ARGS+=" -l $IFACE_IP -u $USER $MEMCACHED_EXTRA_FLAGS"
	local MEMCACHED_CMD="$MEMVAR taskset -c $CPUSET $MEMCACHED_BIN $MEMCACHED_ARGS"

	echo ">>> Starting memcached:"
	[ -n "$MEMVAR" ] && echo "    Environment: $MEMVAR"
	echo "    Command: taskset -c $CPUSET $MEMCACHED_BIN $MEMCACHED_ARGS"
	echo ""

	killall -q memcached 2>/dev/null
	sleep 1

	eval $MEMCACHED_CMD &
	MEMCACHED_PID=$!

	echo ">>> Memcached started with PID: $MEMCACHED_PID"
	echo ">>> Listening on: $IFACE_IP:11212"
	echo ""
}

# Run mutilate benchmarks with agents
# Args: $1 = driver SSH IP, $2 = server IP, $3 = agents string
function run_mutilate_benchmark() {
	local DRIVER_IP="$1"
	local SERVER_IP="$2"
	local AGENTS_STR="$3"
	local SERVER_PORT="11212"
	local MUTILATE_BIN="/home/alireza/workspace/mutilate/mutilate"
	local CPUSET="0-15"
	local THREADS=16
	local FILE_SUFFIX="${file:-default}"
	local MUTILATE="taskset -c 0-15 $MUTILATE_BIN -T 16 -s $SERVER_IP:$SERVER_PORT -u 0.03 -d 1 -K fb_key -V fb_value -i fb_ia -r 1000000"
	
	# Start agents on remote machines if agent IPs provided
	if [ -n "$AGENT_IPS" ]; then
		echo ">>> Starting mutilate agents on: $AGENT_IPS"
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			echo "    Starting agent on $agent"
			ssh "alireza@${agent}" "${MUTILATE_BIN} -A" 2>/dev/null &
		done
		sleep 2
		
		# Check if agents are listening on port 5556
		for agent in "${AGENT_ARRAY[@]}"; do
			timeout 5 bash -c "until nc -z $agent 5556; do sleep 0.1; done" 2>/dev/null || \
				echo "WARNING: Agent on $agent may not be ready"
		done
	fi
	
	# LOAD phase
	echo ">>> Running LOAD phase"
	timeout 40s ssh "alireza@${DRIVER_IP}" \
		"${MUTILATE} --loadonly" \
		|| echo "LOAD FAILED" >> "memcached-${FILE_SUFFIX}.out"
	
	# WARM UP phase
	echo ">>> Running WARM UP phase"
	echo "${MUTILATE} ${AGENTS_STR} --noload -t 5"
	timeout 10s ssh "alireza@${DRIVER_IP}" \
		"${MUTILATE} ${AGENTS_STR} --noload -t 5 -c 16 -q 0" 
		>/dev/null 2>&1 || echo "WARMUP FAILED" >> "memcached-${FILE_SUFFIX}.out"
	
	# RUN phase (actual experiment)
	echo ">>> Running EXPERIMENT phase"
	echo "${MUTILATE} ${AGENTS_STR} --noload -t 20 -q 0"
	timeout 40s ssh "alireza@${DRIVER_IP}" \
		"${MUTILATE} ${AGENTS_STR} --noload -t 20 -c 16 -q 0"
	
	# Stop agents if they were started
	if [ -n "$AGENT_IPS" ]; then
		echo ">>> Stopping mutilate agents"
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			ssh "alireza@${agent}" "killall -q mutilate" 2>/dev/null || true
		done
	fi
	
	# Stop driver mutilate processes
	ssh "alireza@${DRIVER_IP}" "killall -q mutilate" 2>/dev/null || true
}

# Stop memcached server
function stop_memcached() {
	echo ""
	echo "To stop memcached:"
	echo "  kill $MEMCACHED_PID"
	echo "  or: killall memcached"
	echo ""
	killall memcached
}

# Main execution flow
function main() {
	initialize_defaults
	parse_arguments "$@"
	build_memvar
	validate_configuration
	display_configuration
	# configure_irq_settings
	start_memcached
	run_mutilate_benchmark "${DRIVER_IP}" "${IFACE_IP}" "${AGENTS_STRING}"
	stop_memcached
}

# Run main function with all arguments
main "$@"

exit 0
