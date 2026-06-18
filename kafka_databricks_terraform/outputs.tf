output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.kafka.id
}

output "public_ip" {
  description = "Kafka EC2 public IP"
  value       = aws_instance.kafka.public_ip
}

output "kafka_bootstrap_server" {
  description = "Kafka bootstrap server"
  value       = "${aws_instance.kafka.public_ip}:9092"
}

output "ssh_command" {
  description = "SSH connection command"
  value       = "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.kafka.public_ip}"
}
