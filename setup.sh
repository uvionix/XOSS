#!/bin/bash

# First-time setup script for the XOSS UAV, installing all necessary files and dependencies

# Get the logged in username
usr=$(logname)

echo "--------------------------------------------------------------------------------"
echo "Copying XOSS source files ..."
echo "--------------------------------------------------------------------------------"

# Copy the XOSS source files to their respective locations
src_path=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd $src_path
sed -i 's/%u/'"$usr"'/gi' xoss-system-parameters.json
sed -i 's/%u/'"$usr"'/gi' ecam24cunx.json
cp ecam24cunx.json /usr/local/bin/
cp xoss-system-parameters.json /usr/local/bin/
cp xoss.py /usr/local/bin/
cp modem-watchdog.sh /usr/local/bin/
cp mavpylink.service /etc/systemd/system/

if [ ! $? -eq 0 ]
then
        # Error occured
        exit 1
fi

mkdir -p /home/$usr/uvx
cp update.sh /home/$usr/uvx/xoss-update.sh
chown $usr /home/$usr/uvx/xoss-update.sh
chown $usr /home/$usr/uvx

echo "--------------------------------------------------------------------------------"
echo "Installing git ..."
echo "--------------------------------------------------------------------------------"
apt-get update
sleep 2
apt-get -y install git

echo "--------------------------------------------------------------------------------"
echo "Getting source repositories from the UVX git server ..."
echo "--------------------------------------------------------------------------------"
sleep 2
mkdir -p /home/$usr/Repos
cd /home/$usr/Repos

repo_exists=$(ls | grep "Jetson_Nano_Binaries")
if [ ! -z "$repo_exists" ]
then
        rm -d -rf Jetson_Nano_Binaries
fi

repo_exists=$(ls | grep "mavpylink")
if [ ! -z "$repo_exists" ]
then
        rm -d -rf mavpylink
fi

git clone https://github.com/uvionix/Jetson_Nano_Binaries.git
git clone https://github.com/uvionix/mavpylink.git

if [ ! $? -eq 0 ]
then
        # Clone error occured
        rm -d -rf Jetson_Nano_Binaries
        rm -d -rf mavpylink
        exit 1
fi

echo "--------------------------------------------------------------------------------"
echo "Installing python ..."
echo "--------------------------------------------------------------------------------"
apt-get install python
apt-get install python3

echo "--------------------------------------------------------------------------------"
echo "Installing python-pip, python-dev, screen, python-wxgtk4.0, python-lxml ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt-get -y install python-pip
apt-get -y install python-dev
apt-get -y install screen
apt-get -y install python-wxgtk4.0
apt-get -y install python-lxml

echo "--------------------------------------------------------------------------------"
echo "Installing future, pyserial ..."
echo "--------------------------------------------------------------------------------"
sleep 2
sudo -H pip install future pyserial

echo "--------------------------------------------------------------------------------"
echo "Installing OpenVPN ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt-get -y install openvpn

echo "--------------------------------------------------------------------------------"
echo "Installing pymavlink ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt-get -y install libxml2-dev
apt-get -y install libxslt-dev
apt-get -y install python3-pip
apt install python3-serial
sudo -H pip3 install pymavlink

echo "--------------------------------------------------------------------------------"
echo "Installing MAVProxy ..."
echo "--------------------------------------------------------------------------------"
sleep 2
sudo -H pip3 install MAVProxy

echo "--------------------------------------------------------------------------------"
echo "Installing Tkinter ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt-get -y install python3-tk

echo "--------------------------------------------------------------------------------"
echo "Installing Node.js, npm, express, body-parser, ws, ejs ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt -y install nodejs
apt -y install npm
npm install -g npm@3.10.10
npm install -g express --save
npm install -g body-parser --save
npm install -g ws --save
npm install -g ejs --save

echo "--------------------------------------------------------------------------------"
echo "Installing libraries libtbb-dev and libatlas-base-dev ..."
echo "--------------------------------------------------------------------------------"
sleep 2
apt -y install libtbb-dev
apt-get -y install libatlas-base-dev

echo "--------------------------------------------------------------------------------"
echo "Stopping and disabling the nvgetty service ..."
echo "--------------------------------------------------------------------------------"
sleep 2
systemctl stop nvgetty
systemctl disable nvgetty

echo "--------------------------------------------------------------------------------"
echo "Changing user permissions for" "$usr" "..."
echo "--------------------------------------------------------------------------------"
sleep 2
usermod -a -G tty "$usr"
usermod -a -G dialout "$usr"
chmod 666 /dev/ttyTHS1

echo "--------------------------------------------------------------------------------"
echo "Installing MavPylink ..."
echo "--------------------------------------------------------------------------------"
cd /home/$usr/Repos
sleep 2
./mavpylink/setup.sh

if [ ! $? -eq 0 ]
then
        echo "Error installing MavPylink. Aborting!"
        cd /home/$usr/Repos
        rm -d -rf Jetson_Nano_Binaries
        rm -d -rf mavpylink
        exit 1
fi

echo "--------------------------------------------------------------------------------"
echo "Copying camera binary files ..."
echo "--------------------------------------------------------------------------------"
cd /home/$usr/Repos
sleep 2
cp Jetson_Nano_Binaries/gst-camera/gst-start-camera /usr/local/bin/
cp Jetson_Nano_Binaries/gst-camera/libmeshflow.so /usr/lib/aarch64-linux-gnu/tegra/

echo "Removing downloaded repositories..."
echo "--------------------------------------------------------------------------------"
sleep 2
cd /home/$usr/Repos
rm -d -rf Jetson_Nano_Binaries
rm -d -rf mavpylink

echo "Revealing location of cuda libraries..."
echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf.d/nvidia-tegra.conf
ldconfig

echo "Configuration successful!"
read -n 1 -s -r -p "Press any key to reboot the system ..."
echo ""
echo "Rebooting ..."
sleep 2
reboot
