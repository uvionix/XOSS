#!/usr/bin/env python3

import os, atexit, threading, subprocess
import mavpylink
import mavpylink.cameras
from mavpylink.logger import Logger, LOG_MESSAGES
from time import sleep

SYSTEM_PARAMS_FILE = "/usr/local/bin/xoss-system-parameters.json"
CAMERA_BINARY_EXECUTABLE = "/usr/local/bin/gst-start-camera"

# The values of the bellow variables come from the MAVLINK HEARTBEAT message specification
MAV_TYPE_QUADROTOR = 2
MAV_AUTOPILOT_ARDUPILOTMEGA = 3

# Define exit handlers
def system_reboot_exit_handler():
    print("Rebooting...")
    os.system("(sleep 5; reboot)")

def system_shutdown_exit_handler():
    with open('/dev/kmsg', mode='w') as dmesg:
        p = subprocess.Popen(["echo","MavPylink: System shutting down..."], stdout=dmesg)
        p.communicate()
    
    os.system("(sleep 5; shutdown -h now)")

# Define vehicle-specific class
class Copter(mavpylink.Vehicle):
    """  """

    # Constructor
    def __init__(self):
        # Initialize the base class
        super().__init__(json_params_file=SYSTEM_PARAMS_FILE, MAV_TYPE=MAV_TYPE_QUADROTOR, MAV_AUTOPILOT=MAV_AUTOPILOT_ARDUPILOTMEGA)

        # Get a reference to the system parameters
        self.__system_params = self.get_system_parameters()

        # System reboot thread
        self.__t_reboot = threading.Thread(target=self.__handle_system_reboot_request__,args=())

        # Add a camera
        try:
            # Get the camera log file from the system parameters
            self.__cam_log_file = str(self.__system_params["camera_params"]["LOG_FILE"])

            # Create the logger object and add it to the loggers list of the base class
            self.__cam_logger = Logger(name='CAMERA', log_file=self.__cam_log_file)
            self.append_logger(logger=self.__cam_logger)

            # Create the camera object
            self.__camera = mavpylink.cameras.GstEcam24Cunx(system_params=self.__system_params,
                                                            logger=self.__cam_logger,
                                                            binary_executable=CAMERA_BINARY_EXECUTABLE,
                                                            reboot_thread=self.__t_reboot)

            # Notify the base class that the vehicle has a camera
            self.set_vehicle_has_camera()
        except:
            self.__log_message__(f"{LOG_MESSAGES['MSG_ERR_ADDING_CAMERA']}. {LOG_MESSAGES['MSG_CAMERA_DISABLED']}")
            self.__camera = None

        # Notify the base class that the vehicle has a GPS
        self.set_vehicle_has_gps()

        # Initialize system clocks
        self.__init_system_clocks__()
        
        # TODO: Switch vehicle to RTL mode after a defined timeout when the RTL is started

        self.__RTL_started = False

    # Initialize system clocks
    def __init_system_clocks__(self):
        """  """

        self.__log_message__(f"Setting up static max frequency to CPU, GPU and EMC clocks...")
        p = subprocess.Popen(["jetson_clocks"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        err = p.communicate()[1]

        if err is None or not err.decode():
            # Write the current clocks configuration to the log file
            p = subprocess.Popen(["jetson_clocks","--show"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            out = p.communicate()[0].decode().split('\n')
            if len(out):
                for line in out:
                    if line:
                        self.__log_message__("\t"+line)
        else:
            err = err.decode().strip('\n')
            self.__log_message__(f"Error configuring system clocks ({err})")

    def __call__(self):
        # Start base class threads
        super().__call__()

        # Wait for vehicle connection
        while not self.get_vehicle_connected():
            sleep(2.5)

        # Start the camera
        if (self.__camera is not None) and (not self.get_hmi_device_connected()):
            self.__log_message__(f"{LOG_MESSAGES['MSG_CAMERA_STARTING']}")
            self.__camera.start()

    def __stop__(self):
        # Stop the camera
        if self.__camera is not None and self.__camera.get_camera_started():
            self.__log_message__(f"{LOG_MESSAGES['MSG_CAMERA_STOPPING']}")
            self.__camera.stop()

        # Stop base class threads
        self.stop()
    
    def __handle_system_reboot_request__(self):
        atexit.register(system_reboot_exit_handler)
        self.__log_message__(f"{LOG_MESSAGES['MSG_SYSTEM_REBOOT_REQUESTED']}. {LOG_MESSAGES['MSG_STOPPING_THREADS']}")
        self.__stop__()

    def __handle_system_shutdown_request__(self):
        atexit.register(system_shutdown_exit_handler)
        self.__log_message__(f"{LOG_MESSAGES['MSG_SYSTEM_SHUTDOWN_REQUESTED']}. {LOG_MESSAGES['MSG_STOPPING_THREADS']}")
        self.__stop__()

    def __handle_network_disconnected__(self):
        self.set_vehicle_mode(mode='LOITER')
        if not self.__RTL_started:
            self.__log_message__(f"{LOG_MESSAGES['MSG_STARTING_RTH']}")
            self.__RTL_started = True

    def __handle_network_reconnected__(self):
        if self.__RTL_started:
            self.__log_message__(f"{LOG_MESSAGES['MSG_RTH_STOPPING']}")
            self.__RTL_started = False

    def __handle_camera_rec_trigger_toggle__(self):
        if self.__camera.get_camera_recording():
            self.__camera.stop_recording()
        else:
            self.__camera.start_recording()

# Start execution
xoss = Copter()
xoss()
