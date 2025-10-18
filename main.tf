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
  family = "mysql8.0"

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
  major_engine_version = "8.0"   // メジャーバージョン

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

resource "random_password" "random-password" {
  length           = 16
  special          = true
  override_special = "_!%^"
}

resource "aws_secretsmanager_secret" "password" {
  name = "mysql-db-password"
}

resource "aws_secretsmanager_secret_version" "password" {
  secret_id     = aws_secretsmanager_secret.password.id
  secret_string = random_password.random-password.result
}


# DBインスタンス
resource "aws_db_instance" "example" {
  identifier              = "exmaple" // 識別子
  engine                  = "mysql"
  engine_version          = "8.0.42"
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
  skip_final_snapshot        = true // インスタンス削除時のスナップショット作成 本番環境では false にしたほうがいいと思う
  #  final_snapshot_identifier = "example-final-${formatdate("YYYYMMDDhhmmss", timestamp())}" これも入れたほうがいい本番では
  port                       = 3306
  // 設定タイミング「即時」と「メンテナンスウィンドウ」がある
  // RDSでは一部の設定変更に再起動が伴い、予期せぬDTが起こりえる
  // false にすることで、即時反映を避ける
  apply_immediately      = false
  vpc_security_group_ids = [module.mysql_sg.security_group_id]
  parameter_group_name   = aws_db_parameter_group.example.name // DBパラメータ
  option_group_name      = aws_db_option_group.example.name    // DBオプション
  db_subnet_group_name   = aws_db_subnet_group.example.name    // DBサブネット

  // Secrets Manager でマスターパスワードを管理できるようになる
  manage_master_user_password = true
}

// DBインスタンスのセキュリティグループ定義
module "mysql_sg" {
  source      = "./security_group"
  name        = "mysql-sg"
  vpc_id      = aws_vpc.example.id
  port        = 3306
  cidr_blocks = [aws_vpc.example.cidr_block]
}


#--------------------------#
# ElastiCache
#--------------------------#
resource "aws_elasticache_parameter_group" "example" {
  name   = "example"
  family = "valkey8"

  parameter {
    name  = "cluster-enabled"
    value = "no"
  }
}

resource "aws_elasticache_subnet_group" "example" {
  name       = "example"
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_c.id]
}

resource "aws_elasticache_replication_group" "example" {
  replication_group_id       = "example"             // 識別子
  description                = "Cluster Disabled"    // 説明
  engine                     = "valkey"              // engine
  engine_version             = "8.1"                 // 使用バージョン
  num_cache_clusters         = 3                     // ノード数 3だとプライマリノードが1, レプリカノードが2
  node_type                  = "cache.t2.micro"      // ノードの種類
  snapshot_window            = "09:10-10:10"         // スナップショットの取得時間UTC
  snapshot_retention_limit   = 7                     // 保持する期間
  maintenance_window         = "mon:10:40-mon:11:40" // メンテナンス期間
  automatic_failover_enabled = true                  // 自動フェイルオーバー multi az 有効時のみ
  port                       = 6379
  apply_immediately          = false // RDSと同様に即時だと予期せぬDTが発生する可能性がある
  security_group_ids         = [module.valkey_sg.security_group_id]
  parameter_group_name       = aws_elasticache_parameter_group.example.name
  subnet_group_name          = aws_elasticache_subnet_group.example.name
}

module "valkey_sg" {
  source      = "./security_group"
  name        = "valkey-sg"
  vpc_id      = aws_vpc.example.id
  port        = 6379
  cidr_blocks = [aws_vpc.example.cidr_block]
}

#--------------------------#
# ECR
#--------------------------#

# ECR リポジトリの作成
resource "aws_ecr_repository" "example" {
  name = "example"
}

# ECRライフサイクルポリシー
# ECR リポジトリに保存できるイメージ数は制限がある
# イメージが増大しないようにする
# イメージタグを30個までに制限する
data "aws_ecr_lifecycle_policy_document" "example" {
  rule {
    priority    = 1
    description = "Keep last 30 release tagged images"

    selection {
      tag_status      = "tagged"
      tag_prefix_list = ["release"]
      count_type      = "imageCountMoreThan"
      count_number    = 30
    }

    action {
      type = "expire"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "example" {
  repository = aws_ecr_repository.example.name
  policy     = data.aws_ecr_lifecycle_policy_document.example.json
}

#--------------------------#
# Code Build
#--------------------------#
# ビルド出力アーティファクトを保存するためのS3操作権限
# ビルドログを出力するためのCloudWatchLogsの操作権限
# DockerイメージをpushするためのECR操作権限
# ビルド出力アーティファクトとは CodeBuild がビルド時に生成した成果物となるファイルのこと
data "aws_iam_policy_document" "codebuild" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "logs:CreateLogGroup",
      "logs:CreateStream",
      "logs:PutLogEvents",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
  }
}

module "codebuild_role" {
  source     = "./iam_role"
  name       = "codebuild"
  identifier = "codebuild.amazonaws.com" // CodeBuildで使うことを宣言する
  policy     = data.aws_iam_policy_document.codebuild.json
}

# CodeBuild のプロジェクトを作成する
resource "aws_codebuild_project" "example" {
  name         = "example"
  service_role = module.codebuild_role.iam_role_arn

  # ビルド対象のファイルを source で指定する
  source {
    type = "CODEPIPELINE"
  }

  # ビルド出力アーティファクトの格納席を artifacts で指定している
  # CODEPIPELINE を指定すると、CodePipeline と連携することを宣言する
  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:2.0" // これはAWSが管理している ubuntu ベースのイメージ
    privileged_mode = true                         // build 時に docker コマンドを使うため特権を付与している
  }
}

#--------------------------#
# Code Pipeline
#--------------------------#

# ステージ間でデータを受け渡すためのS3操作権限
# CodeBuildプロジェクトを起動するためのCodeBuild操作権限
# ECSにDockerイメージをデプロイするためのECS操作権限
# CodeBuildやECSにロールを渡すための PassRole 権限
data "aws_iam_policy_document" "codepipeline" {
  statement {
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "codebuild:StartBuild",
      "ecs:DescribeServices",
      "ecs:DescribetaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "iam:PassRole",
    ]
  }
}

module "codepipeline_role" {
  source     = "./iam_role"
  name       = "codepipeline"
  identifier = "codepipeline.amazonaws.com"
  policy     = data.aws_iam_policy_document.codepipeline.json
}

# アーティファクトストア
# CodePipeline の各ステージでデータの受け渡しに使用する
# アーティファクトストアを作成する
resource "aws_s3_bucket" "artifact" {
  bucket = "artifact-terraform-aws-portfolio-kk-1111"
}


resource "aws_s3_bucket_lifecycle_configuration" "artifact_lifecycle" {
  bucket = aws_s3_bucket.artifact.id
  rule {
    id     = "artifact-lifecycle"
    status = "Enabled"
    expiration {
      days = "180"
    }
  }
}

resource "aws_codepipeline" "example" {
  name     = "example"
  role_arn = module.codepipeline_role.iam_role_arn

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = 1
      output_artifacts = ["Source"]
      configuration = {
        Owner               = var.github_owner
        Repo                = var.github_repo_name
        Branch              = "main"
        # PollForSorceChanges = false
        OAuthToken = "token"
      }
    }
  }


  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = 1
      input_artifacts  = ["Source"]
      output_artifacts = ["Build"]
      configuration = {
        ProjectName = aws_codebuild_project.example.id
      }
    }
  }


  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = 1
      input_artifacts = ["Build"]

      configuration = {
        ClusterName = aws_ecs_cluster.example.name
        ServiceName = aws_ecs_service.example.name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  artifact_store {
    location = aws_s3_bucket.artifact.id
    type     = "S3"
  }
}

# CodePipeline Webhook
resource "aws_codepipeline_webhook" "example" {
  name            = "example"
  target_pipeline = aws_codepipeline.example.name
  target_action   = "Source"      // 最初に実行するアクション
  authentication  = "GITHUB_HMAC" // 認証

  authentication_configuration {
    // ここは本来はSSMパラメータ等で管理しないとtfstateファイルに平文で書き込まれる
    secret_token = "VeryRandomStringMoreThan20Byte!"
  }

  filter {
    json_path    = "$.ref"
    match_equals = "refs/heads/{Branch}"
  }
}

provider "github" {
  owner = var.github_owner
}

resource "github_repository_webhook" "example" {
  repository = var.github_repo_name

  configuration {
    url          = aws_codepipeline_webhook.example.url
    secret       = "VeryRandomStringMoreThan20Byte!"
    content_type = "json"
    insecure_ssl = false
  }

  events = ["push"]
}


#--------------------------#
# Session Manager
#--------------------------#

data "aws_iam_policy" "ec2_for_ssm" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_for_ssm" {
  source_policy_documents = [data.aws_iam_policy.ec2_for_ssm.policy]
  statement {
    effect = "Allow"
    resources = ["*"]
    actions = [
      "s3:PutObject",
      "logs:PutLogEvents",
      "logs:CreateLogStream",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "kms:Decrypt",
    ]
  }
}

module "ec2_for_ssm_role" {
  source      = "./iam_role"
  name        = "ec2-for-ssm"
  identifier = "ec2.amazonaws.com"
  policy = data.aws_iam_policy_document.ec2_for_ssm.json
}

resource "aws_instance" "example_for_operation" {
  ami = "ami-0bec29af1d113f349"
  instance_type = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.ec2_for_ssm.name
  subnet_id = aws_subnet.private_a.id
  user_data = file("./user_data.sh")
}

resource "aws_iam_instance_profile" "ec2_for_ssm" {
  name = "ec2-for-ssm"
  role = module.ec2_for_ssm_role.iam_role_name
}

output "operation_instance_id" {
  value = aws_instance.example_for_operation.id
}

resource "aws_s3_bucket" "operation" {
  bucket = "operation-terraform-aws-portfolio-kk-1111"
}

resource "aws_s3_bucket_lifecycle_configuration" "operation_rule" {
  bucket = aws_s3_bucket.operation.id
  rule {
    id     = "operation-rule"
    status = "Enabled"
    expiration {
      days = "180"
    }
  }
}

resource "aws_cloudwatch_log_group" "operation" {
  name = "/operation"
  retention_in_days = 180
}

resource "aws_ssm_document" "session_manager_run_shell" {
  name = "SSM-SessionManagerRunShell"
  document_type = "Session"
  document_format = "JSON"
  content = <<EOF
  {
    "schemaVersion": "1.0",
    "description": "Doc to hold regional settings for Session Manger",
    "sessionType": "Standard_Stream",
    "inputs": {
      "s3:BucketName": "${aws_s3_bucket.operation.id}",
      "cloudWatchLogGroupName": "${aws_cloudwatch_log_group.operation.name}"
    } 
  }
EOF
}
