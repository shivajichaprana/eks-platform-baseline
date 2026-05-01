###############################################################################
# VPC module — main
#
# Creates a VPC with paired public + private subnets across the specified AZs,
# an Internet Gateway for public subnets, NAT Gateway(s) for private subnet
# egress, and (optionally) a baseline set of VPC endpoints to keep node ⇄ AWS
# control-plane traffic off the NAT.
###############################################################################

locals {
  azs_count             = length(var.azs)
  private_subnets_count = length(var.private_subnets)
  public_subnets_count  = length(var.public_subnets)
  nat_count             = var.enable_nat ? (var.single_nat_gw ? 1 : local.azs_count) : 0

  # Subnet tags required by the AWS Load Balancer Controller and by EKS.
  # See: https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html
  cluster_shared_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
  public_role_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_role_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Sanity check: AZ count must match each subnet list length so that the
# index-based zipping below produces a deterministic mapping. Surfaced via a
# terraform_data lifecycle precondition so we fail at plan time, not apply time.
resource "terraform_data" "az_subnet_count_guard" {
  lifecycle {
    precondition {
      condition     = local.private_subnets_count == local.azs_count && local.public_subnets_count == local.azs_count
      error_message = "Length of azs, private_subnets, and public_subnets must all match."
    }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = var.name
  })
}

###############################################################################
# Internet Gateway + EIPs for NAT
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = local.public_subnets_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    var.tags,
    local.cluster_shared_tag,
    local.public_role_tags,
    {
      Name = "${var.name}-public-${var.azs[count.index]}"
      Tier = "public"
    },
  )
}

resource "aws_subnet" "private" {
  count = local.private_subnets_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    local.cluster_shared_tag,
    local.private_role_tags,
    {
      Name = "${var.name}-private-${var.azs[count.index]}"
      Tier = "private"
    },
  )
}

###############################################################################
# NAT Gateways — one per AZ, or one shared, depending on single_nat_gw.
###############################################################################

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  # When single_nat_gw is true we drop the NAT in the first public subnet.
  # When false, we create one NAT in each public subnet.
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name}-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route tables
###############################################################################

# Public route table — one for everyone, default route to IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-rt-public"
    Tier = "public"
  })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.public_subnets_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ when running multi-NAT, otherwise one
# shared table that all private subnets attach to.
resource "aws_route_table" "private" {
  count = local.nat_count > 0 ? (var.single_nat_gw ? 1 : local.azs_count) : 1

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-rt-private-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_route" "private_default_via_nat" {
  count = local.nat_count

  route_table_id         = aws_route_table.private[var.single_nat_gw ? 0 : count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.private_subnets_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gw ? 0 : count.index].id
}
