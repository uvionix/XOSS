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
        p = subprocess.Popen(["echo","System shutting down..."], stdout=dmesg)
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
            self.__cam_logger = Logger(name='CAMERA', log_file=self.__cam_log_file, \
                                       http_logging=self.get_node_server_enabled(), \
                                       http_log_port=self.get_node_server_log_msg_port())
            self.append_logger(logger=self.__cam_logger)

            # Create the camera object
            self.__camera = mavpylink.cameras.GstEcam24Cunx(system_params=self.__system_params,
                                                            logger=self.__cam_logger,
                                                            binary_executable=CAMERA_BINARY_EXECUTABLE,
                                                            reboot_thread=self.__t_reboot)

            # Notify the base class that the vehicle has a camera
            self.set_vehicle_has_camera(camera_handle=self.__camera)
        except:
            self.__log_message__(f"{LOG_MESSAGES['MSG_ERR_ADDING_CAMERA']}. {LOG_MESSAGES['MSG_CAMERA_DISABLED']}")
            self.__camera = None

        # Notify the base class that the vehicle has a GPS
        self.set_vehicle_has_gps()

        # Initialize system clocks
        self.__init_system_clocks__()

        # Initialize the camera auto-start
        try:
            self.__camera_auto_start = bool(self.__system_params["camera_params"]["CAMERA_AUTOSTART"])
        except:
            self.__camera_auto_start = False

        if not self.__camera_auto_start:
            self.__log_message__(f"{LOG_MESSAGES['MSG_CAMERA_AUTOSTART_DISABLED']}")

        # Initialize the network failsafe system variables
        try:
            self.__network_failsafe_enabled = bool(self.__system_params["network_watchdog_params"]["NETWORK_FAILSAFE_ENABLED"])
            self.__network_failsafe_mode_sequence = self.__system_params["network_watchdog_params"]["NETWORK_FAILSAFE_MODES_SEQUENCE"]
        except:
            self.__network_failsafe_enabled = False
            self.__network_failsafe_mode_sequence = []

        self.__network_failsafe_final_mode = None
        try:
            self.__network_failsafe_final_mode = str(self.__network_failsafe_mode_sequence[-2])
        except:
            pass

        self.__network_failsafe_started = False
        self.__stop_network_failsafe = threading.Event()

    # Initialize system clocks
    def __init_system_clocks__(self):
        """ Sets up static max frequency to CPU, GPU and EMC clocks by invoking the command "jetson_clocks" """

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
        if (self.__camera is not None) and (not self.get_hmi_device_connected()) and self.__camera_auto_start:
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
        if self.__camera is not None:
            self.__camera.stop_streaming()
        
        if (self.__network_failsafe_enabled) and \
           (self.__network_failsafe_final_mode != None) and \
           (self.get_vehicle_mode() != self.__network_failsafe_final_mode) and \
           (not self.__network_failsafe_started):
            self.__stop_network_failsafe.clear()
            self.__t_network_failsafe = threading.Thread(target=self.__network_failsafe__,args=())
            self.__t_network_failsafe.start()

    def __handle_network_reconnected__(self):
        if self.__network_failsafe_started:
            self.__stop_network_failsafe.set()

    def __network_failsafe__(self):
        switch_seq = self.__network_failsafe_mode_sequence.copy()
        sample_time = 5.0
        
        try:
            switch_mode = str(switch_seq.pop(0))
            switch_timeout = int(switch_seq.pop(0))
            self.__log_message__("Starting network failsafe sequence...")
            self.__network_failsafe_started = True
        except:
            return

        while not self.__stop_network_failsafe.is_set():
            if switch_timeout <= 0.0:
                self.set_vehicle_mode(mode=switch_mode)

                try:
                    switch_mode = str(switch_seq.pop(0))
                    switch_timeout = int(switch_seq.pop(0))
                except:
                    self.__log_message__("Network failsafe sequence completed")
                    self.__network_failsafe_started = False
                    break

            sleep(sample_time)
            switch_timeout -= sample_time
        else:
            self.__log_message__("Network failsafe sequence stopped")
            self.__network_failsafe_started = False

    def __handle_camera_rec_trigger_toggle__(self):
        if self.__camera is not None:
            if not self.__camera.get_camera_started():
                self.__log_message__(f"{LOG_MESSAGES['MSG_CAMERA_STARTING']}")
                self.__camera.start()
            else:
                if self.__camera.get_camera_recording():
                    self.__camera.stop_recording()
                else:
                    self.__camera.start_recording()

    def __handle_mavproxy_peer_connected__(self):
        if (self.__camera is not None) and self.get_hmi_device_connected() and (not self.__camera.get_camera_started()):
            self.__log_message__(f"{LOG_MESSAGES['MSG_CAMERA_STARTING']}")
            self.__camera.start()

            while not self.__camera.get_camera_started():
                sleep(2.5)

            # Wait for the camera to initialize
            sleep(7.0)

        if self.__camera is not None and self.__camera.get_camera_started():
            self.__camera.start_streaming()

    def __handle_mavproxy_peer_disconnected__(self):
        if self.__camera is not None and self.__camera.get_camera_started():
            self.__camera.stop_streaming()

# Start execution
xoss = Copter()
xoss()
