output "schematic_id" {
  description = "Talos factory schematic ID — pinned in stage 03's installer image."
  value       = talos_image_factory_schematic.this.id
}

output "image_urls" {
  description = "Image URLs from the factory (iso, installer, kernel, etc.)."
  value       = data.talos_image_factory_urls.this
}
