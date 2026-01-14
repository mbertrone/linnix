#!/bin/bash
# cognitod-deploy.sh - Manage cognitod deployments across multiple clusters/nodes
#
# Usage:
#   ./cognitod-deploy.sh [--dry-run] deploy <cluster> <node-hostname>  - Deploy to a cluster/node
#   ./cognitod-deploy.sh list                                          - List all tracked deployments
#   ./cognitod-deploy.sh status                                        - Check actual status of deployments
#   ./cognitod-deploy.sh [--dry-run] delete <cluster> [node-hostname]  - Delete deployment(s)
#   ./cognitod-deploy.sh [--dry-run] clean                             - Clean all tracked deployments
#   ./cognitod-deploy.sh clusters                                      - List available clusters

set -e

# Global flags
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.cognitod-deployments.json"
TEMPLATE_FILE="${SCRIPT_DIR}/cognitod-staging-pod.yaml"
TEMP_DIR="${SCRIPT_DIR}/.cognitod-temp"
NAMESPACE="datadog-agent"
POD_BASE_NAME="cognitod"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Execute a command, or print it if dry-run is enabled
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN] Would execute: $*${NC}"
    else
        "$@"
    fi
}

# Print dry-run notice if enabled
dry_run_notice() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}=== DRY-RUN MODE - No changes will be made ===${NC}"
        echo ""
    fi
}

# Initialize state file if it doesn't exist
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"deployments": []}' > "$STATE_FILE"
    fi
    mkdir -p "$TEMP_DIR"
}

# Generate a unique pod name based on cluster and node
generate_pod_name() {
    local cluster="$1"
    local node="$2"
    # Extract short node identifier (last octet or short name)
    local node_short=$(echo "$node" | sed -E 's/ip-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+).*/\1-\2-\3-\4/' | cut -d'.' -f1)
    local cluster_short=$(echo "$cluster" | cut -d'.' -f1)
    echo "${POD_BASE_NAME}-${cluster_short}-${node_short}"
}

# Generate ConfigMap name based on pod name
generate_configmap_name() {
    local pod_name="$1"
    echo "${pod_name}-config"
}

# Add deployment to state
add_to_state() {
    local cluster="$1"
    local node="$2"
    local pod_name="$3"
    local configmap_name="$4"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local new_entry=$(jq -n \
        --arg cluster "$cluster" \
        --arg node "$node" \
        --arg pod_name "$pod_name" \
        --arg configmap_name "$configmap_name" \
        --arg timestamp "$timestamp" \
        '{cluster: $cluster, node: $node, pod_name: $pod_name, configmap_name: $configmap_name, created_at: $timestamp}')

    jq --argjson entry "$new_entry" '.deployments += [$entry]' "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Remove deployment from state
remove_from_state() {
    local cluster="$1"
    local node="$2"

    if [[ -z "$node" ]]; then
        # Remove all deployments for the cluster
        jq --arg cluster "$cluster" '.deployments = [.deployments[] | select(.cluster != $cluster)]' "$STATE_FILE" > "${STATE_FILE}.tmp"
    else
        # Remove specific deployment
        jq --arg cluster "$cluster" --arg node "$node" \
            '.deployments = [.deployments[] | select(.cluster != $cluster or .node != $node)]' "$STATE_FILE" > "${STATE_FILE}.tmp"
    fi
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Check if deployment exists in state
deployment_exists() {
    local cluster="$1"
    local node="$2"
    local count=$(jq --arg cluster "$cluster" --arg node "$node" \
        '[.deployments[] | select(.cluster == $cluster and .node == $node)] | length' "$STATE_FILE")
    [[ "$count" -gt 0 ]]
}

# Get deployment info from state
get_deployment() {
    local cluster="$1"
    local node="$2"
    jq --arg cluster "$cluster" --arg node "$node" \
        '.deployments[] | select(.cluster == $cluster and .node == $node)' "$STATE_FILE"
}

# Switch to cluster context
use_cluster() {
    local cluster="$1"
    echo -e "${BLUE}Switching to cluster: ${cluster}${NC}"
    ddtool clusters use "$cluster" > /dev/null 2>&1
}

# Generate manifest from template
generate_manifest() {
    local node="$1"
    local pod_name="$2"
    local configmap_name="$3"
    local output_file="$4"

    # Read the template and modify it
    sed -e "s/#    kubernetes.io\/hostname: ip-xx-xx-xx-xxx.ec2.internal/    kubernetes.io\/hostname: ${node}/" \
        -e "s/name: cognitod$/name: ${pod_name}/" \
        -e "s/name: cognitod-config/name: ${configmap_name}/g" \
        "$TEMPLATE_FILE" > "$output_file"
}

# Deploy to a cluster/node
cmd_deploy() {
    local cluster="$1"
    local node="$2"

    dry_run_notice

    if [[ -z "$cluster" || -z "$node" ]]; then
        echo -e "${RED}Error: cluster and node-hostname are required${NC}"
        echo "Usage: $0 deploy <cluster> <node-hostname>"
        echo "Example: $0 deploy stripe.us1.staging.dog ip-10-0-1-123.ec2.internal"
        exit 1
    fi

    # Check if already deployed
    if deployment_exists "$cluster" "$node"; then
        echo -e "${YELLOW}Warning: Deployment already exists for ${cluster}/${node}${NC}"
        echo "Use 'delete' command first if you want to redeploy"
        exit 1
    fi

    local pod_name=$(generate_pod_name "$cluster" "$node")
    local configmap_name=$(generate_configmap_name "$pod_name")
    local manifest_file="${TEMP_DIR}/${pod_name}.yaml"

    echo -e "${GREEN}Deploying cognitod to ${cluster} on node ${node}${NC}"
    echo "  Pod name: ${pod_name}"
    echo "  ConfigMap name: ${configmap_name}"

    # Generate manifest
    generate_manifest "$node" "$pod_name" "$configmap_name" "$manifest_file"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN] Generated manifest:${NC}"
        echo "---"
        cat "$manifest_file"
        echo "---"
    fi

    # Switch to cluster and apply
    use_cluster "$cluster"

    echo -e "${BLUE}Applying manifest...${NC}"
    run_cmd kubectl apply -f "$manifest_file"

    # Add to state (skip in dry-run)
    if [[ "$DRY_RUN" != "true" ]]; then
        add_to_state "$cluster" "$node" "$pod_name" "$configmap_name"
    else
        echo -e "${CYAN}[DRY-RUN] Would add to state: cluster=${cluster}, node=${node}, pod=${pod_name}${NC}"
    fi

    echo -e "${GREEN}Deployment successful!${NC}"
    echo "  To check status: kubectl get pod ${pod_name} -n ${NAMESPACE}"
    echo "  To view logs: kubectl logs ${pod_name} -n ${NAMESPACE} -f"
}

# List all tracked deployments
cmd_list() {
    echo -e "${BLUE}Tracked cognitod deployments:${NC}"
    echo ""

    local count=$(jq '.deployments | length' "$STATE_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "  No deployments tracked"
        return
    fi

    printf "%-35s %-40s %-25s %s\n" "CLUSTER" "NODE" "POD NAME" "CREATED"
    printf "%-35s %-40s %-25s %s\n" "-------" "----" "--------" "-------"

    jq -r '.deployments[] | "\(.cluster)|\(.node)|\(.pod_name)|\(.created_at)"' "$STATE_FILE" | \
    while IFS='|' read -r cluster node pod_name created_at; do
        printf "%-35s %-40s %-25s %s\n" "$cluster" "$node" "$pod_name" "$created_at"
    done
}

# Check actual status of deployments
cmd_status() {
    echo -e "${BLUE}Checking status of tracked deployments:${NC}"
    echo ""

    local count=$(jq '.deployments | length' "$STATE_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "  No deployments tracked"
        return
    fi

    printf "%-35s %-40s %-15s %s\n" "CLUSTER" "NODE" "STATUS" "RESTARTS"
    printf "%-35s %-40s %-15s %s\n" "-------" "----" "------" "--------"

    local current_cluster=""

    jq -r '.deployments[] | "\(.cluster)|\(.node)|\(.pod_name)"' "$STATE_FILE" | \
    while IFS='|' read -r cluster node pod_name; do
        # Switch cluster if needed
        if [[ "$cluster" != "$current_cluster" ]]; then
            use_cluster "$cluster" 2>/dev/null
            current_cluster="$cluster"
        fi

        # Get pod status
        local status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        local restarts=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "-")

        # Color code status
        local status_color="$NC"
        case "$status" in
            Running) status_color="$GREEN" ;;
            Pending) status_color="$YELLOW" ;;
            Failed|NotFound) status_color="$RED" ;;
        esac

        printf "%-35s %-40s ${status_color}%-15s${NC} %s\n" "$cluster" "$node" "$status" "$restarts"
    done
}

# Delete deployment(s)
cmd_delete() {
    local cluster="$1"
    local node="$2"

    dry_run_notice

    if [[ -z "$cluster" ]]; then
        echo -e "${RED}Error: cluster is required${NC}"
        echo "Usage: $0 delete <cluster> [node-hostname]"
        exit 1
    fi

    use_cluster "$cluster"

    if [[ -z "$node" ]]; then
        # Delete all deployments for the cluster
        echo -e "${YELLOW}Deleting all cognitod deployments from ${cluster}...${NC}"

        jq -r --arg cluster "$cluster" '.deployments[] | select(.cluster == $cluster) | "\(.pod_name)|\(.configmap_name)"' "$STATE_FILE" | \
        while IFS='|' read -r pod_name configmap_name; do
            echo "  Deleting pod: ${pod_name}"
            run_cmd kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true
            echo "  Deleting configmap: ${configmap_name}"
            run_cmd kubectl delete configmap "$configmap_name" -n "$NAMESPACE" --ignore-not-found=true
        done

        if [[ "$DRY_RUN" != "true" ]]; then
            remove_from_state "$cluster" ""
        else
            echo -e "${CYAN}[DRY-RUN] Would remove all ${cluster} entries from state${NC}"
        fi
    else
        # Delete specific deployment
        if ! deployment_exists "$cluster" "$node"; then
            echo -e "${YELLOW}No deployment found for ${cluster}/${node}${NC}"
            return
        fi

        local deployment=$(get_deployment "$cluster" "$node")
        local pod_name=$(echo "$deployment" | jq -r '.pod_name')
        local configmap_name=$(echo "$deployment" | jq -r '.configmap_name')

        echo -e "${YELLOW}Deleting cognitod deployment from ${cluster} on node ${node}...${NC}"
        echo "  Deleting pod: ${pod_name}"
        run_cmd kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true
        echo "  Deleting configmap: ${configmap_name}"
        run_cmd kubectl delete configmap "$configmap_name" -n "$NAMESPACE" --ignore-not-found=true

        if [[ "$DRY_RUN" != "true" ]]; then
            remove_from_state "$cluster" "$node"
        else
            echo -e "${CYAN}[DRY-RUN] Would remove ${cluster}/${node} from state${NC}"
        fi
    fi

    echo -e "${GREEN}Delete complete${NC}"
}

# Clean all tracked deployments
cmd_clean() {
    dry_run_notice

    echo -e "${YELLOW}Cleaning all tracked cognitod deployments...${NC}"
    echo ""

    local count=$(jq '.deployments | length' "$STATE_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "  No deployments to clean"
        return
    fi

    # Get unique clusters
    local clusters=$(jq -r '[.deployments[].cluster] | unique | .[]' "$STATE_FILE")

    for cluster in $clusters; do
        echo -e "${BLUE}Cleaning cluster: ${cluster}${NC}"
        use_cluster "$cluster"

        jq -r --arg cluster "$cluster" '.deployments[] | select(.cluster == $cluster) | "\(.pod_name)|\(.configmap_name)"' "$STATE_FILE" | \
        while IFS='|' read -r pod_name configmap_name; do
            echo "  Deleting pod: ${pod_name}"
            run_cmd kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true
            echo "  Deleting configmap: ${configmap_name}"
            run_cmd kubectl delete configmap "$configmap_name" -n "$NAMESPACE" --ignore-not-found=true
        done
    done

    # Clear state
    if [[ "$DRY_RUN" != "true" ]]; then
        echo '{"deployments": []}' > "$STATE_FILE"

        # Clean temp files
        rm -rf "$TEMP_DIR"
        mkdir -p "$TEMP_DIR"
    else
        echo -e "${CYAN}[DRY-RUN] Would clear state file and temp directory${NC}"
    fi

    echo ""
    echo -e "${GREEN}All deployments cleaned${NC}"
}

# List available clusters
cmd_clusters() {
    echo -e "${BLUE}Available clusters:${NC}"
    echo ""
    ddtool clusters list | jq -r '.[].name' | sort
}

# Format target from kube tags to deploy arguments
# Input: kube_node:ip-10-131-59-161.ec2.internal,kube_cluster_name:oddish-a
# Output: oddish-a.us1.staging.dog ip-10-131-59-161.ec2.internal
cmd_format_target() {
    local input="$1"

    if [[ -z "$input" ]]; then
        echo -e "${RED}Error: input string is required${NC}"
        echo "Usage: $0 format-target 'kube_node:ip-x-x-x-x.ec2.internal,kube_cluster_name:cluster-name'"
        exit 1
    fi

    # Extract node hostname from kube_node:xxx
    local node=$(echo "$input" | grep -oE 'kube_node:[^,]+' | cut -d: -f2)

    # Extract cluster short name from kube_cluster_name:xxx
    local cluster_short=$(echo "$input" | grep -oE 'kube_cluster_name:[^,]+' | cut -d: -f2)

    if [[ -z "$node" ]]; then
        echo -e "${RED}Error: Could not extract node from input${NC}"
        echo "Expected format: kube_node:ip-x-x-x-x.ec2.internal,kube_cluster_name:cluster-name"
        exit 1
    fi

    if [[ -z "$cluster_short" ]]; then
        echo -e "${RED}Error: Could not extract cluster name from input${NC}"
        echo "Expected format: kube_node:ip-x-x-x-x.ec2.internal,kube_cluster_name:cluster-name"
        exit 1
    fi

    # Look up full cluster name from ddtool
    echo -e "${BLUE}Looking up cluster '${cluster_short}'...${NC}" >&2
    local full_cluster=$(ddtool clusters list | jq -r '.[].name' | grep "^${cluster_short}\.")

    if [[ -z "$full_cluster" ]]; then
        echo -e "${RED}Error: Could not find cluster matching '${cluster_short}'${NC}" >&2
        echo "Available clusters:" >&2
        ddtool clusters list | jq -r '.[].name' | grep -i "${cluster_short}" | head -5 >&2
        exit 1
    fi

    # Check if multiple matches
    local match_count=$(echo "$full_cluster" | wc -l | tr -d ' ')
    if [[ "$match_count" -gt 1 ]]; then
        echo -e "${YELLOW}Warning: Multiple clusters match '${cluster_short}':${NC}" >&2
        echo "$full_cluster" >&2
        echo -e "${YELLOW}Using first match${NC}" >&2
        full_cluster=$(echo "$full_cluster" | head -1)
    fi

    # Output the formatted result (stdout for piping)
    echo "$full_cluster $node"
}

# Deploy using kube tags format directly
# Input: kube_node:ip-10-131-59-161.ec2.internal,kube_cluster_name:oddish-a
cmd_deploy_format() {
    local input="$1"

    if [[ -z "$input" ]]; then
        echo -e "${RED}Error: input string is required${NC}"
        echo "Usage: $0 deploy-format 'kube_node:ip-x-x-x-x.ec2.internal,kube_cluster_name:cluster-name'"
        exit 1
    fi

    # Use format-target to get cluster and node, then deploy
    local formatted=$(cmd_format_target "$input")
    local cluster=$(echo "$formatted" | awk '{print $1}')
    local node=$(echo "$formatted" | awk '{print $2}')

    cmd_deploy "$cluster" "$node"
}

# Clean up pods in Pending state
cmd_clean_pending() {
    echo -e "${BLUE}Checking for pods in Pending state...${NC}"
    echo ""

    local count=$(jq '.deployments | length' "$STATE_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "  No deployments tracked"
        return
    fi

    # Array to store pending deployments
    declare -a pending_deployments=()
    local current_cluster=""

    # Check each tracked deployment
    jq -r '.deployments[] | "\(.cluster)|\(.node)|\(.pod_name)|\(.configmap_name)"' "$STATE_FILE" | \
    while IFS='|' read -r cluster node pod_name configmap_name; do
        # Switch cluster if needed
        if [[ "$cluster" != "$current_cluster" ]]; then
            use_cluster "$cluster" 2>/dev/null
            current_cluster="$cluster"
        fi

        # Get pod status
        local status=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        if [[ "$status" == "Pending" ]]; then
            echo "${cluster}|${node}|${pod_name}|${configmap_name}" >> /tmp/.cognitod-pending-$$
            echo -e "  ${YELLOW}Pending:${NC} ${cluster} / ${node} / ${pod_name}"
        fi
    done

    # Check if we found any pending pods
    if [[ ! -f /tmp/.cognitod-pending-$$ ]]; then
        echo -e "${GREEN}No pending pods found${NC}"
        return
    fi

    local pending_count=$(wc -l < /tmp/.cognitod-pending-$$ | tr -d ' ')
    echo ""
    echo -e "${YELLOW}Found ${pending_count} pending pod(s)${NC}"
    echo ""

    # Ask for confirmation
    echo -n "Do you want to delete these pods? Type 'y' to confirm: "
    read -r confirmation

    if [[ "$confirmation" != "y" ]]; then
        echo -e "${BLUE}Cancelled - no pods were deleted${NC}"
        rm -f /tmp/.cognitod-pending-$$
        return
    fi

    echo ""
    echo -e "${YELLOW}Deleting pending pods...${NC}"

    # Delete the pending pods
    current_cluster=""
    while IFS='|' read -r cluster node pod_name configmap_name; do
        # Switch cluster if needed
        if [[ "$cluster" != "$current_cluster" ]]; then
            use_cluster "$cluster" 2>/dev/null
            current_cluster="$cluster"
        fi

        echo "  Deleting pod: ${pod_name} from ${cluster}"
        kubectl delete pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true
        echo "  Deleting configmap: ${configmap_name}"
        kubectl delete configmap "$configmap_name" -n "$NAMESPACE" --ignore-not-found=true

        # Remove from state
        remove_from_state "$cluster" "$node"
    done < /tmp/.cognitod-pending-$$

    rm -f /tmp/.cognitod-pending-$$

    echo ""
    echo -e "${GREEN}Deleted ${pending_count} pending pod(s)${NC}"
}

# Show usage
cmd_help() {
    cat << EOF
cognitod-deploy.sh - Manage cognitod deployments across multiple clusters/nodes

Usage:
  $0 [--dry-run] <command> [arguments]

Global Flags:
  --dry-run    Show what would be done without making changes

Commands:
  deploy <cluster> <node-hostname>   Deploy cognitod to a specific cluster and node
  deploy-format <tags>               Deploy using kube tags format directly
  list                               List all tracked deployments
  status                             Check actual status of all deployments
  delete <cluster> [node-hostname]   Delete deployment(s) from a cluster
  clean                              Clean all tracked deployments
  clean-pending                      Find and delete pods in Pending state (with confirmation)
  clusters                           List available clusters (via ddtool)
  format-target <tags>               Convert kube tags to deploy arguments
  help                               Show this help message

Examples:
  # List available clusters
  $0 clusters

  # Deploy to a specific node (dry-run first)
  $0 --dry-run deploy stripe.us1.staging.dog ip-10-0-1-123.ec2.internal

  # Deploy to a specific node
  $0 deploy stripe.us1.staging.dog ip-10-0-1-123.ec2.internal

  # Deploy using kube tags format directly
  $0 deploy-format 'kube_node:ip-10-131-59-161.ec2.internal,kube_cluster_name:oddish-a'

  # List all tracked deployments
  $0 list

  # Check status of all deployments
  $0 status

  # Delete a specific deployment (dry-run first)
  $0 --dry-run delete stripe.us1.staging.dog ip-10-0-1-123.ec2.internal

  # Delete a specific deployment
  $0 delete stripe.us1.staging.dog ip-10-0-1-123.ec2.internal

  # Delete all deployments from a cluster
  $0 delete stripe.us1.staging.dog

  # Clean all deployments
  $0 clean

  # Clean up pods in Pending state (requires confirmation)
  $0 clean-pending

  # Convert kube tags to deploy arguments
  $0 format-target 'kube_node:ip-10-131-59-161.ec2.internal,kube_cluster_name:oddish-a'
  # Output: oddish-a.us1.staging.dog ip-10-131-59-161.ec2.internal

  # Use format-target with deploy (one-liner)
  $0 deploy \$($0 format-target 'kube_node:ip-10-131-59-161.ec2.internal,kube_cluster_name:oddish-a')

State file: ${STATE_FILE}
EOF
}

# Main
init_state

# Parse global flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

case "${1:-help}" in
    deploy)
        cmd_deploy "$2" "$3"
        ;;
    deploy-format)
        cmd_deploy_format "$2"
        ;;
    list)
        cmd_list
        ;;
    status)
        cmd_status
        ;;
    delete)
        cmd_delete "$2" "$3"
        ;;
    clean)
        cmd_clean
        ;;
    clean-pending)
        cmd_clean_pending
        ;;
    clusters)
        cmd_clusters
        ;;
    format-target)
        cmd_format_target "$2"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        cmd_help
        exit 1
        ;;
esac
