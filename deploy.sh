#!/bin/bash
# auto deployment script

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
TERRAFORM_DIR="$(pwd)"
LOG_FILE="deployment.log"

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log "${BLUE}Checking prerequisites...${NC}"
    
    # Check if terraform is installed
    if ! command -v terraform &> /dev/null; then
        log "${RED}Error: Terraform is not installed${NC}"
        exit 1
    fi
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity &> /dev/null; then
        log "${RED}Error: AWS CLI is not configured${NC}"
        exit 1
    fi
    
    # Check if GCP credentials file exists
    if [ ! -f "$HOME/.terraform/terraform-sa-keygcp.json" ]; then
        log "${RED}Error: GCP service account key not found at ~/.terraform/terraform-sa-keygcp.json${NC}"
        exit 1
    fi
    
    # Check if terraform.tfvars exists
    if [ ! -f "terraform.tfvars" ]; then
        log "${YELLOW}Warning: terraform.tfvars not found. Please create it with your GCP project ID${NC}"
        log "Example:"
        log 'gcp_project_id = "your-project-id"'
        exit 1
    fi
    
    log "${GREEN}✓ All prerequisites met${NC}"
}

# Initialize Terraform
init_terraform() {
    log "${BLUE}Initializing Terraform...${NC}"
    terraform init
    log "${GREEN}✓ Terraform initialized${NC}"
}

# Plan deployment
plan_deployment() {
    log "${BLUE}Planning deployment...${NC}"
    terraform plan -out=tfplan
    log "${GREEN}✓ Deployment plan created${NC}"
}

# Apply deployment
apply_deployment() {
    log "${BLUE}Applying deployment...${NC}"
    terraform apply tfplan
    log "${GREEN}✓ Deployment completed${NC}"
}

# Wait for services to be ready
wait_for_services() {
    log "${BLUE}Waiting for services to be ready...${NC}"
    
    # Get IPs from Terraform output
    AWS_IP=$(terraform output -raw aws_instance_ip)
    GCP_IP=$(terraform output -raw gcp_instance_ip)
    
    log "AWS Server: $AWS_IP"
    log "GCP Server: $GCP_IP"
    
    # Wait for AWS server
    log "Waiting for AWS server to be ready..."
    for i in {1..30}; do
        if curl -s --connect-timeout 5 "http://$AWS_IP/health" > /dev/null 2>&1; then
            log "${GREEN}✓ AWS server is ready${NC}"
            break
        fi
        echo -n "."
        sleep 10
        if [ $i -eq 30 ]; then
            log "${RED}Warning: AWS server may not be ready${NC}"
        fi
    done
    
    # Wait for GCP server
    log "Waiting for GCP server to be ready..."
    for i in {1..30}; do
        if curl -s --connect-timeout 5 "http://$GCP_IP/health" > /dev/null 2>&1; then
            log "${GREEN}✓ GCP server is ready${NC}"
            break
        fi
        echo -n "."
        sleep 10
        if [ $i -eq 30 ]; then
            log "${RED}Warning: GCP server may not be ready${NC}"
        fi
    done
}

# Validate deployment
validate_deployment() {
    log "${BLUE}Validating deployment...${NC}"
    
    # Get outputs
    AWS_IP=$(terraform output -raw aws_instance_ip)
    GCP_IP=$(terraform output -raw gcp_instance_ip)
    AWS_URL=$(terraform output -raw aws_instance_url)
    GCP_URL=$(terraform output -raw gcp_instance_url)
    
    # Test AWS server
    if curl -s --connect-timeout 10 "$AWS_URL" | grep -q "AWS Server Online"; then
        log "${GREEN}✓ AWS server validation passed${NC}"
    else
        log "${RED}✗ AWS server validation failed${NC}"
    fi
    
    # Test GCP server
    if curl -s --connect-timeout 10 "$GCP_URL" | grep -q "GCP Server Online"; then
        log "${GREEN}✓ GCP server validation passed${NC}"
    else
        log "${RED}✗ GCP server validation failed${NC}"
    fi
    
    # Test health endpoints
    if curl -s --connect-timeout 5 "http://$AWS_IP/health" | grep -q "OK"; then
        log "${GREEN}✓ AWS health check passed${NC}"
    else
        log "${RED}✗ AWS health check failed${NC}"
    fi
    
    if curl -s --connect-timeout 5 "http://$GCP_IP/health" | grep -q "OK"; then
        log "${GREEN}✓ GCP health check passed${NC}"
    else
        log "${RED}✗ GCP health check failed${NC}"
    fi
}

# Show deployment summary
show_summary() {
    log "${YELLOW}=== Deployment Summary ===${NC}"
    
    # Get all outputs
    terraform output -json > output.json
    
    AWS_IP=$(jq -r '.aws_instance_ip.value' output.json)
    GCP_IP=$(jq -r '.gcp_instance_ip.value' output.json)
    AWS_URL=$(jq -r '.aws_instance_url.value' output.json)
    GCP_URL=$(jq -r '.gcp_instance_url.value' output.json)
    SSH_KEY=$(jq -r '.ssh_private_key_path.value' output.json)
    
    log "AWS Server:"
    log "  IP: ${GREEN}$AWS_IP${NC}"
    log "  URL: ${GREEN}$AWS_URL${NC}"
    log "  Health: ${GREEN}http://$AWS_IP/health${NC}"
    log ""
    log "GCP Server:"
    log "  IP: ${BLUE}$GCP_IP${NC}"
    log "  URL: ${BLUE}$GCP_URL${NC}"
    log "  Health: ${BLUE}http://$GCP_IP/health${NC}"
    log ""
    log "SSH Access:"
    log "  Private Key: $SSH_KEY"
    log "  AWS: ssh -i $SSH_KEY ubuntu@$AWS_IP"
    log "  GCP: ssh -i $SSH_KEY ubuntu@$GCP_IP"
    log ""
    log "Next Steps:"
    log "  1. Run './health_check.sh' to test load balancing"
    log "  2. Run './health_check.sh monitor' for continuous monitoring"
    log "  3. Run './health_check.sh load-test 20' to simulate load"
    
    # Clean up
    rm -f output.json
}

# Destroy deployment
destroy_deployment() {
    log "${YELLOW}Destroying deployment...${NC}"
    read -p "Are you sure you want to destroy all resources? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        terraform destroy -auto-approve
        log "${GREEN}✓ Deployment destroyed${NC}"
    else
        log "Destruction cancelled"
    fi
}

# Main function
main() {
    case "${1:-deploy}" in
        "deploy")
            log "${BLUE}Starting multi-cloud deployment...${NC}"
            log "Timestamp: $(date)"
            check_prerequisites
            init_terraform
            plan_deployment
            apply_deployment
            wait_for_services
            validate_deployment
            show_summary
            log "${GREEN}🎉 Multi-cloud deployment completed successfully!${NC}"
            ;;
        "plan")
            check_prerequisites
            init_terraform
            plan_deployment
            ;;
        "apply")
            apply_deployment
            wait_for_services
            validate_deployment
            show_summary
            ;;
        "validate")
            validate_deployment
            ;;
        "status"|"summary")
            show_summary
            ;;
        "destroy")
            destroy_deployment
            ;;
        "help"|*)
            echo "Multi-cloud Auto Deployment Script"
            echo ""
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  deploy     - Full deployment (default)"
            echo "  plan       - Plan deployment only"
            echo "  apply      - Apply existing plan"
            echo "  validate   - Validate deployment"
            echo "  status     - Show deployment summary"
            echo "  destroy    - Destroy all resources"
            echo "  help       - Show this help"
            echo ""
            echo "Examples:"
            echo "  $0 deploy    # Full deployment"
            echo "  $0 plan      # Plan only"
            echo "  $0 validate  # Check if services are working"
            ;;
    esac
}

# Run main function
main "$@"