variable "region" {
  description = "The region name. Example eu-north-1."
  type        = string
}

variable "name_suffix" {
  description = "Suffix that will be applied to all resources. Required to make resource names unique."
  type        = string
  nullable    = false
}

variable "key_pair_name" {
  description = "The name of private key in AWS to connect to the instances"
  type        = string
  default     = null
}

variable "ami" {
  description = "AMI id that used for masters and slaves. Awslogs, docker, kubelet, kubectl, kubeadm must be preinstalled"
  type        = string
  nullable    = false
}

variable "multi_master_cluster_is_initialized_ssm_name" {
  description = "Name of the SSM parameter that contains state of the multi-master cluster readiness. Initial value must be 'false'. If you are creating single-master cluster, this ssm still needed, but in future we will handle this somehow."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "The VPC id."
  type        = string
  nullable    = false
}

variable "cluster_subnets" {
  description = "The list of subnet ids in which cluster will be deployed."
  type        = list(string)
  nullable    = false
}

variable "master_lb_subnets" {
  description = "The list of public subnet ids for Control Plane network LB."
  type        = list(string)
  nullable    = false
}

variable "master_node_type" {
  description = "The ec2 instance type for K8S master nodes"
  type        = string
  default     = "t3.medium"
  nullable    = false
}

variable "master_asg_min_size" {
  description = "The min size of the K8S master asg"
  type        = number
  default     = 1
}

variable "master_asg_max_size" {
  description = "The max size of the K8S master asg"
  type        = number
  default     = 1
}

variable "master_asg_desired_capacity" {
  description = "The desired capacity of the K8S master asg"
  type        = number
  default     = 1
}

variable "master_additional_sg_ids" {
  description = "List of additional SG ids to apply on K8S masters"
  type        = list(string)
  default     = []
}

variable "slave_node_type" {
  description = "The ec2 instance type for K8S slave nodes"
  type        = string
  default     = "t3.small"
  nullable    = false
}

variable "slave_asg_min_size" {
  description = "The min size of the K8S slave asg"
  type        = number
  default     = 1
}

variable "slave_asg_max_size" {
  description = "The max size of the K8S slave asg"
  type        = number
  default     = 1
}

variable "slave_asg_desired_capacity" {
  description = "The desired capacity of the K8S slave asg"
  type        = number
  default     = 1
}

variable "slave_additional_sg_ids" {
  description = "List of additional SG ids to apply on K8S slaves"
  type        = list(string)
  default     = []
}

variable "k8s_version" {
  description = "Kubernetes cluster version. Example: '1.26.1' (if not work, try 1.26.1-00)"
  type        = string
  nullable    = false
}

variable "pod_network_cidr" {
  description = "CIDR for k8s pod network. Default: 192.168.0.0/16. If not default, you need to modify calico manifests in user data"
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for k8s services. Example: 172.16.0.0/16"
  type        = string
  default     = "172.16.0.0/16"
}

variable "calico_version" {
  description = "Calico - is a CNI (Container Network Interface) plugin witch determines how pods are connected to the underlying network from different nodes."
  type        = string
  default     = "v3.25.0"
}

variable "kubeconfig_file_name" {
  description = "The file name of kubeconfig which will be located at $path.root/$var.kubeconfig_file_name. Can set a path, e.g.: 'cluster-kubeconifg/conifg'"
  type        = string
  default     = "config"
}

variable "tags" {
  description = "Tags to set on the resources."
  type        = map(string)
  default     = {}
}
