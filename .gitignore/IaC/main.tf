
provider "aws" {
  region = "us-east-1"   				# Replace with your preferred region
}

##################################################################
# Create a VPC / 2_Public_Subnets / Internet_Gateway
##################################################################

resource "aws_vpc" "example_vpc" {
  cidr_block = "10.0.0.0/24"
  tags = {
    Name = "App_VPC_IaC"
  }
}

# Create a public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "10.0.0.0/28"
  availability_zone = "us-east-1a"   	# Replace with your preferred AZ
  map_public_ip_on_launch = true  		# Enable this to auto-assign public IPs
  tags = {
    Name = "Public_Subnet_IaC"
  }
}


# Create a second public subnet in a different AZ
resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "10.0.0.16/28" 			# Make sure the CIDR block doesn't overlap with the first subnet
  availability_zone = "us-east-1b"   			# Replace with another AZ in your preferred region
  map_public_ip_on_launch = true  				# Enable this to auto-assign public IPs
  tags = {
    Name = "Public_Subnet_2_IaC"
  }
}


# Create an internet gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.example_vpc.id
  tags = {
    Name = "Internet_Gateway_IaC"
  }
}


##################################################################
# Create a private subnet for the MySQL / SEC GROUP / RDS itself
##################################################################


# Create a private subnet in the same AZ as the first public subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "10.0.0.32/28"          # Make sure the CIDR block doesn't overlap with the public subnet
  availability_zone = "us-east-1a"            # Same AZ as the first public subnet
  map_public_ip_on_launch = true              # Auto-assign public IPs
  tags = {
    Name = "RDS_Private_Subnet_IaC"
  }
}



# Create a private subnet in the same AZ as the second public subnet
resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "10.0.0.48/28"          # Make sure the CIDR block doesn't overlap with the public subnet
  availability_zone = "us-east-1b"            # Same AZ as the second public subnet
  map_public_ip_on_launch = true              # Auto-assign public IPs
  tags = {
    Name = "Private_Subnet_2_IaC"
  }
}



# Create a subnet group for the RDS instance
resource "aws_db_subnet_group" "mydb_subnet_group" {
  name       = "mydb_subnet_group"
  subnet_ids = [
    aws_subnet.private_subnet.id,
    aws_subnet.private_subnet_2.id
  ]

  tags = {
    Name = "App_DB_Subnet_Group_IaC"
  }
}



# Create a security group for the RDS instance
resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.example_vpc.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/27"]  # Adjust as necessary
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "App_RDS_SG_IaC"
  }
}



# Create an RDS instance in the private subnet
resource "aws_db_instance" "mydb" {
  allocated_storage    = 20
  engine               = "mysql"
  instance_class       = "db.t3.micro"
  db_name              = "calc_app_rds_iac"
  username             = "admin"
  password             = "12345678"
  parameter_group_name = "default.mysql8.0"
  publicly_accessible  = false
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name = aws_db_subnet_group.mydb_subnet_group.name

  snapshot_identifier  = "db-state-iac-after-deployment"  # Replace with your snapshot ID from which you want the DB to be created 
  
  # Prevent deletion of the database
  final_snapshot_identifier = "calculator-app-rds-final-snapshot-iac"
  skip_final_snapshot       = false
}

# Output the RDS endpoint
output "rds_endpoint" {
  value = aws_db_instance.mydb.endpoint
}


###############################################################################
# CREATING A TEMPLATE FILE SO TERRAFORM CAN PASS THE rds_endpoint to it
###############################################################################


data "template_file" "userdata" {
  template = file("${path.module}/userdata_for_launch_config.tpl")

  vars = {
    db_endpoint = aws_db_instance.mydb.endpoint
  }
}



##################################################################
# Create a route table for the public subnet
##################################################################

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.example_vpc.id

  route {
    cidr_block = "0.0.0.0/0" 					# Any traffic destined for an address outside the VPC will be directed to the VPC internet gateway
    gateway_id = aws_internet_gateway.igw.id    
  }

  tags = {
    Name = "public_rt_IaC"
  }
}

# Associate the route table with the public subnet
resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}


# Associate the route table with the second public subnet
resource "aws_route_table_association" "public_rt_assoc_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}



##################################################################
# Security Group for the EC2s (CREATED IN THE NEW VPC)
##################################################################

resource "aws_security_group" "firstsec" {
  vpc_id = aws_vpc.example_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "FirstSEC"
  }
}


##################################################################
# Security Group allowing HTTP/HTTPS only for the ALB
##################################################################

resource "aws_security_group" "lb_security_group" {
  vpc_id = aws_vpc.example_vpc.id

  # Allow incoming HTTP traffic
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP traffic"
  }

  # Allow incoming HTTPS traffic
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS traffic"
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic (Ensures that the ELB can reach any required service without restrictions!)"
  }

  tags = {
    Name = "lb_security_group"
  }
}


##################################################################
# TARGET GROUP CREATION FOR ALB 
##################################################################

resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.example_vpc.id

  health_check {
    path                = "/"  # Path to your health_check.html file OR "/" FOR GENERIC ROOT_PATH HEALTH_CHECK
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "WebTargetGroup"
  }
}


##################################################################
# Application Load Balancer (ALB)
##################################################################

# Define the Application Load Balancer
resource "aws_lb" "web_alb" {
  name               = "Application-Load-Balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_security_group.id]
  subnets            = [aws_subnet.public_subnet.id, aws_subnet.public_subnet_2.id]   # We need 2 Subnets for the ALB to work
  
  
  enable_deletion_protection = false

  tags = {
    Name = "web-alb"
  }
}

# Define ALB HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}


## Define ALB HTTPS Listener
#resource "aws_lb_listener" "https" {
#  load_balancer_arn = aws_lb.web_alb.arn
#  port              = 443
#  protocol          = "HTTPS"
#  ssl_policy        = "ELBSecurityPolicy-2016-08"
#  certificate_arn   = var.ssl_certificate_arn
#
#  default_action {
#    type             = "forward"
#    target_group_arn = aws_lb_target_group.web_tg.arn
#  }
#}




##################################################################
# LUNCH_CONFIGURATION FOR THE EC2 IN THE AUTO SCALING GROUP
##################################################################

resource "aws_launch_configuration" "web_server_launch_configuration" {
  name          = "web-server-launch-configuration"
  image_id      = "ami-0583d8c7a9c35822c"    		# Replace with your desired AMI ID
  instance_type = "t2.micro"
  key_name      = "Test.env"
  security_groups = [aws_security_group.firstsec.id]
  
  user_data = data.template_file.userdata.rendered

  root_block_device {
    volume_size = 10
    volume_type = "gp2"
  }
  
  # Ensure the launch configuration is created only after the RDS instance
  depends_on = [aws_db_instance.mydb]
}



##################################################################
# AUTO SCALING GROUP CREATION
##################################################################

resource "aws_autoscaling_group" "web_server_asg" {
  launch_configuration = aws_launch_configuration.web_server_launch_configuration.id
  min_size             = 1
  max_size             = 3
  desired_capacity     = 1
  vpc_zone_identifier  = [aws_subnet.public_subnet.id, aws_subnet.public_subnet_2.id]  # Configure the ASG to deploy EC2s in BOTH subnets

  # Correct EC2 target group ARN here
  target_group_arns    = [aws_lb_target_group.web_tg.arn]

  tag {
    key                 = "Name"
    value               = "WEB_SERVER_IaC"
    propagate_at_launch = true
  }

  health_check_type = "ELB"  # Keep this as "ELB" for ALB/ELB compatibility
 
# Ensure the Auto Scaling Group is created only after the launch configuration
  depends_on = [aws_launch_configuration.web_server_launch_configuration]
}


##################################################################
# CLOUDWATCH ALARM AND SCALING OUT POLICY (CPU above 50% ALARM)
##################################################################

# Define a CloudWatch Alarm
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_high" {
  alarm_name          = "cpu_alarm_high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"
  alarm_description   = "This metric monitors the average CPU utilization and triggers if it goes above 50%."
  actions_enabled     = true
  alarm_actions       = [aws_autoscaling_policy.scale_out_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_server_asg.name
  }
}

# Define the Scaling Policy for Scaling Out
resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale_out_policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.web_server_asg.id
}


##################################################################
# CLOUDWATCH ALARM AND SCALING IN POLICY (CPU below 50% ALARM)
##################################################################

# Define a CloudWatch Alarm for CPU Utilization Below 50%
resource "aws_cloudwatch_metric_alarm" "cpu_alarm_low" {
  alarm_name          = "cpu_alarm_low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"
  alarm_description   = "This metric monitors the average CPU utilization and triggers if it goes below 50%."
  actions_enabled     = true
  alarm_actions       = [aws_autoscaling_policy.scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_server_asg.name
  }
}



# Define the Scaling Policy for Scaling In
resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale_in_policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 120
  autoscaling_group_name = aws_autoscaling_group.web_server_asg.id
}





