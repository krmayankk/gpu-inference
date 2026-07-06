variable "region" {
  description = "Region for the state backend. Keep it stable; pools reference it at init."
  type        = string
  default     = "us-west-2"
}
