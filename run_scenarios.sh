#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_FILE="${SCRIPT_DIR}/scenarios.json"

source "${SCRIPT_DIR}/util.sh"

function usage() {
	echo "Usage: $(basename $0) <interface> -i <irq_count> -c <cpuset> -m <memcached_dir> --driver-ip <ip> [options]"
	echo ""
	echo "Required options:"
	echo "  -i, --irq-count <num>          Number of IRQs/queues to configure"
	echo "  -c, --cpuset <cpuset>          CPU set for 1:1 IRQ binding"
	echo "  -m, --memcached-dir <path>     Directory containing memcached binary"
	echo "  --driver-ip <ip>               Driver client SSH IP address"
	echo ""
	echo "Scenario options:"
	echo "  --scenarios <s1,s2,...> | ALL  Comma-separated list of scenarios to run"
	echo "  --runs <num>                   Number of times to run each scenario (default: 1)"
	echo "  --list-scenarios               List available scenarios and exit"
	echo ""
	echo "Optional:"
	echo "  -o, --other-cpus <cpuset>      CPU set for other/non-queue IRQs"
	echo "  --agent-ips <ip1,ip2,...>      Comma-separated agent IPs for mutilate"
	echo "  --output-dir <path>            Directory for output files (default: ./results)"
	echo "  -h, --help                     Show this help"
	echo ""
	echo "Available scenarios:"
	echo "  base, defer20, defer200, napibusy, fullbusy, suspend10, suspend20"
	echo ""
	echo "Examples:"
	echo "  $(basename $0) enp7s0 -i 8 -c 0-7 -m ~/work/memcached --driver-ip 192.168.1.100 --scenarios base,defer20,fullbusy --runs 3"
	echo "  $(basename $0) enp7s0 -i 8 -c 0-7 -m ~/work/memcached --driver-ip 192.168.1.100 --list-scenarios"
	exit 0
}

function list_scenarios() {
	echo "Available scenarios in ${SCENARIOS_FILE}:"
	echo ""
	jq -r '.scenarios | to_entries[] | "\(.key):\n  \(.value.description)\n  gro=\(.value.gro_flush_timeout) defer=\(.value.defer_hard_irqs) suspend=\(.value.irq_suspend_timeout)\n  busy_poll: usecs=\(.value.busy_poll_usecs) budget=\(.value.busy_poll_budget) prefer=\(.value.busy_poll_prefer)\n  flags=\(.value.memcached_extra_flags // "none")\n"' "$SCENARIOS_FILE"
	exit 0
}

function validate_scenario() {
	local scenario=$1
	jq -e ".scenarios.${scenario}" "$SCENARIOS_FILE" > /dev/null 2>&1
	return $?
}

function get_scenario_value() {
	local scenario=$1
	local key=$2
	jq -r ".scenarios.${scenario}.${key}" "$SCENARIOS_FILE"
}

function is_io_uring_scenario() {
	local scenario=$1
	[[ "$scenario" == io_uring_* ]]
	return $?
}

function build_io_uring_stack() {
	echo "========================================="
	echo "Building io_uring stack"
	echo "========================================="
	
	# Build uringshim
	local URINGSHIM_DIR="/home/alireza/workspace/uringshim"
	echo ">>> Building uringshim in $URINGSHIM_DIR"
	if [ -d "$URINGSHIM_DIR" ]; then
		cd "$URINGSHIM_DIR" || ERROR "Failed to cd to $URINGSHIM_DIR"
		make clean >/dev/null 2>&1 || true
		if sudo make install; then
			echo "✓ uringshim built successfully"
		else
			ERROR "Failed to build uringshim"
		fi
	else
		ERROR "uringshim directory not found: $URINGSHIM_DIR"
	fi
	
	# Build memuring
	local MEMURING_DIR="/home/alireza/workspace/memuring"
	echo ">>> Building memuring in $MEMURING_DIR"
	if [ -d "$MEMURING_DIR" ]; then
		cd "$MEMURING_DIR" || ERROR "Failed to cd to $MEMURING_DIR"
		make clean >/dev/null 2>&1 || true
		if make -j$(nproc); then
			echo "✓ memuring built successfully"
		else
			ERROR "Failed to build memuring"
		fi
	else
		ERROR "memuring directory not found: $MEMURING_DIR"
	fi
	
	cd "$SCRIPT_DIR" || ERROR "Failed to return to script directory"
	echo "========================================="
	echo ""
}

# Parse arguments
[ $# -lt 1 ] && usage
IFACE=$1
shift

unset IRQ_COUNT CPUSET MEMCACHED_DIR DRIVER_IP OTHER_CPUS AGENT_IPS SCENARIOS RUNS OUTPUT_DIR

RUNS=1
OUTPUT_DIR="./results"
DEFAULT_MEMCACHED_DIR="/home/alireza/workspace/work-martin/irqsuspend/memcached"

while [ $# -gt 0 ]; do
	case $1 in
		-i|--irq-count)
			IRQ_COUNT=$2; shift 2;;
		-c|--cpuset)
			CPUSET=$2; shift 2;;
		-m|--memcached-dir)
			MEMCACHED_DIR=$2; shift 2;;
		--driver-ip)
			DRIVER_IP=$2; shift 2;;
		-o|--other-cpus)
			OTHER_CPUS=$2; shift 2;;
		--agent-ips)
			AGENT_IPS=$2; shift 2;;
		--scenarios)
			SCENARIOS=$2; shift 2;;
		--runs)
			RUNS=$2; shift 2;;
		--output-dir)
			OUTPUT_DIR=$2; shift 2;;
		--list-scenarios)
			list_scenarios;;
		-h|--help)
			usage;;
		*)
			echo "Unknown option: $1"
			usage;;
	esac
done

# Validate required parameters
[ -z "$IRQ_COUNT" ] && ERROR "IRQ count (-i) is required"
[ -z "$CPUSET" ] && ERROR "CPU set (-c) is required"
[ -z "$DRIVER_IP" ] && ERROR "Driver IP (--driver-ip) is required"
[ -z "$SCENARIOS" ] && ERROR "Scenarios (--scenarios) is required"

# Set default memcached directory if not specified
[ -z "$MEMCACHED_DIR" ] && MEMCACHED_DIR="$DEFAULT_MEMCACHED_DIR"

# Check if scenarios file exists
[ -f "$SCENARIOS_FILE" ] || ERROR "Scenarios file not found: $SCENARIOS_FILE"

# Check if jq is installed
command -v jq >/dev/null 2>&1 || ERROR "jq is required but not installed. Install with: sudo apt-get install jq"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Parse scenarios list
# Parse scenarios list
# If the user passed ALL (case-insensitive), load all scenario keys from the JSON
if [[ "${SCENARIOS}" == "ALL" || "${SCENARIOS}" == "all" ]]; then
	# read all keys from scenarios.json into the array
	mapfile -t SCENARIO_ARRAY < <(jq -r '.scenarios | keys[]' "$SCENARIOS_FILE")
	# rebuild the comma-separated SCENARIOS string for logging/consistency
	SCENARIOS=$(IFS=,; echo "${SCENARIO_ARRAY[*]}")
else
	IFS=',' read -ra SCENARIO_ARRAY <<< "$SCENARIOS"
fi

# Validate all scenarios exist and check if any are io_uring scenarios
HAS_IO_URING_SCENARIO=false
for scenario in "${SCENARIO_ARRAY[@]}"; do
	if ! validate_scenario "$scenario"; then
		ERROR "Unknown scenario: $scenario. Use --list-scenarios to see available scenarios."
	fi
	if is_io_uring_scenario "$scenario"; then
		HAS_IO_URING_SCENARIO=true
	fi
done

# Build io_uring stack if needed
if [ "$HAS_IO_URING_SCENARIO" = true ]; then
	build_io_uring_stack
fi

echo "========================================="
echo "Scenario Runner Configuration"
echo "========================================="
echo "Interface:     $IFACE"
echo "IRQ Count:     $IRQ_COUNT"
echo "CPU Set:       $CPUSET"
echo "Driver IP:     $DRIVER_IP"
echo "Agent IPs:     ${AGENT_IPS:-none}"
echo "Scenarios:     ${SCENARIOS}"
echo "Runs per test: $RUNS"
echo "Output dir:    $OUTPUT_DIR"
echo "Default memcached: $DEFAULT_MEMCACHED_DIR"
echo "io_uring memcached: /home/alireza/workspace/memuring"
echo "========================================="
echo ""

# Run experiments
total_tests=$((${#SCENARIO_ARRAY[@]} * $RUNS))
current_test=0

for scenario in "${SCENARIO_ARRAY[@]}"; do
	for ((run=1; run<=$RUNS; run++)); do
		((current_test++))
		
		echo ""
		echo "========================================="
		echo "Test $current_test/$total_tests: Scenario=$scenario, Run=$run"
		echo "========================================="
		
		# Determine memcached directory based on scenario type
		if is_io_uring_scenario "$scenario"; then
			CURRENT_MEMCACHED_DIR="/home/alireza/workspace/memuring"
			echo ">>> Using io_uring memcached: $CURRENT_MEMCACHED_DIR"
		else
			CURRENT_MEMCACHED_DIR="$DEFAULT_MEMCACHED_DIR"
			echo ">>> Using standard memcached: $CURRENT_MEMCACHED_DIR"
		fi
		
		# Get scenario parameters from JSON
		gro=$(get_scenario_value "$scenario" "gro_flush_timeout")
		defer=$(get_scenario_value "$scenario" "defer_hard_irqs")
		suspend=$(get_scenario_value "$scenario" "irq_suspend_timeout")
		usecs=$(get_scenario_value "$scenario" "busy_poll_usecs")
		budget=$(get_scenario_value "$scenario" "busy_poll_budget")
		prefer=$(get_scenario_value "$scenario" "busy_poll_prefer")
		flags=$(get_scenario_value "$scenario" "memcached_extra_flags")
		
		# Build common arguments with scenario-specific memcached dir
		COMMON_ARGS="$IFACE -i $IRQ_COUNT -c $CPUSET -m $CURRENT_MEMCACHED_DIR --driver-ip $DRIVER_IP --duration 5 -vv"
		[ -n "$OTHER_CPUS" ] && COMMON_ARGS+=" -o $OTHER_CPUS"
		[ -n "$AGENT_IPS" ] && COMMON_ARGS+=" --agent-ips $AGENT_IPS"
		
		# Build scenario-specific arguments
		SCENARIO_ARGS="-g $gro -d $defer -s $suspend --scenario-name $scenario"
		[ "$usecs" != "0" ] && SCENARIO_ARGS+=" --busy-poll-usecs $usecs"
		[ "$budget" != "0" ] && SCENARIO_ARGS+=" --busy-poll-budget $budget"
		[ "$prefer" != "0" ] && SCENARIO_ARGS+=" --busy-poll-prefer $prefer"
		[ "$flags" != "null" ] && [ -n "$flags" ] && SCENARIO_ARGS+=" --memcached-extra-flags '$flags'"
		
		# Set output file prefix
		output_prefix="${OUTPUT_DIR}/log/${scenario}-run${run}"
		
		echo "Running: ${SCRIPT_DIR}/exp.sh $COMMON_ARGS $SCENARIO_ARGS"
		echo "Output prefix: $output_prefix"
		echo ""
		
		# Run the experiment
		OUTPUT_PREFIX="$output_prefix" "${SCRIPT_DIR}/exp.sh" $COMMON_ARGS $SCENARIO_ARGS 2>&1 | tee "${output_prefix}.log"
		
		# Check if experiment succeeded
		if [ ${PIPESTATUS[0]} -eq 0 ]; then
			echo "✓ Test completed successfully"
		else
			echo "✗ Test failed"
		fi
		
		# Wait between tests
		if [ $current_test -lt $total_tests ]; then
			echo ""
			echo "Waiting 2 seconds before next test..."
			sleep 2
		fi
	done
done

echo ""
echo "========================================="
echo "All tests completed!"
echo "========================================="
echo "Results saved to: $OUTPUT_DIR"
echo ""

exit 0
