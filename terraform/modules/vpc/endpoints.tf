###############################################################################
# Baseline VPC endpoints
#
# Keeps S3, ECR, and STS traffic on the AWS backbone instead of NAT — saves
# data-transfer cost and shaves latency. We only define the endpoints that
# matter for an empty cluster on Day 1; later additions (Secrets Manager,
# CloudWatch Logs, SSM, KMS) live in Day 40 with the rest of the addons.
###############################################################################

data "aws_region" "current" {}

# Security group for interface endpoints — allow HTTPS in from inside the VPC.
resource "aws_security_group" "endpoints" {
  count = var.enable_endpoints ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "Allow HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-vpce-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Gateway endpoint for S3 — free, attaches to private route tables only.
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, {
    Name = "${var.name}-vpce-s3"
  })
}

# ECR API + DKR for image pulls without traversing NAT.
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.enable_endpoints ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpce-ecr-api"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.enable_endpoints ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpce-ecr-dkr"
  })
}

# STS endpoint — IAM identity calls from IRSA workloads.
resource "aws_vpc_endpoint" "sts" {
  count = var.enable_endpoints ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpce-sts"
  })
}
