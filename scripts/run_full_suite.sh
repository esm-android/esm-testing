#!/bin/bash
#
# run_full_suite.sh - Master script to run complete ESM performance test suite
#
# Runs all tests in sequence and generates final report.
#
# Usage:
#   ./run_full_suite.sh baseline    # Test stock AOSP
#   ./run_full_suite.sh esm         # Test ESM build
#   ./run_full_suite.sh analyze     # Generate comparison report
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
LOGS_DIR="$SCRIPT_DIR/../logs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Print banner
print_banner() {
    echo ""
    echo "=============================================="
    echo "   ESM Performance Test Suite"
    echo "=============================================="
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check ADB
    if ! command -v adb &> /dev/null; then
        log_error "ADB not found. Please install Android SDK platform-tools."
        exit 1
    fi

    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python3 not found. Please install Python 3."
        exit 1
    fi

    # Check device connection
    if ! adb devices | grep -q "device$"; then
        log_error "No Android device connected."
        log_info "Please connect your Pixel 5 and enable USB debugging."
        exit 1
    fi

    log_success "Prerequisites OK"
}

# Run setup
run_setup() {
    local build_type="$1"
    log_info "Setting up device for $build_type testing..."

    chmod +x "$SCRIPT_DIR/setup_device.sh"
    bash "$SCRIPT_DIR/setup_device.sh"

    log_success "Device setup complete"
}

# Run latency tests
run_latency() {
    local build_type="$1"
    log_info "Running latency tests..."

    chmod +x "$SCRIPT_DIR/run_latency_test.sh"
    bash "$SCRIPT_DIR/run_latency_test.sh" "$build_type"

    if [[ -f "$RESULTS_DIR/$build_type/latency.csv" ]]; then
        log_success "Latency tests complete"
    else
        log_warning "Latency results may be incomplete"
    fi
}

# Run CPU tests
run_cpu() {
    local build_type="$1"
    log_info "Running CPU tests..."

    chmod +x "$SCRIPT_DIR/run_cpu_test.sh"
    bash "$SCRIPT_DIR/run_cpu_test.sh" "$build_type"

    if [[ -f "$RESULTS_DIR/$build_type/cpu.csv" ]]; then
        log_success "CPU tests complete"
    else
        log_warning "CPU results may be incomplete"
    fi
}

# Run syscall tests
run_syscalls() {
    local build_type="$1"
    log_info "Running syscall tests..."

    chmod +x "$SCRIPT_DIR/run_syscall_test.sh"
    bash "$SCRIPT_DIR/run_syscall_test.sh" "$build_type"

    if [[ -f "$RESULTS_DIR/$build_type/syscalls.csv" ]]; then
        log_success "Syscall tests complete"
    else
        log_warning "Syscall results may be incomplete"
    fi
}

# Run wakeup tests
run_wakeups() {
    local build_type="$1"
    log_info "Running wakeup tests..."

    chmod +x "$SCRIPT_DIR/run_wakeup_test.sh"
    bash "$SCRIPT_DIR/run_wakeup_test.sh" "$build_type"

    if [[ -f "$RESULTS_DIR/$build_type/wakeups.csv" ]]; then
        log_success "Wakeup tests complete"
    else
        log_warning "Wakeup results may be incomplete"
    fi
}

# Generate analysis report
run_analysis() {
    log_info "Generating analysis report..."

    python3 "$SCRIPT_DIR/analyze_results.py"

    if [[ -f "$SCRIPT_DIR/../report.md" ]]; then
        log_success "Report generated: $SCRIPT_DIR/../report.md"
    else
        log_warning "Report generation may have failed"
    fi
}

# Print final summary
print_summary() {
    local build_type="$1"
    local results_path="$RESULTS_DIR/$build_type"

    echo ""
    echo "=============================================="
    echo "   Test Suite Complete: $build_type"
    echo "=============================================="
    echo ""
    echo "Results saved to: $results_path/"
    echo ""

    if [[ -d "$results_path" ]]; then
        echo "Generated files:"
        ls -la "$results_path/"
    fi

    echo ""
    echo "Next steps:"
    if [[ "$build_type" == "baseline" ]]; then
        echo "  1. Flash ESM build to device"
        echo "  2. Run: ./run_full_suite.sh esm"
        echo "  3. Run: ./run_full_suite.sh analyze"
    elif [[ "$build_type" == "esm" ]]; then
        echo "  1. Run: ./run_full_suite.sh analyze"
        echo "  2. Review: ../report.md"
    fi
    echo ""
}

# Show usage
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  baseline   Run tests on stock AOSP (epoll) build"
    echo "  esm        Run tests on ESM-modified build"
    echo "  analyze    Generate comparison report from both test sets"
    echo "  help       Show this help message"
    echo ""
    echo "Recommended workflow:"
    echo "  1. Flash baseline AOSP, run: $0 baseline"
    echo "  2. Flash ESM AOSP, run: $0 esm"
    echo "  3. Generate report, run: $0 analyze"
    echo ""
}

# Main
main() {
    local command="${1:-help}"

    print_banner

    case "$command" in
        baseline|esm)
            check_prerequisites

            # Confirm with user
            echo "This will run the complete test suite for '$command' build."
            echo "Estimated time: 2-3 hours"
            echo ""
            read -p "Continue? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Aborted."
                exit 0
            fi

            # Create output directories
            mkdir -p "$RESULTS_DIR/$command" "$LOGS_DIR"

            # Run test sequence
            START_TIME=$(date +%s)

            run_setup "$command"

            log_info "Starting test sequence..."
            echo ""

            run_latency "$command"
            echo ""

            run_cpu "$command"
            echo ""

            run_syscalls "$command"
            echo ""

            run_wakeups "$command"
            echo ""

            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            DURATION_MIN=$((DURATION / 60))

            print_summary "$command"

            log_success "Total test time: ${DURATION_MIN} minutes"
            ;;

        analyze)
            # Check if both result sets exist
            if [[ ! -d "$RESULTS_DIR/baseline" ]]; then
                log_error "Baseline results not found. Run baseline tests first."
                exit 1
            fi

            if [[ ! -d "$RESULTS_DIR/esm" ]]; then
                log_error "ESM results not found. Run ESM tests first."
                exit 1
            fi

            run_analysis

            echo ""
            log_success "Analysis complete!"
            echo ""
            echo "View report: cat $SCRIPT_DIR/../report.md"
            echo ""
            ;;

        help|--help|-h)
            usage
            ;;

        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
