U=jasonlee
H="$(getent passwd "$U" | cut -d: -f6)"

# 0. back up first; /data has 113 GB free
# sudo tar -C /home -czf "/data/home-backup-$U-$(date +%F).tgz" "$U"

# 1. end their sessions (shells, tmux, atuin daemon, Lab, nvim)
sudo loginctl terminate-user "$U"; sudo pkill -KILL -u "$U"

# 2. preview what goes: everything in the home except .ssh
sudo find "$H" -mindepth 1 -maxdepth 1 ! -name .ssh

# 3. wipe it, then put back Ubuntu's defaults (.bashrc, .profile, .bash_logout)
sudo find "$H" -mindepth 1 -maxdepth 1 ! -name .ssh -exec rm -rf {} +
sudo cp -r /etc/skel/. "$H"/
sudo chown -R "$U:$U" "$H" && sudo chmod 750 "$H"

# 4. optional: their files on /data (the folder and its ACL stay)
sudo find "/data/people/$U" -mindepth 1 -delete
sudo crontab -r -u "$U" 2>/dev/null
