provider "aws" {
  region     = "us-east-1"
}

data "aws_s3_bucket" "mc" {
  bucket = var.bucket_id
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name = "name"
    values = [
    "ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
  # Canonical
}

// Script to configure the server - this is where most of the magic occurs!
data "template_file" "user_data" {
  template = file("user_data.sh")

  vars = {
    mc_root        = var.mc_root
    mc_bucket      = var.bucket_id
    mc_backup_freq = var.mc_backup_freq
    mc_version     = var.mc_version
    java_mx_mem    = var.java_mx_mem
    java_ms_mem    = var.java_ms_mem
  }
}

resource "aws_vpc" "main" {
  cidr_block         = "10.0.0.0/16"
  enable_dns_support = true

  tags = var.tags
}

resource "aws_subnet" "main" {
  tags = var.tags

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = var.tags
}

resource "aws_route_table" "r" {
  vpc_id = aws_vpc.main.id

  tags = var.tags

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.r.id
}

resource "aws_security_group" "allow_all" {
  vpc_id      = aws_vpc.main.id
  name        = "allow_all"
  description = "Allow all inbound traffic"

  ingress {
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "allow_s3" {
  name               = "minecraft-ec2-to-s3"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "mc_allow_ec2_to_s3" {
  name   = "mc_allow_ec2_to_s3"
  role   = aws_iam_role.allow_s3.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["${data.aws_s3_bucket.mc.arn}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": ["${data.aws_s3_bucket.mc.arn}/*"]
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "minecraft" {
  name = "minecraft_instance_profile"
  role = aws_iam_role.allow_s3.name
}


resource "aws_instance" "main" {
  ami             = data.aws_ami.ubuntu.image_id
  instance_type   = "t2.medium"
  security_groups = [aws_security_group.allow_all.id]
  key_name        = var.key_name

  tags = var.tags

  user_data            = data.template_file.user_data.rendered
  depends_on           = [aws_internet_gateway.gw]
  subnet_id            = aws_subnet.main.id
  iam_instance_profile = aws_iam_instance_profile.minecraft.id
}
