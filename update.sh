#!/bin/bash

echo "Starting XOSS update script..."

# Get the logged-in username
usr=$(logname)

# Create the download directory for the XOSS repository
mkdir -p /home/$usr/Repos
cd /home/$usr/Repos

# Remove previous repository versions
repo_exists=$(ls | grep "Jetson_Nano_Binaries")
if [ ! -z "$repo_exists" ]
then
	rm -d -rf Jetson_Nano_Binaries
fi

repo_exists=$(ls | grep "XOSS")
if [ ! -z "$repo_exists" ]
then
	rm -d -rf XOSS
fi

# Clone the source repos
echo "Downloading source repositories..."
git clone -q https://github.com/uvionix/Jetson_Nano_Binaries.git
git clone -q https://github.com/uvionix/XOSS.git

if [ ! $? -eq 0 ]
then
    # Clone error occured
    rm -d -rf Jetson_Nano_Binaries
    rm -d -rf XOSS
    exit 1
fi

# Get the MavPylink installation directory
mavpylink_install_dir=$(python3 -q -c "import importlib.util; print(importlib.util.find_spec(name='mavpylink').submodule_search_locations[0])")

if [ ! $? -eq 0 ]
then
    echo "Error obtaining the MavPylink installation directory. Aborting!"
    rm -d -rf Jetson_Nano_Binaries
    rm -d -rf XOSS
    exit 1
fi

# Update MavPylink
$mavpylink_install_dir/shell_scripts/update_check.sh

if [ ! $? -eq 0 ]
then
    echo "Error updating MavPylink. Aborting!"
    rm -d -rf /home/$usr/Repos/Jetson_Nano_Binaries
    rm -d -rf /home/$usr/Repos/XOSS
    exit 1
fi

# Copy the old files within a temporary directory
echo "Fetching old XOSS files..."
cd /home/$usr/Repos
mkdir -p XOSS/old
cp /usr/local/bin/ecam24cunx.json /usr/local/bin/xoss-system-parameters.json /usr/local/bin/xoss.py /usr/local/bin/modem-watchdog.sh /etc/systemd/system/mavpylink.service XOSS/old/

if [ ! $? -eq 0 ]
then
    echo "Aborting!"
    rm -d -rf Jetson_Nano_Binaries
    rm -d -rf XOSS
    exit 1
fi

# Update the camera binary files
echo "Updating the camera binary files..."
sudo cp Jetson_Nano_Binaries/gst-camera/gst-start-camera /usr/local/bin/
sudo cp Jetson_Nano_Binaries/gst-camera/libmeshflow.so /usr/lib/aarch64-linux-gnu/tegra/

# Generate the patch file
echo "Generating patch file..."
cd XOSS
diff -Naur --exclude=.git --exclude=.gitignore --exclude=old --exclude=*.patch --exclude=update.sh --exclude=setup.sh --exclude=*.md old . > xoss.patch
diff_exit_status=$?

if [ $diff_exit_status -eq 1 ]
then
    # Differences found - patching is required
    echo "Patching XOSS..."
    cd old
    patch --dry-run --input=/home/$usr/Repos/XOSS/xoss.patch
    patch --input=/home/$usr/Repos/XOSS/xoss.patch

    # Copy the patched files to their original locations
    sudo cp ecam24cunx.json /usr/local/bin/
    sudo cp xoss-system-parameters.json /usr/local/bin/
    sudo cp xoss.py /usr/local/bin/
    sudo cp modem-watchdog.sh /usr/local/bin/
    sudo cp mavpylink.service /etc/systemd/system/
    sudo systemctl daemon-reload

    echo "Update successful!"
else
    if [ $diff_exit_status -eq 0 ]
    then
        echo "Files are identical. No patching needed!"
    else
        echo "Error generating patch file. Aborting!"
    fi
fi

# Remove the downloaded repositories
cd /home/$usr/Repos
rm -d -rf Jetson_Nano_Binaries
rm -d -rf XOSS
