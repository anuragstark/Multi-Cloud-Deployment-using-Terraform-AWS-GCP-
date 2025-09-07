#!/bin/bash
# health check and simple load balancer

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get server IPs from Terraform output
get_server_ips() {
    echo -e "${BLUE}Getting server information from Terraform...${NC}"
    AWS_IP=$(terraform output -raw aws_instance_ip 2>/dev/null || echo "")
    GCP_IP=$(terraform output -raw gcp_instance_ip 2>/dev/null || echo "")
    
    if [[ -z "$AWS_IP" || -z "$GCP_IP" ]]; then
        echo -e "${RED}Error: Could not get server IPs from Terraform output${NC}"
        echo "Make sure you've run 'terraform apply' successfully"
        exit 1
    fi
    
    echo -e "${GREEN}AWS Server IP: $AWS_IP${NC}"
    echo -e "${GREEN}GCP Server IP: $GCP_IP${NC}"
}

# Function to check server health
check_health() {
    local server_name=$1
    local server_ip=$2
    local health_url="http://$server_ip/health"
    
    echo -n "Checking $server_name ($server_ip): "
    
    if curl -s --connect-timeout 5 --max-time 10 "$health_url" > /dev/null 2>&1; then
        echo -e "${GREEN}HEALTHY${NC}"
        return 0
    else
        echo -e "${RED}UNHEALTHY${NC}"
        return 1
    fi
}

# Function to get response from available server
get_response() {
    local prefer_aws=${1:-false}
    
    # Check AWS first if preferred, otherwise check GCP first
    if [[ "$prefer_aws" == "true" ]]; then
        servers=("AWS:$AWS_IP" "GCP:$GCP_IP")
    else
        servers=("GCP:$GCP_IP" "AWS:$AWS_IP")
    fi
    
    for server in "${servers[@]}"; do
        IFS=':' read -r name ip <<< "$server"
        if curl -s --connect-timeout 5 --max-time 10 "http://$ip" > /dev/null 2>&1; then
            echo -e "${GREEN}Serving from $name server ($ip)${NC}"
            curl -s "http://$ip"
            return 0
        fi
    done
    
    echo -e "${RED}No healthy servers available${NC}"
    return 1
}

# Function to run continuous health monitoring
monitor_health() {
    local interval=${1:-30}
    echo -e "${BLUE}Starting health monitoring (interval: ${interval}s)${NC}"
    echo "Press Ctrl+C to stop"
    
    while true; do
        echo -e "\n${YELLOW}=== Health Check at $(date) ===${NC}"
        
        aws_healthy=false
        gcp_healthy=false
        
        if check_health "AWS" "$AWS_IP"; then
            aws_healthy=true
        fi
        
        if check_health "GCP" "$GCP_IP"; then
            gcp_healthy=true
        fi
        
        # Summary
        if [[ "$aws_healthy" == true && "$gcp_healthy" == true ]]; then
            echo -e "${GREEN}✓ All servers healthy${NC}"
        elif [[ "$aws_healthy" == true || "$gcp_healthy" == true ]]; then
            echo -e "${YELLOW}⚠ Partial outage detected${NC}"
        else
            echo -e "${RED}✗ All servers down${NC}"
        fi
        
        sleep "$interval"
    done
}

# Function to simulate load balancing
simulate_load_balancer() {
    local requests=${1:-10}
    echo -e "${BLUE}Simulating load balancer with $requests requests${NC}"
    
    aws_count=0
    gcp_count=0
    failed_count=0
    
    for ((i=1; i<=requests; i++)); do
        echo -n "Request $i: "
        
        # Simple round-robin: alternate between AWS and GCP
        if (( i % 2 == 1 )); then
            prefer_aws=true
        else
            prefer_aws=false
        fi
        
        # Try to get response
        if [[ "$prefer_aws" == "true" ]]; then
            if curl -s --connect-timeout 3 --max-time 5 "http://$AWS_IP/health" > /dev/null 2>&1; then
                echo -e "${GREEN}AWS${NC}"
                ((aws_count++))
            elif curl -s --connect-timeout 3 --max-time 5 "http://$GCP_IP/health" > /dev/null 2>&1; then
                echo -e "${BLUE}GCP (fallback)${NC}"
                ((gcp_count++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed_count++))
            fi
        else
            if curl -s --connect-timeout 3 --max-time 5 "http://$GCP_IP/health" > /dev/null 2>&1; then
                echo -e "${BLUE}GCP${NC}"
                ((gcp_count++))
            elif curl -s --connect-timeout 3 --max-time 5 "http://$AWS_IP/health" > /dev/null 2>&1; then
                echo -e "${GREEN}AWS (fallback)${NC}"
                ((aws_count++))
            else
                echo -e "${RED}FAILED${NC}"
                ((failed_count++))
            fi
        fi
        
        sleep 0.5
    done
    
    echo -e "\n${YELLOW}=== Load Balancing Results ===${NC}"
    echo -e "AWS requests: ${GREEN}$aws_count${NC}"
    echo -e "GCP requests: ${BLUE}$gcp_count${NC}"
    echo -e "Failed requests: ${RED}$failed_count${NC}"
    echo -e "Success rate: $(( (requests - failed_count) * 100 / requests ))%"
}

# Main script
main() {
    case "${1:-health}" in
        "health"|"check")
            get_server_ips
            echo -e "\n${YELLOW}=== Single Health Check ===${NC}"
            check_health "AWS" "$AWS_IP"
            check_health "GCP" "$GCP_IP"
            ;;
        "monitor")
            get_server_ips
            monitor_health "${2:-30}"
            ;;
        "load-test"|"lb")
            get_server_ips
            simulate_load_balancer "${2:-10}"
            ;;
        "serve")
            get_server_ips
            echo -e "\n${YELLOW}=== Getting page from available server ===${NC}"
            get_response
            ;;
        "urls")
            get_server_ips
            echo -e "\n${YELLOW}=== Server URLs ===${NC}"
            echo -e "AWS: ${GREEN}http://$AWS_IP${NC}"
            echo -e "GCP: ${BLUE}http://$GCP_IP${NC}"
            echo -e "AWS Health: ${GREEN}http://$AWS_IP/health${NC}"
            echo -e "GCP Health: ${BLUE}http://$GCP_IP/health${NC}"
            ;;
        "help"|*)
            echo "Multi-cloud Health Check Tool"
            echo ""
            echo "Usage: $0 [command] [options]"
            echo ""
            echo "Commands:"
            echo "  health, check    - Single health check of both servers"
            echo "  monitor [interval] - Continuous health monitoring (default: 30s)"
            echo "  load-test [count]  - Simulate load balancer (default: 10 requests)"
            echo "  serve           - Get page from available server"
            echo "  urls            - Show server URLs"
            echo "  help            - Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 health"
            echo "  $0 monitor 10"
            echo "  $0 load-test 20"
            ;;
    esac
}

# Run main function with all arguments
main "$@"