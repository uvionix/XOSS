#!/bin/bash

# Initialization in the case where the modem power enable GPIO is a regular GPIO
initialize_case_regular_pwr_en_gpio()
{
    # Export the modem power enable GPIO
    regular_gpioNumber="gpio$modem_pwr_en_gpio"
    echo "Exporting GPIO $modem_pwr_en_gpio..."
    gpio_exported=$(ls /sys/class/gpio/ | grep "$regular_gpioNumber" )
    
    if [ ! -z "$gpio_exported" ]
    then
        echo "GPIO $modem_pwr_en_gpio has already been exported"
    else
        echo $modem_pwr_en_gpio > /sys/class/gpio/export
    fi

    if [ $? -eq 0 ]
    then
        # Configure the modem power enable GPIO as output
        echo "Configuring GPIO $modem_pwr_en_gpio as output..."

        configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

        while true
        do
            if [ ! -z "$configured_direction_out" ]
            then
                echo "GPIO $modem_pwr_en_gpio has already been configured as output"
            else
                echo out > /sys/class/gpio/$regular_gpioNumber/direction
            fi

            if [ $? -eq 0 ]
            then
                configured_direction_out=$(cat /sys/class/gpio/$regular_gpioNumber/direction | grep "out")

                if [ ! -z "$configured_direction_out" ]
                then
                    echo "Modem watchdog initializaton successful"
                    initialization_successful=1

                    # Enable modem power if it is disabled
                    gpio_value=$(cat /sys/class/gpio/$regular_gpioNumber/value)
                    if [ $gpio_value -eq 0 ]
                    then
                        echo "Modem power is disabled. Powering ON..."
                        echo 1 > /sys/class/gpio/$regular_gpioNumber/value
                        sleep $wait_after_power_on
                    fi

                    break
                else
                    echo "Configuring GPIO $modem_pwr_en_gpio as output failed! Retrying..."
                fi
            else
                echo "Configuring GPIO $modem_pwr_en_gpio as output failed"
                break
            fi
        done
    else
        echo "Exporting unsuccessful"
    fi
}

# Modem power ON
modem_pwr_on()
{
    echo 1 > /sys/class/gpio/$regular_gpioNumber/value
}

# Modem power OFF
modem_pwr_off()
{
    echo 0 > /sys/class/gpio/$regular_gpioNumber/value
}

### MAIN SCRIPT STARTS HERE ###

# EXPECTED ENVIRONMENT VARIABLES:
# MODEM_NAME                    # Name of the modem used to detect if it is connected
# PWR_ON_DELAY                  # Power on delay after powering off, [sec]
# WAIT_AFTER_PWR_ON             # Wait time after powering on to evaluate the modem status, [sec]
# WAIT_TIME_INCREMENT           # Amount of time added to PWR_ON_DELAY and WAIT_AFTER_PWR_ON upon unsuccessful power cycle, [sec]
# SERVICE_START_DELAY           # Initial delay before starting execution, [sec]
# SAMPLING_PERIOD               # Time between iterations, [sec]
# PWR_EN_GPIO_BASE              # Modem power enable GPIO base value (obtained by examining the file /sys/kernel/debug/gpio and considering gpiochip0)
# PWR_EN_GPIO_OFFSET            # Modem power enable GPIO offset (PWR_EN_GPIO_BASE + PWR_EN_GPIO_OFFSET = modem_power_enable_GPIO_sysfs_value)

# INITIALIZATION

# Check environment variables
if [ -z "$MODEM_NAME" ] ||
   [ -z "$PWR_ON_DELAY" ] ||
   [ -z "$WAIT_AFTER_PWR_ON" ] ||
   [ -z "$WAIT_TIME_INCREMENT" ] ||
   [ -z "$SERVICE_START_DELAY" ] ||
   [ -z "$SAMPLING_PERIOD" ] ||
   [ -z "$PWR_EN_GPIO_BASE" ] ||
   [ -z "$PWR_EN_GPIO_OFFSET" ];
then
    echo "Empty environment variable/s detected during modem watchdog initialization. Aborting modem watchdog..."
    exit 1
fi

power_on_delay_time=$PWR_ON_DELAY
wait_after_power_on=$WAIT_AFTER_PWR_ON
initialization_successful=0
modem_was_connected=0
modem_status_acquired=0
modem_path=""
modem_model=""
prev_modem_state=""
prev_modem_access_tech=""
prev_modem_signal_quality=""
regular_gpioNumber=""

sleep $SERVICE_START_DELAY
echo "Initializing modem watchdog..."
echo "Modem name set to $MODEM_NAME"
echo "Modem power enable GPIO base value set to $PWR_EN_GPIO_BASE"
echo "Modem power enable GPIO offset set to $PWR_EN_GPIO_OFFSET"

# Calculate the modem power enable GPIO sysfs value
modem_pwr_en_gpio=$(($PWR_EN_GPIO_BASE+$PWR_EN_GPIO_OFFSET))
echo "Modem power enable GPIO sysfs value set to $modem_pwr_en_gpio"

# Configure the modem power enable GPIO
initialize_case_regular_pwr_en_gpio

if [ $initialization_successful -eq 0 ]
then
    echo "Failed configuring the modem power enable GPIO! Aborting modem watchdog..."
    exit 1
fi

# Main watchdog loop
while true
do
    # Check if the modem is connected
    modem_connected=$(lsusb | grep -i "$MODEM_NAME")

    if [ ! -z "$modem_connected" ]
    then
        # Modem is connected
        if [ $modem_was_connected -eq 0 ]
        then
            modem_was_connected=1
            echo "Modem connected! Waiting for status from modem manager..."

            # Reset the delay variables to the initial values
            power_on_delay_time=$PWR_ON_DELAY
            wait_after_power_on=$WAIT_AFTER_PWR_ON
        fi

        if [ -z "$modem_path" ]
        then
            modem_path=$(mmcli -L | grep -i "$MODEM_NAME" | awk -F' ' '{print $1}')
        fi

        if [ ! -z "$modem_path" ]
        then
            if [ $modem_status_acquired -eq 0 ]
            then
                modem_status_acquired=1
                modem_model=$(mmcli -L | grep -i "$MODEM_NAME" | awk -F' ' '{print $3}')
                echo "Modem status acquired! Modem model: $modem_model; Modem path: $modem_path"
            fi

            # Get modem state, removing color specifiers
            modem_state=$(mmcli -m $modem_path | grep -i -m1 -A3 "state" | grep -w -m1 state | awk -F': ' '{print $2}' | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g")
            modem_access_tech=$(mmcli -m $modem_path | grep -i -m1 -A3 "state" | grep -w -m1 "access tech" | awk -F': ' '{print $2}')
            modem_signal_quality=$(mmcli -m $modem_path | grep -i -m1 -A3 "state" | grep -w -m1 "signal quality" | awk -F': ' '{print $2}' | awk -F' ' '{print $1}')
            
            if [ ! -z "$modem_state" ] && [ ! -z "$modem_access_tech" ] && [ ! -z "$modem_signal_quality" ];
            then
                if [ "$modem_state" != "$prev_modem_state" ] ||
                   [ "$modem_access_tech" != "$prev_modem_access_tech" ] ||
                   [ "$modem_signal_quality" != "$prev_modem_signal_quality" ];
                then
                    prev_modem_state=$modem_state
                    prev_modem_access_tech=$modem_access_tech
                    prev_modem_signal_quality=$modem_signal_quality

                    echo "Modem state: $modem_state, access tech: $modem_access_tech, signal quality: $modem_signal_quality"
                fi
            fi
        fi
    else
        # Modem is not connected
        modem_was_connected=0
        modem_status_acquired=0
        modem_path=$(mmcli -L | grep -i "$MODEM_NAME" | awk -F' ' '{print $1}') # This line will empty the variable
        echo "Modem disconnected - attempting power cycle..."
        echo "Modem powering OFF..."

        modem_pwr_off

        sleep $power_on_delay_time
        echo "Modem powering ON..."

        modem_pwr_on

        sleep $wait_after_power_on
        echo "Now checking if the modem is connected..."

        # Increment the wait variables for the next iteration if the modem is still not connected
        power_on_delay_time=$((${power_on_delay_time%.*}+${WAIT_TIME_INCREMENT%.*}))
        wait_after_power_on=$((${wait_after_power_on%.*}+${WAIT_TIME_INCREMENT%.*}))
    fi

    sleep $SAMPLING_PERIOD
done
