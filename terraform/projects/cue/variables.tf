variable "domain" {
  type    = string
  default = "cue.dev"
}

variable "server_ip" {
  type    = string
  default = "10.0.0.95"
}

variable "litellm_url" {
  type    = string
  default = "http://10.0.0.95:4001"
}

variable "litellm_master_key" {
  type      = string
  sensitive = true
}
