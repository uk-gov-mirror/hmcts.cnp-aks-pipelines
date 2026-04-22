#!/usr/bin/env bash

# Clean up old images based on input parameters.

set -euo pipefail

registry=${1:-hmctspublic}
older_than="${2:-30d}"
keep_min_latest_num="${3:-5}"
repo_tag_filters="${4:-.*:-^ignore-.*}"

IFS=',' read -r -a repo_tag_array <<< "$repo_tag_filters"

filter_args=""
for repo_tag_filter in "${repo_tag_array[@]}"; do
    filter_args="$filter_args --filter $repo_tag_filter"
done
echo "$(TERM=xterm tput setaf 2)Cleaning up $registry, deleting [${filter_args}] images older than $older_than and keeping at least $keep_min_latest_num"

# Function to check if error is transient
is_transient_error() {
    local output="$1"
    # Check for common transient error patterns:
    # - HTTP 500 errors
    # - EOF errors
    # - Parse errors from Azure API
    # - Connection timeouts
    if echo "$output" | grep -qiE "(StatusCode=500|EOF|error response cannot be parsed|timeout|connection.*refused|temporary|transient)" 2>/dev/null; then
        return 0  # Is transient
    fi
    return 1  # Not transient
}

# Function to run cleanup with retry logic
run_cleanup_with_retry() {
    local max_retries=3
    local retry_delay=30  # seconds
    local attempt=1
    local temp_log
    temp_log=$(mktemp)
    local last_output=""
    local purge_cmd="acr purge --registry \$RegistryName ${filter_args} --ago ${older_than} --keep ${keep_min_latest_num} --untagged --concurrency 3"

    # Cleanup temp file on exit
    trap "rm -f \"$temp_log\"" EXIT

    while [ $attempt -le $max_retries ]; do
        echo "$(TERM=xterm tput setaf 6)Attempt $attempt of $max_retries..."
        echo "$(TERM=xterm tput setaf 6)Starting az acr run (streaming output; also saved for error handling):"
        echo "  registry=$registry"
        echo "  timeout=10800s"
        echo "  cmd=$purge_cmd"
        echo "$(TERM=xterm tput sgr0)---"
        # Stream CLI output to the terminal and capture the same stream for retries/errors
        set +e
        az acr run --registry "$registry" \
            --cmd "$purge_cmd" \
            --timeout 10800 /dev/null 2>&1 | tee "$temp_log"
        exit_code=$?
        last_output=$(cat "$temp_log" 2>/dev/null || echo "")
        set -e
        echo "$(TERM=xterm tput setaf 6)--- (exit code: $exit_code)"
        
        # If successful, return
        if [ $exit_code -eq 0 ]; then
            echo "$(TERM=xterm tput setaf 2)Cleanup completed successfully on attempt $attempt"
            rm -f "$temp_log"
            return 0
        fi
        
        # Check if error is transient based on exit code and output
        # Exit code 1 with 500 errors or parse errors are typically transient
        if [ $exit_code -eq 1 ] || is_transient_error "$last_output"; then
            if [ $attempt -lt $max_retries ]; then
                echo "$(TERM=xterm tput setaf 3)Transient error detected (attempt $attempt/$max_retries, exit code: $exit_code):"
                if [ -n "$last_output" ]; then
                    echo "$last_output" | tail -5
                else
                    echo "Error occurred during ACR cleanup task (check ACR task logs for details)"
                fi
                echo "$(TERM=xterm tput setaf 6)Retrying in ${retry_delay} seconds..."
                sleep $retry_delay
                # Exponential backoff for subsequent retries
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
            else
                echo "$(TERM=xterm tput setaf 1)Error: Cleanup failed after $max_retries attempts due to transient errors (exit code: $exit_code):"
                if [ -n "$last_output" ]; then
                    echo "$last_output" | tail -10
                fi
                echo "All retry attempts exhausted. Failing pipeline."
                rm -f "$temp_log"
                return $exit_code  # Fail the pipeline
            fi
        else
            # Permanent error - don't retry
            echo "$(TERM=xterm tput setaf 1)Permanent error detected (exit code: $exit_code, not retrying):"
            if [ -n "$last_output" ]; then
                echo "$last_output" | tail -10
            fi
            rm -f "$temp_log"
            return $exit_code
        fi
    done
    
    rm -f "$temp_log"
}

# Run cleanup with retry logic
run_cleanup_with_retry