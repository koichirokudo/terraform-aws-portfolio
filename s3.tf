#--------------------------#
# S3 Private Bucket
#--------------------------#
resource "aws_s3_bucket" "private" {
  bucket = var.s3_private_bucket_name
}

# versioning{} -> aws_s3_bucket_versioning リソースに書き方が変わった
# バージョニング: 有効にするとオブジェクトを変更・削除しても、いつでも
# 以前のバージョンへ復元できるようになる
resource "aws_s3_bucket_versioning" "private" {
  bucket = aws_s3_bucket.private.id
  versioning_configuration {
    status = "Enabled"
  }
}

# server_side_encryption_configuration -> aws_s3_bucket_server_side_encryption_configurationに変わった
# 暗号化: 有効にするとオブジェクト保存時に自動で暗号化し、
# オブジェクト参照時に自動で復号するようになる
# 使い勝手が悪くなることもなく、デメリットがほぼない
resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  bucket = aws_s3_bucket.private.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Public access block: 予期しないオブジェクトの公開を抑止できる
# 既存の公開設定や削除や、新規の公開設定をブロックするなど細かく設定できる
resource "aws_s3_bucket_public_access_block" "private" {
  bucket                  = aws_s3_bucket.private.id
  block_public_acls       = true // 新しいACL設定のブロック
  block_public_policy     = true // 新しいパケットポリシーをブロック
  ignore_public_acls      = true // 公開ACL設定を無視するかどうか
  restrict_public_buckets = true // 所有者とAWSサービスのみにアクセス制限
}

#--------------------------#
# S3 Public Bucket
#--------------------------#

# ACLを使用せず、バケットポリシーだけで公開する方法
# AWS推奨
resource "aws_s3_bucket_public_access_block" "public" {
  bucket                  = aws_s3_bucket.public.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false // バケットポリシーで公開を許可するため
  restrict_public_buckets = false
}

resource "aws_s3_bucket" "public" {
  bucket = var.s3_public_bucket_name
}

# cors_rule -> aws_s3_bucket_cors_configuration
resource "aws_s3_bucket_cors_configuration" "public" {
  bucket = aws_s3_bucket.public.id
  # CORS の設定
  cors_rule {
    allowed_origins = ["https://example.com"]
    allowed_methods = ["GET"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

data "aws_iam_policy_document" "public" {
  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.public.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "public" {
  bucket = aws_s3_bucket.public.id
  policy = data.aws_iam_policy_document.public.json
}

#--------------------------#
# S3 Log Bucket
#--------------------------#

# ALB のアクセスログバケット
resource "aws_s3_bucket" "alb_log" {
  bucket = var.s3_alb_log_bucket_name
}

# ログローテーション
# 180日経過したファイルを自動的に削除
resource "aws_s3_bucket_lifecycle_configuration" "alb_log" {
  bucket = aws_s3_bucket.alb_log.id
  rule {
    id     = "alb-log-rule"
    status = "Enabled"
    expiration {
      days = "180"
    }
  }
}

# バケットポリシー: S3バケットへのアクセス権を設定する
# ALBのようなAWSサービスからS3へ書き込みを行う場合に必要
# https://docs.aws.amazon.com/ja_jp/elasticloadbalancing/latest/application/enable-access-logging.html#access-log-create-bucket
data "aws_iam_policy_document" "alb_log" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.alb_log.id}/*"]

  }
}

resource "aws_s3_bucket_policy" "alb_log" {
  bucket = aws_s3_bucket.alb_log.id
  policy = data.aws_iam_policy_document.alb_log.json
}

