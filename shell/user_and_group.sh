# create group quant
sudo groupadd quant
# add user to groups
sudo usermod -aG quant alice

# file / directory access
sudo mkdir /data/quant
sudo chown root:quant /data/quant
sudo chmod 2775 /data/quant

# umask 002
sudo apt install acl
getfacl /data/quant
sudo setfacl -m u::rwx,g:quant:rwx,o::--- ./quant
sudo setfacl -d -m u::rwx,g:quant:rwx,o::--- ./quant

# check user group
groups alice
id alice

# All users
cut -d: -f1 /etc/passwd

# Human/login users only (UID >= 1000)
awk -F: '$3 >= 1000 {print $1}' /etc/passwd

# Currently logged-in users
who

# All groups
cut -d: -f1 /etc/group

# Groups and their members
getent group

# individual folders set up
sudo chown royceyan:royceyan /data/people/royceyan/
# sudo chmod 700 /data/people/royceyan/  -->redundant bcs of next
sudo setfacl -d -m u::rwx,g::---,o::--- /data/people/royceyan/
sudo ln -sT /data/people/royceyan /home/royceyan/hub
