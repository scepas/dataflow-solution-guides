#  Copyright 2024 Google LLC
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

locals {
  pubsub_logging_topic     = "all-logs"
  pubsub_sink_name         = "pubsub-sink"
  splunk_gke_cluster_name  = "splunk-gke-cluster"
  dataflow_service_account = "my-dataflow-sa"
  logging_service_account  = "my-logging-sa"
  worker_type              = "n2-standard-2"
  max_dataflow_workers     = 10
}

// Project
module "google_cloud_project" {
  source          = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/project?ref=v32.0.0"
  billing_account = var.billing_account
  project_create  = var.project_create
  name            = var.project_id
  parent          = var.organization
  services        = [
    "dataflow.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "autoscaling.googleapis.com",
    "spanner.googleapis.com",
    "bigquery.googleapis.com",
    "container.googleapis.com"
  ]
}

// Buckets for staging data, scripts, etc, in the two regions
module "buckets" {
  source        = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/gcs?ref=v32.0.0"
  project_id    = module.google_cloud_project.project_id
  name          = module.google_cloud_project.project_id
  location      = var.region
  storage_class = "STANDARD"
  force_destroy = var.destroy_all_resources
}


// Service accounts
module "dataflow_sa" {
  source       = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/iam-service-account?ref=v32.0.0"
  project_id   = module.google_cloud_project.project_id
  name         = local.dataflow_service_account
  generate_key = false
  iam_project_roles = {
    (module.google_cloud_project.project_id) = [
      "roles/storage.admin",
      "roles/dataflow.worker",
      "roles/monitoring.metricWriter",
      "roles/pubsub.editor"
    ]
  }
}

module "splunk_gke_cluster" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/gke-cluster-autopilot?ref=v32.0.0"
  project_id = module.google_cloud_project.project_id
  name       = local.splunk_gke_cluster_name
  location   = var.region
  vpc_config = {
    network    = module.vpc_network.self_link
    subnetwork = module.vpc_network.subnets["${var.region}/${var.network_prefix}-subnet"].name
    secondary_range_names = {
      pods     = "pods"
      services = "services"
    }
    master_authorized_ranges = {
      internal-vms = module.vpc_network.subnets["${var.region}/${var.network_prefix}-subnet"].ip_cidr_range
    }
    master_ipv4_cidr_block = "192.168.0.0/28"
  }
  private_cluster_config = {
    enable_private_endpoint = true
    master_global_access    = false
  }
}

// Pubsub topic to receive all logs
module "logging_topic" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/pubsub?ref=v32.0.0"
  project_id = module.google_cloud_project.project_id
  name       = local.pubsub_logging_topic
}

// Logging sink in Pubsub
resource "google_logging_project_sink" "my_logging_sink" {
  name                   = local.pubsub_sink_name
  project                = module.google_cloud_project.project_id
  destination            = "pubsub.googleapis.com/${module.logging_topic.topic.id}"
  unique_writer_identity = true
}

resource "google_project_iam_binding" "pubsub_log_writer" {
  project = module.google_cloud_project.project_id
  role    = "roles/pubsub.editor"

  members = [
    google_logging_project_sink.my_logging_sink.writer_identity
  ]
}

// Network
module "vpc_network" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/net-vpc?ref=v32.0.0"
  project_id = module.google_cloud_project.project_id
  name       = "${var.network_prefix}-net"
  subnets    = [
    {
      ip_cidr_range         = "10.1.0.0/16"
      name                  = "${var.network_prefix}-subnet"
      region                = var.region
      enable_private_access = true
      secondary_ip_ranges = {
        pods     = "10.16.0.0/14"
        services = "10.20.0.0/24"
      }
    }
  ]
}


module "firewall_rules" {
  // Default rules for internal traffic + SSH access via IAP
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/net-vpc-firewall?ref=v32.0.0"
  project_id = module.google_cloud_project.project_id
  network    = module.vpc_network.name
  default_rules_config = {
    admin_ranges = [
      module.vpc_network.subnet_ips["${var.region}/${var.network_prefix}-subnet"],
    ]
  }
  egress_rules = {
    allow-egress-dataflow = {
      deny        = false
      description = "Dataflow firewall rule egress"
      targets     = ["dataflow"]
      rules       = [{ protocol = "tcp", ports = [12345, 12346] }]
    }
  }
  ingress_rules = {
    allow-ingress-dataflow = {
      description = "Dataflow firewall rule ingress"
      targets     = ["dataflow"]
      rules       = [{ protocol = "tcp", ports = [12345, 12346] }]
    }
  }
}

// So we can get to Internet if necessary (from the Dataflow region)
module "regional_nat" {
  count          = var.internet_access ? 1 : 0
  source         = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/net-cloudnat?ref=v32.0.0"
  project_id     = module.google_cloud_project.project_id
  region         = var.region
  name           = "${var.network_prefix}-nat"
  router_network = module.vpc_network.self_link
}

// Script with variables to launch the Dataflow jobs
resource "local_file" "variables_script" {
  filename        = "${path.module}/../../pipelines/etl_integration_java/scripts/01_set_variables.sh"
  file_permission = "0644"
  content         = <<FILE
# This file is generated by the Terraform code of this Solution Guide.
# We recommend that you modify this file only through the Terraform deployment.
export PROJECT=${module.google_cloud_project.project_id}
export REGION=${var.region}
export NETWORK=regions/${var.region}/subnetworks/${var.network_prefix}-subnet
export TEMP_LOCATION=gs://$PROJECT/tmp
export SERVICE_ACCOUNT=${module.dataflow_sa.email}

export MAX_DATAFLOW_WORKERS=${local.max_dataflow_workers}
export WORKER_TYPE=${local.worker_type}
FILE
}