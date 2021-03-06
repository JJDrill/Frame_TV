#!/bin/sh
export PGPASSWORD="password"

# Set the GPIO pin number the motion sensor is connected to
GPIO="15"

# How often we check the staus of the TV
TvStatusCheck=5
TV_SCHEDULE_CHECK=50
ON_OFF_SLEEP=10

DB_NAME="frame_tv_db"
DB_USER="postgres"
TV_Mode_Query="SELECT setting_value FROM app_config WHERE setting_name='TV Mode'"
Tv_Off_Check_Query="SELECT setting_value FROM app_config WHERE setting_name = 'TV Timeout'"
Tv_Off_Threshold_Query="SELECT setting_value FROM app_config WHERE setting_name = 'TV Timeout Motion Threshold'"
MOTION_SENSITIVITY_QUERY="SELECT setting_value FROM app_config WHERE setting_name = 'Motion Sensitivity'"

# TV Activity Wait
# Wait time to give the TV some rest after performing some CEC activity
CEC_Wait=1

cleanup()
{
	printf "\nCleaning up!\n"
	echo "$GPIO" > /sys/class/gpio/unexport
	exit
}
trap cleanup 1 2 3 6

getTvPowerStatus()
{
	status=$( echo pow 0 | cec-client -s -d 1 | grep "power status:" )

	if [ "$status" = "power status: on" ]; then
		echo "on"
	elif [ "$status" = "power status: standby" ]; then
		echo "standby"
	else
		echo "Status undefined: $status"
	fi
}

setTvPower()
{
	if [ "$1" = "on" ]; then
		echo on 0 | cec-client -s -d 1
	elif [ "$1" = "standby" ]; then
		echo standby 0 | cec-client -s -d 1
	else
		echo "Power undefined: $1"
	fi
}

getMotionStatus()
{
	status=$( cat /sys/class/gpio/gpio$GPIO/value )

	if [ "$status" = "0" ]; then
		echo "No Motion"
	else
		echo "Motion"
	fi
}

logDbStatus()
{
	QUERY="INSERT INTO logs (time_stamp, activity, description) VALUES ('$( date '+%Y-%m-%d %H:%M:%S' )', '$1', '$2')"
	psql -c "$QUERY" $DB_NAME $DB_USER
}

getCurrentSchedule()
{
	currentMinute=$(date +%M)

	if   [ $currentMinute -lt "15" ]; then M=00
	elif [ $currentMinute -lt "30" ]; then M=15
	elif [ $currentMinute -lt "45" ]; then M=30
	else M=45
	fi

	currentDay=$(date +%A)
	currentTime=$(date +%H):$M:00
	
	QUERY="SELECT tv_state FROM schedule WHERE day='$currentDay' and time_range='$currentTime'"
	schedule=`psql -tc "$QUERY" $DB_NAME $DB_USER`
	
	echo $schedule
}

# Set up GPIO and set to input
echo "$GPIO" > /sys/class/gpio/export
echo "in" > /sys/class/gpio/gpio$GPIO/direction

motionCount=0
motionTotal=0
FIRST_RUN=true
# set this to 60 at first so we get our schedule for the script start
TV_SCHEDULE_COUNT=100
TV_SCHEDULE=""
UpdateDBSettings=30
UpdateDBSettingsCount=$UpdateDBSettings

while true; do
	# Check if we should update all settings from DB
	if [ $UpdateDBSettingsCount -ge $UpdateDBSettings ]; then
		TV_MODE=`psql -tc "$TV_Mode_Query" $DB_NAME $DB_USER`
		Tv_Off_Check=`psql -tc "$Tv_Off_Check_Query" $DB_NAME $DB_USER`
		Tv_Off_Threshold=`psql -tc "$Tv_Off_Threshold_Query" $DB_NAME $DB_USER`
		MOTION_SENSITIVITY=`psql -tc "$MOTION_SENSITIVITY_QUERY" $DB_NAME $DB_USER`
		UpdateDBSettingsCount=0

		echo --------------------------------------
		echo TV_MODE: $TV_MODE
		echo Tv_Off_Check: $Tv_Off_Check
		echo Tv_Off_Threshold: $Tv_Off_Threshold
		echo Motion Sensitivity: $MOTION_SENSITIVITY
		echo --------------------------------------
	else
		UpdateDBSettingsCount=$(($UpdateDBSettingsCount + 1))
	fi

	if [ $TV_MODE = "Static_On" ]; then
		if [ "$TV_SCHEDULE" != "ON" ]; then
			logDbStatus "MODE" "Changed to TV always on"
			tvScheduleChanged="true"
		fi
		TV_SCHEDULE="ON"
		
	elif [ $TV_MODE = "Static_Off" ]; then
		if [ "$TV_SCHEDULE" != "OFF" ]; then
			logDbStatus "MODE" "Changed to TV always off"
			tvScheduleChanged="true"
		fi
		TV_SCHEDULE="OFF"
		
	elif [ $TV_MODE = "Scheduled" ]; then

		if [ $TV_SCHEDULE_COUNT -ge $TV_SCHEDULE_CHECK ]; then
			oldSchedule=$TV_SCHEDULE
			TV_SCHEDULE=$( getCurrentSchedule )
			echo TV_Schedule: $TV_SCHEDULE
			
			if [ "$TV_SCHEDULE" != "$oldSchedule" ]; then
				logDbStatus "SCHEDULE" "Changed to $TV_SCHEDULE"
				tvScheduleChanged="true"
			fi
			
			TV_SCHEDULE_COUNT=0
		fi
	fi

	if [ $TV_SCHEDULE = 'ON' ]; then
		tvStatus=$( getTvPowerStatus )

		if [ "$tvStatus" = "standby" ]; then
			motionCount=0
			motionTotal=0
			logDbStatus "TV ON" "TV turned on per schedule."
			echo Turning TV On - $(date +"%R")
			setTvPower "on"
		fi

		sleep $ON_OFF_SLEEP
		TV_SCHEDULE_COUNT=$(($TV_SCHEDULE_COUNT + $ON_OFF_SLEEP))
		# force update of DB settings
		UpdateDBSettingsCount=$UpdateDBSettings
		continue
	fi

	if [ $TV_SCHEDULE = "OFF" ]; then
		if [ "$tvScheduleChanged" = "true" ]; then
			tvScheduleChanged="false"
			echo Turning TV Off - $(date +"%R")
			logDbStatus "TV OFF" "TV turned off per schedule."
			setTvPower "standby"
			echo
		fi

		sleep $ON_OFF_SLEEP
		TV_SCHEDULE_COUNT=$(($TV_SCHEDULE_COUNT + $ON_OFF_SLEEP))
		# force update of DB settings
		UpdateDBSettingsCount=$UpdateDBSettings
		continue
	fi

	# TV state is MOTION
	MotionStatus=$( getMotionStatus )
	motionTotal=$(($motionTotal + 1))

	if [ "$MotionStatus" = "Motion" ]; then
		sentivitityReached=false
		start=$( date +"%s%N" )
		printf "In motion detected loop."

		while [ "$MotionStatus" = "Motion" ] ; do
			sleep 0.5
			totalTime=$((($(date +"%s%N") - $start)/1000000))

			if [ $totalTime -gt $MOTION_SENSITIVITY ]; then
				sentivitityReached=true
				break
			fi

			MotionStatus=$( getMotionStatus )
			printf "."
		done

		printf "\n"
		totalTime=$((($(date +"%s%N") - $start)/1000000))
		echo Motion detected - $(date '+%Y-%m-%d %H:%M:%S'): Total Seconds: $totalTime

		# If we did not reach out sensitivity metric we won't count this as motion detected
		if [ $sentivitityReached = "false" ]; then
			logDbStatus "MOTION" "Motion of $totalTime milliseconds detected but did not reach sensitivity of $MOTION_SENSITIVITY milliseconds."
			continue
		fi

		motionCount=$(($motionCount + 1))
		logDbStatus "MOTION" "Motion detected after $motionTotal seconds. (Count: $motionCount - Duration: $totalTime)"
		tvStatus=$( getTvPowerStatus )

		if [ "$tvStatus" = "standby" ]; then
			motionCount=0
			motionTotal=0
			logDbStatus "TV ON" "TV turned on becuase of motion dectection."
			echo Turning TV On - $(date +"%R"): $motionTotal / $motionCount
			setTvPower "on"
			echo
			sleep $CEC_Wait
		fi
	fi

	if [ "$motionTotal" -ge "$Tv_Off_Check" ]; then
		echo "\nChecking if TV should be turned off"
		tvStatus=$( getTvPowerStatus )

		if [ "$tvStatus" = "on" ]; then

			if [ $motionCount -le $Tv_Off_Threshold ]; then
				echo Turning TV Off - $(date +"%R"): $motionTotal / $motionCount
				logDbStatus "TV OFF" "TV turned off becuase of lack of motion."
				setTvPower "standby"
				echo
				sleep $CEC_Wait
			fi
		fi
		motionCount=0
		motionTotal=0

		# Get updated motion settings
		QUERY="SELECT setting_value FROM app_config WHERE setting_name = 'TV Timeout'"
		Tv_Off_Check=`psql -tc "$QUERY" $DB_NAME $DB_USER`

		QUERY="SELECT setting_value FROM app_config WHERE setting_name = 'TV Timeout Motion Threshold'"
		Tv_Off_Threshold=`psql -tc "$QUERY" $DB_NAME $DB_USER`
		echo "Motion metrics updated. Tv_Off_Check - $Tv_Off_Check / Tv_Off_Threshold - $Tv_Off_Threshold"
	fi

	sleep 1.0
	TV_SCHEDULE_COUNT=$(($TV_SCHEDULE_COUNT + 1))
done
