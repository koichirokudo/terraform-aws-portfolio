#--------------------------#
# AWS Certificate Manager
#--------------------------#

# SSL/TLS証明書の作成
resource "aws_acm_certificate" "example" {
  # ドメイン名: *.example.com ワイルドカードで指定すると
  # ワイルドカード証明書を発行できる
  domain_name = "tf-aws-portfolio.koichirokudo.info"
  # ドメイン名の追加: 例えば test.example.com を追加すると
  # example.com と test.example.com のSSL証明書を作成する
  subject_alternative_names = ["tf-aws-portfolio.koichirokudo.info"]
  # ドメイン所有権の検証方法: DNS検証かEメール検証を選択できる
  validation_method = "DNS"

  # ライフサイクル: 新しいSSL証明書を作ってから古いSSL証明書を差し替える
  lifecycle {
    create_before_destroy = true
  }
}

# SSL/TLS証明書の検証
resource "aws_route53_record" "example_dns_resolve" {
  for_each = {
    for dvo in aws_acm_certificate.example.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  allow_overwrite = true
  zone_id         = data.aws_route53_zone.main.id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# 検証の待機
# apply時にSSL/TLS証明書の検証が完了するまで待機してくれる
# 実際になにかのリソースを作るわけではない
resource "aws_acm_certificate_validation" "example_certificate_validation" {
  certificate_arn         = aws_acm_certificate.example.arn
  validation_record_fqdns = [for record in aws_route53_record.example_dns_resolve : record.fqdn]
}
