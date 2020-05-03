terraform {
  required_version = ">= 0.12"
}

provider "aws" {
  # Credentials are read from ~/.aws/credentials
  region = var.region
}

resource "aws_vpc" "main" {
  cidr_block = var.host_network_cidr
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.host_network_cidr
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "main" {
  route_table_id = aws_route_table.main.id
  subnet_id      = aws_subnet.main.id
}

# The AWS provider removes the default egress rule from all security groups, so
# it's necessary to define it explicitly
resource "aws_security_group" "egress" {
  name        = "egress"
  description = "Allow all outgoing traffic to everywhere"
  vpc_id      = aws_vpc.main.id
  egress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ingress_internal" {
  name        = "ingress-internal"
  description = "Allow all incoming traffic from the host network and Pod network (if defined)"
  vpc_id      = aws_vpc.main.id
  ingress {
    protocol    = -1
    from_port   = 0
    to_port     = 0
    cidr_blocks = compact([var.host_network_cidr, var.pod_network_cidr])
  }
}

resource "aws_security_group" "ingress_k8s" {
  name        = "ingress-k8s"
  description = "Allow incoming Kubernetes traffic (TCP/6443) from everywhere"
  vpc_id      = aws_vpc.main.id
  ingress {
    protocol    = "tcp"
    from_port   = 6443
    to_port     = 6443
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ingress_ssh" {
  name        = "ingress-ssh"
  description = "Allow incoming SSH traffic (TCP/22) from a specific IP address"
  vpc_id      = aws_vpc.main.id
  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = ["${var.localhost_ip}/32"]
  }
}

data "local_file" "public_key" {
  filename = pathexpand(var.public_key_file)
}

# Performs 'ImportKeyPair' API operation (not 'CreateKeyPair')
resource "aws_key_pair" "main" {
  key_name_prefix = "terraform-aws-kubeadm-"
  public_key      = data.local_file.public_key.content
}

data "aws_ami" "ubuntu" {
  owners      = ["099720109477"] # AWS account ID of Canonical
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }
}

# Generate bootstrap token
# See https://kubernetes.io/docs/reference/access-authn-authz/bootstrap-tokens/
resource "random_string" "token_id" {
  length  = 6
  special = false
  upper   = false
}
resource "random_string" "token_secret" {
  length  = 16
  special = false
  upper   = false
}
locals {
  token = "${random_string.token_id.result}.${random_string.token_secret.result}"
}

locals {
  install_kubeadm = <<-EOF
    apt-get update
    apt-get install -y apt-transport-https curl
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y docker.io kubeadm
    EOF
}

# EIP for master node because it must know its public IP during initialisation
resource "aws_eip" "master" {
  vpc        = true
  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip_association" "master" {
  allocation_id = aws_eip.master.id
  instance_id   = aws_instance.master.id
}

resource "aws_instance" "master" {
  ami           = data.aws_ami.ubuntu.image_id
  instance_type = var.master_instance_type
  subnet_id     = aws_subnet.main.id
  key_name      = aws_key_pair.main.key_name
  vpc_security_group_ids = [
    aws_security_group.egress.id,
    aws_security_group.ingress_internal.id,
    aws_security_group.ingress_k8s.id,
    aws_security_group.ingress_ssh.id
  ]
  tags = {
    k8s-node = "master"
  }
  user_data = <<-EOF
  #!/bin/bash
  ${local.install_kubeadm}
  kubeadm init \
    --token ${local.token} \
    --token-ttl 15m \
    --apiserver-cert-extra-sans ${aws_eip.master.public_ip} \
    %{if var.pod_network_cidr != ""}--pod-network-cidr "${var.pod_network_cidr}"%{endif} \
    --node-name master
  # Prepare kubeconfig file for download to local machine
  cp /etc/kubernetes/admin.conf /home/ubuntu
  chown ubuntu:ubuntu /home/ubuntu/admin.conf
  kubectl --kubeconfig /home/ubuntu/admin.conf config set-cluster kubernetes --server https://${aws_eip.master.public_ip}:6443
  touch /home/ubuntu/done
  EOF
}

resource "aws_instance" "workers" {
  count                       = var.num_workers
  ami                         = data.aws_ami.ubuntu.image_id
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.main.id
  associate_public_ip_address = true
  key_name                    = aws_key_pair.main.key_name
  vpc_security_group_ids = [
    aws_security_group.egress.id,
    aws_security_group.ingress_internal.id,
    aws_security_group.ingress_ssh.id
  ]
  tags = {
    k8s-node = "worker-${count.index}"
  }
  user_data = <<-EOF
  #!/bin/bash
  ${local.install_kubeadm}
  kubeadm join ${aws_instance.master.private_ip}:6443 \
    --token ${local.token} \
    --discovery-token-unsafe-skip-ca-verification \
    --node-name worker-${count.index}
  touch /home/ubuntu/done
  EOF
}

locals {
  kubeconfig_path = abspath("kubeconfig")
}

# Wait for bootstrap on all nodes to finish and download kubeconfig file
resource "null_resource" "waiting_for_bootstrap_to_finish" {
  provisioner "local-exec" {
    command = <<-EOF
    alias ssh='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.private_key_file}'
    alias scp='scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.private_key_file}'
    while true; do
      sleep 2
      ! ssh ubuntu@${aws_eip.master.public_ip} [[ -f /home/ubuntu/done ]] &>/dev/null && continue
      %{for worker_public_ip in aws_instance.workers[*].public_ip~}
      ! ssh ubuntu@${worker_public_ip} [[ -f /home/ubuntu/done ]] &>/dev/null && continue
      %{endfor~}
      break
    done
    scp ubuntu@${aws_eip.master.public_ip}:admin.conf ${local.kubeconfig_path} &>/dev/null
    EOF
  }
  triggers = {
    instance_ids = join(",", concat([aws_instance.master.id], aws_instance.workers[*].id))
  }
}
