#!/bin/bash

# Dapr Workflow Restart Issue Reproduction Script
# This script reproduces an issue where workflow activities continue executing 
# infinitely after a Redis/Dapr restart, even when the workflow instance is not found

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
API_URL="http://localhost:8080"
WORKFLOW_ID="test-workflow-$(date +%s)-$$"

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}=== STEP: $1 ===${NC}"
}

check_existing_containers() {
    log_info "Checking for existing docker-compose containers..."
    
    # Check if any containers from this compose file are running
    local running_containers=$(docker-compose ps -q 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$running_containers" -gt 0 ]; then
        log_warn "Found $running_containers existing containers from this docker-compose stack"
        docker-compose ps
        return 0  # Found existing containers
    else
        log_info "No existing containers found"
        return 1  # No existing containers
    fi
}

tear_down_existing_stack() {
    log_step "TEARING DOWN EXISTING STACK"
    log_warn "Stopping and removing all existing containers, networks, and volumes..."
    
    # Stop all containers
    log_info "Stopping containers..."
    docker-compose stop || log_warn "Some containers may not have been running"
    
    # Remove containers, networks, and volumes
    log_info "Removing containers, networks, and volumes..."
    docker-compose down --remove-orphans --volumes || log_warn "Some resources may not have existed"
    
    # Optional: Remove any dangling images (commented out to avoid affecting other projects)
    # log_info "Removing dangling images..."
    # docker image prune -f || log_warn "Failed to prune images"
    
    log_info "Stack teardown complete"
    
    # Wait a moment for cleanup to complete
    sleep 2
}

wait_for_api() {
    log_info "Waiting for API to be ready at $API_URL/health..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Simple test - just check if curl succeeds and gets any response
        if curl -s -f -m 5 "$API_URL/health" >/dev/null 2>&1; then
            log_info "API is ready!"
            # Double-check with a real response
            local health_response=$(curl -s -m 5 "$API_URL/health" 2>/dev/null || echo "failed")
            if echo "$health_response" | grep -q "healthy\|status"; then
                log_info "API health check confirmed"
                return 0
            else
                log_warn "API responded but health check unclear, continuing anyway..."
                return 0
            fi
        else
            log_info "Attempt $attempt/$max_attempts - API not ready, waiting 2 seconds..."
            
            # On first few attempts, show more debugging info
            if [ $attempt -le 3 ]; then
                log_info "Debug: Testing connection to $API_URL..."
                local debug_response=$(curl -s -m 3 "$API_URL/health" 2>&1 || echo "Connection failed")
                log_info "Debug response: $(echo "$debug_response" | head -n 1)"
            fi
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log_error "API failed to become ready after $max_attempts attempts"
    log_error "Final test:"
    curl -v -m 10 "$API_URL/health" || log_error "Final connection test failed"
    
    return 1
}

check_workflow_status() {
    local instance_id="$1"
    log_info "Checking workflow status for: $instance_id"
    
    local response=$(curl -s "$API_URL/workflow/$instance_id" 2>/dev/null || echo "ERROR")
    if [ "$response" = "ERROR" ]; then
        log_warn "Failed to get workflow status"
        return 1
    fi
    
    echo "$response" | jq . 2>/dev/null || echo "$response"
}

show_container_logs() {
    local container_name="$1"
    local lines="${2:-20}"
    
    log_info "=== Last $lines lines from $container_name ==="
    docker-compose logs --tail="$lines" "$container_name" || log_warn "Failed to get logs for $container_name"
    echo
}

cleanup() {
    log_step "CLEANUP"
    log_info "Containers not being stopped..."
}

# Trap to ensure cleanup on script exit
trap cleanup EXIT

main() {
    log_step "STARTING DAPR WORKFLOW ISSUE REPRODUCTION"
    
    # Step 0: Check for existing containers and clean up if needed
    if check_existing_containers; then
        tear_down_existing_stack
    fi
    
    # Step 1: Start containers fresh
    log_step "1. STARTING CONTAINERS FROM SCRATCH"
    log_info "Bringing up all containers with docker-compose (fresh start)..."
    
    # Ensure we start completely clean
    docker-compose down --remove-orphans --volumes || true
    docker-compose up -d
    
    # Verify containers started
    log_info "Container status after startup:"
    docker-compose ps
    
    # Wait for API to be ready
    wait_for_api
    
    # Step 2: Create workflow
    log_step "2. CREATING WORKFLOW"
    log_info "Creating workflow with ID: $WORKFLOW_ID"
    
    local create_response=$(curl -s -X POST "$API_URL/workflow/hello" \
        -H "Content-Type: application/json" \
        -d "{\"instance_id\": \"$WORKFLOW_ID\"}" \
        2>/dev/null)
    
    if echo "$create_response" | grep -q "error\|Error"; then
        log_error "Failed to create workflow: $create_response"
        exit 1
    fi
    
    log_info "Workflow created successfully:"
    echo "$create_response" | jq . 2>/dev/null || echo "$create_response"
    
    # Step 3: Wait for workflow to start executing
    log_step "3. WAITING FOR WORKFLOW EXECUTION"
    log_info "Waiting 45 seconds for workflow to start executing activities..."
    
    for i in {1..45}; do
        echo -n "."
        sleep 1
    done
    echo
    
    # Check initial status
    log_info "Initial workflow status:"
    check_workflow_status "$WORKFLOW_ID"
    
    # Show initial logs
    log_info "Initial container activity:"
    show_container_logs "fastapi" 10
    show_container_logs "dapr" 10
    
    # Step 4: Kill Redis and Dapr to simulate failure
    log_step "4. SIMULATING FAILURE (KILLING REDIS AND DAPR)"
    log_warn "Killing Redis and Dapr containers to simulate a restart scenario..."
    
    docker-compose kill redis dapr || log_warn "Some containers may not have been running"
    
    log_info "Killed containers. Current container status:"
    docker-compose ps
    
    # Step 5: Wait during outage
    log_step "5. WAITING DURING OUTAGE"
    log_info "Waiting 10 seconds to simulate downtime..."
    
    for i in {1..10}; do
        echo -n "."
        sleep 1
    done
    echo
    
    # Step 6: Restart containers
    log_step "6. RESTARTING CONTAINERS"
    log_info "Restarting containers with docker-compose up -d..."
    docker-compose up -d
    
    # Wait for services to be ready again
    wait_for_api
    
    # Step 7: Observe the issue
    log_step "7. DEMONSTRATING THE ISSUE"
    log_warn "Now observing the issue where activities continue executing infinitely..."
    log_warn "Even though the workflow instance may not be found after restart"
    
    # Try to check workflow status after restart
    log_info "Checking workflow status after restart:"
    check_workflow_status "$WORKFLOW_ID" || log_warn "Workflow status check failed as expected"
    
    # Show logs to demonstrate the issue
    log_step "8. ISSUE DEMONSTRATION - CONTAINER LOGS"
    log_error "=== SHOWING LOGS THAT DEMONSTRATE THE ISSUE ==="
    
    log_info "Waiting 20 seconds to collect logs showing the infinite execution..."
    sleep 20
    
    echo -e "\n${RED}=== FASTAPI CONTAINER LOGS (showing infinite activity execution) ===${NC}"
    show_container_logs "fastapi" 30
    
    echo -e "\n${RED}=== DAPR SIDECAR LOGS (showing instance not found errors) ===${NC}"
    show_container_logs "dapr" 30
    
    echo -e "\n${RED}=== DAPR SCHEDULER LOGS (showing continued activity scheduling) ===${NC}"
    show_container_logs "dapr-scheduler" 30
    
    # Additional observation period
    log_step "9. CONTINUED OBSERVATION"
    log_warn "The issue should now be visible in the logs above:"
    log_warn "1. Scheduler continues sending run-activity messages"
    log_warn "2. Sidecar reports 'workflow instance not found' errors"
    log_warn "3. BUT activities continue executing infinitely anyway"
    log_warn ""
    log_warn "Observing for another 30 seconds to confirm the infinite execution..."
    
    local start_time=$(date +%s)
    local activity_count_before=$(docker-compose logs fastapi | grep -c "Hello world!" || echo "0")
    
    sleep 30
    
    local end_time=$(date +%s)
    local activity_count_after=$(docker-compose logs fastapi | grep -c "No workflow state found for $WORKFLOW_ID but activity is being executed anyways" || echo "0")
    local duration=$((end_time - start_time))
    local new_activities=$((activity_count_after - activity_count_before))
    
    echo -e "\n${RED}=== ISSUE CONFIRMATION ===${NC}"
    log_error "In the last $duration seconds:"
    log_error "- Activities executed: $new_activities"
    log_error "- This demonstrates the infinite execution issue"
    
    if [ "$new_activities" -gt 0 ]; then
        log_error "✗ ISSUE CONFIRMED: Activities are executing infinitely after restart!"
    else
        log_warn "? Issue may not be visible in this run - check logs manually"
    fi
    
    log_step "10. FINAL LOGS SUMMARY"
    echo -e "\n${BLUE}=== FINAL STATE ===${NC}"
    docker-compose ps
    
    log_info "Script completed. The containers are still running for manual inspection."
    log_info "Use 'docker-compose logs -f [service_name]' to continue monitoring."
    log_info "Use 'docker-compose down' to clean up when done."
}

# Check dependencies
command -v docker-compose >/dev/null 2>&1 || { log_error "docker-compose is required but not installed. Aborting."; exit 1; }
command -v curl >/dev/null 2>&1 || { log_error "curl is required but not installed. Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { log_warn "jq not found - JSON output will be raw"; }

# Run main function
main "$@" 