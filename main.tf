# Multi-Cloud Auto Deployment (AWS + GCP)
# File: main.tf

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

# Variables
variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "multicloud-demo"
}

variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
  # You'll need to set this via terraform.tfvars or TF_VAR_gcp_project_id
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# Provider configurations
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project = var.project_name
      Environment = "demo"
      ManagedBy = "terraform"
    }
  }
}

provider "google" {
  credentials = file("~/.terraform/terraform-sa-keygcp.json")
  project     = var.gcp_project_id
  region      = var.gcp_region
  zone        = var.gcp_zone
}

# Data sources for AMI and GCP image
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# AWS Resources
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Security group for web servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

# User data script for AWS instance
locals {
  aws_user_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    
    # Create custom index page
    cat > /var/www/html/index.html << 'HTML'
    <!DOCTYPE html>
    <html>
    <head>
        <title>AWS Server - ${var.project_name}</title>
        <style>
            body { font-family: Arial, sans-serif; text-align: center; margin: 50px; }
            .aws { color: #FF9900; }
            .status { background: #d4edda; padding: 20px; border-radius: 5px; }
        </style>
    </head>
    <body>
        <h1 class="aws">AWS Server Online</h1>
        <div class="status">
            <h2>Health Check: OK</h2>
            <p>Server: AWS EC2</p>
            <p>Region: ${var.aws_region}</p>
            <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
            <p>Timestamp: $(date)</p>
        </div>
    </body>
    </html>
    HTML
    
    # Create health check endpoint
    cat > /var/www/html/health << 'HEALTH'
    OK
    HEALTH
    
    systemctl restart nginx
    EOF
  )
}

resource "aws_instance" "web_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"  # Free tier eligible
  key_name              = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.web.id]
  subnet_id             = aws_subnet.public.id
  user_data_base64      = local.aws_user_data

  tags = {
    Name = "${var.project_name}-aws-web"
  }
}

# Generate SSH key pair
resource "tls_private_key" "deployer" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-deployer-key"
  public_key = tls_private_key.deployer.public_key_openssh
}

# Save private key to local file
resource "local_file" "private_key" {
  content  = tls_private_key.deployer.private_key_pem
  filename = "${path.module}/deployer-key.pem"
  file_permission = "0600"
}

# GCP Resources
resource "google_compute_network" "vpc_network" {
  name                    = "${var.project_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.project_name}-subnet"
  ip_cidr_range = "10.1.0.0/24"
  region        = var.gcp_region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_firewall" "web" {
  name    = "${var.project_name}-allow-web"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["80", "22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web-server"]
}

# GCP startup script
locals {
  gcp_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    
    # Create custom index page
    cat > /var/www/html/index.html << 'HTML'
    <!DOCTYPE html>
    <html>
    <head>
        <title>GCP Server - ${var.project_name}</title>
        <style>
            body { font-family: Arial, sans-serif; text-align: center; margin: 50px; }
            .gcp { color: #4285F4; }
            .status { background: #d4edda; padding: 20px; border-radius: 5px; }
        </style>
    </head>
    <body>
        <h1 class="gcp">GCP Server Online</h1>
        <div class="status">
            <h2>Health Check: OK</h2>
            <p>Server: Google Compute Engine</p>
            <p>Region: ${var.gcp_region}</p>
            <p>Zone: ${var.gcp_zone}</p>
            <p>Instance Name: ${var.project_name}-gcp-web</p>
            <p>Timestamp: $(date)</p>
        </div>
    </body>
    </html>
    HTML
    
    # Create health check endpoint
    cat > /var/www/html/health << 'HEALTH'
    OK
    HEALTH
    
    systemctl restart nginx
    EOF
}

resource "google_compute_instance" "web_server" {
  name         = "${var.project_name}-gcp-web"
  machine_type = "e2-micro"  # Free tier eligible
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.name
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${tls_private_key.deployer.public_key_openssh}"
  }

  metadata_startup_script = local.gcp_startup_script

  tags = ["web-server"]
}

# Outputs
output "aws_instance_ip" {
  description = "AWS instance public IP"
  value       = aws_instance.web_server.public_ip
}

output "aws_instance_url" {
  description = "AWS instance URL"
  value       = "http://${aws_instance.web_server.public_ip}"
}

output "gcp_instance_ip" {
  description = "GCP instance public IP"
  value       = google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip
}

output "gcp_instance_url" {
  description = "GCP instance URL"
  value       = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}"
}

output "ssh_private_key_path" {
  description = "Path to SSH private key"
  value       = local_file.private_key.filename
}

output "health_check_urls" {
  description = "Health check endpoints"
  value = {
    aws = "http://${aws_instance.web_server.public_ip}/health"
    gcp = "http://${google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip}/health"
  }
}