provider "aws" {
  region  = "eu-central-1"
#  version = "~> 3.33.0"
}

# Задаем какой instance поднимать

resource "aws_instance" "back" {
  ami             = "ami-013fffc873b1eaa1c" # Последний Amazon Linux 2 AMI (HVM)
  instance_type   = "t2.micro"
  key_name        = "FirstAWS-VM"  #имя пары ключей для instance с Jenkins
  security_groups = aws_security_group.back.id  # связываем с  SG, описанной ниже
# security_groups = aws_security_group.back.name
  user_data = <<EOF
#!/bin/bash
sudo amazon-linux-extras install nginx1.12 -y
ip_instance=`curl http://169.254.169.254/latest/meta-data/local-ipv4`
echo "<h3>IP of this instans:</h3><h2 style="color:red"> $ip_instance<h2><br>Build by Terraform" > /usr/share/nginx/html/index.html
sudo service nginx start
chkconfig nginx on
EOF
}

# Добавим security group

resource "aws_security_group" "back" {
  name        = "sg_back"
  description = "Security group for Terraform"
  
  ingress {
    description = "http access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # слушаем всех
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"  # любой протокол
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "http_access"
  }
}
output "instans_public_dns" {
  value = aws_instance.back.public_dns
}