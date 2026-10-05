variable "resource_group_name" {
  description = "Resource group created by bootstrap/bootstrap.sh. Terraform reads it and never manages it, so terraform destroy cannot remove the group that holds its own state."
  type        = string
  default     = "rg-portfolio-on-azure"
}
