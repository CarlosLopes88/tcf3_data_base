# Configura o provedor da AWS e define a região como "us-east-1".
provider "aws" {
  region = "us-east-1"
}

# Data source para listar as zonas de disponibilidade disponíveis na região selecionada.
data "aws_availability_zones" "available" {}

# Criação de uma VPC (Virtual Private Cloud) para isolar os recursos de rede e fornecer controle sobre o tráfego de rede.
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"  # Faixa de endereços IP da VPC.
  tags = {
    Name = "eks-vpc"  # Tag para facilitar a identificação da VPC.
  }
}

# Criação de duas subnets, cada uma em uma zona de disponibilidade diferente, para alta disponibilidade.
resource "aws_subnet" "eks_subnets" {
  count             = 2  # Criar duas subnets.
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)  # Gera blocos de IP diferentes para as subnets.
  vpc_id            = aws_vpc.eks_vpc.id  # Associa as subnets à VPC criada.
  availability_zone = element(data.aws_availability_zones.available.names, count.index)  # Usa zonas de disponibilidade disponíveis.

  tags = {
    Name = "eks-subnet-${count.index + 1}"  # Nomeia as subnets com base em seu índice.
  }
}

# Criação de um Internet Gateway para permitir a comunicação da VPC com a internet.
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id  # Associação do Internet Gateway com a VPC.
  tags = {
    Name = "eks-internet-gateway"  # Tag para identificar o Internet Gateway.
  }
}

# Criação de uma tabela de rotas para rotear o tráfego da VPC para a internet através do Internet Gateway.
resource "aws_route_table" "eks_route_table" {
  vpc_id = aws_vpc.eks_vpc.id  # Associação da tabela de rotas com a VPC.

  route {
    cidr_block = "0.0.0.0/0"  # Permite tráfego de saída para qualquer endereço IP.
    gateway_id = aws_internet_gateway.eks_igw.id  # Direciona o tráfego para o Internet Gateway.
  }

  tags = {
    Name = "eks-route-table"  # Tag para identificar a tabela de rotas.
  }
}

# Associação das subnets criadas à tabela de rotas, permitindo que o tráfego delas seja roteado para a internet.
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2  # Associação para cada subnet.
  subnet_id      = aws_subnet.eks_subnets[count.index].id  # Associa cada subnet à tabela de rotas.
  route_table_id = aws_route_table.eks_route_table.id  # Especifica a tabela de rotas.
}

# Criação de um Security Group para controlar o acesso ao DocumentDB.
resource "aws_security_group" "docdb_sg" {
  name        = "documentdb-sg"  # Nome do grupo de segurança.
  description = "Security group for DocumentDB"  # Descrição do grupo de segurança.
  vpc_id      = aws_vpc.eks_vpc.id  # Associação do grupo de segurança à VPC.

  # Regras de entrada (ingress) para permitir conexões na porta 27017, usada pelo MongoDB/DocumentDB.
  ingress {
    from_port   = 27017  # Porta de origem.
    to_port     = 27017  # Porta de destino.
    protocol    = "tcp"  # Protocolo TCP.
    cidr_blocks = [var.allowed_ips]  # Permite conexões apenas dos IPs especificados (definido na variável).
  }

  # Regras de saída (egress) para permitir tráfego de saída para qualquer destino.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"  # "-1" significa todos os protocolos.
    cidr_blocks = ["0.0.0.0/0"]  # Permite saída para qualquer endereço IP.
  }
}

# Criação de um grupo de subnets para o DocumentDB, garantindo que as instâncias do DocumentDB sejam criadas nas subnets especificadas.
resource "aws_docdb_subnet_group" "docdb_subnet_group" {
  name       = "my-docdb-subnet-group"  # Nome do grupo de subnets.
  subnet_ids = aws_subnet.eks_subnets[*].id  # Associa as subnets criadas anteriormente ao grupo de subnets.

  tags = {
    Name = "my-docdb-subnet-group"  # Tag para identificar o grupo de subnets.
  }
}

# Criação de um cluster DocumentDB, um banco de dados compatível com MongoDB, para armazenar dados.
resource "aws_docdb_cluster" "docdb_cluster" {
  cluster_identifier      = "my-documentdb-cluster"  # Identificador do cluster.
  engine                  = "docdb"  # Motor do banco de dados, no caso, DocumentDB.
  master_username         = var.master_username  # Nome de usuário mestre (definido na variável).
  master_password         = var.master_password  # Senha mestre (definido na variável).
  backup_retention_period = 1  # Mantém backups por 1 dia.
  preferred_backup_window = "07:00-09:00"  # Janela de tempo preferida para backups automáticos.
  vpc_security_group_ids  = [aws_security_group.docdb_sg.id]  # Associa o Security Group criado ao cluster.
  db_subnet_group_name    = aws_docdb_subnet_group.docdb_subnet_group.name  # Associa o cluster ao grupo de subnets.

  tags = {
    Name = "documentdb-cluster"  # Tag para identificar o cluster.
  }
}

# Criação das instâncias DocumentDB que farão parte do cluster.
resource "aws_docdb_cluster_instance" "docdb_instance" {
  count              = 1  # Número de instâncias do cluster (pode ser ajustado para aumentar a disponibilidade).
  identifier         = "my-documentdb-instance-${count.index}"  # Identificador da instância.
  cluster_identifier = aws_docdb_cluster.docdb_cluster.id  # Associa a instância ao cluster.
  instance_class     = "db.t3.medium"  # Tipo de instância, neste caso uma de tamanho médio.
  apply_immediately  = true  # Aplica mudanças imediatamente.

  tags = {
    Name = "documentdb-instance-${count.index}"  # Tag para identificar a instância.
  }
}

# Output que exibe o endpoint do DocumentDB para uso em aplicativos que vão se conectar ao banco de dados.
output "documentdb_endpoint" {
  description = "Endpoint do DocumentDB"
  value       = aws_docdb_cluster.docdb_cluster.endpoint
}

# Definição de variáveis necessárias para a parametrização do Terraform.

# Variável para o nome de usuário do administrador do DocumentDB.
variable "master_username" {
  description = "Nome de usuário administrador do DocumentDB"
  type        = string
}

# Variável para a senha do administrador do DocumentDB.
variable "master_password" {
  description = "Senha do DocumentDB"
  type        = string
  sensitive   = true  # Marca a variável como sensível (oculta em logs).
}

# Variável para especificar os IPs que podem acessar o DocumentDB. Usar "0.0.0.0/0" permite qualquer IP (não recomendado em produção).
variable "allowed_ips" {
  description = "Bloco de CIDR para permitir o acesso ao DocumentDB"
  type        = string
  default     = "0.0.0.0/0"  # Ajuste para IPs específicos em produção.
}