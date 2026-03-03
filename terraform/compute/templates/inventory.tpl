[vmq_nodes]
%{ for i, node in vmq_nodes ~}
${node.private_ip} ansible_host=${node.private_ip} ansible_user=ec2-user node_index=${i + 1} nodename=VerneMQ@${node.private_ip}
%{ endfor ~}

[bench_nodes]
%{ for i, node in bench_nodes ~}
${node.private_ip} ansible_host=${node.private_ip} ansible_user=ec2-user node_index=${i + 1}
%{ endfor ~}

[monitor]
${monitor_ip} ansible_host=${monitor_ip} ansible_user=ec2-user

[private:children]
vmq_nodes
bench_nodes

[private:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o ProxyJump=ec2-user@${monitor_ip}

[monitor:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no

[all:vars]
%{ if lb_enabled ~}
lb_host=${lb_dns_name}
%{ endif ~}
%{ if auth_enabled ~}
bench_mqtt_username=${bench_mqtt_username}
bench_mqtt_password=${bench_mqtt_password}
%{ endif ~}
