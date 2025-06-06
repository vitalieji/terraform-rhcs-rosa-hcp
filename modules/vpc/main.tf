locals {
  tags = var.tags == null ? {} : var.tags
  availability_zones = var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, var.availability_zones_count)
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = merge(
    {
      "Name" = "${var.name_prefix}-vpc"
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "public_subnet" {
  count = length(local.availability_zones)

  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, length(local.availability_zones) * 2, count.index)
  availability_zone = local.availability_zones[count.index]
  tags = merge(
    {
      "Name" = join("-", [var.name_prefix, "subnet", "public${count.index + 1}", local.availability_zones[count.index]])
      "kubernetes.io/role/elb" = ""
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_subnet" "private_subnet" {
  count = length(local.availability_zones)

  vpc_id            = aws_vpc.vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, length(local.availability_zones) * 2, count.index + length(local.availability_zones))
  availability_zone = local.availability_zones[count.index]
  tags = merge(
    {
      "Name" = join("-", [var.name_prefix, "subnet", "private${count.index + 1}", local.availability_zones[count.index]])
      "kubernetes.io/role/internal-elb" = ""
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

#
# Internet gateway
#
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.vpc.id
  tags = merge(
    {
      "Name" = "${var.name_prefix}-igw"
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

#
# Elastic IPs for NAT gateways
#
resource "aws_eip" "eip" {
  count = length(local.availability_zones)

  domain = "vpc"
  tags = merge(
    {
      "Name" = join("-", [var.name_prefix, "eip", local.availability_zones[count.index]])
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

#
# NAT gateways
#
resource "aws_nat_gateway" "public_nat_gateway" {
  count = length(local.availability_zones)

  allocation_id = aws_eip.eip[count.index].id
  subnet_id     = aws_subnet.public_subnet[count.index].id

  tags = merge(
    {
      "Name" = join("-", [var.name_prefix, "nat", "public${count.index}", local.availability_zones[count.index]])
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

#
# Route tables
#
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpc.id
  tags = merge(
    {
      "Name" = "${var.name_prefix}-public"
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_route_table" "private_route_table" {
  count = length(local.availability_zones)

  vpc_id = aws_vpc.vpc.id
  tags = merge(
    {
      "Name" = join("-", [var.name_prefix, "rtb", "private${count.index}", local.availability_zones[count.index]])
    },
    local.tags,
  )
  lifecycle {
    ignore_changes = [tags]
  }
}

#
# Routes
#
# Send all IPv4 traffic to the internet gateway
resource "aws_route" "ipv4_egress_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.internet_gateway.id
  depends_on             = [aws_route_table.public_route_table]
}

# Send all IPv6 traffic to the internet gateway
resource "aws_route" "ipv6_egress_route" {
  route_table_id              = aws_route_table.public_route_table.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.internet_gateway.id
  depends_on                  = [aws_route_table.public_route_table]
}

# Send private traffic to NAT
resource "aws_route" "private_nat" {
  count = length(local.availability_zones)

  route_table_id         = aws_route_table.private_route_table[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.public_nat_gateway[count.index].id
  depends_on             = [aws_route_table.private_route_table, aws_nat_gateway.public_nat_gateway]
}


resource "aws_vpc_endpoint" "private_vpc_endpoints" {
  for_each = var.private_vpc_endpoints_map

  vpc_id            = aws_vpc.vpc.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type = each.value

  subnet_ids         = each.value == "Interface" ? [for subnet in aws_subnet.private_subnet : subnet.id] : null
  security_group_ids = each.value == "Interface" ? [aws_security_group.vpce.id] : null
  route_table_ids    = each.value == "Gateway" ? [for rt in aws_route_table.private_route_table : rt.id] : null

  private_dns_enabled = each.value == "Interface" ? true : null

  tags = merge(
    {
      Name = "${var.name_prefix}-vpce-${each.key}"
    },
    local.tags
  )
}

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Security group for custom VPC endpoints"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # or tighter scope
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr] # or tighter scope
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name = "${var.name_prefix}-vpce-sg"
    },
    local.tags
  )
}


#
# Route table associations
#
resource "aws_route_table_association" "public_route_table_association" {
  count = length(local.availability_zones)

  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "private_route_table_association" {
  count = length(local.availability_zones)

  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_route_table[count.index].id
}

# This resource is used in order to add dependencies on all resources 
# Any resource uses this VPC ID, must wait to all resources creation completion
resource "time_sleep" "vpc_resources_wait" {
  create_duration = "20s"
  destroy_duration = "20s"
  triggers = {
    vpc_id                                           = aws_vpc.vpc.id
    cidr_block                                       = aws_vpc.vpc.cidr_block
    ipv4_egress_route_id                             = aws_route.ipv4_egress_route.id
    ipv6_egress_route_id                             = aws_route.ipv6_egress_route.id
    private_nat_ids                                  = jsonencode([for value in aws_route.private_nat : value.id])
    private_vpc_endpoints                            = jsonencode([for value in aws_vpc_endpoint.private_vpc_endpoints : value.id])
    public_route_table_association_ids               = jsonencode([for value in aws_route_table_association.public_route_table_association : value.id])
    private_route_table_association_ids              = jsonencode([for value in aws_route_table_association.private_route_table_association : value.id])
  }
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  # New configuration to exclude Local Zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
