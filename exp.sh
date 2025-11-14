#!/bin/bash

source $(dirname $0)/util.sh

SCRIPT_DIR="$(dirname $0)"
NDCLI="../linux/net-next/tools/net/ynl/pyynl/cli.py --no-schema --output-json --spec ../linux/net-next/Documentation/netlink/specs/netdev.yaml"

declare -g IFACE IRQ_COUNT CPUSET GRO_TIMEOUT DEFER_IRQS SUSPEND_TIMEOUT
declare -g MEMCACHED_DIR OTHER_CPUS DRIVER_IP AGENT_IPS AGENTS_STRING IFACE_IP MEMCACHED_BIN
declare -g BUSY_POLL_USECS BUSY_POLL_BUDGET BUSY_POLL_PREFER
declare -g MEMCACHED_EXTRA_FLAGS MEMVAR MEMCACHED_PID
declare -g OUTPUT_DIR OUTPUT_CSV EXPERIMENT_DURATION
declare -g IRQ_CONFIG_CACHE="/tmp/exp_irq_config_cache.txt"
declare -g VERBOSITY=0
declare -g SCENARIO_NAME=""

function log_info() { echo "$@"; }
function log_verbose() { [ $VERBOSITY -ge 1 ] && echo "$@"; }
function log_debug() { [ $VERBOSITY -ge 2 ] && echo "$@"; }

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
	echo "  --fullbusy                         Enable fullbusy mode (adds -y flag to memcached)"
	echo "  --output-dir <path>                Output directory for results (default: ./results)"
	echo "  --duration <sec>                   Experiment duration in seconds (default: 20)"
	echo "  --scenario-name <name>             Name for this scenario (for CSV output)"
	echo "  -v,                                Verbose output (show configuration steps)"
	echo "  -vv                                Very verbose output (show all details)"
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
	OUTPUT_DIR="./results"
	EXPERIMENT_DURATION=5
}

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
			--output-dir)
				OUTPUT_DIR=$2; shift 2;;
			--duration)
				EXPERIMENT_DURATION=$2; shift 2;;
			--scenario-name)
				SCENARIO_NAME=$2; shift 2;;
			-vv)
				VERBOSITY=2; shift 1;;
			-v)
				VERBOSITY=1; shift 1;;
			-h|--help)
				usage;;
			*)
				echo "Unknown option: $1"
				usage;;
		esac
	done
	
	if [ -n "$AGENT_IPS" ]; then
		AGENTS_STRING=""
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			AGENTS_STRING+=" -a $agent"
		done
	fi
	
	$opt_fullbusy && MEMCACHED_EXTRA_FLAGS="$MEMCACHED_EXTRA_FLAGS -y"
}

function build_memvar() {
	MEMVAR=""
	[ -n "$BUSY_POLL_USECS" ] && MEMVAR+="_MP_Usecs=$BUSY_POLL_USECS "
	[ -n "$BUSY_POLL_BUDGET" ] && MEMVAR+="_MP_Budget=$BUSY_POLL_BUDGET "
	[ -n "$BUSY_POLL_PREFER" ] && MEMVAR+="_MP_Prefer=$BUSY_POLL_PREFER "
	MEMVAR=$(echo "$MEMVAR" | sed 's/ $//')
}

function parse_and_save_results() {
	local output_file="$1"
	local scenario_name="$2"
	local total_irqs_fired="${3:-0}"
	
	[[ ! -f "$output_file" ]] && { echo "WARNING: Output file not found: $output_file"; return 1; }
	
	local hostname=$(hostname)
	local qps=$(awk '/Total QPS/ {print $4}' "$output_file")
	local avg_read_latency=$(awk '/^read/ {print $2}' "$output_file")
	local latency_99th_read=$(awk '/^read/ {print $10}' "$output_file")
	local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	
	[[ -z "$qps" ]] && { echo "WARNING: Could not parse QPS from output file"; return 1; }
	
	echo "$hostname,$scenario_name,$IRQ_COUNT,$CPUSET,$GRO_TIMEOUT,$DEFER_IRQS,$SUSPEND_TIMEOUT,$BUSY_POLL_USECS,$BUSY_POLL_BUDGET,$BUSY_POLL_PREFER,$total_irqs_fired,$qps,$avg_read_latency,$latency_99th_read,$EXPERIMENT_DURATION,$timestamp" >> "$OUTPUT_CSV"
	
	log_info ">>> Results: QPS=$qps, Avg=${avg_read_latency}ms, p99=${latency_99th_read}ms"
	log_verbose ">>> Results saved to: $OUTPUT_CSV"
	log_debug "    Hostname: $hostname"
	log_debug "    Scenario: $scenario_name"
	log_debug "    Cores: $IRQ_COUNT"
	log_verbose ""
}

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
	
	mkdir -p "$OUTPUT_DIR"
	OUTPUT_CSV="$OUTPUT_DIR/results.csv"
	
	[[ ! -f "$OUTPUT_CSV" ]] && \
		echo "hostname,scenario,cores,cpuset,gro_flush_timeout,defer_hard_irqs,irq_suspend_timeout,busy_poll_usecs,busy_poll_budget,busy_poll_prefer,total_irqs_fired,QPS,avg_read_latency,latency_99th_read,duration,timestamp" > "$OUTPUT_CSV"
}

function display_configuration() {
	log_verbose "========================================="
	log_verbose "Experiment Configuration"
	log_verbose "========================================="
	log_verbose "Interface:        $IFACE"
	log_verbose "Interface IP:     $IFACE_IP"
	log_verbose "Driver IP:        $DRIVER_IP"
	log_verbose "Agent IPs:        ${AGENT_IPS:-none (driver only)}"
	log_verbose "IRQ Count:        $IRQ_COUNT"
	log_verbose "CPU Set:          $CPUSET"
	log_verbose "Other CPUs:       ${OTHER_CPUS:-none}"
	log_verbose "GRO Timeout:      $GRO_TIMEOUT µs"
	log_verbose "Defer IRQs:       $DEFER_IRQS"
	log_verbose "Suspend Timeout:  $SUSPEND_TIMEOUT µs"
	log_verbose "Busy Poll Usecs:  ${BUSY_POLL_USECS:-none}"
	log_verbose "Busy Poll Budget: ${BUSY_POLL_BUDGET:-none}"
	log_verbose "Busy Poll Prefer: ${BUSY_POLL_PREFER:-none}"
	log_verbose "Memcached Dir:    $MEMCACHED_DIR"
	log_verbose "Extra Flags:      ${MEMCACHED_EXTRA_FLAGS:-none}"
	log_verbose "========================================="
	log_verbose ""
}

function check_irq_config_changed() {
	local current_config="${IFACE}|${IRQ_COUNT}|${CPUSET}|${OTHER_CPUS}|${GRO_TIMEOUT}|${DEFER_IRQS}|${SUSPEND_TIMEOUT}"
	
	[[ ! -f "$IRQ_CONFIG_CACHE" ]] && { echo "$current_config" > "$IRQ_CONFIG_CACHE"; return 1; }
	
	local cached_config=$(cat "$IRQ_CONFIG_CACHE")
	if [[ "$current_config" == "$cached_config" ]]; then
		return 0
	else
		echo "$current_config" > "$IRQ_CONFIG_CACHE"
		return 1
	fi
}

function configure_irq_settings() {
	if check_irq_config_changed; then
		log_verbose "========================================="
		log_verbose ">>> IRQ configuration unchanged, skipping..."
		log_verbose "========================================="
		log_verbose ""
		log_debug ">>> Current IRQ configuration:"
		[ $VERBOSITY -ge 2 ] && NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE show
		log_verbose ""
		return 0
	fi
	
	log_verbose ">>> Setting queue count to $IRQ_COUNT"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setq $IRQ_COUNT

	[ -n "$OTHER_CPUS" ] && {
		log_verbose ">>> Setting other IRQs to CPU set: $OTHER_CPUS"
		NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setirqN $OTHER_CPUS 0 0
	}

	log_verbose ">>> Binding IRQs 1:1 to CPU set: $CPUSET"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setirq1 $CPUSET 0 $IRQ_COUNT

	log_verbose ">>> Setting poll parameters (gro=$GRO_TIMEOUT, defer=$DEFER_IRQS, suspend=$SUSPEND_TIMEOUT)"
	NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE setpoll $GRO_TIMEOUT $DEFER_IRQS $SUSPEND_TIMEOUT >/dev/null 2>&1

	log_verbose ""
	log_debug ">>> Current IRQ configuration:"
	[ $VERBOSITY -ge 2 ] && NDCLI="$NDCLI" "$SCRIPT_DIR/irq.sh" $IFACE show
	log_verbose ""
}

function start_memcached() {
	ulimit -Sn 65536
	local MEMCACHED_ARGS="-t $IRQ_COUNT -N $IRQ_COUNT -p 11212 -b 16384 -c 32768 -m 2048"
	MEMCACHED_ARGS+=" -o hashpower=24,no_lru_maintainer,no_lru_crawler"
	MEMCACHED_ARGS+=" -l $IFACE_IP -u $USER $MEMCACHED_EXTRA_FLAGS"
	local MEMCACHED_CMD="$MEMVAR taskset -c $CPUSET $MEMCACHED_BIN $MEMCACHED_ARGS"

	log_verbose ">>> Starting memcached:"
	[ -n "$MEMVAR" ] && log_debug "    Environment: $MEMVAR"
	log_debug "    Command: taskset -c $CPUSET $MEMCACHED_BIN $MEMCACHED_ARGS"
	log_verbose ""

	killall -q memcached 2>/dev/null
	sleep 1

	eval $MEMCACHED_CMD &
	MEMCACHED_PID=$!

	log_verbose ">>> Memcached started with PID: $MEMCACHED_PID"
	log_verbose ">>> Listening on: $IFACE_IP:11212"
	log_verbose ""
}

function run_mutilate_benchmark() {
	local DRIVER_IP="$1"
	local SERVER_IP="$2"
	local AGENTS_STR="$3"
	local SERVER_PORT="11212"
	local MUTILATE_BIN="/home/alireza/workspace/mutilate/mutilate"
	local FILE_SUFFIX="${file:-default}"
	local MUTILATE="taskset -c 0-7 $MUTILATE_BIN -T 8 -s $SERVER_IP:$SERVER_PORT -u 0.03 -d 1 -K fb_key -V fb_value -i fb_ia -r 1000000"
	
	if [ -n "$AGENT_IPS" ]; then
		log_verbose ">>> Starting mutilate agents on: $AGENT_IPS"
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			log_debug "    Starting agent on $agent"
			ssh "alireza@${agent}" taskset -c 0-7 "${MUTILATE_BIN} -A -T 8" 2>/dev/null &
		done
		sleep 2
		
		for agent in "${AGENT_ARRAY[@]}"; do
			timeout 5 bash -c "until nc -z $agent 5556; do sleep 0.1; done" 2>/dev/null || \
				log_verbose "WARNING: Agent on $agent may not be ready"
		done
	fi
	
	log_verbose ">>> Running LOAD phase"
	local max_retries=3
	local retry_count=0
	local load_success=false
	
	while [ $retry_count -lt $max_retries ] && [ "$load_success" = false ]; do
		if [ $retry_count -gt 0 ]; then
			log_info ">>> LOAD phase timed out. Restarting memcached and retrying (attempt $((retry_count + 1))/$max_retries)..."
			
			# Kill and restart memcached
			killall -9 memcached 2>/dev/null
			sleep 2
			
			# Restart memcached using the start_memcached function
			start_memcached
		fi
		
		# Try to load data
		if timeout 10s ssh "alireza@${DRIVER_IP}" \
			"${MUTILATE_BIN} --loadonly -s $SERVER_IP:$SERVER_PORT -K fb_key -V fb_value -i fb_ia -r 1000000" >/dev/null 2>&1; then
			load_success=true
			log_verbose ">>> LOAD phase completed successfully"
		else
			((retry_count++))
			if [ $retry_count -ge $max_retries ]; then
				log_info "ERROR: LOAD phase failed after $max_retries attempts"
				echo "LOAD FAILED" >> "memcached-${FILE_SUFFIX}.out"
				return 1
			fi
		fi
	done
	
	# WARM UP phase
	log_verbose ">>> Running WARM UP phase"
	log_debug "${MUTILATE} ${AGENTS_STR} --noload -t 10 -c 16 -q 0"
	timeout 30s ssh "alireza@${DRIVER_IP}" \
		"${MUTILATE} ${AGENTS_STR} --noload -t 1 -c 16 -q 0" \
		>/dev/null 2>&1 || log_verbose "WARMUP FAILED" >> "memcached-${FILE_SUFFIX}.out"
	
	# RUN phase (actual experiment)
	local SCENARIO_NAME="${4:-experiment}"
	local TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
	local OUTPUT_FILE="${OUTPUT_DIR}/mutilate-${SCENARIO_NAME}-${TIMESTAMP}.txt"

	./irq.sh "$IFACE" count > /dev/null 2>&1

	log_info ">>> Running experiment: ${SCENARIO_NAME} (duration: ${EXPERIMENT_DURATION}s)"
	log_debug "${MUTILATE} ${AGENTS_STR} --noload -t ${EXPERIMENT_DURATION} -c 16 -q 0"
	timeout $((EXPERIMENT_DURATION + 20)) ssh "alireza@${DRIVER_IP}" \
		"${MUTILATE} ${AGENTS_STR} --noload -t ${EXPERIMENT_DURATION} -c 16 -q 0" \
		| tee "$OUTPUT_FILE"

	# Capture IRQ stats after the run and parse total fired
	IRQ_TMP_FILE=$(mktemp)
	./irq.sh "$IFACE" count > "$IRQ_TMP_FILE" 2>/dev/null || true
	local total_irqs_fired=$(awk '/^total/ {print $2}' "$IRQ_TMP_FILE" | tr -d ' ')
	rm -f "$IRQ_TMP_FILE"

	# Stop agents if they were started
	if [ -n "$AGENT_IPS" ]; then
		log_debug ">>> Stopping mutilate agents"
		IFS=',' read -ra AGENT_ARRAY <<< "$AGENT_IPS"
		for agent in "${AGENT_ARRAY[@]}"; do
			ssh "alireza@${agent}" "killall -q mutilate" 2>/dev/null || true
		done
	fi
	
	# Stop driver mutilate processes
	ssh "alireza@${DRIVER_IP}" "killall -q mutilate" 2>/dev/null || true
	
	# Parse and save results
	log_verbose ""
	parse_and_save_results "$OUTPUT_FILE" "$SCENARIO_NAME" "$total_irqs_fired"
	
	# Clean up temporary output file
	rm -f "$OUTPUT_FILE"
	log_debug ">>> Cleaned up temporary output file"
}

# Stop memcached server
function stop_memcached() {
	log_verbose ""
	log_verbose "To stop memcached:"
	log_verbose "  kill $MEMCACHED_PID"
	log_verbose "  or: killall memcached"
	log_verbose ""
	killall memcached
}

# Main execution flow
function main() {
	initialize_defaults
	parse_arguments "$@"
	build_memvar
	validate_configuration
	display_configuration
	configure_irq_settings
	start_memcached
	
	# Use provided scenario name or build from parameters
	local scenario_name="${SCENARIO_NAME:-gro${GRO_TIMEOUT}_defer${DEFER_IRQS}_suspend${SUSPEND_TIMEOUT}}"
	run_mutilate_benchmark "${DRIVER_IP}" "${IFACE_IP}" "${AGENTS_STRING}" "${scenario_name}"
	
	stop_memcached
}

# Run main function with all arguments
main "$@"

exit 0
