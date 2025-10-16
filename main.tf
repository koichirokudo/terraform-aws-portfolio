#--------------------------#
# main
#--------------------------#
terraform {
  required_version = ">= 1.13.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" // 6.0 以上, 7.0未満
    }
  }
}

#--------------------------#
# ECS
#--------------------------#
resource "aws_ecs_cluster" "example" {
  name = "example"
}

# Task Definition
resource "aws_ecs_task_definition" "example" {
  family                   = "example"                                   // タスク定義名のプレフィクス
  cpu                      = "256"                                       // CPU リソースサイズ
  memory                   = "512"                                       // メモリGB
  network_mode             = "awsvpc"                                    // fargate の場合 awsvpc を指定する
  requires_compatibilities = ["FARGATE"]                                 // 起動タイプ
  container_definitions    = file("./container_definitions.json")        // コンテナ定義
  execution_role_arn       = module.ecs_task_execution_role.iam_role_arn // Docker コンテナがCloudWatch Logsにログを投げられるようにする
}

# バッチ用タスク定義
resource "aws_ecs_task_definition" "example_batch" {
  family                   = "example-batch"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  container_definitions    = file("./batch_container_definitions.json")
  execution_role_arn       = module.ecs_task_execution_role.iam_role_arn
}

resource "aws_ecs_service" "example" {
  name            = "example"
  cluster         = aws_ecs_cluster.example.arn
  task_definition = aws_ecs_task_definition.example.arn
  desired_count   = 2         // 維持するタスク数 本番では2以上
  launch_type     = "FARGATE" // 起動タイプ
  // https://docs.aws.amazon.com/ja_jp/AmazonECS/latest/developerguide/platform-fargate.html
  platform_version                  = "1.4.0" // プラットフォームバージョン
  health_check_grace_period_seconds = 60      // ヘルスチェック猶予期間

  // ネットワーク構成
  network_configuration {
    assign_public_ip = false
    security_groups  = [module.nginx_sg.security_group_id]

    subnets = [
      aws_subnet.private_a.id,
      aws_subnet.private_c.id
    ]
  }

  // ターゲットグループとコンテナの名前・ポート番号を指定して
  // LBと関連付ける
  load_balancer {
    target_group_arn = aws_lb_target_group.example.arn
    container_name   = "example"
    container_port   = 80
  }

  // Fargate の場合デプロイのたびにタスク定義が更新され、plan 時に差分がでる
  // なので、Terraform ではタスク定義の変更を無視したほうがいい
  lifecycle {
    ignore_changes = [task_definition]
  }
}

module "nginx_sg" {
  source      = "./security_group"
  name        = "nginx-sg"
  vpc_id      = aws_vpc.example.id
  port        = 80
  cidr_blocks = [aws_vpc.example.cidr_block]
}

#--------------------------#
# CloudWatch Logs
#--------------------------#

// Fargateではホストサーバにログインできず、コンテナのログを直接確認できない
// CloudWatch Logs と連携し、ログを記録できるようにする
resource "aws_cloudwatch_log_group" "for_ecs" {
  name              = "/ecs/example"
  retention_in_days = 180
}

// ECSタスク実行IAMロール
// ECSに権限を付与するため、ECSタスク実行IAMロールを作成する
data "aws_iam_policy" "ecs_task_execution_role_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

// source_policy_documents を使うと既存のポリシーを継承できる
// ここでは AmazonECSTaskExecutionRolePolicy を継承して、
// 必要な権限を追加する(ssmとkms)
data "aws_iam_policy_document" "ecs_task_execution" {
  source_policy_documents = [
    data.aws_iam_policy.ecs_task_execution_role_policy.policy
  ]

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameters", "kms:Decrypt"]
    resources = ["*"]
  }
}

// IAMロール作成
// ecs-tasks.amazonaws.com はECSを使うことを宣言
module "ecs_task_execution_role" {
  source     = "./iam_role"
  name       = "ecs-task-execution"
  identifier = "ecs-tasks.amazonaws.com"
  policy     = data.aws_iam_policy_document.ecs_task_execution.json
}

// Batch用ログ
resource "aws_cloudwatch_log_group" "for_ecs_scheduled_tasks" {
  name              = "/ecs-scheduled-tasks/example"
  retention_in_days = 180
}

data "aws_iam_policy" "ecs_events_role_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceEventsRole"
}

module "ecs_events_role" {
  source     = "./iam_role"
  name       = "ecs-events"
  identifier = "events.amazonaws.com"
  policy     = data.aws_iam_policy.ecs_events_role_policy.policy
}

// CloudWatch イベントルールを定義する
resource "aws_cloudwatch_event_rule" "example_batch" {
  name                = "example-batch"
  description         = "重要なバッチ処理"
  schedule_expression = "cron(*/2 * * * ? *)"
}

// CloudWatch イベントターゲットの定義
// 実行対象のジョブを定義する
resource "aws_cloudwatch_event_target" "example_batch" {
  target_id = "example-batch"
  rule      = aws_cloudwatch_event_rule.example_batch.name
  role_arn  = module.ecs_events_role.iam_role_arn
  arn       = aws_ecs_cluster.example.arn

  ecs_target {
    launch_type         = "FARGATE"
    task_count          = 1
    platform_version    = "1.4.0"
    task_definition_arn = aws_ecs_task_definition.example_batch.arn

    network_configuration {
      assign_public_ip = false
      subnets          = [aws_subnet.private_a.id]
    }
  }
}

#--------------------------#
# Key Management Service
#--------------------------#

# 暗号鍵を管理するマネージドサービス
# KMSでもっとも重要なリソースはカスタマーマスターキー
# カスタマーマスターキーが自動生成したデータキーを使用して暗号化と復号を行う
resource "aws_kms_key" "example" {
  description             = "Example Customer Master Key"
  enable_key_rotation     = true // 自動ローテーション機能:頻度は年に1度
  is_enabled              = true // カスタマーマスターキーの有効化と無効化
  deletion_window_in_days = 30   // 削除待機期間：デフォルトは30日、カスタマーマスターキーの削除は推奨されない（復号できなくなるため）
}

# カスタマーマスターキーにはUUIDが割り当てられるが、わかりずらいので
# エイリアス設定をして、使用用途をわかりやすくする
# エイリアス設定する名前には alias/ というプレフィクスが必要
resource "aws_kms_alias" "example" {
  name          = "alias/example"
  target_key_id = aws_kms_key.example.key_id
}

#--------------------------#
# SSM
#--------------------------#
# 平文
resource "aws_ssm_parameter" "db_username" {
  name        = "/db/username"
  value       = "root"
  type        = "String"
  description = "データベースのユーザー名"
}

# 暗号化
# value が平文になってしまうので、別ファイルでバージョン管理対象外にしたほうがいい
# 今回は、ダミー値を設定してあとで AWS CLI から更新する
resource "aws_ssm_parameter" "db_raw_password" {
  name        = "/db/raw_password"
  value       = "uninitialized"
  type        = "SecureString"
  description = "データベースのパスワード"

  lifecycle {
    ignore_changes = [value]
  }
}

#--------------------------#
# RDS
#--------------------------#
# DBパラメータグループ
# MySQLのmy.cnfファイルやPostgreSQLの
# postgresql.conf、pg_hba.confなどを定義するようなDBの設定は
# DBパラメータグループで記述する
resource "aws_db_parameter_group" "example" {
  name   = "example"
  family = "mysql5.7"

  parameter {
    name  = "character_set_database"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
}

# DBオプショングループ
# DBエンジンのオプション機能を追加する
resource "aws_db_option_group" "example" {
  name                 = "example"
  engine_name          = "mysql" // エンジン名
  major_engine_version = "5.7"   // メジャーバージョン

  option {
    # MariaDB監査プラグイン
    # ユーザのログオン、実行クエリなどのアクティビティを記録するため
    option_name = "MARIADB_AUDIT_PLUGIN"
  }
}

# DBサブネットグループ
# DBを稼働させるサブネットを定義する
resource "aws_db_subnet_group" "example" {
  name       = "example"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

# DBインスタンス
resource "aws_db_instance" "example" {
  identifier              = "exmaple" // 識別子
  engine                  = "mysql"
  engine_version          = "5.7.25"
  instance_class          = "db.t3.small"
  allocated_storage       = 20                      // ストレージ容量
  max_allocated_storage   = 100                     // 指定した量まで自動スケールする
  storage_type            = "gp3"                   // ストレージタイプ
  storage_encrypted       = true                    // ディスク暗号化
  kms_key_id              = aws_kms_key.example.arn // KMSのカギを指定するとディスク暗号化が有効になる
  username                = "admin"                 // マスタユーザ
  multi_az                = true
  publicly_accessible     = false                 // VPC外からのアクセス遮断
  backup_window           = "09:10-09:40"         // RDSのバックアップタイミングを設定(UTC)なお、メンテナンスウィンドウ前にバックアップウィンドウを設定しておくと安心感が増す
  backup_retention_period = 30                    // バックアップ期間（最大35日）
  maintenance_window      = "mon:10:10-mon:10:40" // メンテナスタイミングの設定
  // メンテナンスにはOSやDBエンジンの更新が含まれるメンテナンス自体を無効化することはできない
  // ただし、自動マイナーバージョンアップは無効化できる。たしかここIさんがよくいってたな
  // OSやDBエンジンの更新作業中はサービス止まるときもあるしそうでないときもあるって
  auto_minor_version_upgrade = false
  deletion_protection        = true  // 削除保護
  skip_final_snapshot        = false // インスタンス削除時のスナップショット作成
  port                       = 3306
  // 設定タイミング「即時」と「メンテナンスウィンドウ」がある
  // RDSでは一部の設定変更に再起動が伴い、予期せぬDTが起こりえる
  // false にすることで、即時反映を避ける
  apply_immediately      = false
  vpc_security_group_ids = [module.mysql_sg.security_group_id]
  parameter_group_name   = aws_db_parameter_group.example.name // DBパラメータ
  option_group_name      = aws_db_option_group.example.name    // DBオプション
  db_subnet_group_name   = aws_db_subnet_group.example.name    // DBサブネット

  // aws_db_instance ではリソースの password は必須項目
  // パスワードが tfstate ファイルに平文で書き込まれる
  // variable を使って tf ファイルへ平文で書くことを回避しても、tfstate
  // ファイルへの書き込みは、回避できない。そこで ignore_changes で password を指定
  // apply 後に、マスターパスワード変更する
  // $ aws rds modify-db-instance --db-instance-identifier 'example' \   --master-user-password 'NewMasterPassword!'
  lifecycle {
    ignore_changes = [password]
  }
}

// DBインスタンスのセキュリティグループ定義
module "mysql_sg" {
  source      = "./security_group"
  name        = "mysql-sg"
  vpc_id      = aws_vpc.example.id
  port        = 3306
  cidr_blocks = [aws_vpc.example.cidr_block]
}
