variable "aws_account_id" {
  type        = string
  description = "AWSアカウントID(東京リージョン)"
}

variable "global_ip" {
  type        = string
  description = "固定グローバルIPアドレス"
}

variable "s3_private_bucket_name" {
  type        = string
  description = "s3プライベート用バケット名"
}

variable "s3_public_bucket_name" {
  type        = string
  description = "s3パブリック用バケット名"
}

variable "s3_alb_log_bucket_name" {
  type        = string
  description = "ALBアクセスログ用バケット名"
}

variable "github_owner" {
  type        = string
  description = "GitHubオーナー"
}


variable "github_repo_name" {
  type        = string
  description = "GitHubリポジトリ名"
}
