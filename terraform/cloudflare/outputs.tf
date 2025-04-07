output "dns_records" {
  value = {
    for k, record in cloudflare_record.dns :
    k => record.hostname
  }
}
