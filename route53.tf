#--------------------------#
# Route53
#--------------------------#

data "aws_route53_zone" "main" {
  name = "tf-aws-portfolio.koichirokudo.info"
}

resource "aws_route53_record" "web" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "tf-aws-portfolio.koichirokudo.info"
  type    = "A"

  # ALIAS レコード
  # AWS のみで使用可能なレコードで、S3バケットや
  # CloudFrontなどでも使える DNS から見ればただのAレコード
  # CNAME: ドメイン名->CNAME->IPアドレスの流れで名前解決する
  # ALIAS: ドメイン名->IPアドレスの流れで名前解決するためパフォーマンスが向上する
  # aliasにALBのDNS名とゾーンIDを指定するとALBのIPアドレスへ名前解決できる
  alias {
    name                   = aws_lb.example.dns_name
    zone_id                = aws_lb.example.zone_id
    evaluate_target_health = true
  }
}

output "domain_name" {
  value = aws_route53_record.web.name
}

