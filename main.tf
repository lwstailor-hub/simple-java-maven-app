terraform {
  required_version = ">= 1.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }
  # Backend GCS: usa tu bucket EXISTENTE
  backend "gcs" {
    bucket = "tf-state-gvm"
    prefix = "tfstate/ex3"
  }
}

########################
# Variables y defaults #
########################
variable "project_id" {
  type        = string
  description = "ID del proyecto GCP"
  default     = "gcp-mod1-lab-gobierno-475720"   
}
variable "region" {
  type        = string
  description = "Región GCP"
  default     = "us-central1"
}
variable "zone" {
  type        = string
  description = "Zona GCP (solo se usa en la VM)"
  default     = "us-central1-a"
}
variable "network_name" {
  type        = string
  description = "Nombre de la VPC"
  default     = "vpc-web"
}
variable "subnet_cidr" {
  type        = string
  description = "CIDR de la subred"
  default     = "10.10.0.0/24"
}
variable "machine_type" {
  type        = string
  description = "Tipo de máquina"
  default     = "e2-micro"
}
##############
# Provider   #
##############
provider "google" {
  project = var.project_id
  region  = var.region
  # Nota: "zone" NO va aquí (para evitar duplicidad). La ponemos en el recurso VM.
}
#############################
# Red, subred y firewall    #
#############################
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.network_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
}
resource "google_compute_firewall" "allow_http_https" {
  name    = "${var.network_name}-allow-web"
  network = google_compute_network.vpc.name
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["web"]
}
#############################
# VM Debian + Apache (HTTP) #
#############################
resource "google_compute_instance" "vm_web" {
  name         = "vm-web"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["web"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      # IP pública efímera
    }
  }
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y apache2
    echo "Hola desde Terraform en ${HOSTNAME}" > /var/www/html/index.html
    systemctl enable apache2
    systemctl restart apache2
  EOT
}
############
# Outputs  #
############
output "vm_public_ip" {
  description = "IP pública de la VM web"
  value       = try(google_compute_instance.vm_web.network_interface[0].access_config[0].nat_ip, null)
}
output "http_url" {
  description = "URL HTTP de prueba"
  value = (
try(google_compute_instance.vm_web.network_interface[0].access_config[0].nat_ip, null) != null
    ? "http://${google_compute_instance.vm_web.network_interface[0].access_config[0].nat_ip}"
    : null
  )
}
Pipeline de Terraform con Cloud Build (en el mismo repo, crea cloudbuild.yaml)
substitutions:
  _SA_EMAIL: "tf-runner@gcp-mod1-lab-gobierno.iam.gserviceaccount.com"
steps:
  # (Opcional) Configura el proyecto para comandos gcloud de diagnóstico
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    id: 'Config project'
    entrypoint: bash
    args:
      - -c
      - |
        gcloud config set project gcp-mod1-lab-gobierno
        gcloud --version
  # Diagnóstico: verifica acceso al bucket de estado con la MISMA identidad que usará Terraform
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    id: 'Diag GCS access (impersonating tf-runner)'
    entrypoint: bash
    env:
      - GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=${_SA_EMAIL}
    args:
      - -c
      - |
        gsutil ls -L gs://tf-state-gvm || { echo "ERROR: tf-runner no puede acceder al bucket tf-state-gvm"; exit 1; }
  # Terraform Init
  - name: 'hashicorp/terraform:1.8'
    id: 'Terraform Init'
    env:
      - GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=${_SA_EMAIL}
      - TF_VAR_project_id=gcp-mod1-lab-gobierno
      - TF_VAR_region=us-central1
      - TF_VAR_zone=us-central1-a
    entrypoint: sh
    args: [ "-c", "terraform init -upgrade" ]
  # Terraform Plan
  - name: 'hashicorp/terraform:1.8'
    id: 'Terraform Plan'
    env:
      - GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=${_SA_EMAIL}
      - TF_VAR_project_id=gcp-mod1-lab-gobierno
      - TF_VAR_region=us-central1
      - TF_VAR_zone=us-central1-a
    entrypoint: sh
    args: [ "-c", "terraform plan -out=tfplan" ]
  # Terraform Apply
  - name: 'hashicorp/terraform:1.8'
    id: 'Terraform Apply'
    env:
      - GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=${_SA_EMAIL}
      - TF_VAR_project_id=gcp-mod1-lab-gobierno
      - TF_VAR_region=us-central1
      - TF_VAR_zone=us-central1-a
    entrypoint: sh
    args: [ "-c", "terraform apply -auto-approve tfplan" ]
options:
  logging: CLOUD_LOGGING_ONLY
