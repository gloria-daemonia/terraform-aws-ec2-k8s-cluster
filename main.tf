locals {
  master_join_command_key = "master_join_command"
  slave_join_command_key  = "slave_join_command"
}

data "aws_subnet" "cluster_subnets_cidr" {
  for_each = toset(var.cluster_subnets)
  id       = var.cluster_subnets[each.value]
}

#IAM
data "aws_iam_policy_document" "assume_role_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["ec2.amazonaws.com"]
      type        = "Service"
    }
  }
}

locals {
  master_policies = {
    ModifyInstanceAttribute = {
      effect    = "Allow"
      actions   = ["ec2:ModifyInstanceAttribute"]
      resources = ["*"]
    }
    GetUpdateSecretsManager = {
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:ListSecrets",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret"
      ]
      resources = ["*"]
    }
    GetUpdateSSMParameter = {
      effect = "Allow"
      actions = [
        "ssm:DescribeParameters",
        "ssm:GetParameter*",
        "ssm:LabelParameterVersion",
        "ssm:UnlabelParameterVersion",
        "ssm:PutParameter"
      ]
      resources = ["*"]
    }
    PutCloudWatchLogs = {
      effect = "Allow"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role" "master" {
  name               = "K8S-Master-Role-${var.name_suffix}"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json
  tags = merge(
    { "Description" = "K8S Role used by Master nodes" },
    var.tags
  )
}
resource "aws_iam_instance_profile" "master" {
  name = aws_iam_role.master.name
  role = aws_iam_role.master.name
  path = "/"
  tags = merge(
    { "Description" = "K8S instance profile used by Master nodes" },
    var.tags
  )
}
data "aws_iam_policy_document" "master" {
  for_each = local.master_policies
  statement {
    effect    = each.value.effect
    actions   = each.value.actions
    resources = each.value.resources
  }
}
resource "aws_iam_policy" "master" {
  for_each = local.master_policies
  name     = "${each.key}-${var.name_suffix}"
  path     = "/"
  policy   = data.aws_iam_policy_document.master[each.key].json
  tags = merge(
    { "Name" = each.key },
    var.tags
  )
}
resource "aws_iam_role_policy_attachment" "master" {
  for_each   = local.master_policies
  policy_arn = aws_iam_policy.master[each.key].arn
  role       = aws_iam_role.master.name
}
#this policy is required for SSM Agent on the node to execute cloud-init wait ssm command
resource "aws_iam_role_policy_attachment" "master_ssm_managed_instance_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.master.name
}

locals {
  slave_policies = {
    ModifyInstanceAttribute = { #need to limit access to reources that called "slave-*" or somthing like this so the instance cannot change attributes of masters
      effect    = "Allow"
      actions   = ["ec2:ModifyInstanceAttribute"]
      resources = ["*"]
    }
    GetUpdateSecretsManager = { #need to restrict access to important secrets like kubeconfig
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:ListSecrets"
      ]
      resources = ["*"]
    }
    GetUpdateSSMParameter = {
      effect = "Allow"
      actions = [
        "ssm:DescribeParameters",
        "ssm:GetParameter*"
      ]
      resources = ["*"]
    }
    PutCloudWatchLogs = {
      effect = "Allow"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      resources = ["*"]
    }
  }
}
resource "aws_iam_role" "slave" {
  name               = "K8S-Slave-Role-${var.name_suffix}"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json
  tags = merge(
    { "Description" = "K8S Role used by Slave nodes" },
    var.tags
  )
}
resource "aws_iam_instance_profile" "slave" {
  name = aws_iam_role.slave.name
  role = aws_iam_role.slave.name
  path = "/"
  tags = merge(
    { "Description" = "K8S instance profile used by Slave nodes" },
    var.tags
  )
}
data "aws_iam_policy_document" "slave" {
  for_each = local.slave_policies
  statement {
    effect    = each.value.effect
    actions   = each.value.actions
    resources = each.value.resources
  }
}
resource "aws_iam_policy" "slave" {
  for_each = local.slave_policies
  name     = "${each.key}-${var.name_suffix}"
  path     = "/"
  policy   = data.aws_iam_policy_document.slave[each.key].json
  tags = merge(
    { "Name" = each.key },
    var.tags
  )
}
resource "aws_iam_role_policy_attachment" "slave" {
  for_each   = local.slave_policies
  policy_arn = aws_iam_policy.slave[each.key].arn
  role       = aws_iam_role.slave.name
}
#/IAM

#SSM, Secrets, etc.
resource "aws_secretsmanager_secret" "join_cluster" {
  name                    = "K8S-Join-Cluster-Command-${var.name_suffix}"
  description             = "Join commands for K8S master and slave nodes."
  recovery_window_in_days = 0 #default =30, during this time, you cannot recreate this secret
  tags = merge(
    { "Name" = "K8S Join Command" },
    var.tags
  )
}

resource "aws_secretsmanager_secret" "cluster_config" {
  name                    = "K8S-Cluster-Config-${var.name_suffix}"
  description             = "Contains K8S cluster config of the control-plane"
  recovery_window_in_days = 0 #default =30, during this time, you cannot recreate this secret
  tags = merge(
    { "Name" = "K8S Cluster Config" },
    var.tags
  )
}

data "aws_ssm_parameter" "multi_master_cluster_is_initialized" {
  name = var.multi_master_cluster_is_initialized_ssm_name
}

resource "aws_ssm_document" "cloud_init_wait" {
  name            = "cloud-init-wait-${var.name_suffix}"
  document_type   = "Command"
  document_format = "YAML"
  content         = <<-EOF
    schemaVersion: '2.2'
    description: Wait for cloud init to finish
    mainSteps:
    - action: aws:runShellScript
      name: StopOnLinux
      precondition:
        StringEquals:
        - platformType
        - Linux
      inputs:
        runCommand:
        - cloud-init status --wait
    EOF
  tags = merge(
    { "Description" = "Wait cloud-init completion" },
    var.tags
  )
}
#/SSM, Secrets, etc.

#Bootstrapper
resource "aws_cloudwatch_log_group" "bootstrapper" {
  name              = "/K8S-Bootstrapper-${var.name_suffix}"
  retention_in_days = 7
  tags = merge(
    { "Description" = "Log group with cloud init logs" },
    var.tags
  )
}

resource "aws_instance" "bootstrapper" {
  depends_on = [
    aws_lb_listener.master
  ]
  lifecycle { #terraform apply tries to change the following values to null
    ignore_changes = [iam_instance_profile, tags]
  }
  count = data.aws_ssm_parameter.multi_master_cluster_is_initialized.value == "false" ? 1 : 0
  launch_template {
    id      = aws_launch_template.master.id
    version = aws_launch_template.master.latest_version
  }
  subnet_id                            = var.cluster_subnets[0] #var.master_lb_subnets
  source_dest_check                    = false
  instance_initiated_shutdown_behavior = var.master_asg_desired_capacity == 0 ? "stop" : "terminate"
  user_data_replace_on_change          = true
  user_data = base64encode(templatefile("${path.module}/user_data/k8s_bootstrapper.sh.tpl", {
    join_cluster_secret     = aws_secretsmanager_secret.join_cluster.name
    join_cluster_master_key = local.master_join_command_key
    join_cluster_slave_key  = local.slave_join_command_key
    cluster_config_secret   = aws_secretsmanager_secret.cluster_config.name
    ssm_parameter           = data.aws_ssm_parameter.multi_master_cluster_is_initialized.name
    kubernetes_version      = "v${var.k8s_version}" #v1.25.6
    pod_network_cidr        = var.pod_network_cidr
    service_cidr            = var.service_cidr
    calico_version          = var.calico_version
    log_group_name          = aws_cloudwatch_log_group.bootstrapper.name
    loadbalancer_dns_name   = lower(aws_lb.master.dns_name)
    k8s_master_asg_count    = var.master_asg_desired_capacity
  }))
  tags = merge(
    { "Name" = "K8S-Bootstrapper-${var.name_suffix}" },
    var.tags
  )
}

resource "aws_lb_target_group_attachment" "bootstrapper" {
  count            = data.aws_ssm_parameter.multi_master_cluster_is_initialized.value == "false" ? 1 : 0
  target_group_arn = aws_lb_target_group.master.arn
  target_id        = aws_instance.bootstrapper[0].id
  port             = 6443
  #this provisioner is here because we need to w8 until the bootstrapper finish its user data, AND bootstrapping proccess requires already attached ec2 to the LB
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    #requires latest awscli version
    command = <<-EOF
    set -Ee -o pipefail
    export AWS_DEFAULT_REGION=${var.region}
    wait_command_executed() {
      command_id=$1
      n=0
      until [[ "$n" -ge 3 ]]
      do
        aws ssm wait command-executed --command-id $command_id --instance-id ${aws_instance.bootstrapper[0].id} && break
        n=$((n+1))
      done
      aws ssm wait command-executed --command-id $command_id --instance-id ${aws_instance.bootstrapper[0].id}
    }

    sleep 10
    command_id=$(aws ssm send-command --document-name ${aws_ssm_document.cloud_init_wait.arn} --instance-ids ${aws_instance.bootstrapper[0].id} --output text --query "Command.CommandId")
    if ! wait_command_executed $command_id
    then
      echo "Failed to complete user_data on instance ${aws_instance.bootstrapper[0].id}!"
      echo "stdout:"
      aws ssm get-command-invocation --command-id $command_id --instance-id ${aws_instance.bootstrapper[0].id} --query StandardOutputContent
      echo "stderr:"
      aws ssm get-command-invocation --command-id $command_id --instance-id ${aws_instance.bootstrapper[0].id} --query StandardErrorContent
      exit 1
    fi
    echo "User data has been completed successfully on the new instance with id ${aws_instance.bootstrapper[0].id}!"

    EOF
  }
}
#/Bootstrapper

#Master
resource "aws_lb" "master" {
  name                             = "K8S-Master-LB-${var.name_suffix}"
  load_balancer_type               = "network"
  enable_cross_zone_load_balancing = true
  subnets                          = var.master_lb_subnets
  tags = merge(
    { "Description" = "Public Network LB. Serves as Control Plane endpoint" },
    var.tags
  )
}

resource "aws_lb_target_group" "master" {
  name                 = "K8S-Master-TG-${var.name_suffix}"
  vpc_id               = var.vpc_id
  port                 = 6443
  protocol             = "TCP"
  deregistration_delay = 30
  health_check {
    enabled  = true
    protocol = "HTTPS"
    port     = 6443
    matcher  = "403"
    interval = 10
  }
  tags = merge(
    { "Description" = "Target group with master nodes" },
    var.tags
  )
}

resource "aws_lb_listener" "master" {
  load_balancer_arn = aws_lb.master.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.master.arn
  }
  tags = merge(
    { "Name" = "Listener to K8S Controll Plane" },
    var.tags
  )
}

resource "aws_cloudwatch_log_group" "master" {
  name              = "/K8S-Master-${var.name_suffix}"
  retention_in_days = 7
  tags = merge(
    { "Description" = "Log group with cloud init logs" },
    var.tags
  )
}

resource "aws_security_group" "master" {
  name        = "K8S-master-sg-${var.name_suffix}"
  description = "K8S master security group"
  vpc_id      = var.vpc_id
  egress {
    description      = "Allow all egress"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
  }
  ingress { # do we need this?
    description      = "Allow to ping from anywhere"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "icmp"
    from_port        = 8
    to_port          = 0
  }
  ingress {
    description = "Allow traffic from local network"
    cidr_blocks = data.aws_subnet.cluster_subnets_cidr # ["10.0.0.0/8", "172.16.0.0/16", "192.168.0.0/16"]
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
  }
  ingress { # actually not needed as traffic for local network already allowed, but anyway let it be
    description = "Allow ingress from other instances that have this sg"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }
  # ingress { #if you need ssh you will add this sg separately via additional sg, because we dont know to wich cidr allow ssh
  #   description = "SSH"
  #   cidr_blocks = ["0.0.0.0/0"]
  #   protocol    = "tcp"
  #   from_port   = 22
  #   to_port     = 22
  # }
  ingress {
    description = "Kebernetes API"
    cidr_blocks = ["0.0.0.0/0"]
    protocol    = "tcp"
    from_port   = 6443
    to_port     = 6443
  }
  tags = merge(
    { "Name" = "K8S-master-sg-${var.name_suffix}" },
    var.tags
  )
}

resource "aws_launch_template" "master" {
  name                   = "K8S-Master-Node-Launch-Template-${var.name_suffix}"
  description            = "Lanuch tempalte for K8S Master Node"
  update_default_version = true
  instance_type          = var.master_node_type
  image_id               = var.ami

  user_data = base64encode(templatefile("${path.module}/user_data/k8s_join_cluster.sh.tpl", {
    join_cluster_secret     = aws_secretsmanager_secret.join_cluster.name,
    join_cluster_secret_key = local.master_join_command_key,
    cluster_config_secret   = aws_secretsmanager_secret.cluster_config.name
    log_group_name          = aws_cloudwatch_log_group.master.name
  }))

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "optional"
    instance_metadata_tags = "enabled"
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.master.arn
  }

  network_interfaces {
    security_groups = concat(
      [aws_security_group.master],
      var.master_additional_sg
    )
  }

  key_name = var.key_pair_name

  monitoring { #detailed monitoring
    enabled = false
  }

  dynamic "tag_specifications" {
    for_each = [
      "instance",
      "volume"
      # "spot-instances-request"
    ]
    content {
      resource_type = tag_specifications.value
      tags = merge(
        { "Name" = "K8S-Master-${var.name_suffix}" },
        var.tags
      )
    }
  }

  tags = merge(
    { "Name" = "K8S Master Node Launch Template" },
    var.tags
  )
}

resource "aws_autoscaling_group" "master" {
  depends_on = [aws_lb_target_group_attachment.bootstrapper]
  lifecycle {
    ignore_changes = [desired_capacity]
  }
  count                     = var.master_asg_desired_capacity == 0 ? 0 : 1
  name                      = "K8S-Master-ASG-${var.name_suffix}"
  min_size                  = var.master_asg_min_size
  max_size                  = var.master_asg_max_size
  desired_capacity          = var.master_asg_desired_capacity
  vpc_zone_identifier       = var.cluster_subnets
  health_check_grace_period = 60
  target_group_arns         = [aws_lb_target_group.master.arn]
  launch_template {
    id      = aws_launch_template.master.id
    version = aws_launch_template.master.latest_version
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
    }
    triggers = ["tag"]
  }
  tag {
    key                 = "ASG"
    value               = "K8S-ASG-Master-${var.name_suffix}"
    propagate_at_launch = true
  }
  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }

}
#/Master

#Slave
resource "aws_cloudwatch_log_group" "slave" {
  name              = "/K8S-Slave-${var.name_suffix}"
  retention_in_days = 7
  tags = merge(
    { "Description" = "Log group with cloud init logs" },
    var.tags
  )
}

resource "aws_security_group" "slave" {
  name        = "K8S-slave-sg-${var.name_suffix}"
  description = "K8S slave security group"
  vpc_id      = var.vpc_id
  egress {
    description      = "Allow all egress"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "-1"
    from_port        = 0
    to_port          = 0
  }
  ingress { # do we need this?
    description      = "Allow to ping from anywhere"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    protocol         = "icmp"
    from_port        = 8
    to_port          = 0
  }
  ingress {
    description = "Allow traffic from local network"
    cidr_blocks = data.aws_subnet.cluster_subnets_cidr # ["10.0.0.0/8", "172.16.0.0/16", "192.168.0.0/16"]
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
  }
  ingress { # actually not needed as traffic for local network already allowed, but anyway let it be
    description = "Allow ingress from other instances that have this sg"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }
  # ingress { #if you need ssh you will add this sg separately via additional sg, because we dont know to wich cidr allow ssh
  #   description = "SSH"
  #   cidr_blocks = ["0.0.0.0/0"]
  #   protocol    = "tcp"
  #   from_port   = 22
  #   to_port     = 22
  # }
  tags = merge(
    { "Name" = "K8S-master-sg-${var.name_suffix}" },
    var.tags
  )
}

resource "aws_launch_template" "slave" {
  name                   = "K8S-Slave-Node-Launch-Template-${var.name_suffix}"
  description            = "Lanuch tempalte for K8S Slave nodes"
  update_default_version = true
  instance_type          = var.slave_node_type
  image_id               = var.ami
  user_data = base64encode(templatefile("${path.module}/user_data/k8s_join_cluster.sh.tpl", {
    join_cluster_secret     = aws_secretsmanager_secret.join_cluster.name,
    join_cluster_secret_key = local.slave_join_command_key,
    cluster_config_secret   = aws_secretsmanager_secret.cluster_config.name
    log_group_name          = aws_cloudwatch_log_group.slave.name
  }))

  metadata_options {
    http_endpoint          = "enabled"
    http_tokens            = "optional"
    instance_metadata_tags = "enabled"
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.slave.arn
  }

  network_interfaces {
    security_groups = concat(
      [aws_security_group.slave],
      var.slave_additional_sg
    )
  }

  key_name = var.key_pair_name

  monitoring { #detailed monitoring
    enabled = false
  }

  dynamic "tag_specifications" {
    for_each = [
      "instance",
      "volume"
      # "spot-instances-request"
    ]
    content {
      resource_type = tag_specifications.value
      tags = merge(
        { "Name" = "K8S-Slave-${var.name_suffix}" },
        var.tags
      )
    }
  }

  tags = merge(
    { "Name" = "K8S Slave Node Launch Template" },
    var.tags
  )
}

resource "aws_autoscaling_group" "slave" {
  depends_on = [aws_lb_target_group_attachment.bootstrapper]
  lifecycle {
    ignore_changes = [desired_capacity]
  }
  name                      = "K8S-Slave-ASG-${var.name_suffix}"
  min_size                  = var.slave_asg_min_size
  max_size                  = var.slave_asg_max_size
  desired_capacity          = var.slave_asg_desired_capacity
  vpc_zone_identifier       = var.cluster_subnets
  health_check_grace_period = 60
  launch_template {
    id      = aws_launch_template.slave.id
    version = aws_launch_template.slave.latest_version
  }
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
    }
    triggers = ["tag"]
  }
  tag {
    key                 = "ASG"
    value               = "K8S-ASG-Slave-${var.name_suffix}"
    propagate_at_launch = true
  }
  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}
#/Slave

#post deploy
data "aws_secretsmanager_secret_version" "cluster_config" {
  depends_on = [aws_lb_target_group_attachment.bootstrapper]
  secret_id  = aws_secretsmanager_secret.cluster_config.id
}

resource "local_sensitive_file" "cluster_config" {
  content  = data.aws_secretsmanager_secret_version.cluster_config.secret_string
  filename = var.config_local_path
}

resource "null_resource" "cluster_delete_post_action" {
  count = var.master_asg_desired_capacity == 0 ? 0 : 1
  triggers = {
    region        = var.region
    ssm_parameter = var.multi_master_cluster_is_initialized_ssm_name
  }
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOF
    aws --region=${self.triggers.region} ssm put-parameter \\
    --name "${self.triggers.ssm_parameter}" \\
    --value "false" \\
    --overwrite
    EOF
  }
}
#/post deploy
