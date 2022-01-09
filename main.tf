# We set AWS as the cloud platform to use
provider "aws" {
   region  = "us-east-2"
   access_key = var.access_key
   secret_key = var.secret_key
 }

# We create a new VPC
resource "aws_vpc" "vpc" {
   cidr_block = "192.168.0.0/16"
   instance_tenancy = "default"
   tags = {
      Name = "VPC"
   }
   enable_dns_hostnames = true
}

# We create a public subnet
# Instances will have a dynamic public IP and be accessible via the internet gateway
resource "aws_subnet" "public_subnet" {
   depends_on = [
      aws_vpc.vpc,
   ]
   vpc_id = aws_vpc.vpc.id
   cidr_block = "192.168.0.0/24"
   availability_zone_id = "use2-az1"
   tags = {
      Name = "public-subnet"
   }
   map_public_ip_on_launch = true
}

# We create a private subnet
# Instances will not be accessible via the internet gateway
resource "aws_subnet" "private_subnet" {
   depends_on = [
      aws_vpc.vpc,
   ]
   vpc_id = aws_vpc.vpc.id
   cidr_block = "192.168.1.0/24"
   availability_zone_id = "use2-az1"
   tags = {
      Name = "private-subnet"
   }
}

# We create an internet gateway
# Allows communication between our VPC and the internet
resource "aws_internet_gateway" "internet_gateway" {
   depends_on = [
      aws_vpc.vpc,
   ]
   vpc_id = aws_vpc.vpc.id
   tags = {
      Name = "internet-gateway",
   }
}

# We create a route table with target as our internet gateway and destination as "internet"
# Set of rules used to determine where network traffic is directed
resource "aws_route_table" "IG_route_table" {
   depends_on = [
      aws_vpc.vpc,
      aws_internet_gateway.internet_gateway,
   ]
   vpc_id = aws_vpc.vpc.id
   route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.internet_gateway.id
   }
   tags = {
      Name = "IG-route-table"
   }
}

# We associate our route table to the public subnet
# Makes the subnet public because it has a route to the internet via our internet gateway
resource "aws_route_table_association" "associate_routetable_to_public_subnet" {
   depends_on = [
      aws_subnet.public_subnet,
      aws_route_table.IG_route_table,
   ]
   subnet_id = aws_subnet.public_subnet.id
   route_table_id = aws_route_table.IG_route_table.id
}

# We create an elastic IP 
# A static public IP address that we can assign to any EC2 instance
resource "aws_eip" "elastic_ip" {
   vpc = true
}

# We create a NAT gateway with a required public IP
# Lives in a public subnet and prevents externally initiated traffic to our private subnet
# Allows initiated outbound traffic to the Internet or other AWS services
resource "aws_nat_gateway" "nat_gateway" {
   depends_on = [
      aws_subnet.public_subnet,
      aws_eip.elastic_ip,
   ]
   allocation_id = aws_eip.elastic_ip.id
   subnet_id = aws_subnet.public_subnet.id
   tags = {
      Name = "nat-gateway"
   }
}

# We create a route table with target as NAT gateway and destination as "internet"
# Set of rules used to determine where network traffic is directed
resource "aws_route_table" "NAT_route_table" {
   depends_on = [
      aws_vpc.vpc,
      aws_nat_gateway.nat_gateway,
   ]
   vpc_id = aws_vpc.vpc.id
   route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_nat_gateway.nat_gateway.id
   }
   tags = {
      Name = "NAT-route-table"
   }
}

# We associate our route table to the private subnet
# Keeps the subnet private because it has a route to the internet via our NAT gateway 
resource "aws_route_table_association" "associate_routetable_to_private_subnet" {
   depends_on = [
      aws_subnet.private_subnet,
      aws_route_table.NAT_route_table,
   ]
   subnet_id = aws_subnet.private_subnet.id
   route_table_id = aws_route_table.NAT_route_table.id
}

# We create a security group for SSH traffic
# EC2 instances' firewall that controls incoming and outgoing traffic
resource "aws_security_group" "sg_bastion_host" {
   depends_on = [
      aws_vpc.vpc,
   ]
   name = "sg bastion host"
   description = "bastion host security group"
   vpc_id = aws_vpc.vpc.id
   ingress {
      description = "allow ssh"
      from_port = 22
      to_port = 22
      protocol = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
   }
   egress {
      from_port = 0
      to_port = 0
      protocol = "-1"
      cidr_blocks = ["0.0.0.0/0"]
   }
   tags = {
      Name = "sg bastion host"
   }
}

# We create an elastic IP 
# A static public IP address that we can assign to our bastion host
resource "aws_eip" "bastion_elastic_ip" {
   vpc = true
}

# We create an ssh key using the RSA algorithm with 4096 rsa bits
# The ssh key always includes the public and the private key
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# We upload the public key of our created ssh key to AWS
resource "aws_key_pair" "public_ssh_key" {
  key_name   = var.public_key_name
  public_key = tls_private_key.ssh_key.public_key_openssh

   depends_on = [tls_private_key.ssh_key]
}

# We save our public key at our specified path.
# Can upload on remote server for ssh encryption
resource "local_file" "save_public_key" {
  content = tls_private_key.ssh_key.public_key_openssh 
  filename = "${var.key_path}${var.public_key_name}.pem"
}

# We save our private key at our specified path.
# Allows private key instead of a password to securely access our instances
resource "local_file" "save_private_key" {
  content = tls_private_key.ssh_key.private_key_pem
  filename = "${var.key_path}${var.private_key_name}.pem"
}

# We create a bastion host
# Allows SSH into instances in private subnet
resource "aws_instance" "bastion_host" {
   depends_on = [
      aws_security_group.sg_bastion_host,
   ]
   ami = "ami-077e31c4939f6a2f3"
   instance_type = "t2.micro"
   key_name = aws_key_pair.public_ssh_key.key_name
   vpc_security_group_ids = [aws_security_group.sg_bastion_host.id]
   subnet_id = aws_subnet.public_subnet.id
   tags = {
      Name = "bastion host"
   }
   provisioner "file" {
    source      = "${var.key_path}${var.private_key_name}.pem"
    destination = "/home/ec2-user/private_ssh_key.pem"

    connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.ssh_key.private_key_pem
    host     = aws_instance.bastion_host.public_ip
    }
  }
}

# We associate the elastic ip to our bastion host
resource "aws_eip_association" "bastion_eip_association" {
  instance_id   = aws_instance.bastion_host.id
  allocation_id = aws_eip.bastion_elastic_ip.id
}

# We create a security group for our wordpress instance
resource "aws_security_group" "sg_wordpress" {
  depends_on = [
    aws_vpc.vpc,
  ]

  name        = "sg wordpress"
  description = "Allow http inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "allow TCP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${aws_eip.bastion_elastic_ip.public_ip}/32"] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# We create our wordpress instance in public subnet
resource "aws_instance" "wordpress" {
  depends_on = [
    aws_security_group.sg_wordpress,
    aws_instance.mysql
  ]
  ami = "ami-077e31c4939f6a2f3"
  instance_type = "t2.micro"
  key_name = aws_key_pair.public_ssh_key.key_name
  vpc_security_group_ids = [aws_security_group.sg_wordpress.id]
  subnet_id = aws_subnet.public_subnet.id
  user_data = <<EOF
            #! /bin/bash
            yum update
            yum install docker -y
            systemctl restart docker
            systemctl enable docker
            docker pull wordpress
            docker run --name wordpress -p 80:80 -e WORDPRESS_DB_HOST=${aws_instance.mysql.private_ip} \
            -e WORDPRESS_DB_USER=root -e WORDPRESS_DB_PASSWORD=root -e WORDPRESS_DB_NAME=wordpressdb -d wordpress
  EOF

  tags = {
      Name = "wordpress"
  }
}

# We create an elastic IP for our wordpress server
# A static public IP address that we can assign to our bastion host
resource "aws_eip" "wordpress_elastic_ip" {
   vpc = true
}

# We associate the elastic ip to our wordpress server
resource "aws_eip_association" "wordpress_eip_association" {
  instance_id   = aws_instance.wordpress.id
  allocation_id = aws_eip.wordpress_elastic_ip.id
}

# We create a security group for our mysql instance
resource "aws_security_group" "sg_mysql" {
  depends_on = [
    aws_vpc.vpc,
  ]
  name        = "sg mysql"
  description = "Allow mysql inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "allow TCP"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.sg_wordpress.id]
  }

  ingress {
    description = "allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${aws_eip.bastion_elastic_ip.public_ip}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# We create our mysql instance in the private subnet
resource "aws_instance" "mysql" {
  depends_on = [
    aws_security_group.sg_mysql,
    aws_nat_gateway.nat_gateway,
    aws_route_table_association.associate_routetable_to_private_subnet,
  ]
  ami = "ami-077e31c4939f6a2f3"
  instance_type = "t2.micro"
  key_name = aws_key_pair.public_ssh_key.key_name
  vpc_security_group_ids = [aws_security_group.sg_mysql.id]
  subnet_id = aws_subnet.private_subnet.id
  user_data = file("configure_mysql.sh")
  tags = {
      Name = "mysql-instance"
  }
}

# We save our wordpress and bastion host public ip in a file.
resource "local_file" "ip_addresses" {
  content = <<EOF
            Wordpress public ip address: ${aws_eip.wordpress_elastic_ip.public_ip}
            Wordpress private ip address: ${aws_instance.wordpress.private_ip}
            Bastion host public ip address: ${aws_eip.bastion_elastic_ip.public_ip}
            Bastion host private ip address: ${aws_instance.bastion_host.private_ip}
            Mysql private ip address: ${aws_instance.mysql.private_ip}
  EOF
  filename = "${var.key_path}ip_addresses.txt"
}
