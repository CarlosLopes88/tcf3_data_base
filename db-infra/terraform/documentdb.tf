provider "aws" {
  region = "us-east-1"
}

# Data source para listar as Zonas de Disponibilidade (necessário para criar subnets)
data "aws_availability_zones" "available" {}

# Verificar se a VPC já existe
data "aws_vpc" "existing_vpc" {
  filter {
    name   = "tag:Name"
    values = ["eks-vpc"]
  }
  count = length(try(data.aws_vpc.existing_vpc.id, [])) == 0 ? 1 : 0
}

# Criar a VPC caso não exista
resource "aws_vpc" "eks_vpc" {
  count      = length(data.aws_vpc.existing_vpc.id) == 0 ? 1 : 0
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "eks-vpc"
  }
}

# Verificar se as subnets já existem
data "aws_subnet" "existing_subnet" {
  filter {
    name   = "tag:Name"
    values = ["eks-subnet-1", "eks-subnet-2"]
  }
  count = length(try(data.aws_subnet.existing_subnet.id, [])) == 0 ? 1 : 0
}

# Criar subnets caso não existam
resource "aws_subnet" "eks_subnets" {
  count             = length(data.aws_subnet.existing_subnet.id) == 0 ? 2 : 0
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  vpc_id            = coalesce(data.aws_vpc.existing_vpc.id, aws_vpc.eks_vpc.id)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "eks-subnet-${count.index + 1}"
  }
}

# Verificar se o Internet Gateway já existe
data "aws_internet_gateway" "existing_igw" {
  filter {
    name   = "tag:Name"
    values = ["eks-internet-gateway"]
  }
  count = length(try(data.aws_internet_gateway.existing_igw.id, [])) == 0 ? 1 : 0
}

# Criar Internet Gateway caso não exista
resource "aws_internet_gateway" "eks_igw" {
  count  = length(data.aws_internet_gateway.existing_igw.id) == 0 ? 1 : 0
  vpc_id = coalesce(data.aws_vpc.existing_vpc.id, aws_vpc.eks_vpc.id)
  tags = {
    Name = "eks-internet-gateway"
  }
}

# Verificar se a Tabela de Rotas já existe
data "aws_route_table" "existing_route_table" {
  filter {
    name   = "tag:Name"
    values = ["eks-route-table"]
  }
  count = length(try(data.aws_route_table.existing_route_table.id, [])) == 0 ? 1 : 0
}

# Criar a Tabela de Rotas caso não exista
resource "aws_route_table" "eks_route_table" {
  count  = length(data.aws_route_table.existing_route_table.id) == 0 ? 1 : 0
  vpc_id = coalesce(data.aws_vpc.existing_vpc.id, aws_vpc.eks_vpc.id)

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = coalesce(data.aws_internet_gateway.existing_igw.id, aws_internet_gateway.eks_igw.id)
  }

  tags = {
    Name = "eks-route-table"
  }
}

# Associação das subnets à tabela de rotas
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnets[count.index].id
  route_table_id = coalesce(data.aws_route_table.existing_route_table.id, aws_route_table.eks_route_table.id)
}

# Verificar se o Security Group já existe
data "aws_security_group" "existing_docdb_sg" {
  filter {
    name   = "tag:Name"
    values = ["documentdb-sg"]
  }
  count = length(try(data.aws_security_group.existing_docdb_sg.id, [])) == 0 ? 1 : 0
}

# Criar o Security Group caso não exista
resource "aws_security_group" "docdb_sg" {
  count  = length(data.aws_security_group.existing_docdb_sg.id) == 0 ? 1 : 0
  name        = "documentdb-sg"
  description = "Security group for DocumentDB"
  vpc_id      = coalesce(data.aws_vpc.existing_vpc.id, aws_vpc.eks_vpc.id)

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ips]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Definindo um DB Subnet Group para o DocumentDB
resource "aws_docdb_subnet_group" "docdb_subnet_group" {
  name       = "my-docdb-subnet-group"
  subnet_ids = aws_subnet.eks_subnets[*].id

  tags = {
    Name = "my-docdb-subnet-group"
  }
}

# Verificar se o DocumentDB já existe
data "aws_docdb_cluster" "existing_docdb_cluster" {
  filter {
    name   = "db-cluster-id"
    values = ["my-documentdb-cluster"]
  }
  count = length(try(data.aws_docdb_cluster.existing_docdb_cluster.id, [])) == 0 ? 1 : 0
}

# Criar o cluster DocumentDB caso não exista
resource "aws_docdb_cluster" "docdb_cluster" {
  count               = length(data.aws_docdb_cluster.existing_docdb_cluster.id) == 0 ? 1 : 0
  cluster_identifier  = "my-documentdb-cluster"
  engine              = "docdb"
  master_username     = var.master_username
  master_password     = var.master_password
  backup_retention_period = 1
  preferred_backup_window = "07:00-09:00"
  vpc_security_group_ids  = [coalesce(data.aws_security_group.existing_docdb_sg.id, aws_security_group.docdb_sg.id)]
  db_subnet_group_name    = aws_docdb_subnet_group.docdb_subnet_group.name

  tags = {
    Name = "documentdb-cluster"
  }
}

# Criação das instâncias do DocumentDB
resource "aws_docdb_cluster_instance" "docdb_instance" {
  count              = 1
  identifier         = "my-documentdb-instance-${count.index}"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id
  instance_class     = "db.t3.medium"
  apply_immediately  = true

  tags = {
    Name = "documentdb-instance-${count.index}"
  }
}

# Output do endpoint do DocumentDB
output "documentdb_endpoint" {
  description = "Endpoint do DocumentDB"
  value       = aws_docdb_cluster.docdb_cluster.endpoint
}

# Variáveis de entrada
variable "master_username" {
  description = "Nome de usuário administrador do DocumentDB"
  type        = string
}

variable "master_password" {
  description = "Senha do DocumentDB"
  type        = string
  sensitive   = true
}

variable "allowed_ips" {
  description = "Bloco de CIDR para permitir o acesso ao DocumentDB"
  type        = string
  default     = "0.0.0.0/0"
}