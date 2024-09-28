# Provedor AWS
provider "aws" {
  region = "us-east-1"
}

# Data source para listar as Zonas de Disponibilidade (necessário para criar subnets)
data "aws_availability_zones" "available" {}

# Criação da VPC para isolar os recursos de rede
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "eks-vpc"
  }
}

# Criação de duas subnets em diferentes zonas de disponibilidade
resource "aws_subnet" "eks_subnets" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  vpc_id            = aws_vpc.eks_vpc.id
  availability_zone = element(data.aws_availability_zones.available.names, count.index)  # Zonas de disponibilidade dinâmicas

  tags = {
    Name = "eks-subnet-${count.index + 1}"
  }
}

# Criação do Internet Gateway para permitir a comunicação com a internet
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "eks-internet-gateway"
  }
}

# Criação da tabela de rotas para rotear o tráfego da VPC para a internet
resource "aws_route_table" "eks_route_table" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"  # Permite tráfego para a internet
    gateway_id = aws_internet_gateway.eks_igw.id
  }

  tags = {
    Name = "eks-route-table"
  }
}

# Associação das subnets à tabela de rotas
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnets[count.index].id
  route_table_id = aws_route_table.eks_route_table.id
}

# Criação do Security Group para o DocumentDB (controla o acesso de rede)
resource "aws_security_group" "docdb_sg" {
  name        = "documentdb-sg"
  description = "Security group for DocumentDB"
  vpc_id      = aws_vpc.eks_vpc.id  # Associar o SG à VPC

  ingress {
    from_port   = 27017   # Porta padrão do MongoDB/DocumentDB
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ips]  # Permitir acesso somente de IPs específicos (use 0.0.0.0/0 em ambientes de teste, ajuste para produção)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Permitir saída para qualquer IP
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

# Criação do cluster DocumentDB
resource "aws_docdb_cluster" "docdb_cluster" {
  cluster_identifier      = "my-documentdb-cluster"
  engine                  = "docdb"
  master_username         = var.master_username  # Definido na variável
  master_password         = var.master_password  # Definido na variável (sensível)
  backup_retention_period = 1  # Quantos dias os backups são mantidos
  preferred_backup_window = "07:00-09:00"  # Horário preferido para backups automáticos
  vpc_security_group_ids  = [aws_security_group.docdb_sg.id]  # Associação do SG
  db_subnet_group_name    = aws_docdb_subnet_group.docdb_subnet_group.name  # Associando o Subnet Group

  tags = {
    Name = "documentdb-cluster"
  }
}

# Criação das instâncias que farão parte do cluster DocumentDB
resource "aws_docdb_cluster_instance" "docdb_instance" {
  count              = 1  # Número de instâncias (pode aumentar para melhorar a disponibilidade)
  identifier         = "my-documentdb-instance-${count.index}"
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id  # Associar instância ao cluster criado
  instance_class     = "db.t3.medium"  # Tipo de instância (escolha de acordo com a demanda)
  apply_immediately  = true  # Aplicar mudanças imediatamente

  tags = {
    Name = "documentdb-instance-${count.index}"
  }
}

# Output para exibir o endpoint do DocumentDB, utilizado para conexão no app
output "documentdb_endpoint" {
  description = "Endpoint do DocumentDB"
  value       = aws_docdb_cluster.docdb_cluster.endpoint
}

# Variáveis necessárias para parametrizar o Terraform
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
  default     = "0.0.0.0/0"  # Ajuste para IPs específicos em produção
}
