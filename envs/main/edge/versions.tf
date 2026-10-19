terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
  }

  # State lives in Cloud Storage, in the environment's own project, under this folder's path.
  # The bucket is versioned, and the gcs backend locks the state on its own (S3 needed a
  # DynamoDB table or a lock file for this).
  backend "gcs" {
    bucket = "samwen-gke-lab-main-tfstate"
    prefix = "envs/main/edge"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
