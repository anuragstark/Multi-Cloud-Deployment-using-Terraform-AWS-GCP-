#!/bin/bash
# Local DNS setup for routing

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DOMAIN="multicloud.local"
DNSMASQ_CONFIG_DIR="/etc/dnsmasq.d"
HOSTS_FILE="/etc/hosts"

log() {
    echo -e "$1"
}

# Check and handle port 53 conflicts
handle_port_conflict() {
    log "${BLUE}Checking for port 53 conflicts...${NC}"
    
    # Check what's using port 53
    PORT_USERS=$(sudo netstat -tulpn | grep :53 || true)
    
    if [[ -n "$PORT_USERS" ]]; then
        log "${YELLOW}Port 53 is in use:${NC}"
        echo "$PORT_USERS"
        
        # Check if systemd-resolved is running
        if systemctl is-active --quiet systemd-resolved; then
            log "${YELLOW}systemd-resolved is using port 53. Configuring to work together...${NC}"
            
            # Stop systemd-resolved temporarily
            sudo systemctl stop systemd-resolved
            
            # Backup and modify systemd-resolved config
            if [ ! -f "/etc/systemd/resolved.conf.backup" ]; then
                sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
            fi
            
            # Configure systemd-resolved to not bind to port 53
            sudo tee /etc/systemd/resolved.conf > /dev/null << EOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSStubListener=no
Cache=yes
EOF
            
            # Restart systemd-resolved with new config
            sudo systemctl restart systemd-resolved
            
            log "${GREEN}✓ systemd-resolved configured to not conflict with dnsmasq${NC}"
        fi
        
        # Kill any other processes using port 53 (except systemd-resolved)
        PIDS=$(sudo lsof -ti :53 2>/dev/null || true)
        if [[ -n "$PIDS" ]]; then
            for pid in $PIDS; do
                PROCESS_NAME=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
                if [[ "$PROCESS_NAME" != "systemd-resolve" ]]; then
                    log "${YELLOW}Stopping process $PROCESS_NAME (PID: $pid) using port 53${NC}"
                    sudo kill -TERM $pid 2>/dev/null || true
                    sleep 2
                    # Force kill if still running
                    if kill -0 $pid 2>/dev/null; then
                        sudo kill -KILL $pid 2>/dev/null || true
                    fi
                fi
            done
        fi
        
        # Wait a moment for port to be freed
        sleep 3
    fi
}

# Install dnsmasq if not present
install_dnsmasq() {
    log "${BLUE}Installing dnsmasq...${NC}"
    
    if command -v dnsmasq &> /dev/null; then
        log "${GREEN}✓ dnsmasq is already installed${NC}"
        return 0
    fi
    
    # Handle port conflicts before installation
    handle_port_conflict
    
    # Detect OS and install
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y dnsmasq
        elif command -v yum &> /dev/null; then
            sudo yum install -y dnsmasq
        else
            log "${RED}Error: Package manager not supported${NC}"
            exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install dnsmasq
        else
            log "${RED}Error: Homebrew not found. Please install Homebrew first${NC}"
            exit 1
        fi
    fi
    
    log "${GREEN}✓ dnsmasq installed${NC}"
}

# Get server IPs from Terraform
get_server_ips() {
    if [ ! -f "terraform.tfstate" ]; then
        log "${RED}Error: Terraform state file not found. Run deployment first.${NC}"
        exit 1
    fi
    
    AWS_IP=$(terraform output -raw aws_instance_ip 2>/dev/null || echo "")
    GCP_IP=$(terraform output -raw gcp_instance_ip 2>/dev/null || echo "")
    
    if [[ -z "$AWS_IP" || -z "$GCP_IP" ]]; then
        log "${RED}Error: Could not get server IPs from Terraform${NC}"
        exit 1
    fi
    
    log "AWS IP: $AWS_IP"
    log "GCP IP: $GCP_IP"
}

# Create dnsmasq configuration
create_dnsmasq_config() {
    log "${BLUE}Creating dnsmasq configuration...${NC}"
    
    # Create multicloud.conf for dnsmasq
    cat > multicloud.conf << EOF
# Multi-cloud DNS configuration
# Listen only on localhost
listen-address=127.0.0.1
port=53

# Bind only to specific interfaces
bind-interfaces

# Don't read /etc/hosts
no-hosts

# Domain configuration
domain=${DOMAIN}
expand-hosts

# Local domain resolution
local=/${DOMAIN}/

# Server entries (round-robin DNS)
address=/app.${DOMAIN}/${AWS_IP}
address=/app.${DOMAIN}/${GCP_IP}
address=/aws.${DOMAIN}/${AWS_IP}
address=/gcp.${DOMAIN}/${GCP_IP}

# Health check endpoints
address=/health-aws.${DOMAIN}/${AWS_IP}
address=/health-gcp.${DOMAIN}/${GCP_IP}

# Cache settings
cache-size=1000

# Log queries for debugging
log-queries

# Forward other DNS queries to upstream servers
server=8.8.8.8
server=1.1.1.1

# Don't forward local domain queries
server=/${DOMAIN}/
EOF

    log "${GREEN}✓ dnsmasq configuration created${NC}"
}

# Setup system DNS
setup_system_dns() {
    log "${BLUE}Setting up system DNS...${NC}"
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Handle port conflicts before starting dnsmasq
        handle_port_conflict
        
        # Backup original resolv.conf
        if [ ! -f "/etc/resolv.conf.backup" ]; then
            sudo cp /etc/resolv.conf /etc/resolv.conf.backup
        fi
        
        # Configure dnsmasq
        if [ -d "$DNSMASQ_CONFIG_DIR" ]; then
            sudo cp multicloud.conf "$DNSMASQ_CONFIG_DIR/"
        else
            sudo mkdir -p "$DNSMASQ_CONFIG_DIR"
            sudo cp multicloud.conf "$DNSMASQ_CONFIG_DIR/"
        fi
        
        # Ensure dnsmasq service is stopped before reconfiguring
        sudo systemctl stop dnsmasq || true
        
        # Wait a moment
        sleep 2
        
        # Start/restart dnsmasq
        sudo systemctl enable dnsmasq || true
        
        # Try to start dnsmasq with better error handling
        if ! sudo systemctl start dnsmasq; then
            log "${RED}Failed to start dnsmasq. Checking for remaining conflicts...${NC}"
            
            # Show what might still be using port 53
            sudo netstat -tulpn | grep :53 || true
            sudo lsof -i :53 || true
            
            # Try one more time after killing everything on port 53
            sudo pkill -f dnsmasq || true
            sleep 2
            handle_port_conflict
            sleep 2
            
            if sudo systemctl start dnsmasq; then
                log "${GREEN}✓ dnsmasq started successfully after conflict resolution${NC}"
            else
                log "${RED}Still unable to start dnsmasq. Manual intervention required.${NC}"
                sudo journalctl -xeu dnsmasq.service --no-pager -n 20
                exit 1
            fi
        else
            log "${GREEN}✓ dnsmasq configured and started${NC}"
        fi
        
        # Update resolv.conf to use local dnsmasq
        echo "# Generated by multicloud DNS setup" | sudo tee /etc/resolv.conf > /dev/null
        echo "nameserver 127.0.0.1" | sudo tee -a /etc/resolv.conf > /dev/null
        echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf > /dev/null
        echo "search ${DOMAIN}" | sudo tee -a /etc/resolv.conf > /dev/null
        
        log "${GREEN}✓ System DNS configured${NC}"
        
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS setup
        log "${YELLOW}Manual DNS setup required for macOS${NC}"
        log "1. Copy multicloud.conf to /usr/local/etc/dnsmasq.conf"
        log "2. Start dnsmasq: sudo brew services start dnsmasq"
        log "3. Add 127.0.0.1 to DNS servers in Network Preferences"
    fi
}

# Add entries to hosts file as fallback
update_hosts_file() {
    log "${BLUE}Updating hosts file...${NC}"
    
    # Backup hosts file
    if [ ! -f "${HOSTS_FILE}.backup" ]; then
        sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.backup"
    fi
    
    # Remove old entries
    sudo sed -i.tmp "/# Multicloud DNS entries/,/# End multicloud entries/d" "$HOSTS_FILE"
    
    # Add new entries
    sudo tee -a "$HOSTS_FILE" > /dev/null << EOF

# Multicloud DNS entries
${AWS_IP} aws.${DOMAIN}
${GCP_IP} gcp.${DOMAIN}
${AWS_IP} health-aws.${DOMAIN}
${GCP_IP} health-gcp.${DOMAIN}
# End multicloud entries
EOF

    log "${GREEN}✓ Hosts file updated${NC}"
}

# Test DNS resolution
test_dns() {
    log "${BLUE}Testing DNS resolution...${NC}"
    
    domains=("aws.${DOMAIN}" "gcp.${DOMAIN}" "health-aws.${DOMAIN}" "health-gcp.${DOMAIN}")
    
    for domain in "${domains[@]}"; do
        if nslookup "$domain" 127.0.0.1 > /dev/null 2>&1; then
            resolved_ip=$(nslookup "$domain" 127.0.0.1 | grep "Address:" | tail -1 | awk '{print $2}')
            log "${GREEN}✓ $domain -> $resolved_ip${NC}"
        else
            log "${RED}✗ Failed to resolve $domain${NC}"
        fi
    done
    
    # Also test with dig if available
    if command -v dig &> /dev/null; then
        log "${BLUE}Testing with dig...${NC}"
        for domain in "${domains[@]}"; do
            if dig @127.0.0.1 "$domain" +short > /dev/null 2>&1; then
                resolved_ip=$(dig @127.0.0.1 "$domain" +short | head -1)
                log "${GREEN}✓ $domain -> $resolved_ip (dig)${NC}"
            fi
        done
    fi
}

# Create a simple load balancer script using DNS
create_dns_load_balancer() {
    log "${BLUE}Creating DNS-based load balancer...${NC}"
    
    cat > dns_load_balancer.sh << 'EOF'
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
EOF

    chmod +x dns_load_balancer.sh
    log "${GREEN}✓ DNS load balancer script created${NC}"
}

# Cleanup function
cleanup_dns() {
    log "${BLUE}Cleaning up DNS configuration...${NC}"
    
    # Stop dnsmasq
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo systemctl stop dnsmasq || true
        sudo systemctl disable dnsmasq || true
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        sudo brew services stop dnsmasq || true
    fi
    
    # Restore resolv.conf
    if [ -f "/etc/resolv.conf.backup" ]; then
        sudo cp "/etc/resolv.conf.backup" /etc/resolv.conf
        log "${GREEN}✓ resolv.conf restored${NC}"
    fi
    
    # Restore systemd-resolved config
    if [ -f "/etc/systemd/resolved.conf.backup" ]; then
        sudo cp "/etc/systemd/resolved.conf.backup" /etc/systemd/resolved.conf
        sudo systemctl restart systemd-resolved
        log "${GREEN}✓ systemd-resolved configuration restored${NC}"
    fi
    
    # Restore hosts file
    if [ -f "${HOSTS_FILE}.backup" ]; then
        sudo cp "${HOSTS_FILE}.backup" "$HOSTS_FILE"
        log "${GREEN}✓ Hosts file restored${NC}"
    fi
    
    # Remove dnsmasq config
    if [ -f "$DNSMASQ_CONFIG_DIR/multicloud.conf" ]; then
        sudo rm -f "$DNSMASQ_CONFIG_DIR/multicloud.conf"
    fi
    
    log "${GREEN}✓ DNS cleanup completed${NC}"
}

# Main function
main() {
    case "${1:-setup}" in
        "setup")
            log "${BLUE}Setting up local DNS for multi-cloud routing...${NC}"
            get_server_ips
            install_dnsmasq
            create_dnsmasq_config
            setup_system_dns
            update_hosts_file
            create_dns_load_balancer
            test_dns
            log "${GREEN}🎉 DNS setup completed!${NC}"
            log ""
            log "You can now use:"
            log "  http://aws.${DOMAIN}"
            log "  http://gcp.${DOMAIN}"
            log "  ./dns_load_balancer.sh route"
            ;;
        "test")
            test_dns
            ;;
        "cleanup")
            cleanup_dns
            ;;
        "debug")
            log "${BLUE}Debug information:${NC}"
            echo "Port 53 usage:"
            sudo netstat -tulpn | grep :53 || echo "No processes found on port 53"
            echo ""
            echo "dnsmasq status:"
            sudo systemctl status dnsmasq || echo "dnsmasq not running"
            echo ""
            echo "DNS resolution test:"
            nslookup "aws.${DOMAIN}" 127.0.0.1 || echo "DNS resolution failed"
            ;;
        "help"|*)
            echo "DNS Setup Script for Multi-cloud"
            echo ""
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  setup    - Setup DNS configuration (default)"
            echo "  test     - Test DNS resolution"
            echo "  cleanup  - Remove DNS configuration"
            echo "  debug    - Show debug information"
            echo "  help     - Show this help"
            ;;
    esac
}

main "$@"