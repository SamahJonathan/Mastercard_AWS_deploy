# VPC propia (sin costo por sí misma): subredes privadas para RDS y DMS, una pública para la EC2 de carga.
# Sin NAT Gateway: el tráfico a S3 sale por un VPC endpoint de tipo Gateway (gratuito y privado).

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${local.azs[count.index]}", Tier = "private" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, 100)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${local.azs[0]}", Tier = "public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = { Name = "${local.name}-s3-endpoint" }
}

# El security group por defecto queda sin reglas (buena práctica CIS)
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

# --- Flow logs: tráfico rechazado de la VPC hacia CloudWatch -----------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${local.name}/flow-logs"
  retention_in_days = 14
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "REJECT"
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn    = module.role["vpc-flow-logs"].arn
}

# --- Security groups ---------------------------------------------------------------------------

resource "aws_security_group" "loader" {
  name        = "${local.name}-core-loader"
  description = "EC2 de carga: sin puertos de entrada, se administra con SSM Session Manager"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Salida a internet (SSM, paquetes) y a RDS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "dms" {
  name        = "${local.name}-dms"
  description = "Instancia de replicacion DMS"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Salida a RDS y a S3 via endpoint"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-core-rds"
  description = "PostgreSQL core: solo acepta conexiones de la EC2 de carga y de DMS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL desde EC2 de carga y DMS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.loader.id, aws_security_group.dms.id]
  }
}
