provider "aws" {
  region  = "eu-central-1"
#  version = "~> 3.33.0"
}

# Задаем какой instance поднимать

resource "aws_launch_configuration" "back" {
  name_prefix = "back-"
#  ami             = "ami-013fffc873b1eaa1c" # Последний Amazon Linux 2 AMI (HVM)
  image_id         = "ami-013fffc873b1eaa1c" # Последний Amazon Linux 2 AMI (HVM)
  instance_type   = "t2.micro"
  key_name        = "FirstAWS-VM"  #имя пары ключей для instance с Jenkins
#  security_groups = aws_security_group.back.id  # связываем с  SG, описанной ниже
  security_groups = [aws_security_group.back.name]
  user_data = <<EOF
#!/bin/bash
sudo amazon-linux-extras install nginx1.12 -y
ip_instance=`curl http://169.254.169.254/latest/meta-data/local-ipv4`
echo "<h3>IP of this instance:</h3><h2 style="color:red"> $ip_instance</h2><br>Build by Terraform" > /usr/share/nginx/html/index.html
sudo service nginx start
chkconfig nginx on
EOF
  lifecycle {
    create_before_destroy = true
  }
}


# Добавим security group

resource "aws_security_group" "back" {
  name        = "sg_back"
  description = "Security group for Terraform: http allow"
  
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

# Создадим Virtual Private Cloud, в котором создадим подсети
resource "aws_vpc" "tf_vpc" {
  cidr_block       = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "Terraform_VPC"
  }
}

# Добавим 2 subnet (availability zones) в которых будут масштабироваться backends

resource "aws_subnet" "public_eu_central_1a" {
  vpc_id     = aws_vpc.tf_vpc.id
  cidr_block = "10.0.0.0/24"
  availability_zone = "eu-central-1a"

  tags = {
    Name = "Subnet eu-central-1a"
  }
}

resource "aws_subnet" "public_eu_central_1b" {
  vpc_id     = aws_vpc.tf_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "eu-central-1b"

  tags = {
    Name = "Subnet eu-central-1b"
  }
}

# Добавим интернер-шлюз

resource "aws_inet_gateway" "tf_vpc_igate" {
  vpc_id = aws_vpc.tf_vpc.id

  tags = {
    Name = "Terraform_VPC - Internet Gateway"
  }
}

resource "aws_route_table" "tf_vpc_public" {
  vpc_id = aws_vpc.tf_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_inet_gateway.tf_vpc_igate.id
  }

  tags = {
    Name = "Public Subnets Route Table for Terraform_VPC"
  }
}

# Добавим туда availability zones
resource "aws_route_table_association" "tf_vpc_eu-central-1a_public" {
  subnet_id = aws_subnet.public_eu_central_1a.id
  route_table_id = aws_route_table.tf_vpc_public.id
}

resource "aws_route_table_association" "tf_vpc_eu-central-1b_public" {
  subnet_id = aws_subnet.public_eu_central_1b.id
  route_table_id = aws_route_table.tf_vpc_public.id
}

#  security_group для Elastic Load Balancer

resource "aws_security_group" "elb_http" {
  name        = "elb_http"
  description = "Allow HTTP traffic to instances through Elastic Load Balancer"
  vpc_id = aws_vpc.tf_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Allow HTTP through ELB Security Group"
  }
}

#   Добавим к этой security_group Load balanser, распределяющий нагрузку по нодам и availability зонам

resource "aws_elb" "back_elb" {
  name = "back-elb"
  security_groups = [  aws_security_group.elb_http.id ]
  subnets = [
    aws_subnet.public_eu_central_1a.id,
    aws_subnet.public_eu_central_1b.id
  ]

  cross_zone_load_balancing   = true

  #  Настройка проверки состояния instance
  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    interval = 30
    target = "HTTP:80/"
  }

  listener {
    lb_port = 80
    lb_protocol = "http"
    instance_port = "80"
    instance_protocol = "http"
  }

}

#  Добавляем AutoScallingGroup

resource "aws_autoscaling_group" "back" {
  name = "${aws_launch_configuration.back.name}-asg"

  min_size             = 1
  desired_capacity     = 2
  max_size             = 4
  health_check_grace_period = 60
  health_check_type    = "ELB"
  load_balancers = [
    aws_elb.back_elb.id
  ]

  launch_configuration = aws_launch_configuration.back.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier  = [
    aws_subnet.public_eu_central_1a.id,
    aws_subnet.public_eu_central_1b.id
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "back"
    propagate_at_launch = true
  }
}
# get Load Balancer DNS name as an output from the Terraform infrastructure description:
output "elb_dns_name" {
  value = aws_elb.back_elb.dns_name
}

#output "instans_public_dns" {
#  value = aws_instance.back.public_dns
#}

#  Добавим правила Autoscaling, при которых увеличивать или уменьшать количество instance

resource "aws_autoscaling_policy" "scale_up" {
  name                   = "scale_up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.back.name
}
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_up" {
  alarm_name = "cpu_alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "60"
  statistic = "Average"
  threshold = "60"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.back.name
  }

  alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions = [ aws_autoscaling_policy.scale_up.arn ]
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "scale_down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.back.name
}
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_down" {
  alarm_name = "cpu_alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "60"
  statistic = "Average"
  threshold = "20"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.back.name
  }

  alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions = [ aws_autoscaling_policy.scale_down.arn ]
}


