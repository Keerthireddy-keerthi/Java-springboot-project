terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 🔒 PRODUCTION REMOTE STATE BACKEND
  backend "s3" {
    bucket         = "keerthireddykheer707"
    key            = "prod/state/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-lock-table"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-west-2"
}

# ==========================================
# KEY PAIR
# ==========================================

resource "aws_key_pair" "project_key" {
  key_name   = "project-key"
  public_key = file("${path.module}/project-key.pub")
}

# ==========================================
# NETWORKING LAYER
# ==========================================

resource "aws_vpc" "prod_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "production-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.prod_vpc.id
  tags   = { Name = "prod-igw" }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.prod_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.prod_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-west-2b"
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-2" }
}

resource "aws_subnet" "private_app_1" {
  vpc_id            = aws_vpc.prod_vpc.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "us-west-2a"
  tags              = { Name = "private-app-subnet-1" }
}

resource "aws_subnet" "private_app_2" {
  vpc_id            = aws_vpc.prod_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-west-2b"
  tags              = { Name = "private-app-subnet-2" }
}

resource "aws_eip" "nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_1.id
  tags          = { Name = "prod-nat-gateway" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.prod_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "pub1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "pub2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.prod_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "priv1" {
  subnet_id      = aws_subnet.private_app_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "priv2" {
  subnet_id      = aws_subnet.private_app_2.id
  route_table_id = aws_route_table.private_rt.id
}

# ==========================================
# SECURITY GROUPS
# ==========================================

resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = aws_vpc.prod_vpc.id
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

resource "aws_security_group" "alb_sg" {
  name   = "public-alb-sg"
  vpc_id = aws_vpc.prod_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "app_sg" {
  name   = "private-app-sg"
  vpc_id = aws_vpc.prod_vpc.id
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  ingress {
    from_port       = 8084
    to_port         = 8084
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # allow frontend to call backend privately
  ingress {
    from_port       = 8084
    to_port         = 8084
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "frontend_sg" {
  name   = "private-frontend-sg"
  vpc_id = aws_vpc.prod_vpc.id
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }
  ingress {
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name   = "private-database-sg"
  vpc_id = aws_vpc.prod_vpc.id
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# LOAD BALANCER
# ==========================================

resource "aws_lb" "external_alb" {
  name               = "production-frontend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

# Backend target group (still exists, health-checked, but not on the public listener anymore)
resource "aws_lb_target_group" "app_tg_v3" {
  name     = "tg-final-prod-8084"
  port     = 8084
  protocol = "HTTP"
  vpc_id   = aws_vpc.prod_vpc.id
  health_check {
    path    = "/"
    port    = "8084"
    matcher = "200-399,404"
  }
  lifecycle {
    create_before_destroy = true
  }
}

# Frontend target group — this is now the public-facing one
resource "aws_lb_target_group" "frontend_tg" {
  name     = "tg-frontend-8501"
  port     = 8501
  protocol = "HTTP"
  vpc_id   = aws_vpc.prod_vpc.id
  health_check {
    path    = "/"
    port    = "8501"
    matcher = "200-399"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.external_alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "backend_attach" {
  target_group_arn = aws_lb_target_group.app_tg_v3.arn
  target_id        = aws_instance.app_server_v2.id
  port             = 8084
}

resource "aws_lb_target_group_attachment" "frontend_attach" {
  target_group_arn = aws_lb_target_group.frontend_tg.arn
  target_id        = aws_instance.frontend_server.id
  port             = 8501
}

# ==========================================
# COMPUTE (EC2 & RDS)
# ==========================================

data "aws_ami" "latest_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.latest_amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_1.id
  key_name               = aws_key_pair.project_key.key_name
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  tags                   = { Name = "Production-Bastion-Jump" }
}

resource "aws_instance" "app_server_v2" {
  ami                    = data.aws_ami.latest_amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_app_1.id
  key_name               = aws_key_pair.project_key.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log | logger -t user-data -s) 2>&1

    sudo dnf update -y
    sudo dnf install -y git maven java-17-amazon-corretto

    cd /home/ec2-user
    rm -rf Java-Springboot-Project
    git clone https://github.com/bhavani0131/Java-Springboot-Project.git

    cd Java-Springboot-Project/backend

    mvn clean package -DskipTests

    TARGET_JAR=$(find target/ -maxdepth 1 -name "*.jar" ! -name "*sources*" ! -name "*original*" | head -n 1)

    export SERVER_PORT=8084
    export MYSQL_HOST="${aws_db_instance.mysql_db.address}"
    export MYSQL_PORT="3306"
    export MYSQL_DB_NAME="${aws_db_instance.mysql_db.db_name}"
    export MYSQL_USERNAME="${aws_db_instance.mysql_db.username}"
    export MYSQL_PASSWORD="${aws_db_instance.mysql_db.password}"
    export LOG_FILE_PATH="/home/ec2-user/datastore.log"

    nohup java -jar $TARGET_JAR --server.port=8084 > /home/ec2-user/app.log 2>&1 &

    echo "Application triggered with JAR: $TARGET_JAR on port 8084" > /home/ec2-user/deploy_status.txt
  EOF

  tags = { Name = "Production-Private-App-Host-V2" }
}

resource "aws_instance" "frontend_server" {
  ami                    = data.aws_ami.latest_amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_app_2.id
  key_name               = aws_key_pair.project_key.key_name
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  tags                   = { Name = "Production-Private-Frontend-Host" }
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "main-db-subnet-group"
  subnet_ids = [aws_subnet.private_app_1.id, aws_subnet.private_app_2.id]
}

resource "aws_db_instance" "mysql_db" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  db_name                = "datastore"
  username               = "admin"
  password               = "Cloud123"
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
}

# ==========================================
# OUTPUT VALUES FOR AUTOMATION
# ==========================================

output "bastion_public_ip" { value = aws_instance.bastion.public_ip }
output "private_server_internal_ip" { value = aws_instance.app_server_v2.private_ip }
output "frontend_server_internal_ip" { value = aws_instance.frontend_server.private_ip }
output "rds_endpoint" { value = aws_db_instance.mysql_db.address }
output "load_balancer_dns" { value = aws_lb.external_alb.dns_name }

# ==========================================
# OIDC IDENTITY PROVIDER FOR GITHUB ACTIONS
# ==========================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Official thumbprints for GitHub Actions OIDC
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-infra-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # 🔒 Secures the role so ONLY your GitHub username/repos can assume it
            "token.actions.githubusercontent.com:sub" = "repo:bhavani0131/*:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "admin_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# This will print the exact ARN string we need for GitHub
output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_role.arn
  description = "Copy this ARN value for your GitHub Actions workflow"
}