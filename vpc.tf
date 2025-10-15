#--------------------------#
# VPC
#--------------------------#
resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "example"
  }
}

#--------------------------#
# VPC Public Subnet
#--------------------------#

# パブリックネットワークのマルチAZ
# public-a
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-a"
  }
}

# public-c
resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-c"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "example" {
  vpc_id = aws_vpc.example.id
}

# Route Table
# ルートテーブルはVPC内の通信を有効にするために
# ローカルルートが自動的に作成される
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.example.id
}

# デフォルトルート設定
# VPC内はローカルルートによりルーティングされる
# ローカルルートは変更や削除ができない(Terraformからも制御不可)
# VPC以外への通信をIGW経由でインターネットに流すためのデフォルトルートを設定する
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  gateway_id             = aws_internet_gateway.example.id
  destination_cidr_block = "0.0.0.0/0"
}

# ルートテーブルの関連付け
# どのルートテーブルを使ってルーティングするかはサブネット単位で判断する
# そこでルートテーブルとサブネットを関連付ける
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

#--------------------------#
# VPC Private Subnet
#--------------------------#

# プライベートネットワークのマルチAZ
# public-a
resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.65.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = false
  tags = {
    Name = "private_a"
  }
}

# public-c
resource "aws_subnet" "private_c" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.66.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = false
  tags = {
    Name = "private_c"
  }
}

# Route Table
# デフォルトルートは1つのルートテーブルにつき
# 1つしか定義できないため、ルートテーブルとAZ毎に作成する
# private-a
resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.example.id
}

# private-c
resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.example.id
}

# デフォルトルート設定　
# private-a
resource "aws_route" "private_a" {
  route_table_id         = aws_route_table.private_a.id
  nat_gateway_id         = aws_nat_gateway.nat_gateway_a.id
  destination_cidr_block = "0.0.0.0/0"
}

# private-c
resource "aws_route" "private_c" {
  route_table_id         = aws_route_table.private_c.id
  nat_gateway_id         = aws_nat_gateway.nat_gateway_c.id
  destination_cidr_block = "0.0.0.0/0"
}

# ルートテーブルの関連付け
# private-a
resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

# private-c
resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private_c.id
}

# Elastic IP
resource "aws_eip" "nat_gateway_a" {
  domain = "vpc"
  # 依存関係の明確化: 暗黙的になっているため予期せぬところでエラーがでる。Terraform ドキュメントに書いてある
  # このEIPはインターネットゲートウェイ作成後に作成されることを保証する
  depends_on = [aws_internet_gateway.example]
  tags = {
    Name = "nat-gateway-a"
  }
}

resource "aws_eip" "nat_gateway_c" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.example]
  tags = {
    Name = "nat-gateway-c"
  }
}

# NAT gateway
resource "aws_nat_gateway" "nat_gateway_a" {
  # NAT ゲートウェイに関連付けるElastic IPアドレスの割当ID
  allocation_id = aws_eip.nat_gateway_a.id

  # NAT ゲートウェイを配置するサブネットのサブネットID
  subnet_id = aws_subnet.public_a.id

  depends_on = [aws_internet_gateway.example]
}

resource "aws_nat_gateway" "nat_gateway_c" {
  allocation_id = aws_eip.nat_gateway_c.id
  subnet_id     = aws_subnet.public_c.id
  depends_on    = [aws_internet_gateway.example]
}

