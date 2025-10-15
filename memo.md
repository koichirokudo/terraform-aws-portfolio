# Terraform 学習メモ


## 便利なツール系

**tfenv**: Terraformはリリースサイクルが速いためバージョン管理を容易にするために必要
**.terraform-version**
チーム開発の場合は、このファイルを作成しリポジトリに含める。
このファイルにバージョンを記述すると、チームメンバーが tfenv install コマンドを実行するだけでバージョンを統一できる
**Dockernized Terraform**: Dockerさえ入っていればどこでも実行できるがコマンドが長いためラッパーシェルなどの工夫が必要
**git-secrets**: アクセスキーやパスワードなどの秘匿情報をGitでコミットしようとすると警告してくれる

## 注意点

**リソース再作成時は念入りに確認を！must be replaced**
-/+がつき「aws_instance.example must be replaced」というメッセージが出力されています。
これは「既存のリソースを削除して新しいリソースを作成する」という意味。
リソース削除を伴うため、場合によってはサービスダウンを引き起こす。
リソース再作成時は念入りに確認を！

## tfstate ファイル(terraform.tfstate)

applyを一度でも実行していれば tfstate ファイルが作成される
tfstateファイルは Terraform が生成するファイルで、現在の状態を記録する
Terraform は tfstate ファイルの状態とHCL のコードに差分があれば、その差分のみを変更するように振る舞う

デフォルトではローカルで管理されているが、リモートで管理することも可能

## 変数

variable 変数が定義できる

```terraform
variable "example_instance_type" {
    default = "t3.micro"
}

resource "aws_instance" "example" {
    ami = "xxxxx"
    instance_type = var.example_instance_type
}
```

-var オプションで変数上書きもできる

```bash
$ terraform plan -var 'example_instance_type=t3.nano'
```

環境変数でも変数の上書きができる

```bash
$ TF_VAR_example_instance_type=t3.nano terraform plan
```

## ローカル変数

locals でローカル変数が定義できる
コマンド実行時に上書きができない

```terraform
locals "example_instance_type" {
    default = "t3.micro"
}

resource "aws_instance" "example" {
    ami = "xxxxx"
    instance_type = locals.example_instance_type
}
```

## 出力

output で出力値が定義できる
apply すると実行結果の最後に、作成されたインスタンスIDが出力される

```terraform
resource "aws_instance" "example" {
    ami = "xxxxx"
    instance_type = locals.example_instance_type
}

output "example_instance_id" {
    value = aws_instance.example.id
}
```

## データソース

データソースを使うと外部データを参照できる
filter などを使って検索条件を指定し、 most_recent で最新のAMIを取得している

```terraform
data "aws_ami" "recent_amazon_linux_2" {
    most_recent = true
    owners = ["amazon"]

    filter {
        name = "name"
        values = ["amzn2-ami-hvm-2.0.??????????????-x86_64-gp2"]
    }

    filter {
        name = "state"
        values = ["available"]
    }
}

resource "aws_instance" "example" {
    ami = data.aws_ami.recent_amazon_linux_2.image_id
    instance_type = locals.example_instance_type
}
```

## プロバイダ

Terraform は AWS だけではなく GCP や Azure などにも対応している
APIの違いを吸収するのがプロバイダの役割

```terraform
provider "aws" {
    region = "ap-northeast-1"
}
```

## 組み込み関数

文字列操作やコレクション操作など、よくある処理が組み込み関数として提供されている。
例えば外部ファイルを読み込む file 関数など

user_data.sh

```bash
#!/bin/bash
sudo dnf -y install httpd
sudo systemctl start httpd.service
```

```terraform
resource "aws_instance" "example" {
    ami = "xxxxx"
    instance_type = var.example_instance_type
    user_data = file("./user_data.sh")
}
```

## モジュール

Terraform にもモジュール化の仕組みがある

├── http_server
│   └── main.tf <- モジュールを定義するファイル
├── main.tf <- モジュールを利用するファイル

モジュールを使用する場合、terraform get コマンドか terraform init コマンドを実行してモジュールを事前に取得する必要がある

## SSMパラメータストア

CLI操作

パラメータストアに保存
$ aws ssm put-parameter --name 'plain_name' --value 'plain value' --type String

パラメータストアを参照
$ aws ssm get-parameter --output text --name 'plain_name' --query Parameter.Value

パラメータストアを更新
$ aws ssm put-parameter --name 'plain_name' --type String --value 'modified value' --overwrite

パラメータストアを暗号化して保存
$ aws ssm put-parameter --name 'encryption_name' --value 'encryption value' --type SecureString

パラメータストアから暗号化されたものを参照
$ aws ssm get-parameter --output text --query Parameter.Value --name 'encryption_name' --with-decryption
