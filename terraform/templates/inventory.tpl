[vmq_nodes]
%{ for i, node in vmq_nodes ~}
${node.private_ip} ansible_host=${node.private_ip} ansible_user=ec2-user node_index=${i + 1} nodename=VerneMQ@${node.private_ip}
%{ endfor ~}

[bench_nodes]
%{ for i, node in bench_nodes ~}
${node.private_ip} ansible_host=${node.private_ip} ansible_user=ec2-user node_index=${i + 1}
%{ endfor ~}

[monitor]
${monitor.public_ip} ansible_host=${monitor.public_ip} ansible_user=ec2-user

[private:children]
vmq_nodes
bench_nodes

[private:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o ProxyJump=ec2-user@${monitor.public_ip}

[monitor:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no
