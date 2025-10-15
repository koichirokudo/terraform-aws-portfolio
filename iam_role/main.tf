#--------------------------#
# IAM Role Module
#--------------------------#
terraform {
  required_version = ">= 1.13.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "name" {
  type = string
  description = "IAMロールとIAMポリシーの名前"
}

variable "policy" {
  type = string
  description = "ポリシードキュメント"
}

variable "identifier" {
  type = string
  description = "IAMロールに関連付けるAWSサービス識別子"
}

# aws_iam_policy_document データソースでもポリシーを記述できる
# コメント追加や変数の参照ができるため便利
# IAMロールでは、自身をなんのサービスに関連付けるかを宣言する必要がある
# その宣言は信頼ポリシーと呼ばれる
data "aws_iam_policy_document" "assume_role" {
  statement {
    /*
    このロールを引き受け(Assume)る権限を与える
    指定されたプリンシパル(ServiceやUserなど)が
    このIAMロールを引き受けることを許可する
    sts:AssumeRole は AWS の STS(Security Token Service)を
    通じて一時的な認証情報(トークン)を発行し、指定ロールとして
    振る舞うためのアクション
    */
    # このロールを引き受ける(Assume)ことを許可するアクション
    actions = ["sts:AssumeRole"]

    # このロールを引き受けることを許可する対象(例:EC2, LambdaなどのAWSサービス)
    # 「誰が」特定の操作を行うことができるかを指定する
    # var.identifier で指定されたものに関連付けができるようにしている
    principals {
      type = "Service"
      identifiers = [var.identifier]
    }
  }
}

# IAM ロール: 信頼ポリシーとロール名を指定する
resource "aws_iam_role" "default" {
  name = var.name
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# IAM ポリシー: ポリシー名とポリシードキュメントを保持するリソース
resource "aws_iam_policy" "default" {
  name = var.name
  policy = var.policy
}

# IAM ポリシーの関連付け: IAM ロールに IAM ポリシーを関連付ける
# IAM ポリシーとIAM ロールは関連付けないと機能しないため注意
resource "aws_iam_role_policy_attachment" "default" {
  role = aws_iam_role.default.name
  policy_arn = aws_iam_policy.default.arn
}

output "iam_role_arn" {
  value = aws_iam_role.default.arn
}

output "iam_role_name" {
  value = aws_iam_role.default.name
}
