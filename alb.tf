#--------------------------#
# ALB
#--------------------------#
resource "aws_lb" "example" {
  name                       = "example"
  load_balancer_type         = "application"
  internal                   = false
  idle_timeout               = 60
  enable_deletion_protection = false // productionではtrue

  subnets = [
    aws_subnet.public_a.id,
    aws_subnet.public_c.id
  ]

  access_logs {
    bucket  = aws_s3_bucket.alb_log.id
    enabled = true
  }

  security_groups = [
    module.http_sg.security_group_id,
    module.https_sg.security_group_id,
    module.http_redirect_sg.security_group_id
  ]
}

output "alb_dns_name" {
  value = aws_lb.example.dns_name
}

# ALBのセキュリティグループを定義
module "http_sg" {
  source      = "./security_group"
  name        = "http-sg"
  vpc_id      = aws_vpc.example.id
  port        = 80
  cidr_blocks = ["0.0.0.0/0"]
}

module "https_sg" {
  source      = "./security_group"
  name        = "https-sg"
  vpc_id      = aws_vpc.example.id
  port        = 443
  cidr_blocks = ["0.0.0.0/0"]
}

module "http_redirect_sg" {
  source      = "./security_group"
  name        = "http-redirect-sg"
  vpc_id      = aws_vpc.example.id
  port        = 8080
  cidr_blocks = ["0.0.0.0/0"]
}

# HTTP リスナーの定義
# リスナーは複数のルールを設定して異なるアクションを実行できる
# forward: リクエストを別のターゲットグループに転送
# fixed-response: 固定のHTTPレスポンスを応答
# redirect: 別のURLにリダイレクト
# default_action: いずれかのルールに合致しない場合、default_actionが実行される
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "これはHTTPです"
      status_code  = "200"
    }
  }
}

# HTTPS リスナーの定義
resource "aws_lb_listener" "https" {
  depends_on = [aws_acm_certificate_validation.example_certificate_validation]

  load_balancer_arn = aws_lb.example.arn
  port              = "443"
  protocol          = "HTTPS"
  # SSL/TLS証明書を指定
  certificate_arn = aws_acm_certificate.example.arn
  # 現在のセキュリティポリシーの推奨 TLS1.3/1.2 に対応
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "これはHTTPSです"
      status_code  = "200"
    }
  }
}

# HTTP -> HTTPS へのリダイレクト設定
resource "aws_lb_listener" "redirect_http_to_https" {
  load_balancer_arn = aws_lb.example.arn
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ターゲットグループ設定
resource "aws_lb_target_group" "example" {
  name = "example"
  # EC2インスタンスやIPアドレス、Lambda関数など指定できる
  target_type = "ip"
  # ip を指定した場合 vpc_id/port/protocol を設定する
  # 多くの場合、HTTPSの終端はALBで行うため
  # protocol はHTTPを指定することが多い
  vpc_id   = aws_vpc.example.id
  port     = 80
  protocol = "HTTP"
  # 登録解除の待機時間: ターゲットの登録を解除する前に
  # ALBが待機する時間を秒単位で指定できる
  deregistration_delay = 300

  health_check {
    path                = "/"
    healthy_threshold   = 5              // 正常判定を行うまでのHealth Chek実行回数
    unhealthy_threshold = 2              // 異常判定を行うまでのHealth Check実行回数
    timeout             = 5              // ヘルスチェックのタイムアウト時間(秒)
    interval            = 30             // ヘルスチェックの実行間隔（秒）
    matcher             = 200            // 正常判定を行うために使用するHTTPステータスコード
    port                = "traffic-port" // ヘルスチェックで使用するポート
    protocol            = "HTTP"         // ヘルスチェックで使用するプロトコル
  }

  // ALB作成後にターベットグループを作成する（エラー回避）
  depends_on = [aws_lb.example]
}

# リスナールール
# ターゲットグループにリクエストをフォワードするリスナールールを作る
resource "aws_lb_listener_rule" "example" {
  listener_arn = aws_lb_listener.https.arn
  # 優先順位:数字が小さいほど優先順位が高い
  priority = 100

  # フォワード先のターゲットグループを設定する
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.example.arn
  }

  # 「/img/*」ようなパスベースや「example.com」のような
  # ホストベースなどで条件を指定できる/*はすべてのパスでマッチする
  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
