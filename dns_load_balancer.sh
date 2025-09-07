#!/bin/bash
# Simple DNS-based load balancer

DOMAIN="multicloud.local"
AWS_DOMAIN="aws.${DOMAIN}"
GCP_DOMAIN="gcp.${DOMAIN}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_server() {
    local server_domain=$1
    local server_name=$2
    
    if curl -s --connect-timeout 5 "http://${server_domain}/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ $server_name is healthy${NC}"
        return 0
    else
        echo -e "${RED}✗ $server_name is down${NC}"
        return 1
    fi
}

route_request() {
    echo -e "${YELLOW}Routing request...${NC}"
    
    # Try AWS first
    if check_server "$AWS_DOMAIN" "AWS"; then
        echo -e "Serving from AWS: ${GREEN}http://${AWS_DOMAIN}${NC}"
        curl -s "http://${AWS_DOMAIN}"
        return 0
    fi
    
    # Fallback to GCP
    if check_server "$GCP_DOMAIN" "GCP"; then
        echo -e "Serving from GCP: ${GREEN}http://${GCP_DOMAIN}${NC}"
        curl -s "http://${GCP_DOMAIN}"
        return 0
    fi
    
    echo -e "${RED}All servers are down${NC}"
    return 1
}

# Main execution
case "${1:-route}" in
    "health")
        check_server "$AWS_DOMAIN" "AWS"
        check_server "$GCP_DOMAIN" "GCP"
        ;;
    "route")
        route_request
        ;;
    *)
        echo "Usage: $0 [health|route]"
        ;;
esac
