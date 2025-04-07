variable "cloudflare_zone_id" {
  description = "Zone ID of the Cloudflare zone"
  type        = string
}

variable "cloudflare_api_token" {
  description = "API token for Cloudflare"
  type        = string
  sensitive   = true
}

variable "dns_records" {
  type = list(object({
    name    = string
    content = string
  }))
}
