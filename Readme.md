# Multi-Cloud Auto Deployment with Terraform

This project demonstrates multi-cloud deployment using Terraform to provision resources simultaneously on AWS and GCP, with automated health checks and load balancing simulation.

## Objective

Deploy web servers on both AWS and GCP with a single command, then validate the deployment with health checks and simulate load balancing between the two cloud providers.

## Prerequisites

### Required Tools
- ✅ Terraform (installed)
- ✅ AWS CLI (configured)
- ✅ GCP Service Account Key (configured)
- curl (for health checks)
- jq (for JSON parsing)

### Cloud Account Setup
1. **AWS Free Tier Account** with programmatic access
2. **GCP Free Tier Account** with service account key

### Verification Commands
```bash
# Check Terraform
terraform --version

# Check AWS configuration
aws sts get-caller-identity

# Check GCP key exists
ls ~/.terraform/terraform-sa-keygcp.json
```

## Quick Start

### Step 1: Setup Project Files

1. **Create project directory:**
```bash
mkdir multicloud-terraform
cd multicloud-terraform
```

2. **Save all the provided files:**
   - `main.tf` (main Terraform configuration)
   - `terraform.tfvars` (variables file)
   - `deploy.sh` (deployment script)
   - `health_check.sh` (health monitoring script)
   - `setup_dnsmasq.sh` (DNS configuration script)

3. **Update terraform.tfvars:**
```bash
# Edit terraform.tfvars and replace with your actual GCP project ID
gcp_project_id = "your-actual-gcp-project-id"
```

### Step 2: Deploy Everything

**Single command deployment:**
```bash
chmod +x deploy.sh health_check.sh setup_dnsmasq.sh
./deploy.sh
```

This will:
- Initialize Terraform
- Plan the deployment
- Deploy to both AWS and GCP
- Wait for services to be ready
- Validate the deployment
- Show deployment summary

### Step 3: Test and Monitor

**Health checks:**
```bash
./health_check.sh health          # Single health check
./health_check.sh monitor 30      # Continuous monitoring every 30s
./health_check.sh urls            # Show all server URLs
```

**Load balancing simulation:**
```bash
./health_check.sh load-test 20    # Simulate 20 requests with load balancing
```

### Step 4: Setup Local DNS (Optional)

**Configure local DNS routing:**
```bash
./setup_dnsmasq.sh setup
```

After DNS setup, you can access servers using friendly names:
- `http://aws.multicloud.local`
- `http://gcp.multicloud.local`

## Project Structure

```
multicloud-terraform/
├── main.tf                 # Main Terraform configuration
├── terraform.tfvars       # Variable values
├── deploy.sh              # Auto deployment script
├── health_check.sh        # Health monitoring script
├── setup_dnsmasq.sh       # DNS configuration script
├── terraform.tfstate      # Terraform state (auto-generated)
├── deployer-key.pem       # SSH private key (auto-generated)
└── deployment.log         # Deployment log (auto-generated)
```

## Infrastructure Components

### AWS Resources
- **VPC** with public subnet
- **Internet Gateway** and route table
- **Security Group** (HTTP:80, SSH:22)
- **EC2 Instance** (t2.micro - Free Tier)
- **Key Pair** for SSH access

### GCP Resources
- **VPC Network** with subnet
- **Firewall Rules** (HTTP:80, SSH:22)
- **Compute Engine Instance** (e2-micro - Free Tier)

### Features
- **NGINX web servers** on both clouds
- **Custom health check endpoints** (`/health`)
- **Cloud-specific landing pages**
- **Automatic key pair generation**

## 🔧 Usage Examples

### Basic Operations

```bash
# Deploy everything
./deploy.sh

# Check deployment status
./deploy.sh status

# Plan changes only
./deploy.sh plan

# Destroy all resources
./deploy.sh destroy
```

### Health Monitoring

```bash
# Quick health check
./health_check.sh

# Monitor continuously (Ctrl+C to stop)
./health_check.sh monitor

# Test load balancing
./health_check.sh load-test 50

# Get page from available server
./health_check.sh serve
```

### Manual Testing

```bash
# Get server IPs
terraform output

# Test AWS server
curl http://$(terraform output -raw aws_instance_ip)
curl http://$(terraform output -raw aws_instance_ip)/health

# Test GCP server  
curl http://$(terraform output -raw gcp_instance_ip)
curl http://$(terraform output -raw gcp_instance_ip)/health
```

### SSH Access

```bash
# SSH to AWS instance
ssh -i deployer-key.pem ubuntu@$(terraform output -raw aws_instance_ip)

# SSH to GCP instance
ssh -i deployer-key.pem ubuntu@$(terraform output -raw gcp_instance_ip)
```

##  Health Check Features

The health check system provides:

- **Single health check** - Test both servers once
- **Continuous monitoring** - Real-time health status
- **Load balancing simulation** - Round-robin request distribution  
- **Failover testing** - Automatic fallback to healthy servers
- **Success rate reporting** - Performance metrics

### Health Check Endpoints

Each server provides:
- **Main page**: `/` - Shows server info and status
- **Health endpoint**: `/health` - Returns "OK" for monitoring

## 🌐 DNS Configuration

The DNSMasq setup provides local DNS resolution:

```bash
# Setup local DNS
./setup_dnsmasq.sh setup

# Test DNS resolution
./setup_dnsmasq.sh test

# Clean up DNS config
./setup_dnsmasq.sh cleanup
```

**DNS Mappings:**
- `aws.multicloud.local` → AWS server IP
- `gcp.multicloud.local` → GCP server IP
- `health-aws.multicloud.local` → AWS health endpoint
- `health-gcp.multicloud.local` → GCP health endpoint

##  Troubleshooting

### Common Issues

**1. Terraform initialization fails**
```bash
# Clean and reinitialize
rm -rf .terraform
terraform init
```

**2. AWS credentials not working**
```bash
# Reconfigure AWS CLI
aws configure
aws sts get-caller-identity
```

**3. GCP service account issues**
```bash
# Check key file location and permissions
ls -la ~/.terraform/terraform-sa-keygcp.json
```

**4. Servers not responding**
```bash
# Check security groups/firewall rules
# Wait longer for instances to boot
./health_check.sh monitor
```

**5. DNS resolution fails**
```bash
# Fallback to IP addresses
terraform output
# Or check /etc/hosts entries
```

### Debug Commands

```bash
# Check Terraform state
terraform show

# View detailed logs
cat deployment.log

# Check instance status (AWS)
aws ec2 describe-instances --instance-ids $(terraform output -raw aws_instance_id)

# Check instance status (GCP)
gcloud compute instances describe $(terraform output -raw gcp_instance_name) --zone=$(terraform output -raw gcp_zone)
```

## Cost Management

Both configurations use free tier resources:

### AWS Free Tier
- **EC2**: t2.micro (750 hours/month)
- **VPC**: No additional cost
- **Data transfer**: 1 GB outbound/month

### GCP Free Tier
- **Compute Engine**: e2-micro (744 hours/month)
- **Network**: 1 GB outbound/month
- **VPC**: No additional cost

 **Important**: Monitor your usage and destroy resources when done testing:
```bash
./deploy.sh destroy
```

## 🔧 Customization

### Modify Variables
Edit `terraform.tfvars`:
```hcl
project_name = "my-multicloud-app"
aws_region   = "us-west-2" 
gcp_region   = "us-west1"
```

### Change Instance Types
Edit `main.tf`:
```hcl
# AWS
instance_type = "t3.micro"  # Instead of t2.micro

# GCP  
machine_type = "e2-small"   # Instead of e2-micro
```

### Add More Clouds
The configuration can be extended to include:
- Azure (using azurerm provider)
- DigitalOcean (using digitalocean provider)
- Linode (using linode provider)

## Learning Outcomes

This project demonstrates:

1. **Multi-cloud Infrastructure as Code**
2. **Terraform provider configuration**
3. **Cross-cloud networking concepts**
4. **Health monitoring and load balancing**
5. **DNS-based service discovery**
6. **Cloud security group configuration**
7. **Automated deployment pipelines**

##  Next Steps

1. **Add monitoring**: Integrate with Prometheus/Grafana


##  Additional Resources

- [Terraform Multi-Cloud Guide](https://learn.hashicorp.com/terraform)
- [AWS Free Tier](https://aws.amazon.com/free/)
- [GCP Free Tier](https://cloud.google.com/free)
- [NGINX Configuration](https://nginx.org/en/docs/)

---

**Happy Learning With Me - Anurag Stark❤️** ☁️