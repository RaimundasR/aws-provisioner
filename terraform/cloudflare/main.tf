resource "cloudflare_record" "dns" {
  for_each = {
    for record in var.dns_records : record.name => record
  }

  zone_id = var.cloudflare_zone_id
  name    = each.value.name
  type    = "A"
  content = each.value.content
  ttl     = 1
  proxied = true
}
