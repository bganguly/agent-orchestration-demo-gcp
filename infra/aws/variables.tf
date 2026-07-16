variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "agent-lite"
}

variable "vpc_cidr" {
  type    = string
  default = "10.21.0.0/16"
}

variable "be_task_cpu" {
  type    = number
  default = 512
}

variable "be_task_memory" {
  type    = number
  default = 1024
}

variable "fe_task_cpu" {
  type    = number
  default = 256
}

variable "fe_task_memory" {
  type    = number
  default = 512
}

variable "be_port" {
  type    = number
  default = 8002
}

variable "fe_port" {
  type    = number
  default = 3011
}
